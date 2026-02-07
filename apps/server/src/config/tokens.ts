import { formatCAIP19, parseCAIP19 } from '@/services/system/wallet/shared/utils/caip';
import { toCAIP2 } from './chains';

// CAIP-19 format: {chain_id}/{asset_namespace}:{asset_reference}
export const TOKENS = {
  // Sui tokens
  'sui:mainnet/coin:0x5d4b302506645c37ff133b98c4b50a5ae14841659738d6d733d59d0d217a93bf::coin::COIN': {
    symbol: 'USDC',
    decimals: 6,
    name: 'USD Coin',
  },
  'sui:mainnet/coin:0xc060006111016b8a020ad5b33834984a437aaa7d3c74c18e09a95d48aceab08c::coin::COIN': {
    symbol: 'USDT',
    decimals: 6,
    name: 'Tether USD',
  },
  'sui:mainnet/slip44:784': {
    symbol: 'SUI',
    decimals: 9,
    name: 'Sui',
  },
  // Base tokens
  'eip155:8453/erc20:0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913': {
    symbol: 'USDC',
    decimals: 6,
    name: 'USD Coin',
  },
  'eip155:8453/slip44:60': {
    symbol: 'ETH',
    decimals: 18,
    name: 'Ether',
  },
  'eip155:8453/erc20:0x4200000000000000000000000000000000000006': {
    symbol: 'WETH',
    decimals: 18,
    name: 'Wrapped Ether',
  },
} as const;

// Legacy mapping for backward compatibility
const LEGACY_TOKEN_ADDRESSES = {
  SUI: {
    USDC: '0x5d4b302506645c37ff133b98c4b50a5ae14841659738d6d733d59d0d217a93bf::coin::COIN',
    USDT: '0xc060006111016b8a020ad5b33834984a437aaa7d3c74c18e09a95d48aceab08c::coin::COIN',
    SUI: '0x2::sui::SUI',
  },
  BASE: {
    USDC: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
    ETH: '0x0000000000000000000000000000000000000000',
    WETH: '0x4200000000000000000000000000000000000006',
  },
} as const;

/**
 * Get CAIP-19 asset ID from chain and symbol
 */
export function getAssetId(chainId: string | number, symbol: string): string | null {
  const caip2 = typeof chainId === 'string' && chainId.includes(':') 
    ? chainId 
    : toCAIP2(chainId);
  
  const upperSymbol = symbol.toUpperCase();
  
  // Find matching token
  for (const [assetId, token] of Object.entries(TOKENS)) {
    if (assetId.startsWith(caip2) && token.symbol === upperSymbol) {
      return assetId;
    }
  }
  
  return null;
}

/**
 * Get raw token address from CAIP-19 asset ID (for LI.FI SDK)
 */
export function getRawTokenAddress(assetId: string): string {
  const { assetNamespace, assetReference } = parseCAIP19(assetId);
  
  // For native tokens (slip44), return zero address
  if (assetNamespace === 'slip44') {
    return '0x0000000000000000000000000000000000000000';
  }
  
  // For ERC20/coin tokens, return the address
  return assetReference;
}

/**
 * Get token metadata from CAIP-19 asset ID
 */
export function getTokenMetadata(assetId: string): typeof TOKENS[keyof typeof TOKENS] | null {
  return TOKENS[assetId as keyof typeof TOKENS] || null;
}

/**
 * Legacy function for backward compatibility
 */
export function getTokenAddress(chainId: string | number, symbol: string): string | null {
  const upperSymbol = symbol.toUpperCase();
  
  if (chainId === 'SUI' || chainId === 'sui' || chainId === 'sui:mainnet') {
    return LEGACY_TOKEN_ADDRESSES.SUI[upperSymbol as keyof typeof LEGACY_TOKEN_ADDRESSES.SUI] || null;
  }
  
  if (chainId === 8453 || chainId === '8453' || chainId === 'eip155:8453') {
    return LEGACY_TOKEN_ADDRESSES.BASE[upperSymbol as keyof typeof LEGACY_TOKEN_ADDRESSES.BASE] || null;
  }
  
  return null;
}

/**
 * Get token decimals from symbol or CAIP-19 asset ID
 */
export function getTokenDecimals(symbolOrAssetId: string): number {
  // Try as CAIP-19 first
  if (symbolOrAssetId.includes('/')) {
    const metadata = getTokenMetadata(symbolOrAssetId);
    if (metadata) return metadata.decimals;
  }
  
  // Try as symbol
  const upperSymbol = symbolOrAssetId.toUpperCase();
  for (const token of Object.values(TOKENS)) {
    if (token.symbol === upperSymbol) {
      return token.decimals;
    }
  }
  
  return 18; // Default
}
