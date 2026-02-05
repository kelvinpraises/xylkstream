import { createTool } from "@mastra/core/tools";
import { z } from "zod";

import { accountService } from "@/services/vesting/account-service";
import { streamService } from "@/services/vesting/stream-service";

export const analyzeAccountLiquidity = createTool({
  id: "analyzeAccountLiquidity",
  description: "Calculate idle vs locked funds in vesting account",
  inputSchema: z.object({
    accountId: z.number(),
  }),
  execute: async (inputData) => {
    const account = await accountService.getAccount(inputData.accountId);
    const streams = await streamService.listStreams(inputData.accountId, {
      status: "ACTIVE",
    });

    // Calculate locked funds (sum of remaining amounts in active streams)
    const lockedFunds = streams.reduce((sum, stream) => {
      const distributed = stream.total_distributed || 0;
      const remaining = stream.amount - distributed;
      return sum + remaining;
    }, 0);

    const totalBalance = account.balance;
    const idleFunds = totalBalance - lockedFunds;

    return {
      totalBalance,
      lockedFunds,
      idleFunds,
      utilizationRate: totalBalance > 0 ? (lockedFunds / totalBalance) * 100 : 0,
      activeStreamsCount: streams.length,
    };
  },
});
