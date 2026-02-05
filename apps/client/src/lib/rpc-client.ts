import { newHttpBatchRpcSession, RpcStub } from "capnweb";
import { API_URL } from "@/config";

export interface AuthTarget {
  authenticate(params: { accessToken: string }): Promise<AuthenticatedSession>;
}

export interface AuthenticatedSession {
  // Account
  getAccount(): Promise<{
    id: number;
    walletAddress: string;
    policy: AccountPolicy;
    walletBalances: Record<string, string>;
  }>;
  updatePolicy(params: { policy: AccountPolicy }): Promise<{ success: boolean }>;
  getWalletBalances(): Promise<Record<string, string>>;

  // Vesting Streams
  listStreams(params?: {
    status?: VestingStreamStatus;
    limit?: number;
    offset?: number;
  }): Promise<VestingStreamItem[]>;
  getStreamDetails(params: { streamId: number }): Promise<VestingStreamDetails>;
  cancelStream(params: { streamId: number }): Promise<{ success: boolean }>;
  createStream(params: {
    recipientAddress: string;
    amount: number;
    asset: string;
    startDate: string;
    endDate: string;
    cliffDate?: string;
  }): Promise<{ streamId: number }>;
  claimStream(params: { streamId: number }): Promise<{ success: boolean }>;

  // Audit
  getAuditLogs(params: {
    streamId: number;
    includeInternal?: boolean;
  }): Promise<AuditLogItem[]>;

  // Notification
  getNotifications(params?: {
    unreadOnly?: boolean;
    limit?: number;
  }): Promise<NotificationItem[]>;
  markNotificationRead(params: {
    notificationId: number;
  }): Promise<{ success: boolean }>;

  // Plugin
  listAvailablePlugins(params?: {
    limit?: number;
    offset?: number;
  }): Promise<PluginItem[]>;
  getPluginDetails(params: { pluginId: string }): Promise<PluginDetails>;
  togglePlugin(params: {
    pluginId: string;
    enabled: boolean;
  }): Promise<{ success: boolean }>;

  // Account
  deleteAccount(): Promise<{ success: boolean }>;
}

// Types
export type VestingStreamStatus =
  | "PENDING"
  | "ACTIVE"
  | "PAUSED"
  | "COMPLETED"
  | "CANCELLED";

export interface AccountPolicy {
  yield_optimization: {
    enabled: boolean;
    risk_tolerance: "low" | "medium" | "high";
    preferred_chains: string[];
    min_yield_threshold: number;
  };
  plugins: string[];
  auto_compound: boolean;
  notification_preferences: {
    low_funds: boolean;
    stream_completed: boolean;
    yield_updates: boolean;
    plugin_errors: boolean;
  };
}

export interface VestingStreamItem {
  id: number;
  status: VestingStreamStatus;
  recipientAddress: string;
  amount: number;
  asset: string;
  startDate: string;
  endDate: string;
  cliffDate: string | null;
  vestedAmount: number;
  claimedAmount: number;
  yieldEarned: number;
  createdAt: string;
}

export interface VestingStreamDetails {
  id: number;
  accountId: number;
  status: VestingStreamStatus;
  recipientAddress: string;
  amount: number;
  asset: string;
  startDate: string;
  endDate: string;
  cliffDate: string | null;
  vestedAmount: number;
  claimedAmount: number;
  yieldEarned: number;
  yieldStrategy: string | null;
  createdAt: string;
  lastClaimAt: string | null;
  completedAt: string | null;
}

export type AuditLogType =
  | "STREAM_CREATED"
  | "PLUGIN_ATTACHED"
  | "STREAM_STARTED"
  | "STREAM_CLAIMED"
  | "YIELD_EARNED"
  | "STREAM_COMPLETED"
  | "STREAM_CANCELLED"
  | "PLUGIN_ERROR"
  | "WALLET_ERROR";

export interface AuditLogItem {
  id: number;
  type: AuditLogType;
  content: Record<string, any>;
  confidenceScore: number | null;
  isInternal: boolean;
  createdAt: string;
}

export type NotificationType =
  | "LOW_FUNDS"
  | "STREAM_COMPLETED"
  | "YIELD_UPDATE"
  | "PLUGIN_ERROR"
  | "SYSTEM_ALERT";

export type NotificationSeverity = "info" | "warning" | "error" | "critical";

export interface NotificationItem {
  id: number;
  type: NotificationType;
  message: string;
  severity: NotificationSeverity;
  isRead: boolean;
  metadata: Record<string, any>;
  createdAt: string;
}

export interface PluginItem {
  id: string;
  name: string;
  version: string;
  providerId: string;
  author: string;
  description: string;
  features: string[];
  sourceUrl: string;
}

export interface PluginDetails {
  id: string;
  name: string;
  version: string;
  providerId: string;
  author: string;
  logicPath: string;
  agxManifest: {
    description: string;
    storage_schema?: Record<string, any>;
    api_endpoints?: Record<string, string>;
    features?: string[];
    permissions?: string[];
  };
  sourceUrl: string;
  discoveredAt: string;
  lastValidatedAt: string;
}

/**
 * Authenticate with Privy access token and get RPC session
 */
export async function authenticateRpcSession(
  accessToken: string
): Promise<RpcStub<AuthenticatedSession>> {
  const batch = newHttpBatchRpcSession<AuthTarget>(`${API_URL}/rpc/external/auth`);
  const session = await batch.authenticate({ accessToken });
  return session;
}
