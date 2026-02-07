/// A driver implementing account identification based on wallet addresses.
/// Each address can use Drips with a single account ID derived from that address.
/// No registration is required, an address can start using Drips immediately.
module xylkstream::address_driver;

use movemate::i128;
use sui::clock::Clock;
use sui::coin::Coin;
use xylkstream::drips::{Self, DripsRegistry};
use xylkstream::driver_transfer_utils;
use xylkstream::driver_utils;
use xylkstream::splits::{SplitsReceiver, SplitsRegistry};
use xylkstream::streams::{Self, StreamReceiver, StreamsRegistry};
use xylkstream::yield_manager::{YieldManager, WithdrawalReceipt};

// ═══════════════════════════════════════════════════════════════════════════════
//                              ACCOUNT ID
// ═══════════════════════════════════════════════════════════════════════════════

/// Calculates the account ID for an address.
/// The account ID is simply the address converted to u256.
/// This allows easy recovery of the original address from the account ID.
///
/// `addr`: The address to calculate the account ID for
///
/// Returns: The account ID
public fun calc_account_id(addr: address): u256 {
    addr_to_u256(addr)
}

/// Returns the account ID for the transaction sender.
fun caller_account_id(ctx: &sui::tx_context::TxContext): u256 {
    calc_account_id(ctx.sender())
}

/// Converts an address to u256.
fun addr_to_u256(addr: address): u256 {
    let bytes = std::bcs::to_bytes(&addr);
    let mut result: u256 = 0;
    let mut i = 0;
    while (i < 32) {
        result = (result << 8) | (*vector::borrow(&bytes, i) as u256);
        i = i + 1;
    };
    result
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              DRIPS OPERATIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// Collects the caller's received already split funds
/// and transfers them to the specified address.
///
/// `drips_registry`: The drips registry
/// `splits_registry`: The splits registry
/// `transfer_to`: The address to send collected funds to
/// `ctx`: Transaction context
public fun collect<T>(
    drips_registry: &mut DripsRegistry<T>,
    splits_registry: &mut SplitsRegistry<T>,
    transfer_to: address,
    ctx: &mut sui::tx_context::TxContext,
) {
    driver_transfer_utils::collect_and_transfer(
        drips_registry,
        splits_registry,
        caller_account_id(ctx),
        transfer_to,
        ctx,
    );
}

/// Force collect - for when funds are in YieldManager instead of Drips vault
/// Checks if Drips vault has enough coins first, aborts if it does
/// Returns hot potato that caller must consume by calling strategy
///
/// `drips_registry`: The drips registry
/// `splits_registry`: The splits registry
/// `yield_manager`: The yield manager holding invested funds
/// `strategy_id`: The strategy ID where funds are invested
/// `transfer_to`: The address to send collected funds to
/// `ctx`: Transaction context
///
/// Returns: WithdrawalReceipt hot potato (must be consumed by calling strategy)
public fun force_collect<T>(
    drips_registry: &mut DripsRegistry<T>,
    splits_registry: &mut SplitsRegistry<T>,
    yield_manager: &mut YieldManager<T>,
    strategy_id: sui::object::ID,
    transfer_to: address,
    ctx: &mut sui::tx_context::TxContext,
): WithdrawalReceipt {
    driver_transfer_utils::force_collect_and_transfer(
        drips_registry,
        splits_registry,
        yield_manager,
        caller_account_id(ctx),
        strategy_id,
        transfer_to,
        ctx,
    )
}

/// Gives funds from the caller to the receiver.
/// The receiver can split and collect them immediately.
/// Transfers the funds from the provided coin to the Drips vault.
///
/// `drips_registry`: The drips registry
/// `splits_registry`: The splits registry
/// `receiver`: The receiver account ID
/// `payment`: The coin to give
/// `ctx`: Transaction context
public fun give<T>(
    drips_registry: &mut DripsRegistry<T>,
    splits_registry: &mut SplitsRegistry<T>,
    receiver: u256,
    payment: Coin<T>,
    ctx: &mut sui::tx_context::TxContext,
) {
    let account_id = caller_account_id(ctx);
    driver_transfer_utils::give_and_transfer(
        drips_registry,
        splits_registry,
        payment,
        account_id,
        receiver,
        ctx,
    );
}

/// Sets the caller's streams configuration.
/// Transfers funds between the caller's wallet and the Drips contract
/// to fulfill the change of the streams balance.
/// Note: Not an entry function because it takes Option<Coin<T>>.
///
/// `drips_registry`: The drips registry
/// `streams_registry`: The streams registry
/// `splits_registry`: The splits registry
/// `curr_receivers`: Current streams receivers list
/// `balance_delta_bits`: The streams balance change as i128 bits (positive to add, negative to remove)
/// `new_receivers`: New streams receivers list
/// `max_end_hint1`: Optional hint for gas optimization (pass 0 to ignore)
/// `max_end_hint2`: Optional hint for gas optimization (pass 0 to ignore)
/// `transfer_to`: The address to send funds to if balance decreases
/// `payment`: Optional coin for positive balance delta
/// `clock`: The clock object for timestamp access
/// `ctx`: Transaction context
public fun set_streams<T>(
    drips_registry: &mut DripsRegistry<T>,
    streams_registry: &mut StreamsRegistry<T>,
    splits_registry: &mut SplitsRegistry<T>,
    curr_receivers: vector<StreamReceiver>,
    balance_delta_bits: u128,
    new_receivers: vector<StreamReceiver>,
    max_end_hint1: u64,
    max_end_hint2: u64,
    transfer_to: address,
    payment: Option<Coin<T>>,
    clock: &Clock,
    ctx: &mut sui::tx_context::TxContext,
) {
    let account_id = caller_account_id(ctx);
    let balance_delta = i128::from_bits(balance_delta_bits);
    driver_transfer_utils::set_streams_and_transfer(
        drips_registry,
        streams_registry,
        splits_registry,
        payment,
        account_id,
        &curr_receivers,
        balance_delta,
        &new_receivers,
        max_end_hint1,
        max_end_hint2,
        transfer_to,
        clock,
        ctx,
    );

    // Emit event with new receivers data
    let (_, _, _, balance, max_end) = streams::streams_state(streams_registry, account_id);
    drips::emit_streams_set_from_receivers(
        account_id,
        new_receivers,
        balance,
        max_end,
    );
}

/// Sets the caller's splits configuration.
/// The configuration is common for all token types.
/// Nothing happens to the currently splittable funds, but when they are split
/// after this function finishes, the new splits configuration will be used.
///
/// `registry`: The splits registry
/// `receivers`: The splits receivers
/// `ctx`: Transaction context
public fun set_splits<T>(
    registry: &mut SplitsRegistry<T>,
    receivers: vector<SplitsReceiver>,
    ctx: &mut sui::tx_context::TxContext,
) {
    let account_id = caller_account_id(ctx);
    drips::set_splits(registry, account_id, &receivers, ctx);
    drips::emit_splits_set_from_receivers(account_id, receivers);
}

/// Emits the caller's account metadata for off-chain indexing.
/// The keys and values are not standardized by the protocol — it's up to users
/// to establish conventions for compatibility with consumers.
///
/// `account_metadata`: The metadata key-value pairs
/// `ctx`: Transaction context
public fun emit_account_metadata(
    account_metadata: vector<driver_utils::AccountMetadata>,
    ctx: &sui::tx_context::TxContext,
) {
    drips::emit_account_metadata(caller_account_id(ctx), account_metadata);
}

// ═══════════════════════════════════════════════════════════════════════════════
//                    YIELD MANAGER OPERATIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// Transfer idle funds from Drips to YieldManager
/// Allows caller to invest idle balance in yield strategies
///
/// `drips_registry`: The drips registry
/// `yield_manager`: The yield manager to deposit into
/// `amount`: Amount to transfer
/// `ctx`: Transaction context
public fun transfer_to_yield_manager<T>(
    drips_registry: &mut DripsRegistry<T>,
    yield_manager: &mut YieldManager<T>,
    amount: u128,
    ctx: &mut sui::tx_context::TxContext,
) {
    drips::transfer_to_yield_manager(
        drips_registry,
        yield_manager,
        caller_account_id(ctx),
        amount,
        ctx,
    );
}

/// Return principal from YieldManager back to Drips
/// Allows caller to reclaim principal from YieldManager
///
/// `drips_registry`: The drips registry
/// `yield_manager`: The yield manager to return from
/// `amount`: Amount to return
/// `ctx`: Transaction context
public fun return_from_yield_manager<T>(
    drips_registry: &mut DripsRegistry<T>,
    yield_manager: &mut YieldManager<T>,
    amount: u128,
    ctx: &mut sui::tx_context::TxContext,
) {
    drips::return_from_yield_manager(
        drips_registry,
        yield_manager,
        caller_account_id(ctx),
        amount,
        ctx,
    );
}
