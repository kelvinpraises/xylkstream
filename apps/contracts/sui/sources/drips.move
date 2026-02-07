module xylkstream::drips;

use movemate::i128::{Self, I128};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::dynamic_field;
use sui::event;
use sui::table::{Self, Table};
use xylkstream::driver_utils::{Self, AccountMetadata};
use xylkstream::splits::{Self, SplitsReceiver};
use xylkstream::streams::{Self, StreamReceiver};

// ═══════════════════════════════════════════════════════════════════════════════
//                                 CONSTANTS
// ═══════════════════════════════════════════════════════════════════════════════

/// The total amount the protocol can store of each token (u128 max).
const MAX_TOTAL_BALANCE: u128 = 340282366920938463463374607431768211455;

/// Default cycle length: 1 week (604800 seconds)
const DEFAULT_CYCLE_SECS: u64 = 604800;

// ═══════════════════════════════════════════════════════════════════════════════
//                                   ERRORS
// ═══════════════════════════════════════════════════════════════════════════════

/// Total balance would exceed MAX_TOTAL_BALANCE
const E_TOTAL_BALANCE_TOO_HIGH: u64 = 1;
/// Token balance held by Drips is less than the required amount
const E_TOKEN_BALANCE_TOO_LOW: u64 = 2;
/// Withdrawal amount exceeds available withdrawable balance
const E_WITHDRAWAL_AMOUNT_TOO_HIGH: u64 = 3;

// ═══════════════════════════════════════════════════════════════════════════════
//                              STORAGE & TYPES
// ═══════════════════════════════════════════════════════════════════════════════

/// Global shared registry per token type
/// Coordinates streams and splits, manages balances and vault
public struct DripsRegistry<phantom T> has key {
    id: sui::object::UID,
    /// The balance of each account currently stored in the protocol
    /// Maps account_id -> Balance
    balances: Table<u256, Balance>,
    /// Vault holding all tokens
    vault: Coin<T>,
}

/// The balance currently stored in the protocol per account.
public struct Balance has store {
    /// The balance currently stored in streaming.
    streams: u128,
    /// The balance currently stored in splitting.
    splits: u128,
}

// ═══════════════════════════════════════════════════════════════════════════════
//                                  EVENTS
// ═══════════════════════════════════════════════════════════════════════════════

/// Emitted when a new DripsRegistry is created for a token type
public struct DripsRegistryCreated<phantom T> has copy, drop {
    registry_id: sui::object::ID,
}

/// Emitted by the account to broadcast metadata.
public struct AccountMetadataEmitted has copy, drop {
    account_id: u256,
    key: vector<u8>,
    value: vector<u8>,
}

/// Emitted when streams configuration is updated
public struct StreamsSet has copy, drop {
    account_id: u256,
    receiver_account_ids: vector<u256>,
    receiver_stream_ids: vector<u64>,
    receiver_amt_per_secs: vector<u256>,
    receiver_starts: vector<u64>,
    receiver_durations: vector<u64>,
    balance: u128,
    max_end: u64,
}

/// Emitted when splits configuration is updated
public struct SplitsSet has copy, drop {
    account_id: u256,
    receiver_account_ids: vector<u256>,
    receiver_weights: vector<u32>,
}

/// Emitted when funds are given directly
public struct Given has copy, drop {
    account_id: u256,
    receiver_id: u256,
    amount: u128,
}

/// Emitted when streams are received from completed cycles
public struct Received has copy, drop {
    account_id: u256,
    amount: u128,
}

/// Emitted when streams are squeezed from current cycle
public struct Squeezed has copy, drop {
    account_id: u256,
    sender_id: u256,
    amount: u128,
}

/// Emitted when splits are executed
public struct SplitExecuted has copy, drop {
    account_id: u256,
    to_receivers: u128,
    to_self: u128,
}

/// Emitted when funds are collected
public struct Collected has copy, drop {
    account_id: u256,
    amount: u128,
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              INITIALIZATION
// ═══════════════════════════════════════════════════════════════════════════════

/// Module initializer - placeholder
/// Actual registries created via create_drips_registry
fun init(_ctx: &mut TxContext) {}

/// Creates and shares a new DripsRegistry for a specific token type
/// Also creates the corresponding StreamsRegistry and SplitsRegistry
/// Should be called once per token type (SUI, USDC, etc.)
public fun create_drips_registry<T>(ctx: &mut TxContext) {
    // Create streams registry for this token
    streams::create_registry<T>(DEFAULT_CYCLE_SECS, ctx);

    // Create splits registry for this token
    splits::create_registry<T>(ctx);

    // Create drips registry
    let registry_id_obj = sui::object::new(ctx);
    let registry_id = sui::object::uid_to_inner(&registry_id_obj);

    let registry = DripsRegistry<T> {
        id: registry_id_obj,
        balances: table::new(ctx),
        vault: coin::zero<T>(ctx),
    };

    // Emit event for indexer
    event::emit(DripsRegistryCreated<T> {
        registry_id,
    });

    sui::transfer::share_object(registry);
}

// ═══════════════════════════════════════════════════════════════════════════════
//                           INTERNAL HELPERS
// ═══════════════════════════════════════════════════════════════════════════════

/// Ensures a Balance entry exists for the given account
fun ensure_balance_exists(balances_table: &mut Table<u256, Balance>, account_id: u256) {
    if (!table::contains(balances_table, account_id)) {
        table::add(balances_table, account_id, Balance { streams: 0, splits: 0 });
    };
}

/// Returns the token balance held by the Drips vault
fun token_balance<T>(registry: &DripsRegistry<T>): u128 {
    (coin::value(&registry.vault) as u128)
}

// ═══════════════════════════════════════════════════════════════════════════════
//                           BALANCE MANAGEMENT
// ═══════════════════════════════════════════════════════════════════════════════

/// Returns the amount currently stored in the protocol for the given account.
/// The sum of streaming and splitting balances can never exceed `MAX_TOTAL_BALANCE`.
/// Returns: (streams_balance, splits_balance)
public fun balances<T>(registry: &DripsRegistry<T>, account_id: u256): (u128, u128) {
    if (!table::contains(&registry.balances, account_id)) {
        return (0, 0)
    };
    let balance = table::borrow(&registry.balances, account_id);
    (balance.streams, balance.splits)
}

/// Increases the balance of the given account currently stored in streams.
/// No funds are transferred, all the tokens are expected to be already held by Drips.
/// The new total balance is verified to have coverage in the held tokens
/// and to be within the limit of `MAX_TOTAL_BALANCE`.
fun increase_streams_balance<T>(
    registry: &mut DripsRegistry<T>,
    account_id: u256,
    amt: u128,
) {
    if (amt == 0) { return };
    verify_balance_increase(registry, account_id, amt);
    ensure_balance_exists(&mut registry.balances, account_id);
    let balance = table::borrow_mut(&mut registry.balances, account_id);
    balance.streams = balance.streams + amt;
}

/// Decreases the balance of the given account currently stored in streams.
/// No funds are transferred, but the tokens held by Drips
/// above the total balance become withdrawable.
fun decrease_streams_balance<T>(
    registry: &mut DripsRegistry<T>,
    account_id: u256,
    amt: u128,
) {
    if (amt == 0) { return };
    let balance = table::borrow_mut(&mut registry.balances, account_id);
    balance.streams = balance.streams - amt;
}

/// Increases the balance of the given account currently stored in splits.
/// No funds are transferred, all the tokens are expected to be already held by Drips.
/// The new total balance is verified to have coverage in the held tokens
/// and to be within the limit of `MAX_TOTAL_BALANCE`.
fun increase_splits_balance<T>(
    registry: &mut DripsRegistry<T>,
    account_id: u256,
    amt: u128,
) {
    if (amt == 0) { return };
    verify_balance_increase(registry, account_id, amt);
    ensure_balance_exists(&mut registry.balances, account_id);
    let balance = table::borrow_mut(&mut registry.balances, account_id);
    balance.splits = balance.splits + amt;
}

/// Decreases the balance of the given account currently stored in splits.
/// No funds are transferred, but the tokens held by Drips
/// above the total balance become withdrawable.
fun decrease_splits_balance<T>(
    registry: &mut DripsRegistry<T>,
    account_id: u256,
    amt: u128,
) {
    if (amt == 0) { return };
    let balance = table::borrow_mut(&mut registry.balances, account_id);
    balance.splits = balance.splits - amt;
}

/// Moves the balance from streams to splits for the given account.
/// No funds are transferred, all the tokens are already held by Drips.
/// Used when streams are received and become splittable.
fun move_balance_from_streams_to_splits<T>(
    registry: &mut DripsRegistry<T>,
    account_id: u256,
    amt: u128,
) {
    if (amt == 0) { return };
    let balance = table::borrow_mut(&mut registry.balances, account_id);
    balance.streams = balance.streams - amt;
    balance.splits = balance.splits + amt;
}

/// Verifies that the balance can be increased by the given amount.
/// The sum of streaming and splitting balances is checked to not exceed
/// `MAX_TOTAL_BALANCE` or the amount of tokens held by Drips.
public fun verify_balance_increase<T>(
    registry: &DripsRegistry<T>,
    account_id: u256,
    amt: u128,
) {
    let (streams_balance, splits_balance) = balances(registry, account_id);
    let new_total_balance =
        (streams_balance as u256) + (splits_balance as u256) + (amt as u256);

    // Check against MAX_TOTAL_BALANCE
    assert!(new_total_balance <= (MAX_TOTAL_BALANCE as u256), E_TOTAL_BALANCE_TOO_HIGH);

    // Check against actual token balance held by the vault
    let held_balance = token_balance(registry);
    assert!(new_total_balance <= (held_balance as u256), E_TOKEN_BALANCE_TOO_LOW);
}

/// Transfers withdrawable funds to an address.
/// The withdrawable funds are held by the Drips vault,
/// but not used in the protocol, so they are free to be transferred out.
/// Anybody can call `withdraw`, so all withdrawable funds should be withdrawn
/// or used in the protocol before any 3rd parties have a chance to do that.
public(package) fun withdraw<T>(
    registry: &mut DripsRegistry<T>,
    account_id: u256,
    receiver: address,
    amt: u128,
    ctx: &mut TxContext,
) {
    let (streams_balance, splits_balance) = balances(registry, account_id);
    let held_balance = token_balance(registry);
    let managed_balance = streams_balance + splits_balance;
    let withdrawable = held_balance - managed_balance;
    assert!(amt <= withdrawable, E_WITHDRAWAL_AMOUNT_TOO_HIGH);

    // Split coins from vault and transfer
    let payment = coin::split(&mut registry.vault, (amt as u64), ctx);
    sui::transfer::public_transfer(payment, receiver);
}

/// Deposits coins into the Drips vault
/// Used by drivers when users send tokens to the protocol
public(package) fun deposit<T>(registry: &mut DripsRegistry<T>, coins: Coin<T>) {
    coin::join(&mut registry.vault, coins);
}

// ═══════════════════════════════════════════════════════════════════════════════
//                           STREAMS OPERATIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// Receives streams for an account from completed cycles.
/// Anyone can call this for any account - caller pays gas, account benefits.
public fun receive_streams<T>(
    drips_registry: &mut DripsRegistry<T>,
    streams_registry: &mut streams::StreamsRegistry<T>,
    splits_registry: &mut splits::SplitsRegistry<T>,
    account_id: u256,
    max_cycles: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let received_amt = streams::receive_streams(
        streams_registry,
        account_id,
        max_cycles,
        clock,
        ctx,
    );

    if (received_amt != 0) {
        move_balance_from_streams_to_splits(drips_registry, account_id, received_amt);
        splits::add_splittable(splits_registry, account_id, received_amt, ctx);
        event::emit(Received { account_id, amount: received_amt });
    };
}

/// Squeezes streams from a sender during the current (incomplete) cycle.
/// Anyone can call this for any account - caller pays gas, account benefits.
public fun squeeze_streams<T>(
    drips_registry: &mut DripsRegistry<T>,
    streams_registry: &mut streams::StreamsRegistry<T>,
    splits_registry: &mut splits::SplitsRegistry<T>,
    account_id: u256,
    sender_id: u256,
    history_hash: vector<u8>,
    streams_history: vector<streams::StreamsHistory>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let amt = streams::squeeze_streams(
        streams_registry,
        account_id,
        sender_id,
        history_hash,
        &streams_history,
        clock,
        ctx,
    );

    if (amt != 0) {
        move_balance_from_streams_to_splits(drips_registry, account_id, amt);
        splits::add_splittable(splits_registry, account_id, amt, ctx);
        event::emit(Squeezed { account_id, sender_id, amount: amt });
    };
}

/// Sets the account's streams configuration.
/// Requires that the tokens used to increase the streams balance
/// are already sent to Drips and are withdrawable.
/// If the streams balance is decreased, the released tokens become withdrawable.
public(package) fun set_streams<T>(
    drips_registry: &mut DripsRegistry<T>,
    streams_registry: &mut streams::StreamsRegistry<T>,
    account_id: u256,
    curr_receivers: &vector<StreamReceiver>,
    balance_delta: I128,
    new_receivers: &vector<StreamReceiver>,
    max_end_hint1: u64,
    max_end_hint2: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): I128 {
    if (!i128::is_neg(&balance_delta)) {
        increase_streams_balance(drips_registry, account_id, i128::as_u128(&balance_delta));
    };

    let real_balance_delta = streams::set_streams(
        streams_registry,
        account_id,
        curr_receivers,
        balance_delta,
        new_receivers,
        max_end_hint1,
        max_end_hint2,
        clock,
        ctx,
    );

    if (i128::is_neg(&real_balance_delta)) {
        let abs_delta = i128::abs(&real_balance_delta);
        decrease_streams_balance(drips_registry, account_id, i128::as_u128(&abs_delta));
    };

    real_balance_delta
}

/// Emits a StreamsSet event. Called by drivers after set_streams.
public(package) fun emit_streams_set(
    account_id: u256,
    receiver_account_ids: vector<u256>,
    receiver_stream_ids: vector<u64>,
    receiver_amt_per_secs: vector<u256>,
    receiver_starts: vector<u64>,
    receiver_durations: vector<u64>,
    balance: u128,
    max_end: u64,
) {
    event::emit(StreamsSet {
        account_id,
        receiver_account_ids,
        receiver_stream_ids,
        receiver_amt_per_secs,
        receiver_starts,
        receiver_durations,
        balance,
        max_end,
    });
}

/// Emits a StreamsSet event from StreamReceiver vector. Called by drivers after set_streams.
public(package) fun emit_streams_set_from_receivers(
    account_id: u256,
    receivers: vector<StreamReceiver>,
    balance: u128,
    max_end: u64,
) {
    let len = vector::length(&receivers);
    let mut receiver_account_ids = vector::empty<u256>();
    let mut receiver_stream_ids = vector::empty<u64>();
    let mut receiver_amt_per_secs = vector::empty<u256>();
    let mut receiver_starts = vector::empty<u64>();
    let mut receiver_durations = vector::empty<u64>();

    let mut i = 0;
    while (i < len) {
        let receiver = vector::borrow(&receivers, i);
        vector::push_back(
            &mut receiver_account_ids,
            streams::stream_receiver_account_id(receiver),
        );
        vector::push_back(
            &mut receiver_stream_ids,
            streams::stream_receiver_stream_id(receiver),
        );
        vector::push_back(
            &mut receiver_amt_per_secs,
            streams::stream_receiver_amt_per_sec(receiver),
        );
        vector::push_back(&mut receiver_starts, streams::stream_receiver_start(receiver));
        vector::push_back(
            &mut receiver_durations,
            streams::stream_receiver_duration(receiver),
        );
        i = i + 1;
    };

    emit_streams_set(
        account_id,
        receiver_account_ids,
        receiver_stream_ids,
        receiver_amt_per_secs,
        receiver_starts,
        receiver_durations,
        balance,
        max_end,
    );
}

// ═══════════════════════════════════════════════════════════════════════════════
//                           SPLITS OPERATIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// Splits an account's splittable balance according to their splits configuration.
/// Anyone can call this for any account - caller pays gas, account benefits.
public fun split<T>(
    splits_registry: &mut splits::SplitsRegistry<T>,
    account_id: u256,
    receivers: vector<SplitsReceiver>,
    ctx: &mut TxContext,
) {
    let (to_self, to_receivers) = splits::split(
        splits_registry,
        account_id,
        &receivers,
        ctx,
    );

    if (to_self != 0 || to_receivers != 0) {
        event::emit(SplitExecuted { account_id, to_receivers, to_self });
    };
}

/// Collects account's received already split funds and makes them withdrawable.
/// Anybody can call `withdraw`, so all withdrawable funds should be withdrawn
/// or used in the protocol before any 3rd parties have a chance to do that.
public(package) fun collect<T>(
    drips_registry: &mut DripsRegistry<T>,
    splits_registry: &mut splits::SplitsRegistry<T>,
    account_id: u256,
    ctx: &mut TxContext,
): u128 {
    let amt = splits::collect(splits_registry, account_id, ctx);
    if (amt != 0) {
        decrease_splits_balance(drips_registry, account_id, amt);
        event::emit(Collected { account_id, amount: amt });
    };
    amt
}

/// Gives funds from the account to the receiver.
/// The receiver can split and collect them immediately.
/// Requires that the tokens used to give are already sent to Drips and are withdrawable.
public(package) fun give<T>(
    drips_registry: &mut DripsRegistry<T>,
    splits_registry: &mut splits::SplitsRegistry<T>,
    account_id: u256,
    receiver: u256,
    amt: u128,
    ctx: &mut TxContext,
) {
    if (amt != 0) {
        increase_splits_balance(drips_registry, account_id, amt);
        event::emit(Given { account_id, receiver_id: receiver, amount: amt });
    };
    splits::give(splits_registry, account_id, receiver, amt, ctx);
}

/// Sets the account's splits configuration
public(package) fun set_splits<T>(
    splits_registry: &mut splits::SplitsRegistry<T>,
    account_id: u256,
    receivers: &vector<SplitsReceiver>,
    ctx: &mut TxContext,
) {
    splits::set_splits(splits_registry, account_id, receivers, ctx);
}

/// Emits a SplitsSet event. Called by drivers after set_splits.
public(package) fun emit_splits_set(
    account_id: u256,
    receiver_account_ids: vector<u256>,
    receiver_weights: vector<u32>,
) {
    event::emit(SplitsSet { account_id, receiver_account_ids, receiver_weights });
}

/// Emits a SplitsSet event from SplitsReceiver vector. Called by drivers after set_splits.
public(package) fun emit_splits_set_from_receivers(
    account_id: u256,
    receivers: vector<SplitsReceiver>,
) {
    let len = vector::length(&receivers);
    let mut receiver_account_ids = vector::empty<u256>();
    let mut receiver_weights = vector::empty<u32>();

    let mut i = 0;
    while (i < len) {
        let receiver = vector::borrow(&receivers, i);
        vector::push_back(
            &mut receiver_account_ids,
            splits::splits_receiver_account_id(receiver),
        );
        vector::push_back(&mut receiver_weights, splits::splits_receiver_weight(receiver));
        i = i + 1;
    };

    emit_splits_set(account_id, receiver_account_ids, receiver_weights);
}

// ═══════════════════════════════════════════════════════════════════════════════
//                           METADATA
// ═══════════════════════════════════════════════════════════════════════════════

/// Emits account metadata events
public(package) fun emit_account_metadata(
    account_id: u256,
    account_metadata: vector<AccountMetadata>,
) {
    let len = vector::length(&account_metadata);
    let mut i = 0;
    while (i < len) {
        let metadata = vector::borrow(&account_metadata, i);
        event::emit(AccountMetadataEmitted {
            account_id,
            key: driver_utils::account_metadata_key(metadata),
            value: driver_utils::account_metadata_value(metadata),
        });
        i = i + 1;
    };
}
