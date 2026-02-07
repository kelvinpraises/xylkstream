import { createTool } from "@mastra/core/tools";
import { z } from "zod";
import { lifiService } from "@/services/system/integrations/lifi/lifi-service";
import { SUPPORTED_CHAINS } from "@/config/chains";

export const getSupportedChains = createTool({
  id: "getSupportedChains",
  description: "Get list of all chains supported for swapping and bridging",
  inputSchema: z.object({}),
  execute: async () => {
    try {
      // Return our configured chains with CAIP-2 format
      const chains = Object.values(SUPPORTED_CHAINS).map(chain => ({
        id: chain.id,              // CAIP-2 format
        legacyId: chain.legacyId,  // For compatibility
        name: chain.name,
        nativeToken: chain.nativeToken,
        explorer: chain.explorer,
      }));

      return {
        success: true,
        chains,
        totalChains: chains.length,
        note: "Chain IDs use CAIP-2 format (e.g., 'eip155:8453', 'sui:mainnet')",
      };
    } catch (error: any) {
      return {
        success: false,
        error: error.message,
      };
    }
  },
});
