/// Shared utility functions for account metadata.
/// Used by drips, address_driver, and nft_driver.
module xylkstream::driver_utils;

// ═══════════════════════════════════════════════════════════════════════════════
//                           ACCOUNT METADATA
// ═══════════════════════════════════════════════════════════════════════════════

/// Account metadata key-value pair.
public struct AccountMetadata has copy, drop, store {
    key: vector<u8>,
    value: vector<u8>,
}

public fun new_account_metadata(key: vector<u8>, value: vector<u8>): AccountMetadata {
    AccountMetadata { key, value }
}

public fun account_metadata_key(metadata: &AccountMetadata): vector<u8> {
    metadata.key
}

public fun account_metadata_value(metadata: &AccountMetadata): vector<u8> {
    metadata.value
}
