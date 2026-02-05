import type { AuditLog } from "@/infrastructure/database/schema";
import { auditLogEmitter } from "@/infrastructure/events/audit-log-emitter";
import { streamService } from "@/services/vesting/stream-service";
import { authService } from "@/services/system/auth-service";
import { Request, Response } from "express";

const streamController = {
  async streamVestingLogs(req: Request, res: Response) {
    const streamId = parseInt(req.params.streamId as string, 10);

    if (isNaN(streamId)) {
      res.status(400).json({ error: "Invalid streamId" });
      return;
    }

    const token = req.query.token as string;
    if (!token) {
      res.status(401).json({ error: "Not authorized, no token" });
      return;
    }

    try {
      const { accountId } = await authService.authenticateUser(token);

      const hasAccess = await streamService.verifyStreamOwnership(
        streamId,
        accountId,
      );

      if (!hasAccess) {
        res.status(404).json({ error: "Stream not found or access denied" });
        return;
      }

      res.setHeader("Content-Type", "text/event-stream");
      res.setHeader("Cache-Control", "no-cache");
      res.setHeader("Connection", "keep-alive");
      res.setHeader("X-Accel-Buffering", "no");
      res.write(`data: ${JSON.stringify({ type: "connected", streamId })}\n\n`);

      // SSE is for real-time updates only
      // Initial logs should be fetched via RPC getAuditLogs
      const unsubscribe = auditLogEmitter.onStreamAuditLog(
        streamId,
        (auditLog: AuditLog) => {
          // Skip internal logs (is_internal = 1 in SQLite)
          if (auditLog.is_internal === 1 || auditLog.is_internal === true) {
            return;
          }

          const content =
            typeof auditLog.content === "string"
              ? JSON.parse(auditLog.content)
              : auditLog.content;

          const sseData = {
            type: "audit-log",
            data: {
              id: auditLog.id,
              type: auditLog.type,
              content,
              confidenceScore: auditLog.confidence_score,
              isInternal: auditLog.is_internal,
              createdAt: auditLog.created_at,
            },
          };

          res.write(`data: ${JSON.stringify(sseData)}\n\n`);
        },
      );

      const heartbeatInterval = setInterval(() => {
        res.write(`: heartbeat\n\n`);
      }, 30000);

      req.on("close", () => {
        clearInterval(heartbeatInterval);
        unsubscribe();
        res.end();
      });
    } catch (error) {
      console.error("[SSE] Authentication or authorization failed:", error);
      res.status(401).json({ error: "Authentication failed" });
    }
  },
};

export default streamController;
