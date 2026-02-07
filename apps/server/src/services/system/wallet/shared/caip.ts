/**
 * CAIP Standards Utilities
 * https://github.com/ChainAgnostic/CAIPs
 */

// CAIP-2: Chain ID
export interface CAIP2 {
  namespace: string; // "eip155", "sui", "solana"
  reference: string; // "8453", "mainnet", etc.
}

export function parseCAIP2(chainId: string): CAIP2 {
  const [namespace, reference] = chainId.split(':');
  if (!namespace || !reference) {
    throw new Error(`Invalid CAIP-2 format: ${chainId}. Expected format: namespace:reference`);
  }
  return { namespace, reference };
}

export function formatCAIP2(namespace: string, reference: string): string {
  return `${namespace}:${reference}`;
}

export function isEVMChain(chainId: string): boolean {
  return parseCAIP2(chainId).namespace === 'eip155';
}

export function isSuiChain(chainId: string): boolean {
  return parseCAIP2(chainId).namespace === 'sui';
}

// CAIP-10: Account ID
export interface CAIP10 {
  chainId: string; // CAIP-2 format
  address: string;
}

export function parseCAIP10(accountId: string): CAIP10 {
  const parts = accountId.split(':');
  if (parts.length < 3) {
    throw new Error(`Invalid CAIP-10 format: ${accountId}. Expected format: namespace:reference:address`);
  }
  
  const namespace = parts[0];
  const reference = parts[1];
  const address = parts.slice(2).join(':'); // Handle addresses with colons
  
  return {
    chainId: `${namespace}:${reference}`,
    address,
  };
}

export function formatCAIP10(chainId: string, address: string): string {
  return `${chainId}:${address}`;
}

// CAIP-19: Asset Type
export interface CAIP19 {
  chainId: string; // CAIP-2 format
  assetNamespace: string; // "erc20", "erc721", "slip44", "coin"
  assetReference: string; // Token address or type
  tokenId?: string; // For NFTs
}

export function parseCAIP19(assetId: string): CAIP19 {
  // Format: chain_id/asset_namespace:asset_reference[/token_id]
  const [chainPart, assetPart] = assetId.split('/');
  
  if (!chainPart || !assetPart) {
    throw new Error(`Invalid CAIP-19 format: ${assetId}`);
  }
  
  const [assetNamespace, ...assetRefParts] = assetPart.split(':');
  const assetReference = assetRefParts.join(':'); // Handle Sui format with multiple colons
  
  return {
    chainId: chainPart,
    assetNamespace,
    assetReference,
  };
}

export function formatCAIP19(
  chainId: string,
  assetNamespace: string,
  assetReference: string,
  tokenId?: string
): string {
  let result = `${chainId}/${assetNamespace}:${assetReference}`;
  if (tokenId) {
    result += `/${tokenId}`;
  }
  return result;
}

// Common chain IDs
export const CHAINS = {
  ETHEREUM: 'eip155:1',
  BASE: 'eip155:8453',
  ARBITRUM: 'eip155:42161',
  OPTIMISM: 'eip155:10',
  SUI_MAINNET: 'sui:mainnet',
  SUI_TESTNET: 'sui:testnet',
} as const;

// Native token helpers
export function getNativeAssetId(chainId: string): string {
  const { namespace, reference } = parseCAIP2(chainId);
  
  switch (namespace) {
    case 'eip155':
      return formatCAIP19(chainId, 'slip44', '60'); // ETH
    case 'sui':
      return formatCAIP19(chainId, 'coin', '0x2::sui::SUI');
    default:
      throw new Error(`Unknown native asset for chain: ${chainId}`);
  }
}
