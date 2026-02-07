/// DeepBook Strategy Extension
/// Example of how users can deploy custom yield strategies
/// This strategy deposits funds to DeepBook for market making
module xylkstream::deepbook_strategy;

use sui::coin::{Self, Coin};
use sui::event;
use xylkstream::yield_manager::{Self, YieldManager};

// Note: In production, import actual DeepBook types
// For now, we'll use placeholder types

// ═══════════════════════════════════════════════════════════════════════════════
//                                   ERRORS
// ═══════════════════════════════════════════════════════════════════════════════

const E_INSUFFICIENT_BALANCE: u64 = 1;
const E_WRONG_POOL: u64 = 2;

// ═══════════════════════════════════════════════════════════════════════════════
//                              STORAGE & TYPES
// ═══════════════════════════════════════════════════════════════════════════════

/// Strategy type marker
public struct DeepBookStrategyType has drop {}

/// Strategy configuration
public struct DeepBookStrategy<phantom BaseAsset, phantom QuoteAsset> has key {
    id: UID,
    pool_id: ID,
    // Additional config...
}

/// Inner position that YieldManager will own
/// This represents the user's position in DeepBook
public struct DeepBookPosition has store {
    pool_id: ID,
    /// Amount deposited (for tracking)
    deposited_amount: u64,
    /// DeepBook account capability or position ID
    /// In real implementation, this would be DeepBook's AccountCap
    account_cap_id: ID,
}

// ═══════════════════════════════════════════════════════════════════════════════
//                                  EVENTS
// ═══════════════════════════════════════════════════════════════════════════════

public struct StrategyCreated has copy, drop {
    strategy_id: ID,
    pool_id: ID,
}

public struct PositionCreated has copy, drop {
    strategy_id: ID,
    amount: u64,
}

public struct PositionWithdrawn has copy, drop {
    strategy_id: ID,
    amount: u64,
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              STRATEGY CREATION
// ═══════════════════════════════════════════════════════════════════════════════

/// Create a new DeepBook strategy
/// User deploys this for their specific pool
public fun create_strategy<BaseAsset, QuoteAsset>(
    pool_id: ID,
    ctx: &mut TxContext,
): DeepBookStrategy<BaseAsset, QuoteAsset> {
    let strategy_id = object::new(ctx);
    let id = object::uid_to_inner(&strategy_id);

    event::emit(StrategyCreated {
        strategy_id: id,
        pool_id,
    });

    DeepBookStrategy {
        id: strategy_id,
        pool_id,
    }
}

/// Share the strategy so it can be used
public fun share_strategy<BaseAsset, QuoteAsset>(
    strategy: DeepBookStrategy<BaseAsset, QuoteAsset>,
) {
    transfer::share_object(strategy);
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              INVESTMENT FLOW
// ═══════════════════════════════════════════════════════════════════════════════

/// Execute investment - called internally
/// Invests coins in DeepBook and returns position
fun execute_investment<BaseAsset, QuoteAsset>(
    strategy: &DeepBookStrategy<BaseAsset, QuoteAsset>,
    coins: Coin<BaseAsset>,
    // In real implementation: deepbook_pool: &mut Pool<BaseAsset, QuoteAsset>
    ctx: &mut TxContext,
): DeepBookPosition {
    let amount = coin::value(&coins);

    // In real implementation:
    // 1. Create DeepBook account capability
    // let account_cap = deepbook::create_account(ctx);
    // 2. Deposit to DeepBook
    // deepbook::deposit_base(deepbook_pool, coins, &account_cap);

    // For now, just burn the coins (placeholder)
    transfer::public_transfer(coins, @0x0);

    // Create a placeholder account cap ID
    let account_cap_uid = object::new(ctx);
    let account_cap_id = object::uid_to_inner(&account_cap_uid);
    object::delete(account_cap_uid);

    // Return position that YieldManager will own
    DeepBookPosition {
        pool_id: strategy.pool_id,
        deposited_amount: amount,
        account_cap_id,
    }
}

/// Complete investment flow using hot potato pattern
/// User flow in PTB:
/// 1. Call this function which:
///    a. Opens position in YieldManager (gets coins + hot potato receipt)
///    b. Invests in DeepBook
///    c. Creates position in YieldManager (consumes hot potato)
public fun invest<BaseAsset, QuoteAsset>(
    yield_manager: &mut YieldManager<BaseAsset>,
    strategy: &DeepBookStrategy<BaseAsset, QuoteAsset>,
    amount: u128,
    // In real implementation: deepbook_pool: &mut Pool<BaseAsset, QuoteAsset>
    ctx: &mut TxContext,
) {
    let strategy_id = object::id(strategy);

    // 1. Open position - get coins and hot potato receipt
    let (coins, receipt) = yield_manager::position_open(
        yield_manager,
        strategy_id,
        amount,
        ctx,
    );

    // 2. Execute investment in DeepBook
    let inner_position = execute_investment(
        strategy,
        coins,
        ctx,
    );

    // 3. Create position - store and consume hot potato
    yield_manager::position_create<BaseAsset, DeepBookStrategyType, DeepBookPosition>(
        yield_manager,
        receipt,
        inner_position,
    );

    event::emit(PositionCreated {
        strategy_id,
        amount: (amount as u64),
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              WITHDRAWAL FLOW
// ═══════════════════════════════════════════════════════════════════════════════

/// Execute withdrawal - called internally (read-only position access)
/// In real DeepBook implementation, AccountCap allows withdrawal without mutating position
fun execute_withdrawal_readonly<BaseAsset, QuoteAsset>(
    strategy: &DeepBookStrategy<BaseAsset, QuoteAsset>,
    position: &DeepBookPosition,
    amount: u128,
    // In real implementation: deepbook_pool: &mut Pool<BaseAsset, QuoteAsset>
    ctx: &mut TxContext,
): Coin<BaseAsset> {
    // Verify pool matches
    assert!(position.pool_id == strategy.pool_id, E_WRONG_POOL);

    // Verify sufficient balance
    assert!((amount as u64) <= position.deposited_amount, E_INSUFFICIENT_BALANCE);

    // In real implementation:
    // let coins = deepbook::withdraw_base(
    //     deepbook_pool,
    //     (amount as u64),
    //     &position.account_cap,  // AccountCap allows withdrawal
    //     ctx
    // );

    // For now, create placeholder coins
    let mut coins = coin::zero<BaseAsset>(ctx);
    let mut i = 0;
    while (i < (amount as u64)) {
        coin::join(&mut coins, coin::zero<BaseAsset>(ctx));
        i = i + 1;
    };

    coins
}

/// Complete withdrawal flow - combines withdrawing and closing position
public fun withdraw<BaseAsset, QuoteAsset>(
    yield_manager: &mut YieldManager<BaseAsset>,
    strategy: &DeepBookStrategy<BaseAsset, QuoteAsset>,
    amount: u128,
    // In real implementation: deepbook_pool: &mut Pool<BaseAsset, QuoteAsset>
    ctx: &mut TxContext,
) {
    let strategy_id = object::id(strategy);

    // 1. Borrow position from YieldManager (read-only)
    let position = yield_manager::borrow_inner_position<
        BaseAsset,
        DeepBookStrategyType,
        DeepBookPosition
    >(
        yield_manager,
        strategy_id,
    );

    // 2. Execute withdrawal from DeepBook
    // Note: In real implementation, position would contain AccountCap
    // which allows withdrawal without mutating the position struct
    let coins = execute_withdrawal_readonly(
        strategy,
        position,
        amount,
        ctx,
    );

    // 3. Close position - return coins to YieldManager
    yield_manager::position_close<BaseAsset, DeepBookStrategyType, DeepBookPosition>(
        yield_manager,
        strategy_id,
        coins,
        ctx,
    );

    event::emit(PositionWithdrawn {
        strategy_id,
        amount: (amount as u64),
    });
}

/// Force withdrawal for recipient (clawback)
/// NOTE: This should be called by Drips contract, not directly by users
/// The strategy provides a wrapper, but Drips should verify streamed_amount
public fun force_withdraw_for_recipient<BaseAsset, QuoteAsset>(
    yield_manager: &mut YieldManager<BaseAsset>,
    strategy: &DeepBookStrategy<BaseAsset, QuoteAsset>,
    recipient_account_id: u256,
    amount: u128,
    streamed_amount: u128,
    // In real implementation: deepbook_pool: &mut Pool<BaseAsset, QuoteAsset>
    ctx: &mut TxContext,
) {
    let strategy_id = object::id(strategy);

    // 1. Borrow position from YieldManager (read-only)
    let position = yield_manager::borrow_inner_position<
        BaseAsset,
        DeepBookStrategyType,
        DeepBookPosition
    >(
        yield_manager,
        strategy_id,
    );

    // 2. Execute withdrawal from DeepBook
    let coins = execute_withdrawal_readonly(
        strategy,
        position,
        amount,
        ctx,
    );

    // 3. Force withdraw via YieldManager (sends to recipient)
    // NOTE: This will fail because drips_force_withdraw is public(package)
    // This function should only be called from within the xylkstream package (by Drips)
    yield_manager::drips_force_withdraw<BaseAsset, DeepBookStrategyType>(
        yield_manager,
        strategy_id,
        recipient_account_id,
        streamed_amount,
        coins,
        ctx,
    );
}

// ═══════════════════════════════════════════════════════════════════════════════
//                           VIEW FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// Get position details
public fun get_position_details<BaseAsset>(
    yield_manager: &YieldManager<BaseAsset>,
    strategy_id: ID,
): (ID, u64) {
    let position = yield_manager::borrow_inner_position<
        BaseAsset,
        DeepBookStrategyType,
        DeepBookPosition
    >(
        yield_manager,
        strategy_id,
    );

    (position.pool_id, position.deposited_amount)
}
