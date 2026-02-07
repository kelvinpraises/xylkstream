import { createTool } from "@mastra/core/tools";
import { z } from "zod";
import { lifiService } from "@/services/system/integrations/lifi/lifi-service";
import { walletService } from "@/services/system/wallet/wallet-service";
import { toCAIP2 } from "@/config/chains";

export const getSwapQuote = createTool({
  id: "getSwapQuote",
  description: "Get a quote for swapping tokens on the same chain (e.g., USDC to ETH on Base)",
  inputSchema: z.object({
    accountId: z.number().describe("Account ID"),
    chainId: z.union([z.string(), z.number()]).describe("Chain ID (e.g., 'eip155:8453', 8453, 'sui:mainnet')"),
    fromTokenSymbol: z.string().describe("Token to swap from (e.g., 'USDC')"),
    toTokenSymbol: z.string().describe("Token to swap to (e.g., 'ETH')"),
    amount: z.string().describe("Amount to swap (in token units)"),
    slippage: z.number().optional().describe("Slippage tolerance (0.01 = 1%)"),
  }),
  execute: async (inputData) => {
    try {
      // Convert to CAIP-2 format
      const chainIdCAIP2 = toCAIP2(inputData.chainId);

      // Ensure wallet exists
      await walletService.createWallet(inputData.accountId, chainIdCAIP2);

      // Get wallet address (raw format for LI.FI)
      const address = await walletService.getRawAddress(inputData.accountId, chainIdCAIP2);

      // Build quote request (using CAIP-2)
      const quoteRequest = await lifiService.buildQuoteRequest(
        chainIdCAIP2,
        chainIdCAIP2, // Same chain for swap
        inputData.fromTokenSymbol,
        inputData.toTokenSymbol,
        inputData.amount,
        address,
        address, // Same address for swap
        inputData.slippage
      );

      // Get quote
      const quote = await lifiService.getQuote(quoteRequest);

      // Estimate fees
      const fees = lifiService.estimateFees(quote);

      return {
        success: true,
        quote: {
          id: quote.id,
          fromToken: inputData.fromTokenSymbol,
          toToken: inputData.toTokenSymbol,
          fromAmount: quote.action.fromAmount,
          toAmount: quote.action.toAmount,
          toAmountMin: quote.estimate.toAmountMin,
          chainId: inputData.chainId,
          tool: quote.tool,
          toolName: quote.toolDetails.name,
          fees: {
            totalUSD: fees.totalFeesUSD,
            gasUSD: fees.gasCostUSD,
            bridgeFeeUSD: fees.bridgeFeeUSD,
          },
          executionTime: fees.executionTime,
          slippage: quote.action.slippage,
        },
      };
    } catch (error: any) {
      return {
        success: false,
        error: error.message,
        code: error.code,
      };
    }
  },
});
