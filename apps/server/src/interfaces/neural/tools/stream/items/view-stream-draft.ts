import { createTool } from "@mastra/core/tools";
import { z } from "zod";

import { streamService } from "@/services/vesting/stream-service";

export const viewStreamDraft = createTool({
  id: "viewStreamDraft",
  description: "View current state of stream draft",
  inputSchema: z.object({
    streamId: z.number(),
  }),
  execute: async (inputData) => {
    const stream = await streamService.getStream(inputData.streamId);

    return {
      streamId: stream.id,
      recipientAddress: stream.recipient_address,
      amount: stream.amount,
      startTime: stream.start_time,
      duration: stream.duration,
      cliffDuration: stream.cliff_duration,
      periodDuration: stream.period_duration,
      status: stream.status,
    };
  },
});
