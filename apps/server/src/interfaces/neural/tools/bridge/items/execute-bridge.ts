import { createTool } from "@mastra/core/tools";
import { z } from "zod";
import { lifiService } from "@/services/system/integrations/lifi/lifi-service";
import { walletService } from "@/services/system/wallet/wallet-service";
import { getChainById, toCAIP2 } from "@/config/chains";

export const executeBridge = createTool({
  id: "executeBridge",
  description: "Execute a cross-chain bridge transaction. This actually moves tokens from one chain to another using the user's wallet.",
  inputSchema: z.object({
    accountId: z.number().describe("Account ID"),
    fromChain: z.union([z.string(), z.number()]).describe("Source chain (e.g., 'eip155:8453', 8453, 'sui:mainnet')"),
    toChain: z.union([z.string(), z.number()]).describe("Destination chain (e.g., 'eip155:8453', 8453, 'sui:mainnet')"),
    tokenSymbol: z.string().describe("Token to bridge"),
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
          suggestion: 'Try using USDC or USDT for cross-chain transfers.',
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
        inputData.tokenSymbol,
        inputData.amount,
        fromAddress,
        toAddress,
        inputData.slippage
      );

      // Get quote
      const quote = await lifiService.getQuote(quoteRequest);

      // Execute the bridge (using accountId instead of accountData)
      const result = await lifiService.executeRoute(inputData.accountId, quote as any);

      const fees = lifiService.estimateFees(quote);
      const fromChainInfo = getChainById(inputData.fromChain);
      const toChainInfo = getChainById(inputData.toChain);

      return {
        success: true,
        message: `Bridge executed: ${inputData.amount} ${inputData.tokenSymbol} from ${fromChainInfo?.name} to ${toChainInfo?.name}`,
        bridge: {
          txHash: result.txHash,
          quoteId: quote.id,
          fromChain: fromChainInfo?.name || inputData.fromChain,
          toChain: toChainInfo?.name || inputData.toChain,
          token: inputData.tokenSymbol,
          amount: inputData.amount,
          actualReceive: quote.estimate.toAmount,
          minReceive: quote.estimate.toAmountMin,
          bridge: quote.toolDetails.name,
          fees: fees.totalFeesUSD,
          estimatedTimeMinutes: Math.ceil(fees.executionTime / 60),
          status: result.status,
          steps: quote.includedSteps.length,
        },
      };
    } catch (error: any) {
      if (error.code === 'INSUFFICIENT_GAS') {
        return {
          success: false,
          error: `Insufficient gas on ${inputData.fromChain}. Please add gas tokens to your wallet before bridging.`,
          code: error.code,
          action: 'USER_MUST_ADD_GAS',
          details: `You need native tokens (ETH on Base, SUI on Sui) to pay for transaction fees.`,
        };
      }

      if (error.code === 'INSUFFICIENT_BALANCE') {
        return {
          success: false,
          error: `Insufficient ${inputData.tokenSymbol} balance for this bridge.`,
          code: error.code,
        };
      }

      if (error.code === 'NO_ROUTE_FOUND') {
        return {
          success: false,
          error: `No bridge available for ${inputData.tokenSymbol} between these chains.`,
          code: error.code,
          suggestion: 'Try using USDC or USDT - they have the best bridge support between Sui and Base.',
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
