// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/// @title YieldManager
/// @notice Allows stream creators to earn yield on idle capital
/// @dev Uses extension pattern: users deploy custom strategies, YieldManager owns positions
contract YieldManager {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════════
    //                                   ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════

    error NotAuthorized();
    error InsufficientLiquid();
    error ExceedsPrincipal();
    error NoYield();
    error ExceedsStreamed();
    error PositionNotFound();
    error OnlyDrips();
    error StrategyNotWhitelisted();
    error OnlyOwner();
    error WithdrawalNotFound();
    error AlreadyConsumed();
    error AmountMismatch();
    error WithdrawalPending();
    error WrongStrategy();

    // ═══════════════════════════════════════════════════════════════════════════════
    //                              STORAGE & TYPES
    // ═══════════════════════════════════════════════════════════════════════════════

    struct UserAccount {
        uint128 principal;        // Amount from Drips (must be returnable)
        uint128 liquidBalance;    // Tokens in vault
        uint128 investedBalance;  // Tokens in positions
        // Total = liquid + invested
        // Yield = Total - principal
    }

    struct Position {
        address strategy;
        uint128 amount;
        bytes positionData;  // Strategy-specific position data
    }

    /// @notice Withdrawal state for force collect
    struct WithdrawalState {
        uint256 accountId;
        address strategy;
        uint128 amount;
        address transferTo;
        bool consumed;
    }

    address public immutable dripsContract;
    IERC20 public immutable token;
    address public owner;

    /// account_id => UserAccount
    mapping(uint256 => UserAccount) public accounts;

    /// account_id => strategy => Position
    mapping(uint256 => mapping(address => Position)) public positions;

    /// Whitelisted strategies that users can invest in
    mapping(address => bool) public whitelistedStrategies;

    /// Pending force withdrawals (account_id => WithdrawalState)
    mapping(uint256 => WithdrawalState) public pendingWithdrawals;

    // ═══════════════════════════════════════════════════════════════════════════════
    //                                  EVENTS
    // ═══════════════════════════════════════════════════════════════════════════════

    event DepositedFromDrips(uint256 indexed accountId, uint256 amount);
    event PositionOpened(uint256 indexed accountId, address indexed strategy, uint256 amount);
    event PositionClosed(uint256 indexed accountId, address indexed strategy, uint256 amount, uint256 withdrawn);
    event ForcedWithdrawForRecipient(
        uint256 indexed accountId,
        uint256 indexed recipientAccountId,
        address indexed strategy,
        uint256 amount
    );
    event ReturnedPrincipalToDrips(uint256 indexed accountId, uint256 amount);
    event YieldClaimed(uint256 indexed accountId, uint256 amount);
    event StrategyWhitelisted(address indexed strategy, bool whitelisted);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ═══════════════════════════════════════════════════════════════════════════════
    //                              INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════════

    constructor(address _dripsContract, address _token) {
        dripsContract = _dripsContract;
        token = IERC20(_token);
        owner = msg.sender;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    //                              MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @dev Verifies that caller owns the account (for address driver: account_id = address as uint256)
    modifier onlyAccountOwner(uint256 accountId) {
        if (uint256(uint160(msg.sender)) != accountId) revert NotAuthorized();
        _;
    }

    modifier onlyDrips() {
        if (msg.sender != dripsContract) revert OnlyDrips();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyWhitelistedStrategy(address strategy) {
        if (!whitelistedStrategies[strategy]) revert StrategyNotWhitelisted();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    //                    ADMIN FUNCTIONS (owner-only)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Whitelist or blacklist a strategy
    /// @dev Only owner can manage strategy whitelist
    function setStrategyWhitelist(address strategy, bool whitelisted) external onlyOwner {
        whitelistedStrategies[strategy] = whitelisted;
        emit StrategyWhitelisted(strategy, whitelisted);
    }

    /// @notice Transfer ownership
    function transferOwnership(address newOwner) external onlyOwner {
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    //                    DRIPS INTEGRATION (Drips-only)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Deposit funds from Drips to YieldManager
    /// @dev Called by Drips contract when user transfers idle balance
    function dripsDeposit(uint256 accountId, uint256 amount) external onlyDrips {
        UserAccount storage account = accounts[accountId];
        account.principal += uint128(amount);
        account.liquidBalance += uint128(amount);

        emit DepositedFromDrips(accountId, amount);
    }

    /// @notice Return principal to Drips
    /// @dev Called by Drips contract to reclaim principal
    function dripsReturn(uint256 accountId, uint256 amount) external onlyDrips {
        UserAccount storage account = accounts[accountId];

        // Can only return up to principal
        if (amount > account.principal) revert ExceedsPrincipal();

        // Must have liquid balance
        if (amount > account.liquidBalance) revert InsufficientLiquid();

        // Transfer to Drips
        token.safeTransfer(dripsContract, amount);

        // Reduce both principal and liquid
        account.principal -= uint128(amount);
        account.liquidBalance -= uint128(amount);

        emit ReturnedPrincipalToDrips(accountId, amount);
    }

    /// @notice Force withdrawal for recipient (clawback mechanism)
    /// @dev Called by Drips contract after collect() accounting when recipient claims streamed funds
    /// @dev Creates withdrawal state that must be consumed by calling completeForceWithdrawal
    /// @dev User must call strategy to withdraw and consume the withdrawal state
    function dripsForceWithdraw(
        uint256 accountId,
        address strategy,
        uint128 amount,
        address transferTo
    ) external onlyDrips {
        // Check no pending withdrawal exists
        if (pendingWithdrawals[accountId].amount > 0) revert WithdrawalPending();

        // Store withdrawal state
        pendingWithdrawals[accountId] = WithdrawalState({
            accountId: accountId,
            strategy: strategy,
            amount: amount,
            transferTo: transferTo,
            consumed: false
        });
    }

    /// @notice Complete withdrawal - consumes withdrawal state
    /// @dev Called by strategy after withdrawing from position
    /// @dev Verifies amount, updates accounting, transfers to recipient
    function completeForceWithdrawal(
        uint256 accountId,
        address strategy,
        uint128 amount
    ) external returns (uint128 principalWithdrawn) {
        WithdrawalState storage state = pendingWithdrawals[accountId];

        // Verify withdrawal state exists
        if (state.amount == 0) revert WithdrawalNotFound();
        
        // Verify not already consumed
        if (state.consumed) revert AlreadyConsumed();
        
        // Verify amount matches
        if (state.amount != amount) revert AmountMismatch();
        
        // Verify strategy matches
        if (state.strategy != strategy) revert WrongStrategy();

        // Get position
        Position storage position = positions[accountId][strategy];
        if (position.strategy == address(0)) revert PositionNotFound();

        // Determine principal to deduct (min of amount or position.amount)
        principalWithdrawn = uint128(_min(amount, position.amount));

        // Update position
        position.amount -= principalWithdrawn;

        // Update accounting
        UserAccount storage account = accounts[accountId];
        account.investedBalance -= principalWithdrawn;

        // Mark as consumed
        state.consumed = true;

        // Transfer to recipient
        token.safeTransfer(state.transferTo, amount);

        // Clean up state
        delete pendingWithdrawals[accountId];

        emit ForcedWithdrawForRecipient(accountId, accountId, strategy, principalWithdrawn);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    //                    POSITION MANAGEMENT (user-initiated)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Open position - invest via user-deployed strategy
    /// @dev Strategy receives tokens and returns position data
    /// @dev Strategy must be whitelisted by owner
    function positionOpen(
        uint256 accountId,
        address strategy,
        uint256 amount,
        bytes calldata strategyData
    ) external onlyAccountOwner(accountId) onlyWhitelistedStrategy(strategy) {
        UserAccount storage account = accounts[accountId];
        if (amount > account.liquidBalance) revert InsufficientLiquid();

        // Transfer tokens to strategy
        token.safeTransfer(strategy, amount);

        // Call strategy to execute investment
        bytes memory positionData = IYieldStrategy(strategy).executeInvestment(amount, strategyData);

        // Store position
        positions[accountId][strategy] = Position({
            strategy: strategy,
            amount: uint128(amount),
            positionData: positionData
        });

        // Update accounting: liquid -> invested
        account.liquidBalance -= uint128(amount);
        account.investedBalance += uint128(amount);

        emit PositionOpened(accountId, strategy, amount);
    }

    /// @notice Close position - withdraw from strategy
    /// @dev Strategy returns tokens, YieldManager calculates principal vs yield
    function positionClose(
        uint256 accountId,
        address strategy,
        bytes calldata strategyData
    ) external onlyAccountOwner(accountId) {
        Position storage position = positions[accountId][strategy];
        if (position.strategy == address(0)) revert PositionNotFound();

        // Call strategy to withdraw entire position
        uint256 withdrawn = IYieldStrategy(strategy).executeWithdrawal(
            position.positionData,
            position.amount,
            strategyData
        );

        // Determine principal to deduct (min of withdrawn or position.amount)
        // If withdrawn > position.amount, the extra is yield
        uint128 principalWithdrawn = uint128(_min(withdrawn, position.amount));

        // Update position
        position.amount -= principalWithdrawn;

        // Update accounting: invested -> liquid (may increase if yield earned)
        UserAccount storage account = accounts[accountId];
        account.investedBalance -= principalWithdrawn;
        account.liquidBalance += uint128(withdrawn);

        emit PositionClosed(accountId, strategy, principalWithdrawn, withdrawn);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    //                    YIELD MANAGEMENT (user-initiated)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Claim yield earned on positions
    /// @dev Can only claim yield that is in liquid balance
    function yieldClaim(uint256 accountId, address recipient) external onlyAccountOwner(accountId) {
        UserAccount storage account = accounts[accountId];

        // Calculate yield
        uint256 total = uint256(account.liquidBalance) + uint256(account.investedBalance);
        if (total < account.principal) revert NoYield();
        uint256 yieldAmount = total - account.principal;

        // Must have liquid balance to withdraw
        if (yieldAmount > account.liquidBalance) revert InsufficientLiquid();

        // Transfer yield to recipient
        token.safeTransfer(recipient, yieldAmount);

        // Reduce liquid balance only
        account.liquidBalance -= uint128(yieldAmount);

        emit YieldClaimed(accountId, yieldAmount);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    //                           VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Get user account balances
    function getBalances(uint256 accountId)
        external
        view
        returns (uint128 principal, uint128 liquidBalance, uint128 investedBalance)
    {
        UserAccount storage account = accounts[accountId];
        return (account.principal, account.liquidBalance, account.investedBalance);
    }

    /// @notice Get position details
    function getPosition(uint256 accountId, address strategy)
        external
        view
        returns (address strategyAddr, uint128 amount, bytes memory positionData)
    {
        Position storage position = positions[accountId][strategy];
        return (position.strategy, position.amount, position.positionData);
    }

    /// @notice Calculate yield for an account
    function calculateYield(uint256 accountId) external view returns (uint256) {
        UserAccount storage account = accounts[accountId];
        uint256 total = uint256(account.liquidBalance) + uint256(account.investedBalance);
        if (total < account.principal) return 0;
        return total - account.principal;
    }

    /// @notice Get withdrawal state (for strategy to read)
    function getWithdrawalState(uint256 accountId)
        external
        view
        returns (WithdrawalState memory)
    {
        if (pendingWithdrawals[accountId].amount == 0) revert WithdrawalNotFound();
        return pendingWithdrawals[accountId];
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    //                           INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @dev Returns the minimum of two uint256 values
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

/// @title IYieldStrategy
/// @notice Interface that all yield strategies must implement
interface IYieldStrategy {
    /// @notice Execute investment - returns position data
    /// @param amount Amount to invest
    /// @param strategyData Strategy-specific data
    /// @return positionData Data representing the position
    function executeInvestment(uint256 amount, bytes calldata strategyData)
        external
        returns (bytes memory positionData);

    /// @notice Execute withdrawal - returns amount withdrawn
    /// @param positionData Data representing the position
    /// @param amount Amount to withdraw
    /// @param strategyData Strategy-specific data
    /// @return withdrawn Actual amount withdrawn (may include yield)
    function executeWithdrawal(bytes calldata positionData, uint256 amount, bytes calldata strategyData)
        external
        returns (uint256 withdrawn);
}
