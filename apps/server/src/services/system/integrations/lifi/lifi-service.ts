import { 
  createConfig, 
  getQuote as lifiGetQuote, 
  getRoutes as lifiGetRoutes, 
  getChains, 
  getTokens, 
  ChainType,
  executeRoute as lifiExecuteRoute
} from '@lifi/sdk';
import type { Quote, Route, QuoteRequest, RouteRequest, Chain, Token, LiFiError, ExecutionResult } from '@/types/lifi';
import { getChainById, isEVMChain, isSuiChain, toLegacyChainId, toCAIP2 } from '@/config/chains';
import { getAssetId, getRawTokenAddress } from '@/config/tokens';
import { createEVMProvider } from '@/services/system/integrations/lifi/providers/evm-provider';
import { createSuiProvider } from '@/services/system/integrations/lifi/providers/sui-provider';
import { lifiTransactionService } from '@/services/system/integrations/lifi/lifi-transaction-service';
import { walletService } from '@/services/system/wallet/wallet-service';

// Initialize LI.FI SDK
createConfig({
  integrator: 'xylkstream',
  apiUrl: process.env.LIFI_API_URL || 'https://li.quest/v1',
});

class LiFiService {
  /**
   * Get a quote for a swap or bridge
   */
  async getQuote(params: QuoteRequest): Promise<Quote> {
    try {
      const quote = await lifiGetQuote(params as any);
      return quote as unknown as Quote;
    } catch (error) {
      throw this.handleError(error);
    }
  }

  /**
   * Get multiple route options
   */
  async getRoutes(params: RouteRequest): Promise<Route[]> {
    try {
      const result = await lifiGetRoutes(params as any);
      return result.routes as unknown as Route[];
    } catch (error) {
      throw this.handleError(error);
    }
  }

  /**
   * Get supported chains
   */
  async getSupportedChains(): Promise<Chain[]> {
    try {
      const chains = await getChains({
        chainTypes: [ChainType.EVM] as any,
      });
      return chains as Chain[];
    } catch (error) {
      throw this.handleError(error);
    }
  }

  /**
   * Get supported tokens for a chain
   */
  async getSupportedTokens(chainId: string | number): Promise<Token[]> {
    try {
      const tokens = await getTokens({ chains: [chainId as any] });
      return tokens.tokens[chainId as any] || [];
    } catch (error) {
      throw this.handleError(error);
    }
  }

  /**
   * Build quote request with proper addresses and token formats
   * @param fromChain - CAIP-2 chain ID (e.g., "eip155:8453")
   * @param toChain - CAIP-2 chain ID
   * @param fromTokenSymbol - Token symbol (e.g., "USDC")
   * @param toTokenSymbol - Token symbol
   * @param amount - Amount in token's smallest unit
   * @param fromAddress - Sender address
   * @param toAddress - Recipient address
   * @param slippage - Slippage tolerance (0.01 = 1%)
   */
  async buildQuoteRequest(
    fromChain: string,
    toChain: string,
    fromTokenSymbol: string,
    toTokenSymbol: string,
    amount: string,
    fromAddress: string,
    toAddress: string,
    slippage?: number
  ): Promise<QuoteRequest> {
    // Get CAIP-19 asset IDs
    const fromAssetId = getAssetId(fromChain, fromTokenSymbol);
    const toAssetId = getAssetId(toChain, toTokenSymbol);

    if (!fromAssetId) {
      throw new Error(`Token ${fromTokenSymbol} not supported on chain ${fromChain}`);
    }

    if (!toAssetId) {
      throw new Error(`Token ${toTokenSymbol} not supported on chain ${toChain}`);
    }

    // Get raw token addresses for LI.FI SDK (legacy format)
    const fromToken = getRawTokenAddress(fromAssetId);
    const toToken = getRawTokenAddress(toAssetId);

    // Convert CAIP-2 to legacy chain IDs for LI.FI SDK
    const fromChainLegacy = toLegacyChainId(fromChain);
    const toChainLegacy = toLegacyChainId(toChain);

    // Determine default slippage based on chains
    const defaultSlippage = isSuiChain(fromChain) || isSuiChain(toChain) ? 0.03 : 0.01;

    return {
      fromChain: fromChainLegacy,
      toChain: toChainLegacy,
      fromToken,
      toToken,
      fromAmount: amount,
      fromAddress,
      toAddress,
      slippage: slippage || defaultSlippage,
    };
  }

  /**
   * Validate if a route is possible
   * @param fromChain - CAIP-2 chain ID
   * @param toChain - CAIP-2 chain ID
   * @param tokenSymbol - Token symbol
   */
  async validateRoute(
    fromChain: string,
    toChain: string,
    tokenSymbol: string
  ): Promise<{ valid: boolean; error?: string }> {
    try {
      // Check if chains are supported
      const fromChainConfig = getChainById(fromChain);
      const toChainConfig = getChainById(toChain);

      if (!fromChainConfig) {
        return { valid: false, error: `Chain ${fromChain} not supported` };
      }

      if (!toChainConfig) {
        return { valid: false, error: `Chain ${toChain} not supported` };
      }

      // Check if token exists on both chains
      const fromAssetId = getAssetId(fromChain, tokenSymbol);
      const toAssetId = getAssetId(toChain, tokenSymbol);

      if (!fromAssetId) {
        return { valid: false, error: `Token ${tokenSymbol} not available on ${fromChainConfig.name}` };
      }

      if (!toAssetId) {
        return { valid: false, error: `Token ${tokenSymbol} not available on ${toChainConfig.name}` };
      }

      return { valid: true };
    } catch (error) {
      return { valid: false, error: (error as Error).message };
    }
  }

  /**
   * Estimate total fees for a quote
   */
  estimateFees(quote: Quote): {
    totalFeesUSD: string;
    gasCostUSD: string;
    bridgeFeeUSD: string;
    executionTime: number;
  } {
    let totalFeesUSD = 0;
    let gasCostUSD = 0;
    let bridgeFeeUSD = 0;
    let executionTime = 0;

    // Sum up all steps
    for (const step of quote.includedSteps) {
      // Gas costs
      if (step.estimate.gasCosts) {
        for (const gas of step.estimate.gasCosts) {
          gasCostUSD += parseFloat(gas.amountUSD || '0');
        }
      }

      // Fee costs
      if (step.estimate.feeCosts) {
        for (const fee of step.estimate.feeCosts) {
          bridgeFeeUSD += parseFloat(fee.amountUSD || '0');
        }
      }

      // Execution time
      executionTime += step.estimate.executionDuration || 0;
    }

    totalFeesUSD = gasCostUSD + bridgeFeeUSD;

    return {
      totalFeesUSD: totalFeesUSD.toFixed(2),
      gasCostUSD: gasCostUSD.toFixed(2),
      bridgeFeeUSD: bridgeFeeUSD.toFixed(2),
      executionTime,
    };
  }

  /**
   * Handle LI.FI errors and provide user-friendly messages
   */
  private handleError(error: any): LiFiError {
    const lifiError = error as LiFiError;

    // Insufficient gas
    if (error.message?.includes('insufficient') && error.message?.includes('gas')) {
      lifiError.message = 'Insufficient gas on the source chain. Please add gas tokens to your wallet.';
      lifiError.code = 'INSUFFICIENT_GAS';
    }

    // Insufficient balance
    if (error.message?.includes('insufficient') && error.message?.includes('balance')) {
      lifiError.message = 'Insufficient token balance for this transaction.';
      lifiError.code = 'INSUFFICIENT_BALANCE';
    }

    // Slippage too low
    if (error.message?.includes('slippage')) {
      lifiError.message = 'Slippage tolerance too low. Try increasing slippage to 3-5%.';
      lifiError.code = 'SLIPPAGE_TOO_LOW';
      lifiError.suggestedSlippage = 0.05;
    }

    // Route not found
    if (error.message?.includes('No route found') || error.message?.includes('not available')) {
      lifiError.message = 'No bridge or swap route available for this token pair. Try using USDC or USDT.';
      lifiError.code = 'NO_ROUTE_FOUND';
    }

    // Sui object error
    if (error.message?.includes('object') || error.message?.includes('Sui')) {
      lifiError.message = 'Sui transaction failed. This may be due to stale object references. Please retry.';
      lifiError.code = 'SUI_OBJECT_ERROR';
    }

    // Network error
    if (error.message?.includes('network') || error.message?.includes('timeout')) {
      lifiError.message = 'Network error. Please check your connection and try again.';
      lifiError.code = 'NETWORK_ERROR';
    }

    return lifiError;
  }

  /**
   * Check if error is recoverable
   */
  isRecoverableError(error: LiFiError): boolean {
    const recoverableCodes = ['SUI_OBJECT_ERROR', 'NETWORK_ERROR', 'SLIPPAGE_TOO_LOW'];
    return recoverableCodes.includes(error.code || '');
  }

  /**
   * Execute a route (swap or bridge)
   * @param accountId - Account ID
   * @param route - LI.FI route to execute
   */
  async executeRoute(
    accountId: number,
    route: Route
  ): Promise<ExecutionResult> {
    // Convert legacy chain IDs to CAIP-2
    const fromChainCAIP2 = toCAIP2(route.action.fromChainId);
    const toChainCAIP2 = toCAIP2(route.action.toChainId);

    // Determine transaction type
    const transactionType = route.action.fromChainId === route.action.toChainId ? 'swap' : 'bridge';

    // Log transaction to queue
    const transactionId = await lifiTransactionService.logTransaction({
      accountId,
      chainId: fromChainCAIP2,
      transactionType,
      route,
    });

    try {
      // Ensure wallets exist for both chains
      await walletService.createWallet(accountId, fromChainCAIP2);
      if (fromChainCAIP2 !== toChainCAIP2) {
        await walletService.createWallet(accountId, toChainCAIP2);
      }

      // Configure providers
      const providers: any = {};

      // Add EVM provider if needed
      if (isEVMChain(fromChainCAIP2) || isEVMChain(toChainCAIP2)) {
        const evmChain = isEVMChain(fromChainCAIP2) ? fromChainCAIP2 : toChainCAIP2;
        providers.evm = createEVMProvider(accountId, evmChain);
      }

      // Add Sui provider if needed
      if (isSuiChain(fromChainCAIP2) || isSuiChain(toChainCAIP2)) {
        const suiChain = isSuiChain(fromChainCAIP2) ? fromChainCAIP2 : toChainCAIP2;
        providers.sui = createSuiProvider(accountId, suiChain);
      }

      // Update status to pending
      await lifiTransactionService.updateStatus(transactionId, 'pending');

      // Execute the route with configured providers
      const result = await lifiExecuteRoute(route as any, {
        updateRouteHook: (updatedRoute: any) => {
          console.log('Route update:', updatedRoute.status);
        },
      });

      // Extract transaction hash from result
      let txHash: string | undefined;
      if (result.steps && result.steps.length > 0) {
        const firstStep = result.steps[0];
        if (firstStep.execution?.process && firstStep.execution.process.length > 0) {
          txHash = firstStep.execution.process[0].txHash;
        }
      }

      // Update status to confirmed
      await lifiTransactionService.updateStatus(transactionId, 'confirmed', txHash);

      return {
        route: result as unknown as Route,
        status: (result as any).status || 'DONE',
        txHash,
      };
    } catch (error: any) {
      // Update status to failed
      await lifiTransactionService.updateStatus(
        transactionId,
        'failed',
        undefined,
        error.message
      );

      // Handle Sui object staleness - retry with fresh quote
      if (error.message?.includes('object') || error.message?.includes('Sui')) {
        throw this.handleError({
          ...error,
          code: 'SUI_OBJECT_ERROR',
          message: 'Sui object reference stale. Please retry to get a fresh quote.',
        });
      }

      throw this.handleError(error);
    }
  }
}

export const lifiService = new LiFiService();
