// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IYieldStrategy} from "../YieldManager.sol";

// Uniswap V4 Core imports
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

// Uniswap V4 Periphery imports
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";

/// @notice Interface for YieldManager contract
interface IYieldManager {
    struct WithdrawalState {
        uint256 accountId;
        address strategy;
        IERC20 token;
        uint128 amount;
        address transferTo;
        bool consumed;
    }

    function getWithdrawalState(
        uint256 accountId
    ) external view returns (WithdrawalState memory);
    function getPosition(
        IERC20 token,
        address strategy
    )
        external
        view
        returns (address strategyAddr, uint128 amount, bytes memory positionData);
    function completeForceWithdrawal(
        uint256 accountId,
        address strategy,
        IERC20 token,
        uint128 amount
    ) external returns (uint128 principalWithdrawn);
}

/// @notice Simplified swap router interface
interface ISwapRouter {
    struct SwapParams {
        Currency currencyIn;
        Currency currencyOut;
        uint24 fee;
        int24 tickSpacing;
        IHooks hooks;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function swap(SwapParams calldata params) external returns (uint256 amountOut);
}

/// @title UniswapV4Strategy
/// @notice Yield strategy for Uniswap V4 concentrated liquidity provision
/// @dev Universal strategy - supports any Uniswap V4 pool
contract UniswapV4Strategy {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════════
    //                                   ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════

    error InsufficientBalance();
    error InvalidPosition();
    error WrongPool();
    error SwapFailed();
    error SlippageExceeded();

    // ═══════════════════════════════════════════════════════════════════════════════
    //                              STORAGE & TYPES
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Position data stored in YieldManager
    struct PositionData {
        uint256 tokenId; // Uniswap V4 position NFT ID
        bytes32 poolId; // Pool ID
        address token0; // First token in pair
        address token1; // Second token in pair
        address depositToken; // Original token deposited (for conversion on withdrawal)
        uint128 liquidity; // Liquidity amount
        int24 tickLower; // Lower tick
        int24 tickUpper; // Upper tick
        uint256 amount0; // Token0 amount deposited
        uint256 amount1; // Token1 amount deposited
    }

    address public immutable yieldManager;
    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    ISwapRouter public immutable swapRouter;

    // ═══════════════════════════════════════════════════════════════════════════════
    //                                  EVENTS
    // ═══════════════════════════════════════════════════════════════════════════════

    event PositionCreated(
        uint256 indexed tokenId,
        bytes32 indexed poolId,
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper
    );
    event PositionWithdrawn(
        uint256 indexed tokenId,
        uint128 liquidityRemoved,
        uint256 amount0,
        uint256 amount1
    );

    // ═══════════════════════════════════════════════════════════════════════════════
    //                              INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════════

    constructor(
        address _yieldManager,
        address _poolManager,
        address _positionManager,
        address _swapRouter
    ) {
        yieldManager = _yieldManager;
        poolManager = IPoolManager(_poolManager);
        positionManager = IPositionManager(_positionManager);
        swapRouter = ISwapRouter(_swapRouter);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    //                              MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════════

    modifier onlyYieldManager() {
        require(msg.sender == yieldManager, "Only YieldManager");
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    //                           STRATEGY IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Invest - provide liquidity to Uniswap V4
    /// @param amount Amount of tokens to invest
    /// @param strategyData Encoded parameters (poolId, token0, token1, tickLower, tickUpper, isToken0, fee, tickSpacing)
    /// @return positionData Encoded position information
    function invest(
        uint256 amount,
        bytes calldata strategyData
    ) external onlyYieldManager returns (bytes memory positionData) {
        // Decode strategy data
        (
            bytes32 poolId,
            address token0,
            address token1,
            int24 tickLower,
            int24 tickUpper,
            bool isToken0,
            uint24 fee,
            int24 tickSpacing
        ) = abi.decode(
                strategyData,
                (bytes32, address, address, int24, int24, bool, uint24, int24)
            );

        address depositToken = isToken0 ? token0 : token1;

        // Receive tokens from YieldManager
        IERC20(depositToken).safeTransferFrom(yieldManager, address(this), amount);

        // Get current pool state
        (uint160 sqrtPriceX96, int24 currentTick, , ) = poolManager.getSlot0(
            _buildPoolKey(token0, token1, fee, tickSpacing)
        );

        // Determine position type and prepare tokens
        uint256 amount0;
        uint256 amount1;

        if (tickLower > currentTick) {
            // Position above current price: 100% token0 needed
            if (isToken0) {
                amount0 = amount;
                amount1 = 0;
            } else {
                // Swap token1 → token0
                amount0 = _swap(token1, token0, amount, fee, tickSpacing);
                amount1 = 0;
            }
        } else if (tickUpper < currentTick) {
            // Position below current price: 100% token1 needed
            if (!isToken0) {
                amount0 = 0;
                amount1 = amount;
            } else {
                // Swap token0 → token1
                amount0 = 0;
                amount1 = _swap(token0, token1, amount, fee, tickSpacing);
            }
        } else {
            // Position straddles current price: need both tokens
            (amount0, amount1) = _prepareTokensForPosition(
                amount,
                isToken0,
                token0,
                token1,
                sqrtPriceX96,
                tickLower,
                tickUpper,
                fee,
                tickSpacing
            );
        }

        // Calculate liquidity
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            amount0,
            amount1
        );

        // Mint position
        uint256 tokenId = _mintPosition(
            token0,
            token1,
            fee,
            tickSpacing,
            tickLower,
            tickUpper,
            liquidity,
            amount0,
            amount1
        );

        emit PositionCreated(tokenId, poolId, liquidity, tickLower, tickUpper);

        // Encode position data
        PositionData memory position = PositionData({
            tokenId: tokenId,
            poolId: poolId,
            token0: token0,
            token1: token1,
            depositToken: depositToken, // Track original token
            liquidity: liquidity,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0: amount0,
            amount1: amount1
        });

        return abi.encode(position);
    }

    /// @notice Withdraw - remove liquidity from Uniswap V4
    /// @param positionData Encoded position information
    /// @param amount Amount to withdraw
    /// @return withdrawn Actual amount withdrawn (including fees, in original deposit token)
    function withdraw(
        bytes calldata positionData,
        uint256 amount,
        bytes calldata /* strategyData */
    ) external onlyYieldManager returns (uint256 withdrawn) {
        // Decode position
        PositionData memory position = abi.decode(positionData, (PositionData));

        // Calculate liquidity to remove
        uint128 liquidityToRemove = uint128(
            (amount * position.liquidity) / (position.amount0 + position.amount1)
        );

        require(liquidityToRemove <= position.liquidity, "Insufficient balance");

        // Remove liquidity (automatically collects fees)
        (uint256 amount0, uint256 amount1) = _decreaseLiquidity(
            position.tokenId,
            liquidityToRemove
        );

        emit PositionWithdrawn(position.tokenId, liquidityToRemove, amount0, amount1);

        // Convert both tokens back to original deposit token
        uint256 totalInDepositToken;

        if (position.depositToken == position.token0) {
            // Deposit was token0, keep token0 and convert token1 → token0
            totalInDepositToken = amount0;
            if (amount1 > 0) {
                // Extract fee and tickSpacing from poolId (simplified - should be stored)
                uint24 fee = 3000; // 0.3% default
                int24 tickSpacing = 60;
                totalInDepositToken += _swap(
                    position.token1,
                    position.token0,
                    amount1,
                    fee,
                    tickSpacing
                );
            }
        } else {
            // Deposit was token1, keep token1 and convert token0 → token1
            totalInDepositToken = amount1;
            if (amount0 > 0) {
                uint24 fee = 3000;
                int24 tickSpacing = 60;
                totalInDepositToken += _swap(
                    position.token0,
                    position.token1,
                    amount0,
                    fee,
                    tickSpacing
                );
            }
        }

        // Transfer back to YieldManager in original token
        IERC20(position.depositToken).safeTransfer(yieldManager, totalInDepositToken);

        // Return total withdrawn (principal + fees, all in original token)
        return totalInDepositToken;
    }

    /// @notice Force withdraw - consumes withdrawal state from force collect flow
    /// @dev Called by user after forceCollect returns
    /// @param yieldManagerAddr The YieldManager contract address
    /// @param accountId The account ID
    /// @param amount The amount to withdraw
    function forceWithdraw(
        address yieldManagerAddr,
        uint256 accountId,
        uint128 amount,
        bytes calldata /* strategyData */
    ) external {
        // 1. Get withdrawal state from YieldManager
        IYieldManager.WithdrawalState memory state = IYieldManager(yieldManagerAddr)
            .getWithdrawalState(accountId);

        // 2. Verify amount matches
        require(state.amount == amount, "Amount mismatch");

        // 3. Verify strategy matches
        require(state.strategy == address(this), "Wrong strategy");

        // 4. Get position from YieldManager
        (, , bytes memory positionDataBytes) = IYieldManager(yieldManagerAddr).getPosition(
            state.token,
            address(this)
        );

        // 5. Withdraw from Uniswap V4 position
        uint256 withdrawn = _executeWithdrawal(positionDataBytes, amount, "");

        // 6. Approve YieldManager to take tokens
        // TODO: Determine which token(s) were withdrawn and approve accordingly
        PositionData memory position = abi.decode(positionDataBytes, (PositionData));
        IERC20(position.token0).safeApprove(yieldManagerAddr, withdrawn);

        // 7. Complete withdrawal in YieldManager
        IYieldManager(yieldManagerAddr).completeForceWithdrawal(
            accountId,
            address(this),
            state.token,
            uint128(withdrawn)
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    //                           INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Build PoolKey for Uniswap V4
    function _buildPoolKey(
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing
    ) internal pure returns (PoolKey memory) {
        return
            PoolKey({
                currency0: Currency.wrap(token0),
                currency1: Currency.wrap(token1),
                fee: fee,
                tickSpacing: tickSpacing,
                hooks: IHooks(address(0))
            });
    }

    /// @notice Swap tokens using Uniswap V4
    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 fee,
        int24 tickSpacing
    ) internal returns (uint256 amountOut) {
        // Approve swap router
        IERC20(tokenIn).safeApprove(address(swapRouter), amountIn);

        // Execute swap
        ISwapRouter.SwapParams memory params = ISwapRouter.SwapParams({
            currencyIn: Currency.wrap(tokenIn),
            currencyOut: Currency.wrap(tokenOut),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0)),
            amountIn: amountIn,
            amountOutMinimum: 0 // TODO: Add slippage protection
        });

        amountOut = swapRouter.swap(params);

        if (amountOut == 0) revert SwapFailed();
    }

    /// @notice Prepare tokens for two-sided position (straddles current price)
    function _prepareTokensForPosition(
        uint256 totalAmount,
        bool isToken0,
        address token0,
        address token1,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint24 fee,
        int24 tickSpacing
    ) internal returns (uint256 amount0, uint256 amount1) {
        // Calculate optimal ratio based on price range
        // Simplified: Use 50/50 split for now
        // TODO: Calculate exact ratio using LiquidityAmounts library

        if (isToken0) {
            uint256 swapAmount = totalAmount / 2;
            amount0 = totalAmount - swapAmount;
            amount1 = _swap(token0, token1, swapAmount, fee, tickSpacing);
        } else {
            uint256 swapAmount = totalAmount / 2;
            amount1 = totalAmount - swapAmount;
            amount0 = _swap(token1, token0, swapAmount, fee, tickSpacing);
        }
    }

    /// @notice Mint position via PositionManager
    function _mintPosition(
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max
    ) internal returns (uint256 tokenId) {
        // Approve position manager
        IERC20(token0).safeApprove(address(positionManager), amount0Max);
        IERC20(token1).safeApprove(address(positionManager), amount1Max);

        // Build PoolKey
        PoolKey memory poolKey = _buildPoolKey(token0, token1, fee, tickSpacing);

        // Build command sequence for minting
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        // Encode parameters
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            amount0Max,
            amount1Max,
            address(this),
            "" // hookData
        );
        params[1] = abi.encode(
            Currency.unwrap(poolKey.currency0),
            Currency.unwrap(poolKey.currency1)
        );

        // Execute via PositionManager
        bytes memory unlockData = abi.encode(actions, params);
        bytes memory result = positionManager.modifyLiquidities(
            unlockData,
            block.timestamp + 60
        );

        // Decode tokenId from result
        tokenId = abi.decode(result, (uint256));
    }

    /// @notice Decrease liquidity and collect fees
    function _decreaseLiquidity(
        uint256 tokenId,
        uint128 liquidityToRemove
    ) internal returns (uint256 amount0, uint256 amount1) {
        // Build command sequence for decreasing liquidity
        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );

        // Encode parameters
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            tokenId,
            liquidityToRemove,
            0, // amount0Min (slippage protection)
            0, // amount1Min (slippage protection)
            "" // hookData
        );
        params[1] = abi.encode(
            address(this), // recipient for token0
            address(this) // recipient for token1
        );

        // Execute via PositionManager
        bytes memory unlockData = abi.encode(actions, params);
        bytes memory result = positionManager.modifyLiquidities(
            unlockData,
            block.timestamp + 60
        );

        // Decode amounts from result
        (amount0, amount1) = abi.decode(result, (uint256, uint256));
    }

    /// @notice Internal withdrawal logic (shared by withdraw and forceWithdraw)
    function _executeWithdrawal(
        bytes memory positionData,
        uint256 amount,
        bytes memory /* strategyData */
    ) internal returns (uint256 withdrawn) {
        // Decode position
        PositionData memory position = abi.decode(positionData, (PositionData));

        // Calculate liquidity to remove
        uint128 liquidityToRemove = uint128(
            (amount * position.liquidity) / (position.amount0 + position.amount1)
        );

        require(liquidityToRemove <= position.liquidity, "Insufficient balance");

        // Remove liquidity
        (uint256 amount0, uint256 amount1) = _decreaseLiquidity(
            position.tokenId,
            liquidityToRemove
        );

        emit PositionWithdrawn(position.tokenId, liquidityToRemove, amount0, amount1);

        // Convert to deposit token
        uint256 totalInDepositToken;
        uint24 fee = 3000;
        int24 tickSpacing = 60;

        if (position.depositToken == position.token0) {
            totalInDepositToken = amount0;
            if (amount1 > 0) {
                totalInDepositToken += _swap(
                    position.token1,
                    position.token0,
                    amount1,
                    fee,
                    tickSpacing
                );
            }
        } else {
            totalInDepositToken = amount1;
            if (amount0 > 0) {
                totalInDepositToken += _swap(
                    position.token0,
                    position.token1,
                    amount0,
                    fee,
                    tickSpacing
                );
            }
        }

        withdrawn = totalInDepositToken;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    //                           VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Get position details
    function getPositionDetails(
        bytes calldata positionData
    )
        external
        pure
        returns (
            uint256 tokenId,
            bytes32 poolId,
            address token0,
            address token1,
            address depositToken,
            uint128 liquidity,
            int24 tickLower,
            int24 tickUpper,
            uint256 amount0,
            uint256 amount1
        )
    {
        PositionData memory position = abi.decode(positionData, (PositionData));
        return (
            position.tokenId,
            position.poolId,
            position.token0,
            position.token1,
            position.depositToken,
            position.liquidity,
            position.tickLower,
            position.tickUpper,
            position.amount0,
            position.amount1
        );
    }
}
