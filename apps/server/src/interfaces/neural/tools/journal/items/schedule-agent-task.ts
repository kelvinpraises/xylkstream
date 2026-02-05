import { createTool } from "@mastra/core/tools";
import { z } from "zod";

import { scheduledEventService } from "@/services/system/scheduled-event-service";

export const scheduleAgentTask = createTool({
  id: "scheduleAgentTask",
  description: `Schedule a future task for yourself to resume work.
  
  Use this when you need to:
  - Wait for a specific time before taking action
  - Rebalance liquidity before distributions
  - Check yield performance periodically
  - Resume optimization after market conditions change
  
  Examples:
  - "Withdraw 10K from Aave in 2 hours before distribution"
  - "Check Compound APY again in 24 hours"
  - "Rebalance portfolio in 1 week"`,
  inputSchema: z.object({
    scheduledAt: z.string().describe("ISO timestamp when to resume (e.g., 2024-01-15T10:00:00Z)"),
    taskDescription: z.string().describe("What you need to do when you resume"),
    contextToRemember: z
      .string()
      .optional()
      .describe("Important context to remember when you resume"),
  }),
  execute: async (inputData, context) => {
    const accountId = context?.requestContext?.get("accountId") as number;
    const streamId = context?.requestContext?.get("streamId") as number | undefined;

    await scheduledEventService.createScheduledEvent({
      entityType: streamId ? "stream" : "account",
      entityId: streamId ?? accountId,
      eventType: "AGENT_TASK",
      scheduledAt: new Date(inputData.scheduledAt),
      metadata: {
        accountId,
        streamId,
        taskDescription: inputData.taskDescription,
        contextToRemember: inputData.contextToRemember,
      },
    });

    return {
      success: true,
      message: `Task scheduled for ${inputData.scheduledAt}`,
    };
  },
});
