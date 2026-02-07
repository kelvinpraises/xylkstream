/**
 * LI.FI Integration Types
 * 
 * These types extend the base LI.FI SDK types with CAIP standards
 */

import type { Route, Quote } from '@/types/lifi';

/**
 * CAIP-standardized quote request
 */
export interface CAIPQuoteRequest {
  fromChain: string;      // CAIP-2: "eip155:8453"
  toChain: string;        // CAIP-2: "sui:mainnet"
  fromAsset: string;      // CAIP-19: "eip155:8453/erc20:0x833..."
  toAsset: string;        // CAIP-19: "sui:mainnet/coin:0x5d4..."
  amount: string;
  fromAddress: string;    // CAIP-10: "eip155:8453:0x742d..."
  toAddress: string;      // CAIP-10: "sui:mainnet:0x829a..."
  slippage?: number;
}

/**
 * CAIP-standardized route request
 */
export interface CAIPRouteRequest extends CAIPQuoteRequest {
  options?: {
    order?: 'RECOMMENDED' | 'FASTEST' | 'CHEAPEST' | 'SAFEST';
    slippage?: number;
    maxPriceImpact?: number;
    allowSwitchChain?: boolean;
  };
}

/**
 * Execution result with transaction tracking
 */
export interface ExecutionResult {
  route: Route;
  status: 'PENDING' | 'DONE' | 'FAILED';
  txHash?: string;
  transactionId?: number;  // Internal transaction queue ID
}

/**
 * Transaction metadata for logging
 */
export interface TransactionMetadata {
  accountId: number;
  chainId: string;         // CAIP-2
  assetId?: string;        // CAIP-19
  transactionType: 'transfer' | 'swap' | 'bridge' | 'contract_call';
  route: Route;
}
