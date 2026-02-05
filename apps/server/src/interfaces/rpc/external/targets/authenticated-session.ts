import { RpcTarget } from "capnweb";

import {
  AgxManifest,
  AuditLogType,
  VestingStreamStatus,
  NotificationSeverity,
  NotificationType,
  AccountPolicy,
} from "@/infrastructure/database/schema";
import { neuralAgent } from "@/interfaces/neural";
import { auditLogService } from "@/services/vesting/audit-log-service";
import { streamService } from "@/services/vesting/stream-service";
import { accountService } from "@/services/vesting/account-service";
import { notificationService } from "@/services/system/notification-service";
import { pluginRegistryService } from "@/services/system/plugin/plugin-registry-service";

/**
 * AuthenticatedSession RPC Target
 * Capability-based security - possession of this object proves authentication
 * All methods are scoped to the authenticated user
 */
export class AuthenticatedSession extends RpcTarget {
  constructor(
    private userId: number,
    private accountId: number,
  ) {
    super();
  }

  // ===== Account Methods =====

  async getAccount(): Promise<{
    id: number;
    walletAddress: string;
    policy: AccountPolicy;
    walletBalances: Record<string, string>;
  }> {
    const account = await accountService.getAccount(this.accountId);

    const policy =
      typeof account.policy_json === "string"
        ? JSON.parse(account.policy_json)
        : account.policy_json;

    const walletBalances =
      typeof account.wallet_balances === "string"
        ? JSON.parse(account.wallet_balances)
        : account.wallet_balances;

    return {
      id: account.id,
      walletAddress: account.wallet_address,
      policy: policy as AccountPolicy,
      walletBalances: walletBalances as Record<string, string>,
    };
  }

  async updatePolicy(params: { policy: AccountPolicy }): Promise<{ success: boolean }> {
    await accountService.updatePolicy(this.accountId, params.policy);
    return { success: true };
  }

  async getWalletBalances(): Promise<Record<string, string>> {
    const account = await accountService.getAccount(this.accountId);
    return account.wallet_balances as Record<string, string>;
  }

  // ===== Vesting Stream Methods =====

  async listStreams(params?: {
    status?: VestingStreamStatus;
    limit?: number;
    offset?: number;
  }): Promise<
    Array<{
      id: number;
      status: VestingStreamStatus;
      recipientAddress: string;
      title: string;
      description: string;
      totalAmount: number;
      amountPerPeriod: number;
      periodDuration: number;
      assetId: string;
      startDate: string;
      endDate: string;
      totalDistributed: number;
      yieldEarned: number;
      createdAt: string;
    }>
  > {
    const streams = await streamService.listStreamsForAccount(
      this.accountId,
      params,
    );

    return streams.map((s) => ({
      id: s.id,
      status: s.status,
      recipientAddress: s.recipient_address,
      title: s.title,
      description: s.description,
      totalAmount: s.total_amount,
      amountPerPeriod: s.amount_per_period,
      periodDuration: s.period_duration,
      assetId: s.asset_id,
      startDate: s.start_date instanceof Date ? s.start_date.toISOString() : s.start_date,
      endDate: s.end_date instanceof Date ? s.end_date.toISOString() : s.end_date,
      totalDistributed: s.total_distributed,
      yieldEarned: s.yield_earned,
      createdAt: s.created_at instanceof Date ? s.created_at.toISOString() : s.created_at,
    }));
  }

  async getStreamDetails(params: { streamId: number }): Promise<{
    id: number;
    accountId: number;
    status: VestingStreamStatus;
    recipientAddress: string;
    title: string;
    description: string;
    totalAmount: number;
    amountPerPeriod: number;
    periodDuration: number;
    assetId: string;
    startDate: string;
    endDate: string;
    lastDistributionAt: string | null;
    totalDistributed: number;
    yieldEarned: number;
    createdAt: string;
    completedAt: string | null;
  }> {
    console.log("[RPC] getStreamDetails called with:", params);
    
    const stream = await streamService.getStream(params.streamId);
    console.log("[RPC] Found stream:", stream);

    // Verify ownership
    if (stream.account_id !== this.accountId) {
      console.error(
        `[RPC] Ownership mismatch: stream.account_id=${stream.account_id}, this.accountId=${this.accountId}`
      );
      throw new Error("Unauthorized: Stream does not belong to this account");
    }

    return {
      id: stream.id,
      accountId: stream.account_id,
      status: stream.status,
      recipientAddress: stream.recipient_address,
      title: stream.title,
      description: stream.description,
      totalAmount: stream.total_amount,
      amountPerPeriod: stream.amount_per_period,
      periodDuration: stream.period_duration,
      assetId: stream.asset_id,
      startDate: stream.start_date instanceof Date ? stream.start_date.toISOString() : stream.start_date,
      endDate: stream.end_date instanceof Date ? stream.end_date.toISOString() : stream.end_date,
      lastDistributionAt: stream.last_distribution_at 
        ? (stream.last_distribution_at instanceof Date ? stream.last_distribution_at.toISOString() : stream.last_distribution_at)
        : null,
      totalDistributed: stream.total_distributed,
      yieldEarned: stream.yield_earned,
      createdAt: stream.created_at instanceof Date ? stream.created_at.toISOString() : stream.created_at,
      completedAt: stream.completed_at
        ? (stream.completed_at instanceof Date ? stream.completed_at.toISOString() : stream.completed_at)
        : null,
    };
  }

  async cancelStream(params: { streamId: number }): Promise<{ success: boolean }> {
    await streamService.transitionStatus(params.streamId, "CANCELLED");
    return { success: true };
  }

  async pauseStream(params: { streamId: number }): Promise<{ success: boolean }> {
    await streamService.transitionStatus(params.streamId, "PAUSED");
    return { success: true };
  }

  async resumeStream(params: { streamId: number }): Promise<{ success: boolean }> {
    await streamService.transitionStatus(params.streamId, "ACTIVE");
    return { success: true };
  }

  async requestStreamCreation(params: {
    prompt: string;
  }): Promise<{ streamId: number }> {
    console.log("[RPC] requestStreamCreation called for account:", this.accountId);
    console.log("[RPC] Prompt:", params.prompt);
    
    // Create stream with user prompt
    const streamId = await neuralAgent.createStream(this.accountId, params.prompt);

    console.log("[RPC] Stream created with ID:", streamId);

    if (streamId <= 0) {
      throw new Error(
        "Failed to create stream - check budget limits or policy configuration",
      );
    }

    return { streamId };
  }

  // ===== Audit Methods =====

  async getAuditLogs(params: {
    streamId: number;
    includeInternal?: boolean;
  }): Promise<
    Array<{
      id: number;
      type: AuditLogType;
      content: Record<string, any>;
      confidenceScore: number | null;
      isInternal: boolean;
      createdAt: string;
    }>
  > {
    console.log(`[RPC getAuditLogs] streamId: ${params.streamId}, includeInternal: ${params.includeInternal}`);
    
    const logs = await auditLogService.getAuditLogsForStream(
      params.streamId,
      params.includeInternal ?? false,
    );

    console.log(`[RPC getAuditLogs] Retrieved ${logs.length} logs from service`);

    return logs.map((log) => {
      const content =
        typeof log.content === "string" ? JSON.parse(log.content) : log.content;

      const createdAt = typeof log.created_at === 'string' 
        ? log.created_at 
        : log.created_at.toISOString();

      return {
        id: log.id,
        type: log.type,
        content: content as Record<string, any>,
        confidenceScore: log.confidence_score,
        isInternal: log.is_internal,
        createdAt,
      };
    });
  }

  async addUserFeedback(params: {
    streamId: number;
    feedback: string;
  }): Promise<{ success: boolean }> {
    await neuralAgent.handleUserFeedback(
      params.streamId,
      this.accountId,
      params.feedback,
    );

    return { success: true };
  }

  // ===== Notification Methods =====

  async getNotifications(params?: { unreadOnly?: boolean; limit?: number }): Promise<
    Array<{
      id: number;
      type: NotificationType;
      message: string;
      severity: NotificationSeverity;
      isRead: boolean;
      metadata: Record<string, any>;
      createdAt: string;
    }>
  > {
    const notifications = await notificationService.getNotifications(
      this.accountId,
      params,
    );

    return notifications.map((n) => ({
      id: n.id,
      type: n.type,
      message: n.message,
      severity: n.severity,
      isRead: n.is_read,
      metadata: n.metadata as Record<string, any>,
      createdAt: n.created_at.toISOString(),
    }));
  }

  async markNotificationRead(params: {
    notificationId: number;
  }): Promise<{ success: boolean }> {
    await notificationService.markAsRead(params.notificationId, this.accountId);
    return { success: true };
  }

  // ===== Plugin Methods =====

  async listAvailablePlugins(params?: { limit?: number; offset?: number }): Promise<
    Array<{
      id: string;
      name: string;
      version: string;
      providerId: string;
      author: string;
      description: string;
      features: string[];
      sourceUrl: string;
    }>
  > {
    const plugins = await pluginRegistryService.listPlugins(params);

    return plugins.map((p) => {
      const manifest = p.agx_manifest as AgxManifest;
      return {
        id: p.id,
        name: p.name,
        version: p.version,
        providerId: p.provider_id,
        author: p.author,
        description: manifest.description,
        features: manifest.features || [],
        sourceUrl: p.source_url,
      };
    });
  }

  async getPluginDetails(params: { pluginId: string }): Promise<{
    id: string;
    name: string;
    version: string;
    providerId: string;
    author: string;
    logicPath: string;
    agxManifest: AgxManifest;
    sourceUrl: string;
    discoveredAt: string;
    lastValidatedAt: string;
  }> {
    const plugin = await pluginRegistryService.getPluginById(params.pluginId);

    return {
      id: plugin.id,
      name: plugin.name,
      version: plugin.version,
      providerId: plugin.provider_id,
      author: plugin.author,
      logicPath: plugin.logic_path,
      agxManifest: plugin.agx_manifest as AgxManifest,
      sourceUrl: plugin.source_url,
      discoveredAt: plugin.discovered_at.toISOString(),
      lastValidatedAt: plugin.last_validated_at.toISOString(),
    };
  }

  // ===== Account Deletion =====

  async deleteAccount(): Promise<{ success: boolean }> {
    await accountService.deleteAccount(this.accountId, this.userId);
    return { success: true };
  }
}
