import { Kysely, sql } from "kysely";

import { DB } from "@/infrastructure/database/schema";

export async function up(db: Kysely<DB>): Promise<void> {
  // Users table - Farcaster-based authentication via Privy
  await db.schema
    .createTable("users")
    .addColumn("id", "integer", (col) => col.primaryKey().autoIncrement())
    .addColumn("privy_did", "text", (col) => col.notNull().unique())
    .addColumn("fid", "integer", (col) => col.notNull().unique())
    .addColumn("username", "text", (col) => col.notNull())
    .addColumn("created_at", "text", (col) =>
      col.notNull().defaultTo(sql`CURRENT_TIMESTAMP`),
    )
    .addColumn("updated_at", "text")
    .execute();

  // Vesting accounts table - One per user, contains wallet and policy
  await db.schema
    .createTable("vesting_accounts")
    .addColumn("id", "integer", (col) => col.primaryKey().autoIncrement())
    .addColumn("user_id", "integer", (col) =>
      col.notNull().unique().references("users.id").onDelete("cascade"),
    )
    .addColumn("wallet_address", "text", (col) => col.notNull())
    .addColumn("privy_wallet_id", "text", (col) => col.notNull())
    .addColumn("policy_json", "text", (col) => col.notNull()) // JSON as TEXT (standard for SQLite)
    .addColumn("wallet_balances", "text", (col) => col.notNull()) // JSON as TEXT (standard for SQLite)
    .addColumn("last_stream_created_at", "text") // Throttle stream creation (prevent spam)
    .addColumn("created_at", "text", (col) =>
      col.notNull().defaultTo(sql`CURRENT_TIMESTAMP`),
    )
    .addColumn("updated_at", "text")
    .execute();

  // Plugin registry table - Global catalog of discovered plugins
  await db.schema
    .createTable("plugin_registry")
    .addColumn("id", "text", (col) => col.primaryKey()) // Content hash (SHA256)
    .addColumn("name", "text", (col) => col.notNull())
    .addColumn("version", "text", (col) => col.notNull())
    .addColumn("provider_id", "text", (col) => col.notNull())
    .addColumn("author", "text", (col) => col.notNull())
    .addColumn("logic_path", "text", (col) => col.notNull())
    .addColumn("agx_manifest", "text", (col) => col.notNull()) // JSON
    .addColumn("source_url", "text", (col) => col.notNull())
    .addColumn("discovered_at", "text", (col) =>
      col.notNull().defaultTo(sql`CURRENT_TIMESTAMP`),
    )
    .addColumn("last_validated_at", "text", (col) => col.notNull())
    .addColumn("created_at", "text", (col) =>
      col.notNull().defaultTo(sql`CURRENT_TIMESTAMP`),
    )
    .addColumn("updated_at", "text")
    .execute();

  // Vesting streams table - Payment streams with yield optimization
  await db.schema
    .createTable("vesting_streams")
    .addColumn("id", "integer", (col) => col.primaryKey().autoIncrement())
    .addColumn("account_id", "integer", (col) =>
      col.notNull().references("vesting_accounts.id").onDelete("cascade"),
    )
    .addColumn("status", "text", (col) =>
      col
        .notNull()
        .check(
          sql`status IN ('DRAFTING', 'ACTIVE', 'PAUSED', 'COMPLETED', 'CANCELLED')`,
        ),
    )
    .addColumn("recipient_address", "text", (col) => col.notNull())
    .addColumn("title", "text", (col) => col.notNull())
    .addColumn("description", "text", (col) => col.notNull())
    .addColumn("total_amount", "real", (col) => col.notNull())
    .addColumn("amount_per_period", "real", (col) => col.notNull())
    .addColumn("period_duration", "integer", (col) => col.notNull())
    .addColumn("asset_id", "text", (col) => col.notNull())
    .addColumn("start_date", "text", (col) => col.notNull())
    .addColumn("end_date", "text", (col) => col.notNull())
    .addColumn("last_distribution_at", "text")
    .addColumn("total_distributed", "real", (col) => col.notNull().defaultTo(0))
    .addColumn("yield_earned", "real", (col) => col.notNull().defaultTo(0))
    .addColumn("created_at", "text", (col) =>
      col.notNull().defaultTo(sql`CURRENT_TIMESTAMP`),
    )
    .addColumn("updated_at", "text")
    .addColumn("completed_at", "text")
    .execute();

  // Audit logs table - Immutable decision trail
  await db.schema
    .createTable("audit_logs")
    .addColumn("id", "integer", (col) => col.primaryKey().autoIncrement())
    .addColumn("account_id", "integer", (col) =>
      col.notNull().references("vesting_accounts.id").onDelete("cascade"),
    )
    .addColumn("stream_id", "integer", (col) =>
      col.references("vesting_streams.id").onDelete("cascade"),
    )
    .addColumn("type", "text", (col) =>
      col
        .notNull()
        .check(
          sql`type IN ('STREAM_CREATED', 'PLUGIN_ATTACHED', 'STREAM_STARTED', 'DISTRIBUTION_MADE', 'YIELD_EARNED', 'AI_OPTIMIZATION', 'USER_FEEDBACK', 'AI_THOUGHT', 'PLUGIN_UI_ATTACHMENT', 'STREAM_PAUSED', 'STREAM_RESUMED', 'STREAM_COMPLETED', 'STREAM_CANCELLED')`,
        ),
    )
    .addColumn("content", "text", (col) => col.notNull()) // JSON
    .addColumn("confidence_score", "real")
    .addColumn("is_internal", "integer", (col) => col.notNull().defaultTo(0)) // boolean
    .addColumn("created_at", "text", (col) =>
      col.notNull().defaultTo(sql`CURRENT_TIMESTAMP`),
    )
    .execute();

  // Notifications table - User actionable items
  await db.schema
    .createTable("notifications")
    .addColumn("id", "integer", (col) => col.primaryKey().autoIncrement())
    .addColumn("account_id", "integer", (col) =>
      col.notNull().references("vesting_accounts.id").onDelete("cascade"),
    )
    .addColumn("type", "text", (col) =>
      col
        .notNull()
        .check(
          sql`type IN ('LOW_FUNDS', 'STREAM_COMPLETED', 'DISTRIBUTION_FAILED', 'PLUGIN_ERROR', 'YIELD_OPPORTUNITY', 'SYSTEM_ALERT')`,
        ),
    )
    .addColumn("message", "text", (col) => col.notNull())
    .addColumn("severity", "text", (col) =>
      col.notNull().check(sql`severity IN ('info', 'warning', 'error', 'critical')`),
    )
    .addColumn("is_read", "integer", (col) => col.notNull().defaultTo(0)) // boolean
    .addColumn("metadata", "text", (col) => col.notNull()) // JSON
    .addColumn("created_at", "text", (col) =>
      col.notNull().defaultTo(sql`CURRENT_TIMESTAMP`),
    )
    .execute();

  // Plugin isolated storage table - Per-account, per-plugin storage for RPC
  await db.schema
    .createTable("plugin_isolated_storage")
    .addColumn("account_id", "integer", (col) => col.notNull())
    .addColumn("provider_id", "text", (col) => col.notNull())
    .addColumn("storage_json", "text", (col) => col.notNull())
    .addColumn("updated_at", "text", (col) =>
      col.notNull().defaultTo(sql`CURRENT_TIMESTAMP`),
    )
    .addPrimaryKeyConstraint("plugin_isolated_storage_pk", ["account_id", "provider_id"])
    .addForeignKeyConstraint(
      "plugin_isolated_storage_account_fk",
      ["account_id"],
      "vesting_accounts",
      ["id"],
      (cb) => cb.onDelete("cascade"),
    )
    .execute();

  // Account wallets table - Multi-chain wallet support with CAIP standards
  await db.schema
    .createTable("account_wallets")
    .addColumn("id", "integer", (col) => col.primaryKey().autoIncrement())
    .addColumn("account_id", "integer", (col) => col.notNull())
    .addColumn("chain_id", "text", (col) => col.notNull()) // CAIP-2 format
    .addColumn("address", "text", (col) => col.notNull()) // CAIP-10 format
    .addColumn("privy_wallet_id", "text", (col) => col.notNull())
    .addColumn("created_at", "text", (col) =>
      col.notNull().defaultTo(sql`CURRENT_TIMESTAMP`)
    )
    .addColumn("updated_at", "text", (col) =>
      col.notNull().defaultTo(sql`CURRENT_TIMESTAMP`)
    )
    .addForeignKeyConstraint(
      "fk_account_wallets_account",
      ["account_id"],
      "vesting_accounts",
      ["id"],
      (cb) => cb.onDelete("cascade")
    )
    .addUniqueConstraint("uq_account_chain", ["account_id", "chain_id"])
    .execute();

  // Transaction queue table - Track swap/bridge transactions
  await db.schema
    .createTable("transaction_queue")
    .addColumn("id", "integer", (col) => col.primaryKey().autoIncrement())
    .addColumn("account_id", "integer", (col) => col.notNull())
    .addColumn("chain_id", "text", (col) => col.notNull()) // CAIP-2
    .addColumn("asset_id", "text") // CAIP-19 (nullable for native transfers)
    .addColumn("transaction_type", "text", (col) => col.notNull()) // 'transfer' | 'swap' | 'bridge' | 'contract_call'
    .addColumn("status", "text", (col) => col.notNull()) // 'queued' | 'pending' | 'confirmed' | 'failed'
    .addColumn("tx_hash", "text")
    .addColumn("nonce", "integer")
    .addColumn("raw_transaction", "text") // JSON
    .addColumn("error", "text")
    .addColumn("created_at", "text", (col) =>
      col.notNull().defaultTo(sql`CURRENT_TIMESTAMP`)
    )
    .addColumn("confirmed_at", "text")
    .addForeignKeyConstraint(
      "fk_transaction_queue_account",
      ["account_id"],
      "vesting_accounts",
      ["id"],
      (cb) => cb.onDelete("cascade")
    )
    .execute();

  // Create indexes for common queries
  await db.schema
    .createIndex("vesting_streams_account_status_idx")
    .on("vesting_streams")
    .columns(["account_id", "status"])
    .execute();

  await db.schema
    .createIndex("audit_logs_account_idx")
    .on("audit_logs")
    .columns(["account_id", "created_at"])
    .execute();

  await db.schema
    .createIndex("notifications_account_unread_idx")
    .on("notifications")
    .columns(["account_id", "is_read"])
    .execute();

  await db.schema
    .createIndex("idx_account_wallets_account")
    .on("account_wallets")
    .column("account_id")
    .execute();

  await db.schema
    .createIndex("idx_account_wallets_chain")
    .on("account_wallets")
    .column("chain_id")
    .execute();

  await db.schema
    .createIndex("idx_transaction_queue_account")
    .on("transaction_queue")
    .column("account_id")
    .execute();

  await db.schema
    .createIndex("idx_transaction_queue_status")
    .on("transaction_queue")
    .column("status")
    .execute();

  await db.schema
    .createIndex("idx_transaction_queue_chain")
    .on("transaction_queue")
    .column("chain_id")
    .execute();
}

export async function down(db: Kysely<any>): Promise<void> {
  // Drop in reverse order to respect foreign keys
  await db.schema.dropTable("transaction_queue").ifExists().execute();
  await db.schema.dropTable("account_wallets").ifExists().execute();
  await db.schema.dropTable("plugin_isolated_storage").ifExists().execute();
  await db.schema.dropTable("notifications").ifExists().execute();
  await db.schema.dropTable("audit_logs").ifExists().execute();
  await db.schema.dropTable("vesting_streams").ifExists().execute();
  await db.schema.dropTable("plugin_registry").ifExists().execute();
  await db.schema.dropTable("vesting_accounts").ifExists().execute();
  await db.schema.dropTable("users").ifExists().execute();
}
