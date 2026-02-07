import { createTool } from "@mastra/core/tools";
import { z } from "zod";
import { lifiService } from "@/services/system/integrations/lifi/lifi-service";
import { walletService } from "@/services/system/wallet/wallet-service";
import { toCAIP2 } from "@/config/chains";

export const findBestSwapRoute = createTool({
  id: "findBestSwapRoute",
  description: "Find the best swap route with multiple options (fastest, cheapest, recommended)",
  inputSchema: z.object({
    accountId: z.number().describe("Account ID"),
    chainId: z.union([z.string(), z.number()]).describe("Chain ID (e.g., 'eip155:8453', 8453, 'sui:mainnet')"),
    fromTokenSymbol: z.string().describe("Token to swap from"),
    toTokenSymbol: z.string().describe("Token to swap to"),
    amount: z.string().describe("Amount to swap"),
    slippage: z.number().optional().describe("Slippage tolerance"),
  }),
  execute: async (inputData) => {
    try {
      // Convert to CAIP-2 format
      const chainIdCAIP2 = toCAIP2(inputData.chainId);

      // Ensure wallet exists
      await walletService.createWallet(inputData.accountId, chainIdCAIP2);

      // Get wallet address (raw format for LI.FI)
      const address = await walletService.getRawAddress(inputData.accountId, chainIdCAIP2);

      // Build route request (using CAIP-2)
      const routeRequest = await lifiService.buildQuoteRequest(
        chainIdCAIP2,
        chainIdCAIP2,
        inputData.fromTokenSymbol,
        inputData.toTokenSymbol,
        inputData.amount,
        address,
        address,
        inputData.slippage
      );

      // Get multiple routes
      const routes = await lifiService.getRoutes(routeRequest as any);

      // Sort and categorize routes
      const sortedByPrice = [...routes].sort((a, b) => 
        parseFloat(b.estimate.toAmount) - parseFloat(a.estimate.toAmount)
      );

      const sortedByTime = [...routes].sort((a, b) => {
        const timeA = a.includedSteps.reduce((sum, step) => sum + (step.estimate.executionDuration || 0), 0);
        const timeB = b.includedSteps.reduce((sum, step) => sum + (step.estimate.executionDuration || 0), 0);
        return timeA - timeB;
      });

      const recommended = routes[0]; // LI.FI's recommended route

      return {
        success: true,
        routes: {
          recommended: {
            id: recommended.id,
            tool: recommended.toolDetails.name,
            toAmount: recommended.estimate.toAmount,
            fees: lifiService.estimateFees(recommended),
          },
          cheapest: sortedByPrice[0] ? {
            id: sortedByPrice[0].id,
            tool: sortedByPrice[0].toolDetails.name,
            toAmount: sortedByPrice[0].estimate.toAmount,
            fees: lifiService.estimateFees(sortedByPrice[0]),
          } : null,
          fastest: sortedByTime[0] ? {
            id: sortedByTime[0].id,
            tool: sortedByTime[0].toolDetails.name,
            toAmount: sortedByTime[0].estimate.toAmount,
            fees: lifiService.estimateFees(sortedByTime[0]),
          } : null,
        },
        totalRoutes: routes.length,
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
