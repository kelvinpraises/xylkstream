/// YieldManager - Allows stream creators to earn yield on idle capital
/// Uses extension pattern: users deploy custom strategies, YieldManager owns positions
module xylkstream::yield_manager;

use sui::coin::{Self, Coin};
use sui::dynamic_field;
use sui::event;

// ═══════════════════════════════════════════════════════════════════════════════
//                                   ERRORS
// ═══════════════════════════════════════════════════════════════════════════════

const E_INSUFFICIENT_LIQUID: u64 = 1;
const E_EXCEEDS_PRINCIPAL: u64 = 2;
const E_NO_YIELD: u64 = 3;
const E_EXCEEDS_STREAMED: u64 = 4;
const E_POSITION_NOT_FOUND: u64 = 5;

// ═══════════════════════════════════════════════════════════════════════════════
//                              STORAGE & TYPES
// ═══════════════════════════════════════════════════════════════════════════════

/// YieldManager owned by a single app owner
public struct YieldManager<phantom T> has key {
    id: UID,
    /// Vault holding owner's funds
    vault: Coin<T>,
    /// Amount that came from Drips (must be returnable)
    principal: u128,
    /// Coins currently in YieldManager vault
    liquid_balance: u128,
    /// Coins currently in positions (across all strategies)
    invested_balance: u128,
    // Total = liquid_balance + invested_balance
    // Yield = Total - principal
    // Positions stored as dynamic fields: PositionKey -> Position<StrategyType>
    // Inner positions stored as dynamic fields: InnerPositionKey -> InnerPosition
}

/// Key for position storage
public struct PositionKey has copy, drop, store {
    strategy_id: ID,
}

/// Position wrapper - tracks principal amount
public struct Position<phantom StrategyType> has store {
    strategy_id: ID,
    amount: u128,
}

/// Creates inner position key (for storing InnerPosition separately)
public struct InnerPositionKey has copy, drop, store {
    strategy_id: ID,
}

/// Hot potato - must be consumed by calling complete_investment
/// Ensures strategies complete the investment flow
public struct InvestmentReceipt {
    strategy_id: ID,
    amount: u128,
}

// ═══════════════════════════════════════════════════════════════════════════════
//                                  EVENTS
// ═══════════════════════════════════════════════════════════════════════════════

public struct YieldManagerCreated<phantom T> has copy, drop {
    manager_id: ID,
}

public struct DepositedFromDrips has copy, drop {
    amount: u128,
}

public struct InvestedViaStrategy has copy, drop {
    strategy_id: ID,
    amount: u128,
}

public struct WithdrewFromStrategy has copy, drop {
    strategy_id: ID,
    amount: u128,
    withdrawn: u128,
}

public struct ForcedWithdrawForRecipient has copy, drop {
    recipient_account_id: u256,
    strategy_id: ID,
    amount: u128,
}

public struct ReturnedPrincipalToDrips has copy, drop {
    amount: u128,
}

public struct WithdrewYield has copy, drop {
    amount: u128,
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              INITIALIZATION
// ═══════════════════════════════════════════════════════════════════════════════

fun init(_ctx: &mut TxContext) {}

/// Creates a new YieldManager owned by the caller (app owner)
/// Each app owner creates their own YieldManager for their streaming app
public fun create_yield_manager<T>(ctx: &mut TxContext) {
    let manager_uid = object::new(ctx);
    let manager_id = object::uid_to_inner(&manager_uid);

    let manager = YieldManager<T> {
        id: manager_uid,
        vault: coin::zero<T>(ctx),
        principal: 0,
        liquid_balance: 0,
        invested_balance: 0,
    };

    event::emit(YieldManagerCreated<T> { manager_id });

    transfer::transfer(manager, tx_context::sender(ctx));
}

// ═══════════════════════════════════════════════════════════════════════════════
//                           INTERNAL HELPERS
// ═══════════════════════════════════════════════════════════════════════════════

/// Creates position key
fun position_key(strategy_id: ID): PositionKey {
    PositionKey { strategy_id }
}

/// Creates inner position key
fun inner_position_key(strategy_id: ID): InnerPositionKey {
    InnerPositionKey { strategy_id }
}

/// Helper: min of two u128 values
fun min_u128(a: u128, b: u128): u128 {
    if (a < b) { a } else { b }
}

// ═══════════════════════════════════════════════════════════════════════════════
//                    DRIPS INTEGRATION (package-only)
// ═══════════════════════════════════════════════════════════════════════════════

/// Deposit funds from Drips to YieldManager
/// Called by Drips contract when owner transfers idle balance
public(package) fun drips_deposit<T>(manager: &mut YieldManager<T>, coins: Coin<T>) {
    let amount = coin::value(&coins);

    // Merge into vault
    coin::join(&mut manager.vault, coins);

    // Update accounting
    manager.principal = manager.principal + (amount as u128);
    manager.liquid_balance = manager.liquid_balance + (amount as u128);

    event::emit(DepositedFromDrips {
        amount: (amount as u128),
    });
}

/// Return principal to Drips
/// Called by Drips contract to reclaim principal
/// Returns coins that Drips will credit to owner's account
public(package) fun drips_return<T>(
    manager: &mut YieldManager<T>,
    amount: u128,
    ctx: &mut TxContext,
): Coin<T> {
    // Can only return up to principal
    assert!(amount <= manager.principal, E_EXCEEDS_PRINCIPAL);

    // Must have liquid balance
    assert!(amount <= manager.liquid_balance, E_INSUFFICIENT_LIQUID);

    // Split from vault
    let coins = coin::split(&mut manager.vault, (amount as u64), ctx);

    // Reduce both principal and liquid
    manager.principal = manager.principal - amount;
    manager.liquid_balance = manager.liquid_balance - amount;

    event::emit(ReturnedPrincipalToDrips {
        amount,
    });

    coins
}

/// Force withdrawal for recipient (clawback mechanism)
/// Called by Drips contract when recipient claims streamed funds from invested position
/// MUST be called by Drips which verifies streamed_amount
public(package) fun drips_force_withdraw<T, StrategyType>(
    manager: &mut YieldManager<T>,
    strategy_id: ID,
    recipient_account_id: u256,
    streamed_amount: u128,
    coins: Coin<T>,
    ctx: &mut TxContext,
) {
    let key = position_key(strategy_id);
    assert!(dynamic_field::exists_(&manager.id, key), E_POSITION_NOT_FOUND);

    // Get actual withdrawn amount from coins
    let withdrawn = coin::value(&coins);

    // Verify amount doesn't exceed what has streamed
    assert!((withdrawn as u128) <= streamed_amount, E_EXCEEDS_STREAMED);

    // Access position
    let position = dynamic_field::borrow_mut<PositionKey, Position<StrategyType>>(
        &mut manager.id,
        key,
    );

    // Determine principal to deduct
    let principal_withdrawn = min_u128((withdrawn as u128), position.amount);

    // Update position
    position.amount = position.amount - principal_withdrawn;

    // Update accounting
    manager.invested_balance = manager.invested_balance - principal_withdrawn;

    // Transfer coins to recipient
    transfer::public_transfer(coins, tx_context::sender(ctx));

    event::emit(ForcedWithdrawForRecipient {
        recipient_account_id,
        strategy_id,
        amount: principal_withdrawn,
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
//                    POSITION MANAGEMENT (user-initiated)
// ═══════════════════════════════════════════════════════════════════════════════

/// Open position - get coins and hot potato receipt
/// Strategy must call position_create to consume the receipt
public fun position_open<T>(
    manager: &mut YieldManager<T>,
    strategy_id: ID,
    amount: u128,
    ctx: &mut TxContext,
): (Coin<T>, InvestmentReceipt) {
    assert!(amount <= manager.liquid_balance, E_INSUFFICIENT_LIQUID);

    // Split coins from vault
    let coins = coin::split(&mut manager.vault, (amount as u64), ctx);

    // Create hot potato receipt
    let receipt = InvestmentReceipt {
        strategy_id,
        amount,
    };

    (coins, receipt)
}

/// Create position - consumes hot potato receipt
/// Called by strategy after executing investment
public fun position_create<T, StrategyType, InnerPosition: store>(
    manager: &mut YieldManager<T>,
    receipt: InvestmentReceipt,
    inner_position: InnerPosition,
) {
    let InvestmentReceipt { strategy_id, amount } = receipt;

    // Store Position wrapper
    let key = position_key(strategy_id);
    let position = Position<StrategyType> {
        strategy_id,
        amount,
    };
    dynamic_field::add(&mut manager.id, key, position);

    // Store inner position with composite key
    let inner_key = inner_position_key(strategy_id);
    dynamic_field::add(&mut manager.id, inner_key, inner_position);

    // Update accounting: liquid -> invested
    manager.liquid_balance = manager.liquid_balance - amount;
    manager.invested_balance = manager.invested_balance + amount;

    event::emit(InvestedViaStrategy {
        strategy_id,
        amount,
    });
}

/// Close position - return coins from strategy
/// Strategy returns coins, YieldManager determines how much principal to deduct
public fun position_close<T, StrategyType, InnerPosition: store>(
    manager: &mut YieldManager<T>,
    strategy_id: ID,
    coins: Coin<T>,
    _ctx: &mut TxContext,
) {
    let key = position_key(strategy_id);
    assert!(dynamic_field::exists_(&manager.id, key), E_POSITION_NOT_FOUND);

    let position = dynamic_field::borrow_mut<PositionKey, Position<StrategyType>>(
        &mut manager.id,
        key,
    );

    let withdrawn = coin::value(&coins);

    // Determine principal to deduct (min of withdrawn or position.amount)
    // If withdrawn > position.amount, the extra is yield
    let principal_withdrawn = min_u128((withdrawn as u128), position.amount);

    // Update position
    position.amount = position.amount - principal_withdrawn;

    // Merge coins back into vault
    coin::join(&mut manager.vault, coins);

    // Update accounting: invested -> liquid (may increase if yield earned)
    manager.invested_balance = manager.invested_balance - principal_withdrawn;
    manager.liquid_balance = manager.liquid_balance + (withdrawn as u128);

    event::emit(WithdrewFromStrategy {
        strategy_id,
        amount: principal_withdrawn,
        withdrawn: (withdrawn as u128),
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
//                    YIELD MANAGEMENT (user-initiated)
// ═══════════════════════════════════════════════════════════════════════════════

/// Claim yield earned on positions
public fun yield_claim<T>(
    manager: &mut YieldManager<T>,
    recipient: address,
    ctx: &mut TxContext,
) {
    // Calculate yield
    let total = manager.liquid_balance + manager.invested_balance;
    assert!(total >= manager.principal, E_NO_YIELD);
    let yield_amount = total - manager.principal;

    // Must have liquid balance to withdraw
    assert!(yield_amount <= manager.liquid_balance, E_INSUFFICIENT_LIQUID);

    // Split from vault
    let coins = coin::split(&mut manager.vault, (yield_amount as u64), ctx);

    // Transfer to recipient
    transfer::public_transfer(coins, recipient);

    // Reduce liquid balance only
    manager.liquid_balance = manager.liquid_balance - yield_amount;

    event::emit(WithdrewYield {
        amount: yield_amount,
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
//                           VIEW FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// Get owner's balances
public fun get_balances<T>(manager: &YieldManager<T>): (u128, u128, u128) {
    (manager.principal, manager.liquid_balance, manager.invested_balance)
}

/// Get position amount
public fun get_position_amount<T, StrategyType>(
    manager: &YieldManager<T>,
    strategy_id: ID,
): u128 {
    let key = position_key(strategy_id);
    if (!dynamic_field::exists_(&manager.id, key)) {
        return 0
    };
    let position = dynamic_field::borrow<PositionKey, Position<StrategyType>>(
        &manager.id,
        key,
    );
    position.amount
}

/// Borrow inner position (for strategy to read)
public fun borrow_inner_position<T, StrategyType, InnerPosition: store>(
    manager: &YieldManager<T>,
    strategy_id: ID,
): &InnerPosition {
    let key = inner_position_key(strategy_id);
    dynamic_field::borrow<InnerPositionKey, InnerPosition>(&manager.id, key)
}
