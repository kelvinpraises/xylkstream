import { createTool } from "@mastra/core/tools";
import { z } from "zod";

import { streamService } from "@/services/vesting/stream-service";

export const queryStreams = createTool({
  id: "queryStreams",
  description: "Search and filter streams by criteria",
  inputSchema: z.object({
    accountId: z.number(),
    status: z.enum(["ACTIVE", "PAUSED", "COMPLETED", "CANCELLED"]).optional(),
    recipientAddress: z.string().optional(),
  }),
  execute: async (inputData) => {
    const streams = await streamService.listStreams(inputData.accountId, {
      status: inputData.status,
      recipientAddress: inputData.recipientAddress,
    });

    return {
      count: streams.length,
      streams: streams.map((s) => ({
        id: s.id,
        recipientAddress: s.recipient_address,
        amount: s.amount,
        status: s.status,
        startTime: s.start_time,
        duration: s.duration,
      })),
    };
  },
});
