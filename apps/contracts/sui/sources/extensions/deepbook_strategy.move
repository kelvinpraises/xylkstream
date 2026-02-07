/// DeepBook Market Making Strategy Extension
/// Universal strategy for supplying liquidity to DeepBook MarginPools
/// ONE strategy contract serves UNLIMITED users with UNLIMITED positions
/// 
/// Flow:
/// 1. User calls invest<Asset>() with runtime params (pool_id, referral)
/// 2. Strategy supplies to DeepBook MarginPool, receives supply_shares
/// 3. Yield accrues automatically via share appreciation
/// 4. User calls withdraw() to redeem shares for principal + yield
/// 5. force_withdraw() handles hot potato flow for stream recipients
module xylkstream::deepbook_strategy;

use sui::coin::{Self, Coin};
use sui::event;
use sui::clock::Clock;
use xylkstream::yield_manager::{Self, YieldManager};

// DeepBook Margin imports (mainnet addresses)
// Package: 0x97d9473771b01f77b0940c589484184b49f6444627ec121314fae6a6d36fb86b
// Registry: 0x0e40998b359a9ccbab22a98ed21bd4346abf19158bc7980c8291908086b3a742

// Note: In production, uncomment these imports:
// use deepbook_margin::margin_pool::{Self, MarginPool, SupplierCap};
// use deepbook_margin::margin_registry::{Self, MarginRegistry};

// ═══════════════════════════════════════════════════════════════════════════════
//                                   ERRORS
// ═══════════════════════════════════════════════════════════════════════════════

const E_INSUFFICIENT_BALANCE: u64 = 1;
const E_WRONG_POOL: u64 = 2;
const E_SUPPLY_CAP_EXCEEDED: u64 = 3;
const E_RATE_LIMIT_EXCEEDED: u64 = 4;
const E_NOT_ENOUGH_LIQUIDITY: u64 = 5;
const E_INVALID_PARAMS: u64 = 6;
const E_ZERO_AMOUNT: u64 = 7;

// ═══════════════════════════════════════════════════════════════════════════════
//                              STORAGE & TYPES
// ═══════════════════════════════════════════════════════════════════════════════

/// Strategy type marker
public struct DeepBookStrategyType has drop {}

/// Universal strategy - NO immutable config!
/// ONE instance serves ALL users across ALL MarginPools
public struct DeepBookStrategy has key {
    id: UID,
    /// Shared SupplierCap used by strategy for all users
    /// In production: This would be deepbook_margin::margin_pool::SupplierCap
    supplier_cap_id: ID,
    version: u64,
}

/// Inner position stored in YieldManager per user
/// Tracks user's supply shares in a specific MarginPool
public struct DeepBookPosition has store {
    /// Which DeepBook MarginPool (e.g., SUI pool, USDC pool)
    margin_pool_id: ID,
    /// Asset type as bytes (for validation)
    asset_type: vector<u8>,
    /// Original amount deposited
    deposited_amount: u64,
    /// Supply shares received from MarginPool
    supply_shares: u64,
    /// Optional referral ID for fee sharing
    referral_id: option::Option<ID>,
    /// Timestamp when position opened
    timestamp: u64,
}

/// Runtime parameters (encoded in invest call)
public struct StrategyParams has drop {
    /// Which DeepBook MarginPool to supply to
    margin_pool_id: ID,
    /// Optional referral for fee sharing
    referral_id: option::Option<ID>,
}

// ═══════════════════════════════════════════════════════════════════════════════
//                                  EVENTS
// ═══════════════════════════════════════════════════════════════════════════════

public struct StrategyCreated has copy, drop {
    strategy_id: ID,
    supplier_cap_id: ID,
}

public struct PositionOpened has copy, drop {
    strategy_id: ID,
    margin_pool_id: ID,
    asset_type: vector<u8>,
    deposited_amount: u64,
    supply_shares: u64,
    referral_id: option::Option<ID>,
}

public struct PositionClosed has copy, drop {
    strategy_id: ID,
    margin_pool_id: ID,
    withdrawn_amount: u64,
    redeemed_shares: u64,
    yield_earned: u64,
}

public struct ForceWithdrawalCompleted has copy, drop {
    strategy_id: ID,
    margin_pool_id: ID,
    recipient_account_id: u256,
    amount: u64,
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              STRATEGY CREATION
// ═══════════════════════════════════════════════════════════════════════════════

/// Create universal DeepBook MM strategy (deployed ONCE)
/// In production: Pass MarginRegistry to mint SupplierCap
public fun create_strategy(
    // registry: &MarginRegistry,  // Uncomment in production
    // clock: &Clock,               // Uncomment in production
    ctx: &mut TxContext,
): DeepBookStrategy {
    let strategy_id = object::new(ctx);
    let id = object::uid_to_inner(&strategy_id);

    // In production: Mint SupplierCap from DeepBook
    // let supplier_cap = margin_pool::mint_supplier_cap(registry, clock, ctx);
    // let supplier_cap_id = object::id(&supplier_cap);
    
    // Placeholder: Create dummy ID
    let dummy_uid = object::new(ctx);
    let supplier_cap_id = object::uid_to_inner(&dummy_uid);
    object::delete(dummy_uid);

    event::emit(StrategyCreated {
        strategy_id: id,
        supplier_cap_id,
    });

    DeepBookStrategy {
        id: strategy_id,
        supplier_cap_id,
        version: 1,
    }
}

/// Share strategy for public use
public fun share_strategy(strategy: DeepBookStrategy) {
    transfer::share_object(strategy);
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              PARAMETER ENCODING
// ═══════════════════════════════════════════════════════════════════════════════

/// Encode strategy parameters for invest call
public fun encode_params(
    margin_pool_id: ID,
    referral_id: option::Option<ID>,
): vector<u8> {
    let mut data = vector::empty<u8>();
    vector::append(&mut data, sui::bcs::to_bytes(&margin_pool_id));
    vector::append(&mut data, sui::bcs::to_bytes(&referral_id));
    data
}

/// Decode strategy parameters (placeholder - use proper BCS in production)
fun decode_params(_data: &vector<u8>): StrategyParams {
    // In production: Proper BCS deserialization
    // For now: Return placeholder
    StrategyParams {
        margin_pool_id: object::id_from_address(@0x0),
        referral_id: option::none(),
    }
}

/// Helper to convert type to bytes
fun type_to_bytes<T>(): vector<u8> {
    // In production: use type_name::get<T>().into_string().into_bytes()
    sui::bcs::to_bytes(&std::type_name::get<T>())
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              INVESTMENT FLOW
// ═══════════════════════════════════════════════════════════════════════════════

/// Universal invest function - works for ANY asset, ANY MarginPool
/// User specifies pool and referral at runtime
/// 
/// Example usage:
/// ```
/// let params = encode_params(SUI_MARGIN_POOL_ID, some(referral_id));
/// invest<SUI>(yield_manager, strategy, 1000_SUI, params, registry, clock, ctx);
/// ```
public fun invest<Asset>(
    yield_manager: &mut YieldManager<Asset>,
    strategy: &DeepBookStrategy,
    amount: u128,
    params_bytes: vector<u8>,
    // registry: &MarginRegistry,     // Uncomment in production
    // margin_pool: &mut MarginPool<Asset>,  // Uncomment in production
    // clock: &Clock,                 // Uncomment in production
    ctx: &mut TxContext,
) {
    let strategy_id = object::id(strategy);
    let params = decode_params(&params_bytes);
    
    assert!(amount > 0, E_ZERO_AMOUNT);

    // 1. Open position in YieldManager (get coins + hot potato receipt)
    let (coins, receipt) = yield_manager::position_open(
        yield_manager,
        strategy_id,
        amount,
        ctx,
    );

    // 2. Execute investment in DeepBook MarginPool
    let inner_position = execute_investment<Asset>(
        strategy,
        coins,
        params,
        // registry,      // Uncomment in production
        // margin_pool,   // Uncomment in production
        // clock,         // Uncomment in production
        ctx,
    );

    // 3. Store position and consume hot potato
    yield_manager::position_create<Asset, DeepBookStrategyType, DeepBookPosition>(
        yield_manager,
        receipt,
        inner_position,
    );

    event::emit(PositionOpened {
        strategy_id,
        margin_pool_id: params.margin_pool_id,
        asset_type: type_to_bytes<Asset>(),
        deposited_amount: (amount as u64),
        supply_shares: 0,  // Will be set in execute_investment
        referral_id: params.referral_id,
    });
}

/// Execute investment logic - supply to DeepBook MarginPool
fun execute_investment<Asset>(
    _strategy: &DeepBookStrategy,
    coins: Coin<Asset>,
    params: StrategyParams,
    // registry: &MarginRegistry,     // Uncomment in production
    // margin_pool: &mut MarginPool<Asset>,  // Uncomment in production
    // clock: &Clock,                 // Uncomment in production
    ctx: &mut TxContext,
): DeepBookPosition {
    let deposited_amount = coin::value(&coins);
    
    // In production: Supply to DeepBook MarginPool
    // let supply_shares = margin_pool::supply(
    //     margin_pool,
    //     registry,
    //     &strategy.supplier_cap,  // Use strategy's shared SupplierCap
    //     coins,
    //     params.referral_id,
    //     clock,
    // );
    
    // Placeholder: Burn coins and return dummy shares
    transfer::public_transfer(coins, @0x0);
    let supply_shares = deposited_amount; // 1:1 for placeholder

    // Return position data
    DeepBookPosition {
        margin_pool_id: params.margin_pool_id,
        asset_type: type_to_bytes<Asset>(),
        deposited_amount,
        supply_shares,
        referral_id: params.referral_id,
        timestamp: tx_context::epoch_timestamp_ms(ctx),
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              WITHDRAWAL FLOW
// ═══════════════════════════════════════════════════════════════════════════════

/// Universal withdraw - works for any position
/// Redeems supply shares for principal + yield
/// 
/// Example usage:
/// ```
/// withdraw<SUI>(yield_manager, strategy, 500_SUI, registry, margin_pool, clock, ctx);
/// ```
public fun withdraw<Asset>(
    yield_manager: &mut YieldManager<Asset>,
    strategy: &DeepBookStrategy,
    amount: u128,
    // registry: &MarginRegistry,     // Uncomment in production
    // margin_pool: &mut MarginPool<Asset>,  // Uncomment in production
    // clock: &Clock,                 // Uncomment in production
    ctx: &mut TxContext,
) {
    let strategy_id = object::id(strategy);

    // 1. Borrow position (read-only)
    let position = yield_manager::borrow_inner_position<
        Asset,
        DeepBookStrategyType,
        DeepBookPosition,
    >(yield_manager, strategy_id);

    // 2. Withdraw from DeepBook MarginPool
    let (withdrawn_coins, redeemed_shares, yield_earned) = execute_withdrawal<Asset>(
        strategy,
        position,
        amount,
        // registry,      // Uncomment in production
        // margin_pool,   // Uncomment in production
        // clock,         // Uncomment in production
        ctx,
    );

    // 3. Return coins to YieldManager
    yield_manager::position_close<Asset, DeepBookStrategyType, DeepBookPosition>(
        yield_manager,
        strategy_id,
        withdrawn_coins,
        ctx,
    );

    event::emit(PositionClosed {
        strategy_id,
        margin_pool_id: position.margin_pool_id,
        withdrawn_amount: coin::value(&withdrawn_coins),
        redeemed_shares,
        yield_earned,
    });
}

/// Execute withdrawal logic - redeem shares from DeepBook MarginPool
fun execute_withdrawal<Asset>(
    _strategy: &DeepBookStrategy,
    position: &DeepBookPosition,
    amount: u128,
    // registry: &MarginRegistry,     // Uncomment in production
    // margin_pool: &mut MarginPool<Asset>,  // Uncomment in production
    // clock: &Clock,                 // Uncomment in production
    ctx: &mut TxContext,
): (Coin<Asset>, u64, u64) {
    // Calculate shares to redeem
    // In production: Use margin_pool::user_supply_amount() to get current value
    let current_value = position.supply_shares; // Placeholder: 1:1
    let shares_to_redeem = if ((amount as u64) >= current_value) {
        position.supply_shares
    } else {
        // Proportional redemption
        ((position.supply_shares as u128) * amount / (current_value as u128) as u64)
    };

    // In production: Withdraw from DeepBook MarginPool
    // let withdrawn_coins = margin_pool::withdraw(
    //     margin_pool,
    //     registry,
    //     &strategy.supplier_cap,
    //     option::some((amount as u64)),
    //     clock,
    //     ctx,
    // );
    
    // Placeholder: Create dummy coins
    let withdrawn_coins = coin::zero<Asset>(ctx);
    let withdrawn_amount = (amount as u64);
    
    // Calculate yield
    let yield_earned = if (withdrawn_amount > position.deposited_amount) {
        withdrawn_amount - position.deposited_amount
    } else {
        0
    };

    (withdrawn_coins, shares_to_redeem, yield_earned)
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              FORCE WITHDRAWAL FLOW
// ═══════════════════════════════════════════════════════════════════════════════

/// Force withdraw - consumes hot potato from force_collect flow
/// Called by stream recipient after force_collect_and_transfer
/// 
/// Flow:
/// 1. Recipient calls force_collect (gets WithdrawalReceipt hot potato)
/// 2. Recipient calls this function with hot potato
/// 3. Strategy withdraws from DeepBook
/// 4. Strategy completes withdrawal (consumes hot potato, transfers to recipient)
/// 
/// Example usage:
/// ```
/// let receipt = force_collect_and_transfer(...);
/// force_withdraw<SUI>(yield_manager, strategy, receipt, registry, margin_pool, clock, ctx);
/// ```
public fun force_withdraw<Asset>(
    yield_manager: &mut YieldManager<Asset>,
    strategy: &DeepBookStrategy,
    receipt: yield_manager::WithdrawalReceipt,
    // registry: &MarginRegistry,     // Uncomment in production
    // margin_pool: &mut MarginPool<Asset>,  // Uncomment in production
    // clock: &Clock,                 // Uncomment in production
    ctx: &mut TxContext,
) {
    let strategy_id = object::id(strategy);
    let account_id = yield_manager::withdrawal_receipt_account_id(&receipt);
    let amount = yield_manager::withdrawal_receipt_amount(&receipt);

    // 1. Verify strategy matches
    assert!(
        yield_manager::withdrawal_receipt_strategy_id(&receipt) == strategy_id,
        E_WRONG_POOL,
    );

    // 2. Borrow position
    let position = yield_manager::borrow_inner_position<
        Asset,
        DeepBookStrategyType,
        DeepBookPosition,
    >(yield_manager, strategy_id);

    // 3. Withdraw from DeepBook
    let (withdrawn_coins, _redeemed_shares, _yield_earned) = execute_withdrawal<Asset>(
        strategy,
        position,
        amount,
        // registry,      // Uncomment in production
        // margin_pool,   // Uncomment in production
        // clock,         // Uncomment in production
        ctx,
    );

    // 4. Complete withdrawal (consumes hot potato, transfers to recipient)
    yield_manager::complete_force_withdrawal<Asset, DeepBookStrategyType>(
        yield_manager,
        receipt,
        withdrawn_coins,
        ctx,
    );

    event::emit(ForceWithdrawalCompleted {
        strategy_id,
        margin_pool_id: position.margin_pool_id,
        recipient_account_id: account_id,
        amount: (amount as u64),
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
//                           VIEW FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// Get position details for a user
public fun get_position_details<Asset>(
    yield_manager: &YieldManager<Asset>,
    strategy_id: ID,
): (ID, u64, u64, option::Option<ID>) {
    let position = yield_manager::borrow_inner_position<
        Asset,
        DeepBookStrategyType,
        DeepBookPosition,
    >(yield_manager, strategy_id);

    (
        position.margin_pool_id,
        position.deposited_amount,
        position.supply_shares,
        position.referral_id,
    )
}

/// Get strategy info
public fun get_strategy_info(strategy: &DeepBookStrategy): (ID, u64) {
    (strategy.supplier_cap_id, strategy.version)
}
