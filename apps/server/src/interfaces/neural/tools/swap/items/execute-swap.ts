import { createTool } from "@mastra/core/tools";
import { z } from "zod";
import { lifiService } from "@/services/system/integrations/lifi/lifi-service";
import { walletService } from "@/services/system/wallet/wallet-service";
import { toCAIP2 } from "@/config/chains";

export const executeSwap = createTool({
  id: "executeSwap",
  description: "Execute a token swap on the same chain. This actually performs the swap transaction using the user's wallet.",
  inputSchema: z.object({
    accountId: z.number().describe("Account ID"),
    chainId: z.union([z.string(), z.number()]).describe("Chain ID (e.g., 'eip155:8453', 8453, 'sui:mainnet')"),
    fromTokenSymbol: z.string().describe("Token to swap from"),
    toTokenSymbol: z.string().describe("Token to swap to"),
    amount: z.string().describe("Amount to swap"),
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
        chainIdCAIP2,
        inputData.fromTokenSymbol,
        inputData.toTokenSymbol,
        inputData.amount,
        address,
        address,
        inputData.slippage
      );

      // Get quote
      const quote = await lifiService.getQuote(quoteRequest);

      // Execute the swap (using accountId instead of accountData)
      const result = await lifiService.executeRoute(inputData.accountId, quote as any);

      const fees = lifiService.estimateFees(quote);

      return {
        success: true,
        message: `Swap executed: ${inputData.amount} ${inputData.fromTokenSymbol} → ${quote.estimate.toAmount} ${inputData.toTokenSymbol}`,
        swap: {
          txHash: result.txHash,
          quoteId: quote.id,
          fromToken: inputData.fromTokenSymbol,
          toToken: inputData.toTokenSymbol,
          fromAmount: inputData.amount,
          actualToAmount: quote.estimate.toAmount,
          minToAmount: quote.estimate.toAmountMin,
          tool: quote.toolDetails.name,
          fees: fees.totalFeesUSD,
          status: result.status,
        },
      };
    } catch (error: any) {
      if (error.code === 'INSUFFICIENT_GAS') {
        return {
          success: false,
          error: `Insufficient gas on ${inputData.chainId}. Please add gas tokens to your wallet.`,
          code: error.code,
          action: 'USER_MUST_ADD_GAS',
        };
      }

      if (error.code === 'INSUFFICIENT_BALANCE') {
        return {
          success: false,
          error: `Insufficient ${inputData.fromTokenSymbol} balance for this swap.`,
          code: error.code,
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
