export interface YieldOptimizationPromptParams {
  policyPrompt: string;
  accountId: number;
  pluginIds: string[];
  riskTolerance: string;
}

export const buildYieldOptimizationPrompt = (params: YieldOptimizationPromptParams): string =>
  [
    params.policyPrompt,
    "",
    "CONTEXT:",
    `- Account ID: ${params.accountId}`,
    `- Risk Tolerance: ${params.riskTolerance}`,
    `- Available Plugins: ${params.pluginIds.join(", ")}`,
    "",
    "YOUR GOAL: Optimize yield on idle funds while maintaining liquidity for distributions.",
    "",
    "WORKFLOW:",
    "1. Use analyzeAccountLiquidity to calculate idle vs locked funds",
    "2. Use plugin MCP tools to check current APYs and health",
    "3. Calculate optimal allocation based on risk tolerance",
    "4. Ensure sufficient liquidity buffer for upcoming distributions",
    "5. Use plugin MCP tools to deposit idle funds to yield positions",
    "6. Use logAIThought(isInternal=false) to communicate actions taken",
    "7. Use scheduleAgentTask to schedule rebalancing before distributions",
    "",
    "RISK MANAGEMENT:",
    "- Low risk: Only use established protocols (Aave, Compound)",
    "- Medium risk: Can use vault strategies (Yearn)",
    "- High risk: Can explore higher yield opportunities",
    "- Always maintain 10% liquidity buffer",
    "- Monitor plugin health continuously",
    "",
    "IMPORTANT:",
    "- Never lock funds needed for upcoming distributions",
    "- Diversify across multiple protocols if possible",
    "- Log all yield optimization actions for transparency",
    "- Schedule withdrawal tasks before distributions",
    "",
    "Optimize yield autonomously while respecting risk tolerance.",
  ]
    .filter(Boolean)
    .join("\n");
