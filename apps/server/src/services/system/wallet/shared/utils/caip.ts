/**
 * CAIP (Chain Agnostic Improvement Proposals) utilities
 * https://github.com/ChainAgnostic/CAIPs
 */

/**
 * CAIP-2: Chain ID Specification
 * Format: <namespace>:<reference>
 * Examples: eip155:1, eip155:8453, sui:mainnet
 */
export interface CAIP2 {
  namespace: string;
  reference: string;
}

export function parseCAIP2(chainId: string): CAIP2 {
  const parts = chainId.split(':');
  if (parts.length !== 2) {
    throw new Error(`Invalid CAIP-2 format: ${chainId}`);
  }
  return {
    namespace: parts[0],
    reference: parts[1],
  };
}

export function formatCAIP2(caip2: CAIP2): string {
  return `${caip2.namespace}:${caip2.reference}`;
}

/**
 * CAIP-10: Account ID Specification
 * Format: <chain_id>:<address>
 * Examples: eip155:8453:0x742d..., sui:mainnet:0x829a...
 */
export interface CAIP10 {
  chainId: string;
  address: string;
}

export function parseCAIP10(accountId: string): CAIP10 {
  const lastColonIndex = accountId.lastIndexOf(':');
  if (lastColonIndex === -1) {
    throw new Error(`Invalid CAIP-10 format: ${accountId}`);
  }
  return {
    chainId: accountId.substring(0, lastColonIndex),
    address: accountId.substring(lastColonIndex + 1),
  };
}

export function formatCAIP10(caip10: CAIP10): string {
  return `${caip10.chainId}:${caip10.address}`;
}

/**
 * CAIP-19: Asset Type and Asset ID Specification
 * Format: <chain_id>/<asset_namespace>:<asset_reference>
 * Examples:
 * - eip155:8453/erc20:0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 (USDC on Base)
 * - sui:mainnet/coin:0x5d4b302506645c37ff133b98c4b50a5ae14841659738d6d733d59d0d217a93bf::coin::COIN
 */
export interface CAIP19 {
  chainId: string;
  assetNamespace: string;
  assetReference: string;
}

export function parseCAIP19(assetId: string): CAIP19 {
  const slashIndex = assetId.indexOf('/');
  if (slashIndex === -1) {
    throw new Error(`Invalid CAIP-19 format: ${assetId}`);
  }

  const chainId = assetId.substring(0, slashIndex);
  const assetPart = assetId.substring(slashIndex + 1);

  const colonIndex = assetPart.indexOf(':');
  if (colonIndex === -1) {
    throw new Error(`Invalid CAIP-19 format: ${assetId}`);
  }

  return {
    chainId,
    assetNamespace: assetPart.substring(0, colonIndex),
    assetReference: assetPart.substring(colonIndex + 1),
  };
}

export function formatCAIP19(caip19: CAIP19): string {
  return `${caip19.chainId}/${caip19.assetNamespace}:${caip19.assetReference}`;
}
