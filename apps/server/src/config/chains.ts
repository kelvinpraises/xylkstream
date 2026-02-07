import { parseCAIP2 } from '@/services/system/wallet/shared/utils/caip';

// CAIP-2 format: {namespace}:{reference}
export const SUPPORTED_CHAINS = {
  SUI: {
    id: 'sui:mainnet',  // CAIP-2
    legacyId: 'SUI',    // For LI.FI compatibility
    name: 'Sui',
    nativeToken: 'SUI',
    rpcUrl: process.env.SUI_RPC_URL || 'https://fullnode.mainnet.sui.io:443',
    explorer: 'https://suiscan.xyz/mainnet',
  },
  BASE: {
    id: 'eip155:8453',  // CAIP-2
    legacyId: 8453,     // For LI.FI compatibility
    name: 'Base',
    nativeToken: 'ETH',
    rpcUrl: process.env.BASE_RPC_URL || 'https://mainnet.base.org',
    explorer: 'https://basescan.org',
  },
} as const;

export type SupportedChainId = keyof typeof SUPPORTED_CHAINS;

/**
 * Get chain config by CAIP-2 ID or legacy ID
 */
export function getChainById(chainId: string | number): typeof SUPPORTED_CHAINS[SupportedChainId] | null {
  // Try CAIP-2 format first
  if (chainId === 'sui:mainnet' || chainId === 'SUI' || chainId === 'sui') {
    return SUPPORTED_CHAINS.SUI;
  }
  if (chainId === 'eip155:8453' || chainId === 8453 || chainId === '8453') {
    return SUPPORTED_CHAINS.BASE;
  }
  return null;
}

/**
 * Convert legacy chain ID to CAIP-2 format
 */
export function toCAIP2(chainId: string | number): string {
  const chain = getChainById(chainId);
  if (!chain) {
    throw new Error(`Unsupported chain: ${chainId}`);
  }
  return chain.id;
}

/**
 * Convert CAIP-2 to legacy format (for LI.FI SDK)
 */
export function toLegacyChainId(caip2: string): string | number {
  const chain = getChainById(caip2);
  if (!chain) {
    throw new Error(`Unsupported chain: ${caip2}`);
  }
  return chain.legacyId;
}

/**
 * Check if chain is EVM-based using CAIP-2
 */
export function isEVMChain(chainId: string | number): boolean {
  const caip2 = typeof chainId === 'string' && chainId.includes(':') 
    ? chainId 
    : toCAIP2(chainId);
  
  const { namespace } = parseCAIP2(caip2);
  return namespace === 'eip155';
}

/**
 * Check if chain is Sui using CAIP-2
 */
export function isSuiChain(chainId: string | number): boolean {
  const caip2 = typeof chainId === 'string' && chainId.includes(':') 
    ? chainId 
    : toCAIP2(chainId);
  
  const { namespace } = parseCAIP2(caip2);
  return namespace === 'sui';
}
