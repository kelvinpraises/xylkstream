/// A driver implementing token-based account identification.
/// Anybody can mint a new token and create a new identity.
/// Only the current holder of the token can control its account ID.
module xylkstream::nft_driver;

use movemate::i128;
use std::string;
use sui::clock::Clock;
use sui::coin::Coin;
use sui::display;
use sui::event;
use sui::package;
use sui::table::{Self, Table};
use xylkstream::drips::{Self, DripsRegistry};
use xylkstream::driver_transfer_utils;
use xylkstream::driver_utils::{Self, AccountMetadata};
use xylkstream::splits::{SplitsReceiver, SplitsRegistry};
use xylkstream::streams::{Self, StreamReceiver, StreamsRegistry};

// ═══════════════════════════════════════════════════════════════════════════════
//                                 CONSTANTS
// ═══════════════════════════════════════════════════════════════════════════════
const COLLECTION_DESCRIPTION: vector<u8> = b"NFT-based identity for Drips protocol";

// ═══════════════════════════════════════════════════════════════════════════════
//                                 ERROR CODES
// ═══════════════════════════════════════════════════════════════════════════════

/// Salt has already been used by this minter
const E_SALT_ALREADY_USED: u64 = 103;

// ═══════════════════════════════════════════════════════════════════════════════
//                              STORAGE
// ═══════════════════════════════════════════════════════════════════════════════

/// Global shared registry for NFT driver configuration.
public struct NFTDriverRegistry has key {
    id: object::UID,
    /// The number of tokens minted without salt.
    minted_tokens: u64,
    /// The salts already used for minting tokens (flattened key).
    used_salts: Table<SaltKey, bool>,
    /// Mapping from token_id to NFT object ID.
    token_registry: Table<u256, object::ID>,
}

/// Flattened key for salt tracking
public struct SaltKey has copy, drop, store {
    minter: address,
    salt: u64,
}

/// The Drips Identity NFT - represents control over a drips account.
public struct DripsIdentityNFT has key, store {
    id: object::UID,
    /// The token ID (equal to account ID controlled by this NFT).
    token_id: u256,
}

/// One-Time-Witness for the module.
public struct NFT_DRIVER has drop {}

// ═══════════════════════════════════════════════════════════════════════════════
//                                  EVENTS
// ═══════════════════════════════════════════════════════════════════════════════

/// Emitted when the NFT driver registry is created
public struct RegistryCreated has copy, drop {
    registry_id: ID,
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              INITIALIZATION
// ═══════════════════════════════════════════════════════════════════════════════

/// Initialize the NFT driver.
/// Creates the NFT collection for Drips identity tokens.
fun init(otw: NFT_DRIVER, ctx: &mut TxContext) {
    // Create registry
    let registry_id_obj = object::new(ctx);
    let registry_id = object::uid_to_inner(&registry_id_obj);

    let registry = NFTDriverRegistry {
        id: registry_id_obj,
        minted_tokens: 0,
        used_salts: table::new(ctx),
        token_registry: table::new(ctx),
    };

    // Emit event
    event::emit(RegistryCreated { registry_id });

    // Create Display for NFTs
    let publisher = package::claim(otw, ctx);
    let mut display_obj = display::new<DripsIdentityNFT>(&publisher, ctx);

    display::add(
        &mut display_obj,
        string::utf8(b"name"),
        string::utf8(b"Drips Identity #{token_id}"),
    );
    display::add(
        &mut display_obj,
        string::utf8(b"description"),
        string::utf8(COLLECTION_DESCRIPTION),
    );
    display::add(
        &mut display_obj,
        string::utf8(b"project_url"),
        string::utf8(b"https://drips.network"),
    );
    display::add(&mut display_obj, string::utf8(b"creator"), string::utf8(b"Drips Protocol"));

    display::update_version(&mut display_obj);

    transfer::public_transfer(publisher, ctx.sender());
    transfer::public_transfer(display_obj, ctx.sender());
    transfer::share_object(registry);
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              TOKEN ID CALCULATION
// ═══════════════════════════════════════════════════════════════════════════════

/// Get the ID of the next minted token (without salt).
/// Token ID = minter (160 bits) | salt/counter (64 bits), with minter = 0x0 for sequential mints.
///
/// Returns: The token ID (equal to the account ID controlled by it)
public fun next_token_id(registry: &NFTDriverRegistry): u256 {
    calc_token_id_internal(@0x0, registry.minted_tokens)
}

/// Calculate the ID of the token minted with salt.
/// Token ID = minter (160 bits) | salt (64 bits).
/// The minter's lower 160 bits are used to avoid collisions with address-based accounts.
///
/// `minter`: The minter of the token
/// `salt`: The salt used for minting the token
///
/// Returns: The token ID (equal to the account ID controlled by it)
public fun calc_token_id_with_salt(minter: address, salt: u64): u256 {
    calc_token_id_internal(minter, salt)
}

/// Internal token ID calculation.
/// Uses lower 160 bits of minter address + 64 bit salt.
fun calc_token_id_internal(minter: address, salt: u64): u256 {
    let minter_bits =
        addr_to_u256(minter) & 0x000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    (minter_bits << 64) | (salt as u256)
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

/// Checks if the salt has already been used for minting a token.
///
/// `registry`: The NFT driver registry
/// `minter`: The minter of the token
/// `salt`: The salt used for minting the token
///
/// Returns: True if the salt has been used, false otherwise
public fun is_salt_used(registry: &NFTDriverRegistry, minter: address, salt: u64): bool {
    let key = SaltKey { minter, salt };
    table::contains(&registry.used_salts, key)
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              MINTING
// ═══════════════════════════════════════════════════════════════════════════════

/// Mints a new token controlling a new account ID and transfers it to an address.
/// Emits account metadata for the new token.
///
/// `registry`: The NFT driver registry
/// `to`: The address to transfer the minted token to
/// `account_metadata`: The metadata key-value pairs to emit
/// `ctx`: Transaction context
public fun mint(
    registry: &mut NFTDriverRegistry,
    to: address,
    account_metadata: vector<driver_utils::AccountMetadata>,
    ctx: &mut TxContext,
) {
    let token_id = calc_token_id_internal(@0x0, registry.minted_tokens);
    registry.minted_tokens = registry.minted_tokens + 1;
    mint_internal(registry, to, token_id, account_metadata, ctx);
}

/// Mints a new token controlling a new account ID and transfers it to an address.
/// The token ID is deterministically derived from the caller's address and the salt.
/// Each caller can use each salt only once, to mint a single token.
/// Emits account metadata for the new token.
///
/// `registry`: The NFT driver registry
/// `salt`: The salt to use for token ID calculation
/// `to`: The address to transfer the minted token to
/// `account_metadata`: The metadata key-value pairs to emit
/// `ctx`: Transaction context
public fun mint_with_salt(
    registry: &mut NFTDriverRegistry,
    salt: u64,
    to: address,
    account_metadata: vector<driver_utils::AccountMetadata>,
    ctx: &mut TxContext,
) {
    let minter = ctx.sender();
    assert!(!is_salt_used(registry, minter, salt), E_SALT_ALREADY_USED);

    // Record salt usage
    let key = SaltKey { minter, salt };
    table::add(&mut registry.used_salts, key, true);

    let token_id = calc_token_id_internal(minter, salt);
    mint_internal(registry, to, token_id, account_metadata, ctx);
}

/// Internal mint function that creates the token and transfers it.
fun mint_internal(
    registry: &mut NFTDriverRegistry,
    to: address,
    token_id: u256,
    account_metadata: vector<AccountMetadata>,
    ctx: &mut TxContext,
) {
    let nft = DripsIdentityNFT {
        id: object::new(ctx),
        token_id,
    };

    let nft_id = object::id(&nft);
    table::add(&mut registry.token_registry, token_id, nft_id);

    emit_account_metadata_internal(token_id, account_metadata);
    transfer::public_transfer(nft, to);
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              DRIPS OPERATIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// Collects the account's received already split funds
/// and transfers them out of the Drips contract.
/// Ownership is proven by having the NFT reference.
///
/// `nft`: The NFT representing the account (proves ownership)
/// `drips_registry`: The drips registry
/// `splits_registry`: The splits registry
/// `transfer_to`: The address to send collected funds to
/// `ctx`: Transaction context
public fun collect<T>(
    nft: &DripsIdentityNFT,
    drips_registry: &mut DripsRegistry<T>,
    splits_registry: &mut SplitsRegistry<T>,
    transfer_to: address,
    ctx: &mut TxContext,
) {
    let token_id = nft.token_id;
    driver_transfer_utils::collect_and_transfer(
        drips_registry,
        splits_registry,
        token_id,
        transfer_to,
        ctx,
    );
}

/// Gives funds from the account to the receiver.
/// The receiver can split and collect them immediately.
/// Ownership is proven by having the NFT reference.
///
/// `nft`: The NFT representing the account (proves ownership)
/// `drips_registry`: The drips registry
/// `splits_registry`: The splits registry
/// `receiver`: The receiver account ID
/// `payment`: The coin to give
/// `ctx`: Transaction context
public fun give<T>(
    nft: &DripsIdentityNFT,
    drips_registry: &mut DripsRegistry<T>,
    splits_registry: &mut SplitsRegistry<T>,
    receiver: u256,
    payment: Coin<T>,
    ctx: &mut TxContext,
) {
    let token_id = nft.token_id;
    driver_transfer_utils::give_and_transfer(
        drips_registry,
        splits_registry,
        payment,
        token_id,
        receiver,
        ctx,
    );
}

/// Sets the account's streams configuration.
/// Ownership is proven by having the NFT reference.
/// Note: Not an entry function because it takes Option<Coin<T>>.
///
/// `nft`: The NFT representing the account (proves ownership)
/// `drips_registry`: The drips registry
/// `streams_registry`: The streams registry
/// `splits_registry`: The splits registry
/// `curr_receivers`: Current streams receivers list
/// `balance_delta_bits`: The streams balance change as i128 bits
/// `new_receivers`: New streams receivers list
/// `max_end_hint1`: Optional hint for gas optimization (pass 0 to ignore)
/// `max_end_hint2`: Optional hint for gas optimization (pass 0 to ignore)
/// `transfer_to`: The address to send funds to in case of decreasing balance
/// `payment`: Optional coin for positive balance delta
/// `clock`: The clock object for timestamp access
/// `ctx`: Transaction context
public fun set_streams<T>(
    nft: &DripsIdentityNFT,
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
    ctx: &mut TxContext,
) {
    let token_id = nft.token_id;
    let balance_delta = i128::from_bits(balance_delta_bits);
    driver_transfer_utils::set_streams_and_transfer(
        drips_registry,
        streams_registry,
        splits_registry,
        payment,
        token_id,
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
    let (_, _, _, balance, max_end) = streams::streams_state(streams_registry, token_id);
    drips::emit_streams_set_from_receivers(
        token_id,
        new_receivers,
        balance,
        max_end,
    );
}

/// Sets the account splits configuration.
/// Ownership is proven by having the NFT reference.
///
/// `nft`: The NFT representing the account (proves ownership)
/// `splits_registry`: The splits registry
/// `receivers`: The splits receivers
/// `ctx`: Transaction context
public fun set_splits<T>(
    nft: &DripsIdentityNFT,
    splits_registry: &mut SplitsRegistry<T>,
    receivers: vector<SplitsReceiver>,
    ctx: &mut TxContext,
) {
    let token_id = nft.token_id;
    drips::set_splits(splits_registry, token_id, &receivers, ctx);
    drips::emit_splits_set_from_receivers(token_id, receivers);
}

/// Emits account metadata for the given token.
/// Ownership is proven by having the NFT reference.
///
/// `nft`: The NFT representing the account (proves ownership)
/// `account_metadata`: The metadata key-value pairs
public fun emit_account_metadata(
    nft: &DripsIdentityNFT,
    account_metadata: vector<AccountMetadata>,
) {
    let token_id = nft.token_id;
    emit_account_metadata_internal(token_id, account_metadata);
}

/// Internal function to emit account metadata.
/// The keys and the values are not standardized by the protocol, it's up to the users
/// to establish and follow conventions to ensure compatibility with the consumers.
fun emit_account_metadata_internal(
    token_id: u256,
    account_metadata: vector<AccountMetadata>,
) {
    if (vector::length(&account_metadata) == 0) { return };
    drips::emit_account_metadata(token_id, account_metadata);
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              TOKEN MANAGEMENT
// ═══════════════════════════════════════════════════════════════════════════════

/// Burns the token controlling an account.
/// This freezes the account configuration and prevents any funds
/// from being deposited to or withdrawn from the protocol using that account.
/// Consumes the NFT by value to prove ownership.
///
/// `nft`: The NFT to burn (consumed)
/// `registry`: The NFT driver registry
public fun burn(nft: DripsIdentityNFT, registry: &mut NFTDriverRegistry) {
    let DripsIdentityNFT { id, token_id } = nft;
    table::remove(&mut registry.token_registry, token_id);
    object::delete(id);
}

// ═══════════════════════════════════════════════════════════════════════════════
//                              VIEW FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// Returns the number of tokens minted without salt.
public fun minted_tokens(registry: &NFTDriverRegistry): u64 {
    registry.minted_tokens
}

/// Returns the object ID for a given token ID.
/// Returns none if the token doesn't exist.
public fun token_object_id(registry: &NFTDriverRegistry, token_id: u256): Option<object::ID> {
    if (table::contains(&registry.token_registry, token_id)) {
        option::some(*table::borrow(&registry.token_registry, token_id))
    } else {
        option::none()
    }
}

/// Returns the token ID from an NFT.
public fun get_token_id(nft: &DripsIdentityNFT): u256 {
    nft.token_id
}
