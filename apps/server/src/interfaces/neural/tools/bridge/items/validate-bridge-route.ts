import { createTool } from "@mastra/core/tools";
import { z } from "zod";
import { lifiService } from "@/services/system/integrations/lifi/lifi-service";
import { toCAIP2 } from "@/config/chains";

export const validateBridgeRoute = createTool({
  id: "validateBridgeRoute",
  description: "Check if a bridge route is available for a token between two chains",
  inputSchema: z.object({
    fromChain: z.union([z.string(), z.number()]).describe("Source chain (e.g., 'eip155:8453', 8453, 'sui:mainnet')"),
    toChain: z.union([z.string(), z.number()]).describe("Destination chain (e.g., 'eip155:8453', 8453, 'sui:mainnet')"),
    tokenSymbol: z.string().describe("Token symbol"),
  }),
  execute: async (inputData) => {
    try {
      // Convert to CAIP-2 format
      const fromChainCAIP2 = toCAIP2(inputData.fromChain);
      const toChainCAIP2 = toCAIP2(inputData.toChain);

      // Validate route using CAIP-2
      const validation = await lifiService.validateRoute(
        fromChainCAIP2,
        toChainCAIP2,
        inputData.tokenSymbol
      );

      if (!validation.valid) {
        return {
          valid: false,
          error: validation.error,
          suggestion: "Try using USDC or USDT for cross-chain transfers. These tokens have the best bridge support.",
        };
      }

      return {
        valid: true,
        message: `Bridge route available for ${inputData.tokenSymbol} from ${fromChainCAIP2} to ${toChainCAIP2}`,
      };
    } catch (error: any) {
      return {
        valid: false,
        error: error.message,
      };
    }
  },
});
