/// YieldManager - Allows stream creators to earn yield on idle capital
/// Uses extension pattern: users deploy custom strategies, YieldManager owns positions
module xylkstream::yield_manager;

use sui::coin::{Self, Coin};
use sui::dynamic_field;
use sui::event;
use sui::table::{Self, Table};

// ═══════════════════════════════════════════════════════════════════════════════
//                                   ERRORS
// ═══════════════════════════════════════════════════════════════════════════════

const E_INSUFFICIENT_LIQUID: u64 = 1;
const E_EXCEEDS_PRINCIPAL: u64 = 2;
const E_NO_YIELD: u64 = 3;
const E_POSITION_NOT_FOUND: u64 = 4;
const E_WITHDRAWAL_NOT_FOUND: u64 = 5;
const E_ALREADY_CONSUMED: u64 = 6;
const E_AMOUNT_MISMATCH: u64 = 7;
const E_WITHDRAWAL_PENDING: u64 = 8;
const E_WRONG_STRATEGY: u64 = 9;

// ═══════════════════════════════════════════════════════════════════════════════
//                              STORAGE & TYPES
// ═══════════════════════════════════════════════════════════════════════════════

/// YieldManager owned by a single app owner
#[allow(lint(coin_field))]
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
    /// Pending force withdrawals (account_id -> WithdrawalState)
    pending_withdrawals: Table<u256, WithdrawalState>,
    // Total = liquid_balance + invested_balance
    // Yield = Total - principal
    // Positions stored as dynamic fields: PositionKey -> Position<StrategyType>
    // Inner positions stored as dynamic fields: InnerPositionKey -> InnerPosition
}

/// Withdrawal state for force collect
public struct WithdrawalState has store {
    account_id: u256,
    strategy_id: ID,
    amount: u128,
    transfer_to: address,
    consumed: bool,
}

/// Hot potato - must be consumed by calling complete_force_withdrawal
public struct WithdrawalReceipt {
    account_id: u256,
    strategy_id: ID,
    amount: u128,
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
        pending_withdrawals: table::new(ctx),
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

// ═══════════════════════════════════════════════════════════════════════════════
//                    FORCE WITHDRAW (Hot Potato Flow)
// ═══════════════════════════════════════════════════════════════════════════════

/// Force withdrawal for recipient (clawback mechanism with hot potato)
/// Called by Drips after collect() accounting when recipient claims streamed funds
/// Creates withdrawal state and returns hot potato that MUST be consumed
/// User must call strategy to withdraw and consume the hot potato
public(package) fun drips_force_withdraw<T>(
    manager: &mut YieldManager<T>,
    account_id: u256,
    strategy_id: ID,
    amount: u128,
    transfer_to: address,
): WithdrawalReceipt {
    // Store withdrawal state
    let state = WithdrawalState {
        account_id,
        strategy_id,
        amount,
        transfer_to,
        consumed: false,
    };

    // If already exists, abort (shouldn't happen in atomic tx)
    assert!(
        !table::contains(&manager.pending_withdrawals, account_id),
        E_WITHDRAWAL_PENDING,
    );
    table::add(&mut manager.pending_withdrawals, account_id, state);

    // Return hot potato
    WithdrawalReceipt {
        account_id,
        strategy_id,
        amount,
    }
}

/// Complete withdrawal - consumes hot potato
/// Called by strategy after withdrawing from position
/// Verifies coins, updates accounting, transfers to recipient
public fun complete_force_withdrawal<T, StrategyType>(
    manager: &mut YieldManager<T>,
    receipt: WithdrawalReceipt,
    coins: Coin<T>,
    _ctx: &mut TxContext,
) {
    let WithdrawalReceipt { account_id, strategy_id, amount } = receipt;

    // 1. Get withdrawal state
    assert!(
        table::contains(&manager.pending_withdrawals, account_id),
        E_WITHDRAWAL_NOT_FOUND,
    );
    let state = table::borrow_mut(&mut manager.pending_withdrawals, account_id);

    // 2. Verify not already consumed
    assert!(!state.consumed, E_ALREADY_CONSUMED);

    // 3. Verify coins match amount
    let withdrawn = coin::value(&coins);
    assert!((withdrawn as u128) == amount, E_AMOUNT_MISMATCH);

    // 4. Verify strategy matches
    assert!(state.strategy_id == strategy_id, E_WRONG_STRATEGY);

    // 5. Update position
    let key = position_key(strategy_id);
    assert!(dynamic_field::exists_(&manager.id, key), E_POSITION_NOT_FOUND);
    let position = dynamic_field::borrow_mut<PositionKey, Position<StrategyType>>(
        &mut manager.id,
        key,
    );
    let principal_withdrawn = min_u128(amount, position.amount);
    position.amount = position.amount - principal_withdrawn;

    // 6. Update accounting
    manager.invested_balance = manager.invested_balance - principal_withdrawn;

    // 7. Mark as consumed
    state.consumed = true;

    // 8. Transfer coins to recipient
    let transfer_to = state.transfer_to;
    transfer::public_transfer(coins, transfer_to);

    // 9. Clean up state
    let WithdrawalState {
        account_id: _,
        strategy_id: _,
        amount: _,
        transfer_to: _,
        consumed: _,
    } = table::remove(&mut manager.pending_withdrawals, account_id);

    // 10. Emit event
    event::emit(ForcedWithdrawForRecipient {
        recipient_account_id: account_id,
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
#[allow(unused_type_parameter)]
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
#[allow(unused_type_parameter)]
public fun borrow_inner_position<T, StrategyType, InnerPosition: store>(
    manager: &YieldManager<T>,
    strategy_id: ID,
): &InnerPosition {
    let key = inner_position_key(strategy_id);
    dynamic_field::borrow<InnerPositionKey, InnerPosition>(&manager.id, key)
}

/// Get withdrawal state (for strategy to read)
public fun get_withdrawal_state<T>(
    manager: &YieldManager<T>,
    account_id: u256,
): &WithdrawalState {
    assert!(
        table::contains(&manager.pending_withdrawals, account_id),
        E_WITHDRAWAL_NOT_FOUND,
    );
    table::borrow(&manager.pending_withdrawals, account_id)
}

/// Accessor functions for WithdrawalReceipt
public fun withdrawal_receipt_account_id(receipt: &WithdrawalReceipt): u256 {
    receipt.account_id
}

public fun withdrawal_receipt_strategy_id(receipt: &WithdrawalReceipt): ID {
    receipt.strategy_id
}

public fun withdrawal_receipt_amount(receipt: &WithdrawalReceipt): u128 {
    receipt.amount
}

/// Accessor functions for WithdrawalState
public fun withdrawal_state_strategy_id(state: &WithdrawalState): ID {
    state.strategy_id
}

public fun withdrawal_state_amount(state: &WithdrawalState): u128 {
    state.amount
}

public fun withdrawal_state_transfer_to(state: &WithdrawalState): address {
    state.transfer_to
}
