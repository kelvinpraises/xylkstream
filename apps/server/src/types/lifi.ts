export interface QuoteRequest {
  fromChain: string | number;
  toChain: string | number;
  fromToken: string;
  toToken: string;
  fromAmount: string;
  fromAddress: string;
  toAddress: string;
  slippage?: number;
}

export interface RouteRequest extends QuoteRequest {
  options?: {
    order?: 'RECOMMENDED' | 'FASTEST' | 'CHEAPEST';
    slippage?: number;
    maxPriceImpact?: number;
  };
}

export interface Token {
  address: string;
  symbol: string;
  decimals: number;
  chainId: number | string;
  name: string;
  priceUSD?: string;
}

export interface Step {
  id: string;
  type: 'lifi' | 'cross' | 'swap';
  tool: string;
  toolDetails: {
    key: string;
    name: string;
    logoURI: string;
  };
  action: {
    fromChainId: number | string;
    toChainId: number | string;
    fromToken: Token;
    toToken: Token;
    fromAmount: string;
    toAmount: string;
    slippage: number;
  };
  estimate: {
    fromAmount: string;
    toAmount: string;
    toAmountMin: string;
    approvalAddress?: string;
    executionDuration: number;
    feeCosts?: Array<{
      name: string;
      description: string;
      token: Token;
      amount: string;
      amountUSD: string;
    }>;
    gasCosts?: Array<{
      type: string;
      price: string;
      estimate: string;
      limit: string;
      amount: string;
      amountUSD: string;
      token: Token;
    }>;
  };
  execution?: {
    status: 'NOT_STARTED' | 'PENDING' | 'DONE' | 'FAILED';
    process?: Array<{
      type: string;
      txHash?: string;
      txLink?: string;
      status: string;
    }>;
  };
  transactionRequest?: {
    to: string;
    from: string;
    data: string;
    value: string;
    gasLimit?: string;
    gasPrice?: string;
    chainId: number;
  };
}

export interface Quote {
  id: string;
  type: 'lifi';
  tool: string;
  toolDetails: {
    key: string;
    name: string;
    logoURI: string;
  };
  action: {
    fromChainId: number | string;
    toChainId: number | string;
    fromToken: Token;
    toToken: Token;
    fromAmount: string;
    toAmount: string;
    slippage: number;
    fromAddress: string;
    toAddress: string;
  };
  estimate: {
    fromAmount: string;
    toAmount: string;
    toAmountMin: string;
    approvalAddress?: string;
    executionDuration: number;
    feeCosts?: Array<{
      name: string;
      description: string;
      token: Token;
      amount: string;
      amountUSD: string;
    }>;
    gasCosts?: Array<{
      type: string;
      price: string;
      estimate: string;
      limit: string;
      amount: string;
      amountUSD: string;
      token: Token;
    }>;
  };
  includedSteps: Step[];
  transactionRequest?: {
    to: string;
    from: string;
    data: string;
    value: string;
    gasLimit?: string;
    gasPrice?: string;
    chainId: number;
  };
}

export interface Route extends Quote {
  steps: Step[];
}

export interface ExecutionResult {
  route: Route;
  status: 'PENDING' | 'DONE' | 'FAILED';
  txHash?: string;
  error?: string;
}

export interface RouteUpdate {
  step: number;
  totalSteps: number;
  status: string;
  txHash?: string;
  message?: string;
}

export interface Chain {
  id: number | string;
  name: string;
  key: string;
  chainType: 'EVM' | 'SUI' | 'SOLANA' | 'UTXO';
  nativeToken: Token;
  metamask?: {
    chainId: string;
    chainName: string;
    nativeCurrency: {
      name: string;
      symbol: string;
      decimals: number;
    };
    rpcUrls: string[];
    blockExplorerUrls: string[];
  };
}

export interface LiFiError extends Error {
  code?: string;
  suggestedSlippage?: number;
  details?: any;
}
