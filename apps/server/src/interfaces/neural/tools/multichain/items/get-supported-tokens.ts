import { createTool } from "@mastra/core/tools";
import { z } from "zod";
import { TOKENS, getTokenMetadata } from "@/config/tokens";
import { toCAIP2 } from "@/config/chains";

export const getSupportedTokens = createTool({
  id: "getSupportedTokens",
  description: "Get list of tokens supported on a specific chain for swapping and bridging",
  inputSchema: z.object({
    chainId: z.union([z.string(), z.number()]).describe("Chain ID (e.g., 'eip155:8453', 8453, 'sui:mainnet')"),
  }),
  execute: async (inputData) => {
    try {
      // Convert to CAIP-2 format
      const chainIdCAIP2 = toCAIP2(inputData.chainId);

      // Filter tokens for this chain
      const chainTokens = Object.entries(TOKENS)
        .filter(([assetId]) => assetId.startsWith(chainIdCAIP2))
        .map(([assetId, metadata]) => ({
          assetId,           // CAIP-19 format
          symbol: metadata.symbol,
          name: metadata.name,
          decimals: metadata.decimals,
        }));

      return {
        success: true,
        chainId: chainIdCAIP2,
        tokens: chainTokens,
        totalTokens: chainTokens.length,
        note: "Asset IDs use CAIP-19 format (e.g., 'eip155:8453/erc20:0x833...')",
      };
    } catch (error: any) {
      return {
        success: false,
        error: error.message,
      };
    }
  },
});
