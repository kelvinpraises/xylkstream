export interface BridgeParams {
  accountId: number;
  fromChain: 'SUI' | 'BASE' | number;
  toChain: 'SUI' | 'BASE' | number;
  tokenSymbol: string;
  amount: string;
  slippage?: number;
}

export interface SwapParams {
  accountId: number;
  chainId: 'SUI' | 'BASE' | number;
  fromTokenSymbol: string;
  toTokenSymbol: string;
  amount: string;
  slippage?: number;
}

export interface BridgeResult {
  success: boolean;
  txHash?: string;
  fromChain: string | number;
  toChain: string | number;
  amount: string;
  estimatedTime: number;
  trackingUrl?: string;
  error?: string;
}

export interface SwapResult {
  success: boolean;
  txHash?: string;
  chainId: string | number;
  fromToken: string;
  toToken: string;
  fromAmount: string;
  toAmount: string;
  error?: string;
}

export interface ChainBalance {
  chainId: string | number;
  chainName: string;
  balances: Array<{
    token: string;
    symbol: string;
    balance: string;
    balanceUSD?: string;
  }>;
}
