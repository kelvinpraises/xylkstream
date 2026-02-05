import { createTool } from "@mastra/core/tools";
import { z } from "zod";

import { accountService } from "@/services/vesting/account-service";

export const checkPolicyCompliance = createTool({
  id: "checkPolicyCompliance",
  description: "Validate if a proposed action complies with account policy",
  inputSchema: z.object({
    accountId: z.number(),
    action: z.enum(["create_stream", "modify_stream", "yield_optimization"]),
    parameters: z.record(z.any()).describe("Action parameters to validate"),
  }),
  execute: async (inputData) => {
    const account = await accountService.getAccount(inputData.accountId);
    const policy = account.policy_json;

    const violations: string[] = [];
    const warnings: string[] = [];

    // Validate based on action type
    if (inputData.action === "create_stream") {
      const { amount, recipientAddress } = inputData.parameters;

      // Check budget limits
      if (policy.budget_limits?.max_stream_amount && amount > policy.budget_limits.max_stream_amount) {
        violations.push(
          `Amount ${amount} exceeds max stream amount ${policy.budget_limits.max_stream_amount}`,
        );
      }

      // Check whitelist if exists
      if (policy.recipient_whitelist && !policy.recipient_whitelist.includes(recipientAddress)) {
        violations.push(`Recipient ${recipientAddress} not in whitelist`);
      }

      // Check balance
      if (amount > account.balance) {
        violations.push(`Insufficient balance: ${account.balance} < ${amount}`);
      }
    }

    return {
      compliant: violations.length === 0,
      violations,
      warnings,
      policy: {
        budgetLimits: policy.budget_limits,
        plugins: policy.plugins,
        riskTolerance: policy.risk_tolerance,
      },
    };
  },
});
