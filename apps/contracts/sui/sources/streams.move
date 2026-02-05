module xylkstream::streams;

use movemate::i128::{Self, I128};
use movemate::i256::{Self, I256};
use std::vector;
use sui::bcs;
use sui::clock::{Self, Clock};
use sui::dynamic_field;
use sui::event;
use sui::hash;
use sui::object::{Self, UID, ID};
use sui::table::{Self, Table};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

// ═══════════════════════════════════════════════════════════════════════════════
//                              CONSTANTS
// ═══════════════════════════════════════════════════════════════════════════════

/// Maximum number of streams receivers of a single account
const MAX_STREAMS_RECEIVERS: u64 = 100;

/// Additional decimals for all amt_per_sec values
const AMT_PER_SEC_EXTRA_DECIMALS: u8 = 9;

/// Multiplier for all amt_per_sec values (10^AMT_PER_SEC_EXTRA_DECIMALS)
const AMT_PER_SEC_MULTIPLIER: u256 = 1_000_000_000;

/// Maximum streams balance (2^127 - 1)
const MAX_STREAMS_BALANCE: u128 = 170141183460469231731687303715884105727;

/// Maximum u64 value
const MAX_U64: u64 = 18446744073709551615;

/// Default cycle length in seconds (1 week)
const DEFAULT_CYCLE_SECS: u64 = 604800;

// ═══════════════════════════════════════════════════════════════════════════════
//                              ERROR CODES
// ═══════════════════════════════════════════════════════════════════════════════

/// Too many streams receivers (max 100)
const E_TOO_MANY_RECEIVERS: u64 = 1;
/// Streams receivers not sorted by account_id then config
const E_RECEIVERS_NOT_SORTED: u64 = 2;
/// Stream receiver amt_per_sec below minimum (1 token per cycle)
const E_AMT_PER_SEC_TOO_LOW: u64 = 3;
/// Cycle length must be greater than 1
const E_CYCLE_SECS_TOO_LOW: u64 = 4;
/// Invalid streams receivers list (hash mismatch)
const E_INVALID_STREAMS_RECEIVERS: u64 = 5;
/// Invalid streams history (hash mismatch)
const E_INVALID_STREAMS_HISTORY: u64 = 6;
/// History entry has both hash and receivers (must have one or the other)
const E_ENTRY_WITH_HASH_AND_RECEIVERS: u64 = 7;
/// Timestamp is before the last streams update
const E_TIMESTAMP_BEFORE_UPDATE: u64 = 8;

// ═══════════════════════════════════════════════════════════════════════════════
//                              STORAGE & TYPES
// ═══════════════════════════════════════════════════════════════════════════════

/// Global shared registry for streams state per token type
/// Type parameter T represents the Coin type (e.g., Coin<SUI>, Coin<USDC>)
struct StreamsRegistry<phantom T> has key {
    id: UID,
    /// Cycle length in seconds (set once at initialization, must be > 1)
    cycle_secs: u64,
    /// Minimum amt_per_sec: 1 token per cycle = ceil(AMT_PER_SEC_MULTIPLIER / cycle_secs)
    min_amt_per_sec: u256,
    /// All account states: account_id -> StreamsState
    states: Table<u256, StreamsState>,
}

/// Per-account streams state
/// Note: nested tables (next_squeezed, amt_deltas) stored as dynamic fields
struct StreamsState has store {
    id: UID,
    /// Hash of streams history for squeeze validation
    streams_history_hash: vector<u8>,
    /// Hash of current streams receivers list
    streams_hash: vector<u8>,
    /// Next cycle that can be received
    next_receivable_cycle: u64,
    /// Time when streams were last configured
    update_time: u64,
    /// When funds will run out
    max_end: u64,
    /// Balance snapshot at last update
    balance: u128,
    /// Number of configs seen in current cycle (for squeeze)
    curr_cycle_configs: u64,
    // Dynamic fields:
    // - "next_squeezed": Table<NextSqueezedKey, u64>
    // - "amt_deltas": Table<u64, AmtDelta>
}

/// Key for next_squeezed mapping
struct NextSqueezedKey has copy, drop, store {
    sender_account_id: u256,
    config_index: u64,
}

/// Delta amounts applied to cycles
struct AmtDelta has copy, drop, store {
    this_cycle: I128,
    next_cycle: I128,
}

/// Stream receiver configuration
struct StreamReceiver has copy, drop, store {
    account_id: u256,
    config: StreamConfig,
}

/// Stream configuration settings
struct StreamConfig has copy, drop, store {
    stream_id: u64,
    amt_per_sec: u256,
    start: u64,
    duration: u64,
}

/// History entry for squeezing
struct StreamsHistory has copy, drop, store {
    streams_hash: vector<u8>,
    receivers: vector<StreamReceiver>,
    update_time: u64,
    max_end: u64,
}

/// Preprocessed stream config for balance calculations
struct ProcessedConfig has copy, drop, store {
    amt_per_sec: u256,
    start: u64,
    end: u64,
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              EVENTS
// ═══════════════════════════════════════════════════════════════════════════════

/// Emitted when a new StreamsRegistry is created for a token type
/// Indexer tracks this to provide registry object IDs to clients
struct RegistryCreated<phantom T> has copy, drop {
    registry_id: ID,
    cycle_secs: u64,
    min_amt_per_sec: u256,
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              INITIALIZATION
// ═══════════════════════════════════════════════════════════════════════════════

/// Module initializer - creates shared registry with default cycle length
/// Called automatically when module is published
fun init(ctx: &mut TxContext) {}

/// Creates and shares a new StreamsRegistry for a specific token type
/// Should be called once per token type (SUI, USDC, etc.)
/// Emits RegistryCreated event for indexer to track
public fun create_registry<T>(cycle_secs: u64, ctx: &mut TxContext) {
    assert!(cycle_secs > 1, E_CYCLE_SECS_TOO_LOW);

    // min_amt_per_sec = ceil(AMT_PER_SEC_MULTIPLIER / cycle_secs)
    let min_amt_per_sec =
        (AMT_PER_SEC_MULTIPLIER + (cycle_secs as u256) - 1) / (cycle_secs as u256);

    let registry = StreamsRegistry<T> {
        id: object::new(ctx),
        cycle_secs,
        min_amt_per_sec,
        states: table::new(ctx),
    };

    let registry_id = object::id(&registry);

    // Emit event for indexer to track registry object ID
    event::emit(RegistryCreated<T> {
        registry_id,
        cycle_secs,
        min_amt_per_sec,
    });

    transfer::share_object(registry);
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              CONSTRUCTORS
// ═══════════════════════════════════════════════════════════════════════════════

/// Creates a new StreamReceiver
public fun new_stream_receiver(
    account_id: u256,
    stream_id: u64,
    amt_per_sec: u256,
    start: u64,
    duration: u64,
): StreamReceiver {
    StreamReceiver {
        account_id,
        config: StreamConfig { stream_id, amt_per_sec, start, duration },
    }
}

/// Creates a new StreamsHistory entry
public fun new_streams_history(
    streams_hash: vector<u8>,
    receivers: vector<StreamReceiver>,
    update_time: u64,
    max_end: u64,
): StreamsHistory {
    StreamsHistory { streams_hash, receivers, update_time, max_end }
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              CORE UTILITIES
// ═══════════════════════════════════════════════════════════════════════════════

/// Returns current timestamp from Clock object
fun curr_timestamp(clock: &Clock): u64 {
    clock::timestamp_ms(clock) / 1000
}

/// Returns the cycle containing the given timestamp
/// Note: There can never be cycle 0 (timestamp / cycle_secs + 1)
fun cycle_of(ts: u64, cycle_secs: u64): u64 {
    ts / cycle_secs + 1
}

/// Returns the start timestamp of the current cycle
fun curr_cycle_start(cycle_secs: u64, clock: &Clock): u64 {
    let curr_ts = curr_timestamp(clock);
    curr_ts - (curr_ts % cycle_secs)
}

/// Calculates the amount streamed over a time range
/// Uses: floor(end × rate) - floor(start × rate)
fun streamed_amt(amt_per_sec: u256, start: u64, end: u64): u256 {
    if (end <= start) {
        return 0
    };
    let amt_end = ((end as u256) * amt_per_sec) / AMT_PER_SEC_MULTIPLIER;
    let amt_start = ((start as u256) * amt_per_sec) / AMT_PER_SEC_MULTIPLIER;
    amt_end - amt_start
}

/// Calculates the time range in which a receiver is streamed to, capped to a window
fun stream_range(
    config: &StreamConfig,
    update_time: u64,
    max_end: u64,
    start_cap: u64,
    end_cap: u64,
): (u64, u64) {
    let stream_start = if (config.start == 0) {
        update_time
    } else {
        config.start
    };
    let stream_end = stream_start + config.duration;

    // If duration is 0 (forever) or exceeds max_end, cap to max_end
    if (stream_end == stream_start || stream_end > max_end) {
        stream_end = max_end
    };

    let start = max_u64(stream_start, start_cap);
    let end = max_u64(min_u64(stream_end, end_cap), start);

    (start, end)
}

/// Calculates the time range in the future in which a receiver will be streamed to
fun stream_range_in_future(
    receiver: &StreamReceiver,
    update_time: u64,
    max_end: u64,
    clock: &Clock,
): (u64, u64) {
    stream_range(
        &receiver.config,
        update_time,
        max_end,
        curr_timestamp(clock),
        MAX_U64,
    )
}

/// Checks if receivers are properly ordered
/// First by account_id, then by config (stream_id, amt_per_sec, start, duration)
fun is_ordered(prev: &StreamReceiver, next: &StreamReceiver): bool {
    if (prev.account_id != next.account_id) {
        return prev.account_id < next.account_id
    };
    // Same account_id: compare configs lexicographically
    config_lt(&prev.config, &next.config)
}

/// Config less-than comparison
/// Compares as if packed: stream_id | amt_per_sec | start | duration
fun config_lt(a: &StreamConfig, b: &StreamConfig): bool {
    if (a.stream_id != b.stream_id) {
        return a.stream_id < b.stream_id
    };
    if (a.amt_per_sec != b.amt_per_sec) {
        return a.amt_per_sec < b.amt_per_sec
    };
    if (a.start != b.start) {
        return a.start < b.start
    };
    a.duration < b.duration
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              HELPER FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════════

fun max_u64(a: u64, b: u64): u64 {
    if (a > b) { a } else { b }
}

fun min_u64(a: u64, b: u64): u64 {
    if (a < b) { a } else { b }
}

/// Helper to process cycles and accumulate received amounts
fun process_cycles(
    state: &StreamsState,
    from_cycle: u64,
    to_cycle: u64,
    received_amt: u128,
    amt_per_cycle: I128,
): (u128, I128) {
    let cycle = from_cycle;
    let acc_received = received_amt;
    let acc_rate = amt_per_cycle;

    // Borrow amt_deltas table from dynamic field
    let amt_deltas = dynamic_field::borrow<vector<u8>, Table<u64, AmtDelta>>(
        &state.id,
        b"amt_deltas",
    );

    while (cycle < to_cycle) {
        if (table::contains(amt_deltas, cycle)) {
            let delta = table::borrow(amt_deltas, cycle);
            acc_rate = i128::add(&acc_rate, &delta.this_cycle);
            acc_received = acc_received + i128::as_u128(&acc_rate);
            acc_rate = i128::add(&acc_rate, &delta.next_cycle);
        } else {
            // No delta for this cycle, just accumulate current rate
            acc_received = acc_received + i128::as_u128(&acc_rate);
        };
        cycle = cycle + 1;
    };

    (acc_received, acc_rate)
}

// ═══════════════════════════════════════════════════════════════════════════════
//                         HASHING & CONFIGURATION
// ═══════════════════════════════════════════════════════════════════════════════

/// Calculates the hash of the streams configuration
/// Returns empty vector if receivers is empty, otherwise blake2b_256 hash
public fun hash_streams(receivers: &vector<StreamReceiver>): vector<u8> {
    if (vector::length(receivers) == 0) {
        return vector::empty<u8>()
    };
    let bytes = bcs::to_bytes(receivers);
    vector::from_slice(&hash::blake2b256(&bytes), 0, 32)
}

/// Calculates the hash of the streams history after configuration update
/// The history hash forms a chain: each new config hashes with the previous history hash
public fun hash_streams_history(
    old_streams_history_hash: &vector<u8>,
    streams_hash: &vector<u8>,
    update_time: u64,
    max_end: u64,
): vector<u8> {
    let data = vector::empty<u8>();
    vector::append(&mut data, *old_streams_history_hash);
    vector::append(&mut data, *streams_hash);
    vector::append(&mut data, bcs::to_bytes(&update_time));
    vector::append(&mut data, bcs::to_bytes(&max_end));
    vector::from_slice(&hash::blake2b256(&data), 0, 32)
}

/// Builds a preprocessed list of stream configurations from receivers
/// Validates sorting, deduplication, and amt_per_sec requirements
/// Skips expired streams (where start == end after range calculation)
fun build_configs<T>(
    registry: &StreamsRegistry<T>,
    receivers: &vector<StreamReceiver>,
    clock: &Clock,
): vector<ProcessedConfig> {
    let len = vector::length(receivers);
    assert!(len <= MAX_STREAMS_RECEIVERS, E_TOO_MANY_RECEIVERS);

    let configs = vector::empty<ProcessedConfig>();
    let min_amt = registry.min_amt_per_sec;
    let curr_ts = curr_timestamp(clock);

    let i = 0;
    while (i < len) {
        let receiver = vector::borrow(receivers, i);

        if (i > 0) {
            let prev = vector::borrow(receivers, i - 1);
            assert!(is_ordered(prev, receiver), E_RECEIVERS_NOT_SORTED);
        };

        assert!(receiver.config.amt_per_sec >= min_amt, E_AMT_PER_SEC_TOO_LOW);

        let (start, end) = stream_range_in_future(receiver, curr_ts, MAX_U64, clock);

        // Skip expired streams
        if (start != end) {
            vector::push_back(
                &mut configs,
                ProcessedConfig { amt_per_sec: receiver.config.amt_per_sec, start, end },
            );
        };

        i = i + 1;
    };

    configs
}

/// Extracts config values from the preprocessed configs vector
fun get_config(configs: &vector<ProcessedConfig>, idx: u64): (u256, u64, u64) {
    let config = vector::borrow(configs, idx);
    (config.amt_per_sec, config.start, config.end)
}

/// Verifies that the provided receivers list matches the stored hash
fun verify_streams_receivers(receivers: &vector<StreamReceiver>, state: &StreamsState) {
    let provided_hash = hash_streams(receivers);
    assert!(provided_hash == state.streams_hash, E_INVALID_STREAMS_RECEIVERS);
}

/// Verifies a streams history chain and returns the history hashes
/// Each entry's hash is computed and chained to verify the final hash matches
/// Returns vector of history hashes valid for squeezing each entry
fun verify_streams_history(
    history_hash: vector<u8>,
    streams_history: &vector<StreamsHistory>,
    final_history_hash: &vector<u8>,
): vector<vector<u8>> {
    let len = vector::length(streams_history);
    let history_hashes = vector::empty<vector<u8>>();
    let current_hash = history_hash;

    let i = 0;
    while (i < len) {
        let entry = vector::borrow(streams_history, i);

        let streams_hash = if (vector::length(&entry.receivers) != 0) {
            // Entry has receivers so hash MUST stay empty
            assert!(
                vector::length(&entry.streams_hash) == 0,
                E_ENTRY_WITH_HASH_AND_RECEIVERS,
            );
            hash_streams(&entry.receivers)
        } else {
            // Entry has no receivers (signals receiver has no stream in entry so skips)
            entry.streams_hash
        };

        // Store hash valid BEFORE this entry
        vector::push_back(&mut history_hashes, current_hash);

        current_hash =
            hash_streams_history(
                &current_hash,
                &streams_hash,
                entry.update_time,
                entry.max_end,
            );

        i = i + 1;
    };

    assert!(current_hash == *final_history_hash, E_INVALID_STREAMS_HISTORY);

    history_hashes
}

// ═══════════════════════════════════════════════════════════════════════════════
//                            DELTA ACCOUNTING
// ═══════════════════════════════════════════════════════════════════════════════

/// Adds delta of funds received by an account at a given timestamp
/// To set a delta on a specific timestamp it must be introduced in two cycles.
/// The math follows _streamedAmt logic for consistency.
fun add_delta(
    state: &mut StreamsState,
    timestamp: u64,
    amt_per_sec: I256,
    cycle_secs: u64,
    ctx: &mut TxContext,
) {
    let multiplier = i256::from((AMT_PER_SEC_MULTIPLIER as u256));

    let cycle_secs_i256 = i256::from_u64(cycle_secs);
    let full_cycle = i256::div(
        &i256::mul(&cycle_secs_i256, &amt_per_sec),
        &multiplier,
    );
    let remainder = timestamp % cycle_secs;
    let remainder_i256 = i256::from_u64(remainder);
    let next_cycle = i256::div(
        &i256::mul(&remainder_i256, &amt_per_sec),
        &multiplier,
    );
    let cycle = cycle_of(timestamp, cycle_secs);

    // Borrow amt_deltas table mutably from dynamic field
    let amt_deltas = dynamic_field::borrow_mut<vector<u8>, Table<u64, AmtDelta>>(
        &mut state.id,
        b"amt_deltas",
    );

    if (!table::contains(amt_deltas, cycle)) {
        table::add(
            amt_deltas,
            cycle,
            AmtDelta {
                this_cycle: i128::zero(),
                next_cycle: i128::zero(),
            },
        );
    };

    let delta = table::borrow_mut(amt_deltas, cycle);
    let this_cycle_delta = i256::sub(&full_cycle, &next_cycle);
    let this_cycle_to_add = i128::from_bits(i256::as_i128(&this_cycle_delta));
    let next_cycle_to_add = i128::from_bits(i256::as_i128(&next_cycle));
    delta.this_cycle = i128::add(&delta.this_cycle, &this_cycle_to_add);
    delta.next_cycle = i128::add(&delta.next_cycle, &next_cycle_to_add);
}

/// Adds funds received by an account in a given time range
/// `state`: The account state
/// `start`: The timestamp from which the delta takes effect
/// `end`: The timestamp until which the delta takes effect
/// `amt_per_sec`: The streaming rate (can be negative to remove)
fun add_delta_range(
    state: &mut StreamsState,
    start: u64,
    end: u64,
    amt_per_sec: I256,
    cycle_secs: u64,
    ctx: &mut TxContext,
) {
    if (start == end) { return };
    add_delta(
        state,
        start,
        amt_per_sec,
        cycle_secs,
        ctx,
    );
    let neg_amt_per_sec = i256::neg(&amt_per_sec);
    add_delta(
        state,
        end,
        neg_amt_per_sec,
        cycle_secs,
        ctx,
    );
}

/// Applies the effects of streams configuration changes on receivers' states
/// Uses a two-pointer merge approach to efficiently diff old vs new receivers
fun update_receiver_states<T>(
    registry: &mut StreamsRegistry<T>,
    curr_receivers: &vector<StreamReceiver>,
    last_update: u64,
    curr_max_end: u64,
    new_receivers: &vector<StreamReceiver>,
    new_max_end: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let curr_len = vector::length(curr_receivers);
    let new_len = vector::length(new_receivers);
    let curr_idx: u64 = 0;
    let new_idx: u64 = 0;
    let cycle_secs = registry.cycle_secs;
    let curr_ts = curr_timestamp(clock);

    loop {
        let pick_curr = curr_idx < curr_len;
        let pick_new = new_idx < new_len;

        // Get current receiver if available
        let curr_recv = if (pick_curr) {
            *vector::borrow(curr_receivers, curr_idx)
        } else {
            StreamReceiver {
                account_id: 0,
                config: StreamConfig {
                    stream_id: 0,
                    amt_per_sec: 0,
                    start: 0,
                    duration: 0,
                },
            }
        };

        // Get new receiver if available
        let new_recv = if (pick_new) {
            *vector::borrow(new_receivers, new_idx)
        } else {
            StreamReceiver {
                account_id: 0,
                config: StreamConfig {
                    stream_id: 0,
                    amt_per_sec: 0,
                    start: 0,
                    duration: 0,
                },
            }
        };

        // Limit picking both to situations when they differ only by time
        if (pick_curr && pick_new) {
            if (
                curr_recv.account_id != new_recv.account_id
                    || curr_recv.config.amt_per_sec != new_recv.config.amt_per_sec
            ) {
                pick_curr = is_ordered(&curr_recv, &new_recv);
                pick_new = !pick_curr;
            };
        };

        if (pick_curr && pick_new) {
            // Shift existing stream to fulfil new configuration
            ensure_state_exists(&mut registry.states, curr_recv.account_id, ctx);
            let state = table::borrow_mut(&mut registry.states, curr_recv.account_id);

            let (curr_start, curr_end) = stream_range(
                &curr_recv.config,
                last_update,
                curr_max_end,
                curr_ts,
                MAX_U64,
            );
            let (new_start, new_end) = stream_range(
                &new_recv.config,
                curr_ts,
                new_max_end,
                curr_ts,
                MAX_U64,
            );

            let amt_per_sec = i256::from_u128((curr_recv.config.amt_per_sec as u128));

            // Optimization: instead of removing old range and adding new range,
            // just adjust the start and end deltas
            let neg_amt_per_sec = i256::neg(&amt_per_sec);
            add_delta_range(
                state,
                curr_start,
                new_start,
                neg_amt_per_sec,
                cycle_secs,
                ctx,
            );
            add_delta_range(
                state,
                curr_end,
                new_end,
                amt_per_sec,
                cycle_secs,
                ctx,
            );

            // Ensure account receives updated cycles
            let curr_start_cycle = cycle_of(curr_start, cycle_secs);
            let new_start_cycle = cycle_of(new_start, cycle_secs);
            if (
                curr_start_cycle > new_start_cycle
                    && state.next_receivable_cycle > new_start_cycle
            ) {
                state.next_receivable_cycle = new_start_cycle;
            };

            curr_idx = curr_idx + 1;
            new_idx = new_idx + 1;
        } else if (pick_curr) {
            // Remove an existing stream
            ensure_state_exists(&mut registry.states, curr_recv.account_id, ctx);
            let state = table::borrow_mut(&mut registry.states, curr_recv.account_id);

            let (start, end) = stream_range(
                &curr_recv.config,
                last_update,
                curr_max_end,
                curr_ts,
                MAX_U64,
            );
            let amt_per_sec = i256::from_u128((curr_recv.config.amt_per_sec as u128));
            let neg_amt_per_sec = i256::neg(&amt_per_sec);
            add_delta_range(state, start, end, neg_amt_per_sec, cycle_secs, ctx);

            curr_idx = curr_idx + 1;
        } else if (pick_new) {
            // Create a new stream
            ensure_state_exists(&mut registry.states, new_recv.account_id, ctx);
            let state = table::borrow_mut(&mut registry.states, new_recv.account_id);

            let (start, end) = stream_range(
                &new_recv.config,
                curr_ts,
                new_max_end,
                curr_ts,
                MAX_U64,
            );
            let amt_per_sec = i256::from_u128((new_recv.config.amt_per_sec as u128));
            add_delta_range(state, start, end, amt_per_sec, cycle_secs, ctx);

            // Ensure account receives updated cycles
            let start_cycle = cycle_of(start, cycle_secs);
            let next_receivable = state.next_receivable_cycle;
            if (next_receivable == 0 || next_receivable > start_cycle) {
                state.next_receivable_cycle = start_cycle;
            };

            new_idx = new_idx + 1;
        } else { break };
    };
}

/// Ensures a StreamsState exists for the given account_id, creating if needed
fun ensure_state_exists(
    states: &mut Table<u256, StreamsState>,
    account_id: u256,
    ctx: &mut TxContext,
) {
    if (!table::contains(states, account_id)) {
        let state_id = object::new(ctx);

        // Create nested tables as dynamic fields
        dynamic_field::add(
            &mut state_id,
            b"next_squeezed",
            table::new<NextSqueezedKey, u64>(ctx),
        );
        dynamic_field::add(
            &mut state_id,
            b"amt_deltas",
            table::new<u64, AmtDelta>(ctx),
        );

        let state = StreamsState {
            id: state_id,
            streams_history_hash: vector::empty(),
            streams_hash: vector::empty(),
            next_receivable_cycle: 0,
            update_time: 0,
            max_end: 0,
            balance: 0,
            curr_cycle_configs: 0,
        };

        table::add(states, account_id, state);
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
//                        BALANCE & MAX END CALCULATION
// ═══════════════════════════════════════════════════════════════════════════════

/// Returns the account's streams balance at a given timestamp
/// `registry`: The streams registry for token type T
/// `account_id`: The account ID
/// `curr_receivers`: Current receivers list (must match stored hash)
/// `timestamp`: The timestamp to calculate balance at (must be >= update_time)
public fun balance_at<T>(
    registry: &StreamsRegistry<T>,
    account_id: u256,
    curr_receivers: &vector<StreamReceiver>,
    timestamp: u64,
): u128 {
    // Non-existent account = 0 balance
    if (!table::contains(&registry.states, account_id)) {
        return 0
    };

    let state = table::borrow(&registry.states, account_id);
    assert!(timestamp >= state.update_time, E_TIMESTAMP_BEFORE_UPDATE);
    verify_streams_receivers(curr_receivers, state);

    calc_balance(
        state.balance,
        state.update_time,
        state.max_end,
        curr_receivers,
        timestamp,
    )
}

/// Calculates the streams balance at a given timestamp
/// Subtracts all amounts streamed from last_update to timestamp
fun calc_balance(
    last_balance: u128,
    last_update: u64,
    max_end: u64,
    receivers: &vector<StreamReceiver>,
    timestamp: u64,
): u128 {
    let balance = (last_balance as u256);
    let len = vector::length(receivers);
    let i = 0;

    while (i < len) {
        let receiver = vector::borrow(receivers, i);
        let (start, end) = stream_range(
            &receiver.config,
            last_update,
            max_end,
            last_update,
            timestamp,
        );
        let spent = streamed_amt(receiver.config.amt_per_sec, start, end);
        balance = balance - spent;
        i = i + 1;
    };

    (balance as u128)
}

/// Calculates the maximum end time when all streams stop due to funds running out
/// Uses binary search between current timestamp and max u64
public fun calc_max_end<T>(
    registry: &StreamsRegistry<T>,
    balance: u128,
    receivers: &vector<StreamReceiver>,
    hint1: u64,
    hint2: u64,
    clock: &Clock,
): u64 {
    let configs = build_configs(registry, receivers, clock);
    let configs_len = vector::length(&configs);
    let min_guaranteed_end = curr_timestamp(clock);

    // No configs or zero balance = end now
    if (configs_len == 0 || balance == 0) {
        return min_guaranteed_end
    };

    let max_possible_end = MAX_U64;
    // Balance covers everything forever
    if (is_balance_enough(balance, &configs, max_possible_end)) {
        return max_possible_end
    };

    // Use u256 for arithmetic to avoid overflow
    let enough_end: u256 = (min_guaranteed_end as u256);
    let not_enough_end: u256 = (max_possible_end as u256);

    if ((hint1 as u256) > enough_end && (hint1 as u256) < not_enough_end) {
        if (is_balance_enough(balance, &configs, hint1)) {
            enough_end = (hint1 as u256);
        } else {
            not_enough_end = (hint1 as u256);
        };
    };

    if ((hint2 as u256) > enough_end && (hint2 as u256) < not_enough_end) {
        if (is_balance_enough(balance, &configs, hint2)) {
            enough_end = (hint2 as u256);
        } else {
            not_enough_end = (hint2 as u256);
        };
    };

    // Binary search for exact end time
    loop {
        let mid = (enough_end + not_enough_end) / 2;
        if (mid == enough_end) {
            return (mid as u64)
        };
        if (is_balance_enough(balance, &configs, (mid as u64))) {
            enough_end = mid;
        } else {
            not_enough_end = mid;
        };
    }
}

/// Checks if balance is enough to cover all streams until max_end
fun is_balance_enough(
    balance: u128,
    configs: &vector<ProcessedConfig>,
    max_end: u64,
): bool {
    let spent: u256 = 0;
    let balance_u256 = (balance as u256);
    let len = vector::length(configs);
    let i = 0;

    while (i < len) {
        let (amt_per_sec, start, end) = get_config(configs, i);

        // Stream hasn't started yet at max_end
        if (max_end <= start) {
            i = i + 1;
            continue
        };

        // Cap end to max_end
        let capped_end = if (end > max_end) {
            max_end
        } else { end };

        spent = spent + streamed_amt(amt_per_sec, start, capped_end);

        // Early exit if already over budget
        if (spent > balance_u256) {
            return false
        };

        i = i + 1;
    };

    true
}

// ═══════════════════════════════════════════════════════════════════════════════
//                            RECEIVING STREAMS
// ═══════════════════════════════════════════════════════════════════════════════

/// Returns the number of cycles from which streams can be collected.
/// Useful to detect if there are too many cycles to analyze in a single transaction.
public fun receivable_streams_cycles<T>(
    registry: &StreamsRegistry<T>,
    account_id: u256,
    clock: &Clock,
): u64 {
    let (from_cycle, to_cycle) = receivable_streams_cycles_range(
        registry,
        account_id,
        clock,
    );
    if (to_cycle > from_cycle) {
        to_cycle - from_cycle
    } else { 0 }
}

/// Returns (from_cycle, to_cycle) range for receivable streams
fun receivable_streams_cycles_range<T>(
    registry: &StreamsRegistry<T>,
    account_id: u256,
    clock: &Clock,
): (u64, u64) {
    if (!table::contains(&registry.states, account_id)) {
        return (0, 0)
    };

    let state = table::borrow(&registry.states, account_id);
    let from_cycle = state.next_receivable_cycle;
    let to_cycle = cycle_of(curr_timestamp(clock), registry.cycle_secs);

    // Nothing to receive if from_cycle is 0 or ahead of current cycle
    if (from_cycle == 0 || to_cycle < from_cycle) {
        (from_cycle, from_cycle)
    } else {
        (from_cycle, to_cycle)
    }
}

/// Calculate effects of calling `receive_streams` with the given parameters
/// Returns: (received_amt, receivable_cycles, from_cycle, to_cycle, amt_per_cycle)
public fun receive_streams_result<T>(
    registry: &StreamsRegistry<T>,
    account_id: u256,
    max_cycles: u64,
    clock: &Clock,
): (u128, u64, u64, u64, I128) {
    let (from_cycle, to_cycle_raw) = receivable_streams_cycles_range(
        registry,
        account_id,
        clock,
    );

    // Cap cycles to max_cycles
    let (receivable_cycles, to_cycle) = if (to_cycle_raw - from_cycle > max_cycles) {
        let remaining = to_cycle_raw - from_cycle - max_cycles;
        (remaining, to_cycle_raw - remaining)
    } else {
        (0, to_cycle_raw)
    };

    let received_amt: u128 = 0;
    let amt_per_cycle: I128 = i128::zero();

    // Only process if state exists and there are cycles to process
    let (final_received_amt, final_amt_per_cycle) = if (
        table::contains(&registry.states, account_id) && from_cycle < to_cycle
    ) {
        let state = table::borrow(&registry.states, account_id);
        process_cycles(
            state,
            from_cycle,
            to_cycle,
            received_amt,
            amt_per_cycle,
        )
    } else {
        (received_amt, amt_per_cycle)
    };

    (final_received_amt, receivable_cycles, from_cycle, to_cycle, final_amt_per_cycle)
}

/// Receive streams from unreceived cycles of the account.
/// Received streams cycles won't need to be analyzed ever again.
/// Returns: `received_amt` - The amount received
public(package) fun receive_streams<T>(
    registry: &mut StreamsRegistry<T>,
    account_id: u256,
    max_cycles: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u128 {
    let (
        received_amt,
        _receivable_cycles,
        from_cycle,
        to_cycle,
        final_amt_per_cycle,
    ) = receive_streams_result(registry, account_id, max_cycles, clock);

    if (from_cycle != to_cycle) {
        ensure_state_exists(&mut registry.states, account_id, ctx);
        let state = table::borrow_mut(&mut registry.states, account_id);

        // Update next receivable cycle
        state.next_receivable_cycle = to_cycle;

        // Delete processed cycle deltas - CRITICAL for preventing unbounded growth
        let amt_deltas = dynamic_field::borrow_mut<vector<u8>, Table<u64, AmtDelta>>(
            &mut state.id,
            b"amt_deltas",
        );

        let cycle = from_cycle;
        while (cycle < to_cycle) {
            if (table::contains(amt_deltas, cycle)) {
                table::remove(amt_deltas, cycle);
            };
            cycle = cycle + 1;
        };

        // The next cycle delta must be relative to the last received cycle (which got zeroed)
        // In other words, the next cycle delta must be an absolute value
        if (!i128::is_zero(&final_amt_per_cycle)) {
            if (!table::contains(amt_deltas, to_cycle)) {
                table::add(
                    amt_deltas,
                    to_cycle,
                    AmtDelta {
                        this_cycle: i128::zero(),
                        next_cycle: i128::zero(),
                    },
                );
            };
            let delta = table::borrow_mut(amt_deltas, to_cycle);
            delta.this_cycle = i128::add(&delta.this_cycle, &final_amt_per_cycle);
        };
    };

    received_amt
}

// ═══════════════════════════════════════════════════════════════════════════════
//                          SQUEEZING & SET STREAMS
// ═══════════════════════════════════════════════════════════════════════════════

/// Squeeze streams from the currently running cycle from a single sender.
/// It doesn't receive streams from finished cycles - use `receive_streams` for that.
/// Squeezed funds won't be received in subsequent calls to `squeeze_streams` or `receive_streams`.
/// Only funds streamed before current timestamp can be squeezed.
/// Returns: `amt` - The squeezed amount
public(package) fun squeeze_streams<T>(
    registry: &mut StreamsRegistry<T>,
    account_id: u256,
    sender_id: u256,
    history_hash: vector<u8>,
    streams_history: &vector<StreamsHistory>,
    clock: &Clock,
    ctx: &mut TxContext,
): u128 {
    let (
        amt,
        squeezed_indexes,
        _history_hashes,
        curr_cycle_configs,
    ) = squeeze_streams_result(
        registry,
        account_id,
        sender_id,
        history_hash,
        streams_history,
        clock,
    );

    let cycle_secs = registry.cycle_secs;
    ensure_state_exists(&mut registry.states, account_id, ctx);
    let state = table::borrow_mut(&mut registry.states, account_id);

    // Update next_squeezed timestamps
    let next_squeezed = dynamic_field::borrow_mut<vector<u8>, Table<NextSqueezedKey, u64>>(
        &mut state.id,
        b"next_squeezed",
    );

    let squeezed_len = vector::length(&squeezed_indexes);
    let i = 0;
    while (i < squeezed_len) {
        let idx = *vector::borrow(&squeezed_indexes, i);
        let config_index = curr_cycle_configs - idx;
        let squeezed_key = NextSqueezedKey {
            sender_account_id: sender_id,
            config_index,
        };
        let curr_ts = curr_timestamp(clock);
        if (table::contains(next_squeezed, squeezed_key)) {
            *table::borrow_mut(next_squeezed, squeezed_key) = curr_ts;
        } else {
            table::add(next_squeezed, squeezed_key, curr_ts);
        };
        i = i + 1;
    };

    // Apply negative delta to remove squeezed amount from current cycle
    // This prevents double-receiving via receive_streams
    if (amt > 0) {
        let cycle_start = curr_cycle_start(cycle_secs, clock);
        let amt_i256 = i256::from_u128(amt);
        let multiplier_i256 = i256::from(AMT_PER_SEC_MULTIPLIER);
        let neg_amt_per_sec = i256::neg(&i256::mul(&amt_i256, &multiplier_i256));
        add_delta_range(
            state,
            cycle_start,
            cycle_start + 1,
            neg_amt_per_sec,
            cycle_secs,
            ctx,
        );
    };

    amt
}

/// Calculate effects of calling `squeeze_streams` with the given parameters.
/// Returns: (amt, squeezed_indexes, history_hashes, curr_cycle_configs)
public fun squeeze_streams_result<T>(
    registry: &StreamsRegistry<T>,
    account_id: u256,
    sender_id: u256,
    history_hash: vector<u8>,
    streams_history: &vector<StreamsHistory>,
    clock: &Clock,
): (u128, vector<u64>, vector<vector<u8>>, u64) {
    let cycle_secs = registry.cycle_secs;

    // Get sender's final history hash for verification
    let final_history_hash = if (table::contains(&registry.states, sender_id)) {
        table::borrow(&registry.states, sender_id).streams_history_hash
    } else {
        vector::empty<u8>()
    };

    // Verify the history chain
    let history_hashes = verify_streams_history(
        history_hash,
        streams_history,
        &final_history_hash,
    );

    // Determine how many configs to check in current cycle
    let curr_cycle_start_ts = curr_cycle_start(cycle_secs, clock);
    let curr_cycle_configs = if (table::contains(&registry.states, sender_id)) {
        let sender_state = table::borrow(&registry.states, sender_id);
        if (sender_state.update_time >= curr_cycle_start_ts) {
            sender_state.curr_cycle_configs
        } else { 1 }
    } else { 1 };

    let amt: u128 = 0;
    let squeezed_indexes = vector::empty<u64>();
    let squeeze_end_cap = curr_timestamp(clock);
    let history_len = vector::length(streams_history);

    // Process history entries from newest to oldest (up to curr_cycle_configs)
    let i: u64 = 1;
    while (i <= history_len && i <= curr_cycle_configs) {
        let entry_idx = history_len - i;
        let entry = vector::borrow(streams_history, entry_idx);

        // Skip entries with no receivers
        if (vector::length(&entry.receivers) != 0) {
            // Get next_squeezed timestamp (0 if never squeezed)
            let next_squeezed_ts = if (table::contains(&registry.states, account_id)) {
                let state = table::borrow(&registry.states, account_id);
                let next_squeezed = dynamic_field::borrow<
                    vector<u8>,
                    Table<NextSqueezedKey, u64>,
                >(
                    &state.id,
                    b"next_squeezed",
                );
                let key = NextSqueezedKey {
                    sender_account_id: sender_id,
                    config_index: curr_cycle_configs - i,
                };
                if (table::contains(next_squeezed, key)) {
                    *table::borrow(next_squeezed, key)
                } else { 0 }
            } else { 0 };

            // squeeze_start_cap = max(next_squeezed, curr_cycle_start, entry.update_time)
            let squeeze_start_cap = max_u64(
                max_u64(next_squeezed_ts, curr_cycle_start_ts),
                entry.update_time,
            );

            // Only squeeze if there's a valid time range
            if (squeeze_start_cap < squeeze_end_cap) {
                vector::push_back(&mut squeezed_indexes, i);
                amt =
                    amt + squeezed_amt(
                        account_id,
                        entry,
                        squeeze_start_cap,
                        squeeze_end_cap
                    );
            };
        };

        // Next entry's end cap is this entry's update_time
        squeeze_end_cap = entry.update_time;
        i = i + 1;
    };

    // Reverse squeezed_indexes to be oldest-to-newest
    let reversed = vector::empty<u64>();
    let j = vector::length(&squeezed_indexes);
    while (j > 0) {
        j = j - 1;
        vector::push_back(&mut reversed, *vector::borrow(&squeezed_indexes, j));
    };

    (amt, reversed, history_hashes, curr_cycle_configs)
}

/// Calculate the amount squeezable by an account from a single streams history entry.
fun squeezed_amt(
    account_id: u256,
    history_entry: &StreamsHistory,
    squeeze_start_cap: u64,
    squeeze_end_cap: u64,
): u128 {
    let receivers = &history_entry.receivers;
    let receivers_len = vector::length(receivers);

    // Binary search for the first occurrence of account_id
    let idx: u64 = 0;
    let idx_cap = receivers_len;
    while (idx < idx_cap) {
        let idx_mid = (idx + idx_cap) / 2;
        if (vector::borrow(receivers, idx_mid).account_id < account_id) {
            idx = idx_mid + 1;
        } else {
            idx_cap = idx_mid;
        };
    };

    let update_time = history_entry.update_time;
    let max_end = history_entry.max_end;
    let amt: u256 = 0;

    // Sum up all streams to this account_id
    while (idx < receivers_len) {
        let receiver = vector::borrow(receivers, idx);
        if (receiver.account_id != account_id) { break };

        let (start, end) = stream_range(
            &receiver.config,
            update_time,
            max_end,
            squeeze_start_cap,
            squeeze_end_cap,
        );
        amt = amt + streamed_amt(receiver.config.amt_per_sec, start, end);
        idx = idx + 1;
    };

    (amt as u128)
}

/// Sets the account's streams configuration.
/// Main entry point to configure streams.
/// Returns: `real_balance_delta` - The actually applied balance change
public(package) fun set_streams<T>(
    registry: &mut StreamsRegistry<T>,
    account_id: u256,
    curr_receivers: &vector<StreamReceiver>,
    balance_delta: I128,
    new_receivers: &vector<StreamReceiver>,
    max_end_hint1: u64,
    max_end_hint2: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): I128 {
    let cycle_secs = registry.cycle_secs;
    let curr_ts = curr_timestamp(clock);

    // Get current state info
    let (
        curr_balance,
        last_update,
        curr_max_end,
        old_history_hash,
        old_curr_cycle_configs,
    ) = {
        if (!table::contains(&registry.states, account_id)) {
            (0u128, 0u64, 0u64, vector::empty<u8>(), 0u64)
        } else {
            let state = table::borrow(&registry.states, account_id);
            verify_streams_receivers(curr_receivers, state);
            let balance = calc_balance(
                state.balance,
                state.update_time,
                state.max_end,
                curr_receivers,
                curr_ts,
            );
            (
                balance,
                state.update_time,
                state.max_end,
                state.streams_history_hash,
                state.curr_cycle_configs,
            )
        }
    };

    // Cap balance_delta at withdrawal of entire balance
    let neg_curr_balance = i128::neg_from(curr_balance);
    let real_balance_delta = if (i128::compare(&balance_delta, &neg_curr_balance) == 1) {
        // balance_delta < neg_curr_balance
        neg_curr_balance
    } else {
        balance_delta
    };

    // Calculate new balance
    let new_balance = if (!i128::is_neg(&real_balance_delta)) {
        curr_balance + i128::as_u128(&real_balance_delta)
    } else {
        let neg_delta = i128::neg(&real_balance_delta);
        curr_balance - i128::as_u128(&neg_delta)
    };

    // Calculate new max_end
    let new_max_end = calc_max_end(
        registry,
        new_balance,
        new_receivers,
        max_end_hint1,
        max_end_hint2,
        clock,
    );

    // Ensure state exists
    ensure_state_exists(&mut registry.states, account_id, ctx);

    // Update receiver states (apply deltas)
    update_receiver_states(
        registry,
        curr_receivers,
        last_update,
        curr_max_end,
        new_receivers,
        new_max_end,
        clock,
        ctx,
    );

    // Update sender state
    let state = table::borrow_mut(&mut registry.states, account_id);

    state.update_time = curr_ts;
    state.max_end = new_max_end;
    state.balance = new_balance;

    // Update curr_cycle_configs
    // If history exists and we crossed a cycle boundary, reset to 2
    // Otherwise increment
    if (
        vector::length(&old_history_hash) != 0
            && cycle_of(last_update, cycle_secs) != cycle_of(curr_ts, cycle_secs)
    ) {
        state.curr_cycle_configs = 2;
    } else {
        state.curr_cycle_configs = old_curr_cycle_configs + 1;
    };

    // Update streams hash and history hash
    let new_streams_hash = hash_streams(new_receivers);
    state.streams_history_hash =
        hash_streams_history(
            &old_history_hash,
            &new_streams_hash,
            curr_ts,
            new_max_end,
        );

    // Update streams_hash if changed
    if (new_streams_hash != state.streams_hash) {
        state.streams_hash = new_streams_hash;
    };

    real_balance_delta
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              VIEW FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// Returns the current streams state for an account
/// Returns: (streams_hash, streams_history_hash, update_time, balance, max_end)
public fun streams_state<T>(
    registry: &StreamsRegistry<T>,
    account_id: u256,
): (vector<u8>, vector<u8>, u64, u128, u64) {
    if (!table::contains(&registry.states, account_id)) {
        return (vector::empty<u8>(), vector::empty<u8>(), 0, 0, 0)
    };

    let state = table::borrow(&registry.states, account_id);
    (
        state.streams_hash,
        state.streams_history_hash,
        state.update_time,
        state.balance,
        state.max_end,
    )
}

/// Returns the cycle_secs configuration for this registry
public fun get_cycle_secs<T>(registry: &StreamsRegistry<T>): u64 {
    registry.cycle_secs
}

/// Returns the min_amt_per_sec configuration for this registry
public fun get_min_amt_per_sec<T>(registry: &StreamsRegistry<T>): u256 {
    registry.min_amt_per_sec
}
