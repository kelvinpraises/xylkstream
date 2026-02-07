import { createTool } from "@mastra/core/tools";
import { z } from "zod";
import { lifiService } from "@/services/system/integrations/lifi/lifi-service";
import { walletService } from "@/services/system/wallet/wallet-service";
import { getChainById, toCAIP2 } from "@/config/chains";

export const getBridgeQuote = createTool({
  id: "getBridgeQuote",
  description: "Get a quote for bridging tokens between chains (e.g., USDC from Base to Sui)",
  inputSchema: z.object({
    accountId: z.number().describe("Account ID"),
    fromChain: z.union([z.string(), z.number()]).describe("Source chain (e.g., 'eip155:8453', 8453, 'sui:mainnet')"),
    toChain: z.union([z.string(), z.number()]).describe("Destination chain (e.g., 'eip155:8453', 8453, 'sui:mainnet')"),
    tokenSymbol: z.string().describe("Token to bridge (e.g., 'USDC')"),
    amount: z.string().describe("Amount to bridge"),
    slippage: z.number().optional().describe("Slippage tolerance"),
  }),
  execute: async (inputData) => {
    try {
      // Convert to CAIP-2 format
      const fromChainCAIP2 = toCAIP2(inputData.fromChain);
      const toChainCAIP2 = toCAIP2(inputData.toChain);

      // Validate route first (using CAIP-2)
      const validation = await lifiService.validateRoute(
        fromChainCAIP2,
        toChainCAIP2,
        inputData.tokenSymbol
      );

      if (!validation.valid) {
        return {
          success: false,
          error: validation.error,
          code: 'INVALID_ROUTE',
        };
      }

      // Ensure wallets exist for both chains
      await walletService.createWallet(inputData.accountId, fromChainCAIP2);
      await walletService.createWallet(inputData.accountId, toChainCAIP2);

      // Get addresses for both chains (raw format for LI.FI)
      const fromAddress = await walletService.getRawAddress(inputData.accountId, fromChainCAIP2);
      const toAddress = await walletService.getRawAddress(inputData.accountId, toChainCAIP2);

      // Build quote request (using CAIP-2)
      const quoteRequest = await lifiService.buildQuoteRequest(
        fromChainCAIP2,
        toChainCAIP2,
        inputData.tokenSymbol,
        inputData.tokenSymbol, // Same token on both chains
        inputData.amount,
        fromAddress,
        toAddress,
        inputData.slippage
      );

      // Get quote
      const quote = await lifiService.getQuote(quoteRequest);

      // Estimate fees
      const fees = lifiService.estimateFees(quote);

      const fromChainInfo = getChainById(inputData.fromChain);
      const toChainInfo = getChainById(inputData.toChain);

      return {
        success: true,
        quote: {
          id: quote.id,
          fromChain: fromChainInfo?.name || inputData.fromChain,
          toChain: toChainInfo?.name || inputData.toChain,
          token: inputData.tokenSymbol,
          fromAmount: quote.action.fromAmount,
          toAmount: quote.action.toAmount,
          toAmountMin: quote.estimate.toAmountMin,
          bridge: quote.toolDetails.name,
          fees: {
            totalUSD: fees.totalFeesUSD,
            gasUSD: fees.gasCostUSD,
            bridgeFeeUSD: fees.bridgeFeeUSD,
          },
          estimatedTime: fees.executionTime,
          estimatedTimeMinutes: Math.ceil(fees.executionTime / 60),
          slippage: quote.action.slippage,
          steps: quote.includedSteps.length,
        },
      };
    } catch (error: any) {
      // Handle specific errors
      if (error.code === 'INSUFFICIENT_GAS') {
        return {
          success: false,
          error: `Insufficient gas on ${inputData.fromChain}. Please add gas tokens to your wallet before bridging.`,
          code: error.code,
          action: 'ADD_GAS',
        };
      }

      return {
        success: false,
        error: error.message,
        code: error.code,
      };
    }
  },
});
