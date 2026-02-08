module xylkstream::splits;

use sui::bcs;
use sui::dynamic_field;
use sui::event;
use sui::hash;
use sui::table::{Self, Table};

// ═══════════════════════════════════════════════════════════════════════════════
//                              CONSTANTS
// ═══════════════════════════════════════════════════════════════════════════════

/// Maximum number of splits receivers of a single account.
const MAX_SPLITS_RECEIVERS: u64 = 200;

/// The total splits weight of an account (1_000_000 = 100%).
const TOTAL_SPLITS_WEIGHT: u32 = 1_000_000;

// ═══════════════════════════════════════════════════════════════════════════════
//                              ERROR CODES
// ═══════════════════════════════════════════════════════════════════════════════

/// Too many splits receivers (max 200)
const E_TOO_MANY_SPLITS_RECEIVERS: u64 = 1;
/// Splits receiver weight is zero
const E_SPLITS_RECEIVER_WEIGHT_ZERO: u64 = 2;
/// Splits receivers not sorted by account_id
const E_SPLITS_RECEIVERS_NOT_SORTED: u64 = 3;
/// Sum of splits weights exceeds TOTAL_SPLITS_WEIGHT
const E_SPLITS_WEIGHTS_SUM_TOO_HIGH: u64 = 4;
/// Provided receivers don't match stored splits hash
const E_INVALID_CURRENT_SPLITS_RECEIVERS: u64 = 5;

// ═══════════════════════════════════════════════════════════════════════════════
//                              STORAGE & TYPES
// ═══════════════════════════════════════════════════════════════════════════════

/// Global shared registry per token type
public struct SplitsRegistry<phantom T> has key {
    id: UID,
    /// Account splits states: account_id -> SplitsState
    states: Table<u256, SplitsState>,
}

/// Per-account splits state
/// Balances stored as dynamic field to avoid nested table issue
#[allow(lint(missing_key))]
public struct SplitsState has store {
    id: UID,
    /// The account's splits configuration hash.
    splits_hash: vector<u8>,
    // Balances stored as dynamic field: b"balances" -> Table<address, SplitsBalance>
}

/// Balance tracking for an account per token
public struct SplitsBalance has store {
    /// Not yet split balance, must be split before collecting.
    splittable: u128,
    /// Already split balance, ready to be collected.
    collectable: u128,
}

/// A splits receiver configuration
public struct SplitsReceiver has copy, drop, store {
    /// The receiver's account ID
    account_id: u256,
    /// The splits weight (share = weight / TOTAL_SPLITS_WEIGHT)
    weight: u32,
}

/// Helper struct for split calculation (internal use only)
public struct SplitAmount has copy, drop, store {
    receiver_id: u256,
    amount: u128,
}

// ═══════════════════════════════════════════════════════════════════════════════
//                                  EVENTS
// ═══════════════════════════════════════════════════════════════════════════════

/// Emitted when a new SplitsRegistry is created for a token type
public struct SplitsRegistryCreated<phantom T> has copy, drop {
    registry_id: ID,
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              CONSTRUCTORS
// ═══════════════════════════════════════════════════════════════════════════════

/// Creates a new SplitsReceiver
public fun new_splits_receiver(account_id: u256, weight: u32): SplitsReceiver {
    SplitsReceiver { account_id, weight }
}

/// Accessor functions for SplitsReceiver
public fun splits_receiver_account_id(receiver: &SplitsReceiver): u256 {
    receiver.account_id
}

public fun splits_receiver_weight(receiver: &SplitsReceiver): u32 {
    receiver.weight
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              INITIALIZATION
// ═══════════════════════════════════════════════════════════════════════════════

/// Module initializer - placeholder
fun init(_ctx: &mut TxContext) {}

/// Creates and shares a new SplitsRegistry for a specific token type
/// Should be called once per token type (SUI, USDC, etc.)
public fun create_registry<T>(ctx: &mut TxContext) {
    let registry_id_obj = object::new(ctx);
    let registry_id = object::uid_to_inner(&registry_id_obj);

    let registry = SplitsRegistry<T> {
        id: registry_id_obj,
        states: table::new(ctx),
    };

    // Emit event for indexer
    event::emit(SplitsRegistryCreated<T> {
        registry_id,
    });

    transfer::share_object(registry);
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              HELPER FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// Ensures a SplitsState exists for the given account_id, creating if needed
fun ensure_state_exists(
    states: &mut Table<u256, SplitsState>,
    account_id: u256,
    ctx: &mut TxContext,
) {
    if (!table::contains(states, account_id)) {
        let mut state_id = object::new(ctx);

        // Create balances table as dynamic field
        let balances = table::new<address, SplitsBalance>(ctx);
        dynamic_field::add(&mut state_id, b"balances", balances);

        let state = SplitsState {
            id: state_id,
            splits_hash: vector::empty(),
        };

        table::add(states, account_id, state);
    };
}

/// Ensures a SplitsBalance exists for the given token address, creating if needed
fun ensure_balance_exists(
    state: &mut SplitsState,
    fa_metadata: address,
    ctx: &mut TxContext,
) {
    // Check if balances dynamic field exists first
    if (!dynamic_field::exists_(&state.id, b"balances")) {
        let balances = table::new<address, SplitsBalance>(ctx);
        dynamic_field::add(&mut state.id, b"balances", balances);
        return
    };

    let balances = dynamic_field::borrow_mut<vector<u8>, Table<address, SplitsBalance>>(
        &mut state.id,
        b"balances",
    );

    if (!table::contains(balances, fa_metadata)) {
        table::add(
            balances,
            fa_metadata,
            SplitsBalance {
                splittable: 0,
                collectable: 0,
            },
        );
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
//                            BALANCE OPERATIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// Adds an amount to the splittable balance of an account.
/// Called internally when funds are received (e.g., from streams or gives).
public(package) fun add_splittable<T>(
    registry: &mut SplitsRegistry<T>,
    account_id: u256,
    amt: u128,
    ctx: &mut TxContext,
) {
    if (amt == 0) { return };

    ensure_state_exists(&mut registry.states, account_id, ctx);
    let state = table::borrow_mut(&mut registry.states, account_id);

    // For add_splittable, we use a dummy address since it's token-agnostic
    // The actual token type is in the registry type parameter
    let fa_metadata = @0x0;
    ensure_balance_exists(state, fa_metadata, ctx);

    let balances = dynamic_field::borrow_mut<vector<u8>, Table<address, SplitsBalance>>(
        &mut state.id,
        b"balances",
    );
    let balance = table::borrow_mut(balances, fa_metadata);
    balance.splittable = balance.splittable + amt;
}

/// Returns account's received but not split yet funds.
public fun splittable<T>(registry: &SplitsRegistry<T>, account_id: u256): u128 {
    if (!table::contains(&registry.states, account_id)) {
        return 0
    };

    let state = table::borrow(&registry.states, account_id);
    let balances = dynamic_field::borrow<vector<u8>, Table<address, SplitsBalance>>(
        &state.id,
        b"balances",
    );

    let fa_metadata = @0x0;
    if (!table::contains(balances, fa_metadata)) {
        return 0
    };

    table::borrow(balances, fa_metadata).splittable
}

/// Returns account's received funds already split and ready to be collected.
public fun collectable<T>(registry: &SplitsRegistry<T>, account_id: u256): u128 {
    if (!table::contains(&registry.states, account_id)) {
        return 0
    };

    let state = table::borrow(&registry.states, account_id);
    let balances = dynamic_field::borrow<vector<u8>, Table<address, SplitsBalance>>(
        &state.id,
        b"balances",
    );

    let fa_metadata = @0x0;
    if (!table::contains(balances, fa_metadata)) {
        return 0
    };

    table::borrow(balances, fa_metadata).collectable
}

/// Collects account's received already split funds.
/// Resets the collectable balance to 0 and returns the collected amount.
public(package) fun collect<T>(
    registry: &mut SplitsRegistry<T>,
    account_id: u256,
    _ctx: &mut TxContext,
): u128 {
    if (!table::contains(&registry.states, account_id)) {
        return 0
    };

    let state = table::borrow_mut(&mut registry.states, account_id);
    let balances = dynamic_field::borrow_mut<vector<u8>, Table<address, SplitsBalance>>(
        &mut state.id,
        b"balances",
    );

    let fa_metadata = @0x0;
    if (!table::contains(balances, fa_metadata)) {
        return 0
    };

    let balance = table::borrow_mut(balances, fa_metadata);
    let amt = balance.collectable;
    balance.collectable = 0;

    amt
}

/// Gives funds from the account to the receiver.
/// The receiver can split and collect them immediately.
/// Adds the amount directly to the receiver's splittable balance.
public(package) fun give<T>(
    registry: &mut SplitsRegistry<T>,
    _account_id: u256,
    receiver: u256,
    amt: u128,
    ctx: &mut TxContext,
) {
    add_splittable(registry, receiver, amt, ctx);
}

// ═══════════════════════════════════════════════════════════════════════════════
//                            SPLIT OPERATIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// Calculate the result of splitting an amount using the current splits configuration.
/// Does not modify state - use for previewing split results.
public fun split_result<T>(
    registry: &SplitsRegistry<T>,
    account_id: u256,
    curr_receivers: &vector<SplitsReceiver>,
    amount: u128,
): (u128, u128) {
    assert_curr_splits(registry, account_id, curr_receivers);

    if (amount == 0) {
        return (0, 0)
    };

    // Calculate total weight of all receivers
    let mut splits_weight: u64 = 0;
    let len = vector::length(curr_receivers);
    let mut i = 0;
    while (i < len) {
        splits_weight = splits_weight + (vector::borrow(curr_receivers, i).weight as u64);
        i = i + 1;
    };

    let split_amt = (
        (
            (amount as u256) * (splits_weight as u256) / (TOTAL_SPLITS_WEIGHT as u256),
        ) as u128,
    );
    let collectable_amt = amount - split_amt;

    (collectable_amt, split_amt)
}

/// Splits the account's splittable funds among receivers.
/// The entire splittable balance of the given token is split.
/// All split funds are split using the current splits configuration.
///
/// CRITICAL: Refactored to avoid multiple mutable borrows
/// Phase 1: Calculate all splits
/// Phase 2: Apply all splits sequentially
public(package) fun split<T>(
    registry: &mut SplitsRegistry<T>,
    account_id: u256,
    curr_receivers: &vector<SplitsReceiver>,
    ctx: &mut sui::tx_context::TxContext,
): (u128, u128) {
    assert_curr_splits(registry, account_id, curr_receivers);

    ensure_state_exists(&mut registry.states, account_id, ctx);
    let state = table::borrow_mut(&mut registry.states, account_id);

    let fa_metadata = @0x0;
    ensure_balance_exists(state, fa_metadata, ctx);

    // Get splittable amount and reset it
    let balances = dynamic_field::borrow_mut<vector<u8>, Table<address, SplitsBalance>>(
        &mut state.id,
        b"balances",
    );
    let balance = table::borrow_mut(balances, fa_metadata);
    let collectable_amt = balance.splittable;

    if (collectable_amt == 0) {
        return (0, 0)
    };

    // Reset splittable
    balance.splittable = 0;

    // PHASE 1: Calculate all splits (no state mutations)
    let mut split_amounts = vector::empty<SplitAmount>();
    let mut splits_weight: u64 = 0;
    let mut split_amt: u128 = 0;
    let len = vector::length(curr_receivers);
    let mut i = 0;

    while (i < len) {
        let receiver = vector::borrow(curr_receivers, i);
        splits_weight = splits_weight + (receiver.weight as u64);

        // Calculate this receiver's share using cumulative weight
        let curr_split_amt =
            (
                    ((collectable_amt as u256) * (splits_weight as u256)
                        / (TOTAL_SPLITS_WEIGHT as u256)) as u128
                ) - split_amt;
        split_amt = split_amt + curr_split_amt;

        if (curr_split_amt > 0) {
            vector::push_back(
                &mut split_amounts,
                SplitAmount {
                    receiver_id: receiver.account_id,
                    amount: curr_split_amt,
                },
            );
        };

        i = i + 1;
    };

    // PHASE 2: Apply all splits sequentially (avoids multiple mutable borrows)
    let mut j = 0;
    let split_amounts_len = vector::length(&split_amounts);
    while (j < split_amounts_len) {
        let split_amt_struct = vector::borrow(&split_amounts, j);
        let receiver_id = split_amt_struct.receiver_id;
        let amount = split_amt_struct.amount;

        ensure_state_exists(&mut registry.states, receiver_id, ctx);
        let receiver_state = table::borrow_mut(&mut registry.states, receiver_id);
        ensure_balance_exists(receiver_state, fa_metadata, ctx);

        let receiver_balances = dynamic_field::borrow_mut<
            vector<u8>,
            Table<address, SplitsBalance>,
        >(
            &mut receiver_state.id,
            b"balances",
        );
        let receiver_balance = table::borrow_mut(receiver_balances, fa_metadata);
        receiver_balance.splittable = receiver_balance.splittable + amount;

        j = j + 1;
    };

    // Remaining amount goes to account's collectable
    let collectable_amt = collectable_amt - split_amt;

    // Re-borrow sender's state to update collectable
    let state = table::borrow_mut(&mut registry.states, account_id);
    let balances = dynamic_field::borrow_mut<vector<u8>, Table<address, SplitsBalance>>(
        &mut state.id,
        b"balances",
    );
    let balance = table::borrow_mut(balances, fa_metadata);
    balance.collectable = balance.collectable + collectable_amt;

    (collectable_amt, split_amt)
}

/// Sets the account splits configuration.
/// The configuration is common for all token types.
/// Nothing happens to the currently splittable funds, but when they are split
/// after this function finishes, the new splits configuration will be used.
public(package) fun set_splits<T>(
    registry: &mut SplitsRegistry<T>,
    account_id: u256,
    receivers: &vector<SplitsReceiver>,
    ctx: &mut sui::tx_context::TxContext,
) {
    ensure_state_exists(&mut registry.states, account_id, ctx);
    let state = table::borrow_mut(&mut registry.states, account_id);
    let new_splits_hash = hash_splits(receivers);

    // Only validate and update if hash changed
    if (new_splits_hash != state.splits_hash) {
        assert_splits_valid(receivers);
        state.splits_hash = new_splits_hash;
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
//                         VALIDATION & HASHING
// ═══════════════════════════════════════════════════════════════════════════��═══

/// Validates a list of splits receivers.
/// Checks: count <= MAX, no zero weights, sorted by account_id, total weight <= TOTAL.
fun assert_splits_valid(receivers: &vector<SplitsReceiver>) {
    let len = vector::length(receivers);
    assert!(len <= MAX_SPLITS_RECEIVERS, E_TOO_MANY_SPLITS_RECEIVERS);

    let mut total_weight: u64 = 0;
    let mut prev_account_id: u256 = 0;
    let mut i = 0;

    while (i < len) {
        let receiver = vector::borrow(receivers, i);

        // Weight must be non-zero
        assert!(receiver.weight != 0, E_SPLITS_RECEIVER_WEIGHT_ZERO);
        total_weight = total_weight + (receiver.weight as u64);

        // Must be sorted by account_id (strictly increasing)
        if (i > 0) {
            assert!(prev_account_id < receiver.account_id, E_SPLITS_RECEIVERS_NOT_SORTED);
        };
        prev_account_id = receiver.account_id;

        i = i + 1;
    };

    // Total weight must not exceed maximum
    assert!(total_weight <= (TOTAL_SPLITS_WEIGHT as u64), E_SPLITS_WEIGHTS_SUM_TOO_HIGH);
}

/// Asserts that the list of splits receivers is the account's currently used one.
fun assert_curr_splits<T>(
    registry: &SplitsRegistry<T>,
    account_id: u256,
    curr_receivers: &vector<SplitsReceiver>,
) {
    assert!(
        hash_splits(curr_receivers) == splits_hash(registry, account_id),
        E_INVALID_CURRENT_SPLITS_RECEIVERS,
    );
}

/// Returns the current account's splits hash.
public fun splits_hash<T>(registry: &SplitsRegistry<T>, account_id: u256): vector<u8> {
    if (!table::contains(&registry.states, account_id)) {
        return vector::empty()
    };

    table::borrow(&registry.states, account_id).splits_hash
}

/// Calculates the hash of the list of splits receivers.
/// Returns empty vector if receivers is empty, otherwise blake2b_256 hash.
public fun hash_splits(receivers: &vector<SplitsReceiver>): vector<u8> {
    if (vector::length(receivers) == 0) {
        return vector::empty()
    };
    let bytes = bcs::to_bytes(receivers);
    let hash_array = hash::blake2b256(&bytes);
    // Convert [u8; 32] to vector<u8>
    let mut result = vector::empty<u8>();
    let mut i = 0;
    while (i < 32) {
        vector::push_back(&mut result, hash_array[i]);
        i = i + 1;
    };
    result
}
