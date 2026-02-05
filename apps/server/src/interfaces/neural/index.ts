import { Mastra } from "@mastra/core";
import { RequestContext } from "@mastra/core/request-context";
import { LibSQLStore } from "@mastra/libsql";
import { PinoLogger } from "@mastra/loggers";
import { MCPClient } from "@mastra/mcp";

import { vestingAgent } from "@/interfaces/neural/agents/vesting-agent";
import {
  buildScheduledTaskPrompt,
  buildStreamCreationPrompt,
  buildUserFeedbackPrompt,
  buildYieldOptimizationPrompt,
} from "@/interfaces/neural/prompts";
import { accountService } from "@/services/vesting/account-service";
import { auditLogService } from "@/services/vesting/audit-log-service";
import { streamService } from "@/services/vesting/stream-service";
import { pluginService } from "@/services/system/plugin/plugin-service";
import type { ScheduledEvent } from "@/types/scheduled-event";

const runningAgentTasks = new Map<string, AbortController>();

export const mastra = new Mastra({
  agents: { vestingAgent },
  storage: new LibSQLStore({
    id: "vesting-memory",
    url: process.env.TURSO_AI_MEMORY_DB_URL || "file:mastra.db",
    authToken: process.env.TURSO_AI_MEMORY_DB_TOKEN,
  }),
  logger: new PinoLogger({
    name: "xylkstream-agent",
    level: "info",
  }),
});

export const neuralAgent = {
  /**
   * Create vesting stream from natural language
   */
  async createStreamFromNaturalLanguage(
    accountId: number,
    userPrompt: string,
  ): Promise<number> {
    const startTime = Date.now();
    console.log(`[neural] Starting stream creation for account ${accountId}`);

    const account = await accountService.getAccount(accountId);
    const policy = account.policy_json;
    const streamId = await streamService.createDraft(accountId);
    const pluginIds = policy.plugins || [];
    console.log(
      `[neural] Created draft stream ${streamId}, plugins: ${pluginIds.join(", ")} (${Date.now() - startTime}ms)`,
    );

    // Load plugins
    const pluginPorts = await Promise.all(
      pluginIds.map((pluginId) =>
        pluginService.getOrServePlugin(accountId, pluginId, {}, streamId),
      ),
    );
    console.log(
      `[neural] Plugins ready on ports: ${pluginPorts.map((p) => p.port).join(", ")} (${Date.now() - startTime}ms)`,
    );

    const mcpServers = Object.fromEntries(
      pluginIds.map((pluginId, index) => [
        pluginId,
        { url: new URL(`http://localhost:${pluginPorts[index].port}/mcp`) },
      ]),
    );
    const pluginsMCP = new MCPClient({
      id: `stream-create-${streamId}-${Date.now()}`,
      servers: mcpServers,
    });

    const requestContext = new RequestContext();
    requestContext.set("streamId", streamId);
    requestContext.set("accountId", accountId);

    const abortController = new AbortController();
    const taskKey = `stream-${streamId}`;
    runningAgentTasks.set(taskKey, abortController);

    const systemPrompt = buildStreamCreationPrompt({
      policyPrompt: policy.prompt || "Follow account policy for stream creation.",
      userPrompt,
      accountId,
      streamId,
      budgetLimits: policy.budget_limits,
      pluginIds,
    });

    await auditLogService.createAuditLog({
      accountId,
      streamId,
      type: "USER_FEEDBACK",
      content: { feedback: userPrompt },
      isInternal: false,
    });

    try {
      const agent = mastra.getAgent("vestingAgent");
      const toolsets = await pluginsMCP.listToolsets();

      await agent.generate(
        [
          { role: "system", content: systemPrompt },
          { role: "user", content: userPrompt },
        ],
        {
          toolsets,
          requestContext,
          abortSignal: abortController.signal,
          memory: {
            resource: `account-${accountId}`,
            thread: streamId.toString(),
          },
        },
      );

      console.log(
        `[neural] Stream creation complete (${Date.now() - startTime}ms)`,
      );
      return streamId;
    } catch (error) {
      if (error instanceof Error && error.name !== "AbortError") {
        console.error(`[neural] Error creating stream ${streamId}:`, error);
      }
      return -1;
    } finally {
      runningAgentTasks.delete(taskKey);
    }
  },

  /**
   * Optimize yield on idle account funds
   */
  async optimizeAccountYield(accountId: number): Promise<void> {
    const account = await accountService.getAccount(accountId);
    const policy = account.policy_json;
    const pluginIds = policy.plugins || [];

    if (pluginIds.length === 0) {
      console.log(`[neural] No plugins attached to account ${accountId}, skipping optimization`);
      return;
    }

    const pluginPorts = await Promise.all(
      pluginIds.map((pluginId) =>
        pluginService.getOrServePlugin(accountId, pluginId, {}),
      ),
    );

    const mcpServers = Object.fromEntries(
      pluginIds.map((pluginId, index) => [
        pluginId,
        { url: new URL(`http://localhost:${pluginPorts[index].port}/mcp`) },
      ]),
    );
    const pluginsMCP = new MCPClient({
      id: `yield-optimize-${accountId}-${Date.now()}`,
      servers: mcpServers,
    });

    const requestContext = new RequestContext();
    requestContext.set("accountId", accountId);

    const abortController = new AbortController();
    const taskKey = `yield-${accountId}`;
    runningAgentTasks.set(taskKey, abortController);

    const systemPrompt = buildYieldOptimizationPrompt({
      policyPrompt: policy.prompt || "Optimize yield while maintaining liquidity.",
      accountId,
      pluginIds,
      riskTolerance: policy.risk_tolerance || "medium",
    });

    try {
      const agent = mastra.getAgent("vestingAgent");
      await agent.generate(
        [
          { role: "system", content: systemPrompt },
          { role: "user", content: "Optimize yield on idle funds." },
        ],
        {
          toolsets: await pluginsMCP.listToolsets(),
          requestContext,
          abortSignal: abortController.signal,
          memory: {
            resource: `account-${accountId}`,
            thread: "yield-optimization",
          },
        },
      );
    } catch (error) {
      if (error instanceof Error && error.name !== "AbortError") {
        console.error(`[neural] Error optimizing yield for account ${accountId}:`, error);
      }
    } finally {
      runningAgentTasks.delete(taskKey);
    }
  },

  /**
   * Handle user feedback on agent work
   */
  async handleUserFeedback(
    accountId: number,
    streamId: number | null,
    feedback: string,
  ): Promise<void> {
    // Interrupt current task if running
    const taskKey = streamId ? `stream-${streamId}` : `yield-${accountId}`;
    this.interruptAgentTask(taskKey);

    const account = await accountService.getAccount(accountId);
    const policy = account.policy_json;
    const pluginIds = policy.plugins || [];

    await auditLogService.createAuditLog({
      accountId,
      streamId: streamId ?? undefined,
      type: "USER_FEEDBACK",
      content: { feedback },
      isInternal: false,
    });

    const pluginPorts = await Promise.all(
      pluginIds.map((pluginId) =>
        pluginService.getOrServePlugin(accountId, pluginId, {}, streamId ?? undefined),
      ),
    );

    const mcpServers = Object.fromEntries(
      pluginIds.map((pluginId, index) => [
        pluginId,
        { url: new URL(`http://localhost:${pluginPorts[index].port}/mcp`) },
      ]),
    );
    const pluginsMCP = new MCPClient({
      id: `feedback-${accountId}-${Date.now()}`,
      servers: mcpServers,
    });

    const requestContext = new RequestContext();
    requestContext.set("accountId", accountId);
    if (streamId) requestContext.set("streamId", streamId);

    const abortController = new AbortController();
    runningAgentTasks.set(taskKey, abortController);

    let currentState: any = { account };
    if (streamId) {
      currentState.stream = await streamService.getStream(streamId);
    }

    const systemPrompt = buildUserFeedbackPrompt({
      goal: streamId ? "Create vesting stream" : "Optimize account yield",
      accountId,
      streamId: streamId ?? undefined,
      currentState,
      userMessage: feedback,
    });

    try {
      const agent = mastra.getAgent("vestingAgent");
      await agent.generate(
        [
          { role: "system", content: systemPrompt },
          { role: "user", content: feedback },
        ],
        {
          toolsets: await pluginsMCP.listToolsets(),
          requestContext,
          abortSignal: abortController.signal,
          memory: {
            resource: `account-${accountId}`,
            thread: streamId?.toString() || "yield-optimization",
          },
        },
      );
    } catch (error) {
      if (error instanceof Error && error.name !== "AbortError") {
        console.error(`[neural] Error handling feedback for account ${accountId}:`, error);

        await auditLogService.createAuditLog({
          accountId,
          streamId: streamId ?? undefined,
          type: "AI_THOUGHT",
          content: {
            thought: `I encountered an error while processing your feedback: ${error instanceof Error ? error.message : "Unknown error"}. Please try again or contact support if this persists.`,
          },
          isInternal: false,
        });
      }
    } finally {
      runningAgentTasks.delete(taskKey);
    }
  },

  /**
   * Resume scheduled agent task
   */
  async resumeAgentTask(event: ScheduledEvent): Promise<void> {
    const { entityId, metadata } = event;
    const { accountId, streamId, taskDescription, contextToRemember } = metadata;

    const account = await accountService.getAccount(accountId);
    const policy = account.policy_json;
    const pluginIds = policy.plugins || [];

    const pluginPorts = await Promise.all(
      pluginIds.map((pluginId) =>
        pluginService.getOrServePlugin(accountId, pluginId, {}, streamId),
      ),
    );

    const mcpServers = Object.fromEntries(
      pluginIds.map((pluginId, index) => [
        pluginId,
        { url: new URL(`http://localhost:${pluginPorts[index].port}/mcp`) },
      ]),
    );
    const pluginsMCP = new MCPClient({
      id: `resume-${entityId}-${Date.now()}`,
      servers: mcpServers,
    });

    const requestContext = new RequestContext();
    requestContext.set("accountId", accountId);
    if (streamId) requestContext.set("streamId", streamId);
    requestContext.set("scheduledTaskContext", contextToRemember);

    const systemPrompt = buildScheduledTaskPrompt({
      taskDescription,
      contextToRemember,
      accountId,
      streamId,
    });

    const agent = mastra.getAgent("vestingAgent");
    await agent.generate(
      [
        { role: "system", content: systemPrompt },
        { role: "user", content: "Resume the scheduled task." },
      ],
      {
        toolsets: await pluginsMCP.listToolsets(),
        requestContext,
        memory: {
          resource: `account-${accountId}`,
          thread: streamId?.toString() || "yield-optimization",
        },
      },
    );
  },

  /**
   * Interrupt running agent task
   */
  interruptAgentTask(taskKey: string): boolean {
    const abortController = runningAgentTasks.get(taskKey);
    if (abortController) {
      abortController.abort();
      return true;
    }
    return false;
  },
};
