/// Token transfer utilities for drivers.
/// Encapsulates the logic for token transfers made by drivers implementing user identities.
/// All funds going into Drips are transferred via Coin<T> objects passed by the caller,
/// and all funds going out of Drips are returned as Coin<T> objects or transferred directly.
module xylkstream::driver_transfer_utils;

use movemate::i128::{Self, I128};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use xylkstream::drips::{Self, DripsRegistry};
use xylkstream::splits::SplitsRegistry;
use xylkstream::streams::{StreamReceiver, StreamsRegistry};
use xylkstream::yield_manager::{YieldManager, WithdrawalReceipt};

// ═══════════════════════════════════════════════════════════════════════════════
//                              TRANSFER FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// Collects the account's received already split funds
/// and transfers them out of the Drips contract to the specified address.
///
/// `drips_registry`: The drips registry
/// `splits_registry`: The splits registry
/// `account_id`: The account ID to collect for
/// `transfer_to`: The address to send collected funds to
/// `ctx`: Transaction context
///
/// Returns: The collected amount
public fun collect_and_transfer<T>(
    drips_registry: &mut DripsRegistry<T>,
    splits_registry: &mut SplitsRegistry<T>,
    account_id: u256,
    transfer_to: address,
    ctx: &mut TxContext,
): u128 {
    let amt = drips::collect(drips_registry, splits_registry, account_id, ctx);
    if (amt > 0) {
        drips::withdraw(drips_registry, account_id, transfer_to, amt, ctx);
    };
    amt
}

/// Force collect - for when funds are in YieldManager instead of Drips vault
/// Checks if Drips vault has enough coins first, aborts if it does
/// Returns hot potato that user must consume by calling strategy
///
/// `drips_registry`: The drips registry
/// `splits_registry`: The splits registry
/// `yield_manager`: The yield manager holding invested funds
/// `account_id`: The account ID to collect for
/// `strategy_id`: The strategy ID where funds are invested
/// `transfer_to`: The address to send collected funds to
/// `ctx`: Transaction context
///
/// Returns: WithdrawalReceipt hot potato (must be consumed)
public fun force_collect_and_transfer<T>(
    drips_registry: &mut DripsRegistry<T>,
    splits_registry: &mut SplitsRegistry<T>,
    yield_manager: &mut YieldManager<T>,
    account_id: u256,
    strategy_id: sui::object::ID,
    transfer_to: address,
    ctx: &mut TxContext,
): WithdrawalReceipt {
    drips::force_collect(
        drips_registry,
        splits_registry,
        yield_manager,
        account_id,
        strategy_id,
        transfer_to,
        ctx,
    )
}

/// Gives funds from the caller to the receiver.
/// The receiver can split and collect them immediately.
/// Deposits the provided coin into the Drips vault.
///
/// `drips_registry`: The drips registry
/// `splits_registry`: The splits registry
/// `payment`: The coin to deposit
/// `account_id`: The giving account ID
/// `receiver`: The receiver account ID
/// `ctx`: Transaction context
public fun give_and_transfer<T>(
    drips_registry: &mut DripsRegistry<T>,
    splits_registry: &mut SplitsRegistry<T>,
    payment: Coin<T>,
    account_id: u256,
    receiver: u256,
    ctx: &mut TxContext,
) {
    let amt = coin::value(&payment);
    if (amt > 0) {
        drips::deposit(drips_registry, payment);
    } else {
        coin::destroy_zero(payment);
    };
    drips::give(drips_registry, splits_registry, account_id, receiver, (amt as u128), ctx);
}

/// Sets the account's streams configuration.
/// Handles token transfers between the caller and the Drips contract
/// to fulfill the change of the streams balance.
///
/// `drips_registry`: The drips registry
/// `streams_registry`: The streams registry
/// `splits_registry`: The splits registry
/// `payment`: Optional coin for positive balance delta (deposit)
/// `account_id`: The account ID
/// `curr_receivers`: The current streams receivers list
/// `balance_delta`: The streams balance change (positive to add, negative to remove)
/// `new_receivers`: The new streams receivers list
/// `max_end_hint1`: Optional hint for gas optimization (pass 0 to ignore)
/// `max_end_hint2`: Optional hint for gas optimization (pass 0 to ignore)
/// `transfer_to`: The address to send funds to if balance decreases
/// `clock`: The clock object for timestamp access
/// `ctx`: Transaction context
///
/// Returns: The actually applied streams balance change
public fun set_streams_and_transfer<T>(
    drips_registry: &mut DripsRegistry<T>,
    streams_registry: &mut StreamsRegistry<T>,
    _splits_registry: &mut SplitsRegistry<T>,
    mut payment: Option<Coin<T>>,
    account_id: u256,
    curr_receivers: &vector<StreamReceiver>,
    balance_delta: I128,
    new_receivers: &vector<StreamReceiver>,
    max_end_hint1: u64,
    max_end_hint2: u64,
    transfer_to: address,
    clock: &Clock,
    ctx: &mut TxContext,
): I128 {
    // If positive balance delta, deposit the payment
    if (!i128::is_neg(&balance_delta)) {
        let deposit_amt = i128::as_u128(&balance_delta);
        if (deposit_amt > 0) {
            let coin = option::extract(&mut payment);
            drips::deposit(drips_registry, coin);
        };
    };

    // Destroy empty option if not used
    option::destroy_none(payment);

    // Set streams configuration
    let real_balance_delta = drips::set_streams(
        drips_registry,
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

    // If negative real balance delta, withdraw and transfer
    if (i128::is_neg(&real_balance_delta)) {
        let neg_delta = i128::neg(&real_balance_delta);
        let withdraw_amt = i128::as_u128(&neg_delta);
        if (withdraw_amt > 0) {
            drips::withdraw(drips_registry, account_id, transfer_to, withdraw_amt, ctx);
        };
    };

    real_balance_delta
}
