import cron from "node-cron";

import { neuralAgent } from "@/interfaces/neural";
import { accountService } from "@/services/vesting/account-service";

/**
 * Yield Optimizer Cron Job
 *
 * Runs every hour to optimize yield for idle vesting funds.
 */
const yieldOptimizerCron = {
  async start() {
    console.log("[yield-optimizer-cron] Starting yield optimizer cron job...");

    // Schedule the job to run every hour
    cron.schedule("0 * * * *", async () => {
      console.log("[yield-optimizer-cron] Running yield optimization cycle...");
      await this.runCycle();
    });
  },

  async runCycle() {
    try {
      const accounts = await accountService.listAccounts();

      let optimized = 0;
      for (const account of accounts) {
        console.log(`[yield-optimizer-cron] Optimizing yield for account ${account.id}`);
        
        try {
          await neuralAgent.optimizeYield(account.id);
          optimized++;
        } catch (error) {
          console.error(`[yield-optimizer-cron] Failed to optimize account ${account.id}:`, error);
        }
      }

      console.log(`[yield-optimizer-cron] Cycle completed: ${optimized} accounts optimized`);
    } catch (error) {
      console.error("[yield-optimizer-cron] Yield optimization cycle failed:", error);
    }
  },
};

export default yieldOptimizerCron;
