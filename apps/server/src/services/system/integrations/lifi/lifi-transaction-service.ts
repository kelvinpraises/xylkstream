import { db } from '@/infrastructure/database/turso-connection';
import type { Route } from '@/types/lifi';

export type TransactionType = 'transfer' | 'swap' | 'bridge' | 'contract_call';
export type TransactionStatus = 'queued' | 'pending' | 'confirmed' | 'failed';

export interface TransactionRecord {
  id: number;
  accountId: number;
  chainId: string;
  assetId: string | null;
  transactionType: TransactionType;
  status: TransactionStatus;
  txHash: string | null;
  nonce: number | null;
  rawTransaction: string | null;
  error: string | null;
  createdAt: Date;
  confirmedAt: Date | null;
}

class LiFiTransactionService {
  /**
   * Log a new transaction to the queue
   */
  async logTransaction(params: {
    accountId: number;
    chainId: string;
    assetId?: string;
    transactionType: TransactionType;
    route: Route;
  }): Promise<number> {
    const result = await db
      .insertInto('transaction_queue')
      .values({
        account_id: params.accountId,
        chain_id: params.chainId,
        asset_id: params.assetId || null,
        transaction_type: params.transactionType,
        status: 'queued',
        tx_hash: null,
        nonce: null,
        raw_transaction: JSON.stringify(params.route),
        error: null,
        created_at: new Date().toISOString(),
        confirmed_at: null,
      })
      .returning('id')
      .executeTakeFirstOrThrow();

    return result.id;
  }

  /**
   * Update transaction status
   */
  async updateStatus(
    transactionId: number,
    status: TransactionStatus,
    txHash?: string,
    error?: string
  ): Promise<void> {
    await db
      .updateTable('transaction_queue')
      .set({
        status,
        tx_hash: txHash || null,
        error: error || null,
        confirmed_at: status === 'confirmed' ? new Date() : null,
      })
      .where('id', '=', transactionId)
      .execute();
  }

  /**
   * Get transaction by ID
   */
  async getTransaction(transactionId: number): Promise<TransactionRecord | null> {
    const result = await db
      .selectFrom('transaction_queue')
      .selectAll()
      .where('id', '=', transactionId)
      .executeTakeFirst();

    if (!result) return null;

    return {
      id: result.id,
      accountId: result.account_id,
      chainId: result.chain_id,
      assetId: result.asset_id,
      transactionType: result.transaction_type as TransactionType,
      status: result.status as TransactionStatus,
      txHash: result.tx_hash,
      nonce: result.nonce,
      rawTransaction: result.raw_transaction,
      error: result.error,
      createdAt: result.created_at,
      confirmedAt: result.confirmed_at,
    };
  }

  /**
   * Get transaction history for an account
   */
  async getTransactionHistory(
    accountId: number,
    limit: number = 50
  ): Promise<TransactionRecord[]> {
    const results = await db
      .selectFrom('transaction_queue')
      .selectAll()
      .where('account_id', '=', accountId)
      .orderBy('created_at', 'desc')
      .limit(limit)
      .execute();

    return results.map(result => ({
      id: result.id,
      accountId: result.account_id,
      chainId: result.chain_id,
      assetId: result.asset_id,
      transactionType: result.transaction_type as TransactionType,
      status: result.status as TransactionStatus,
      txHash: result.tx_hash,
      nonce: result.nonce,
      rawTransaction: result.raw_transaction,
      error: result.error,
      createdAt: result.created_at,
      confirmedAt: result.confirmed_at,
    }));
  }

  /**
   * Get pending transactions for an account
   */
  async getPendingTransactions(accountId: number): Promise<TransactionRecord[]> {
    const results = await db
      .selectFrom('transaction_queue')
      .selectAll()
      .where('account_id', '=', accountId)
      .where('status', '=', 'pending')
      .orderBy('created_at', 'desc')
      .execute();

    return results.map(result => ({
      id: result.id,
      accountId: result.account_id,
      chainId: result.chain_id,
      assetId: result.asset_id,
      transactionType: result.transaction_type as TransactionType,
      status: result.status as TransactionStatus,
      txHash: result.tx_hash,
      nonce: result.nonce,
      rawTransaction: result.raw_transaction,
      error: result.error,
      createdAt: result.created_at,
      confirmedAt: result.confirmed_at,
    }));
  }

  /**
   * Get failed transactions for an account
   */
  async getFailedTransactions(accountId: number): Promise<TransactionRecord[]> {
    const results = await db
      .selectFrom('transaction_queue')
      .selectAll()
      .where('account_id', '=', accountId)
      .where('status', '=', 'failed')
      .orderBy('created_at', 'desc')
      .execute();

    return results.map(result => ({
      id: result.id,
      accountId: result.account_id,
      chainId: result.chain_id,
      assetId: result.asset_id,
      transactionType: result.transaction_type as TransactionType,
      status: result.status as TransactionStatus,
      txHash: result.tx_hash,
      nonce: result.nonce,
      rawTransaction: result.raw_transaction,
      error: result.error,
      createdAt: result.created_at,
      confirmedAt: result.confirmed_at,
    }));
  }
}

export const lifiTransactionService = new LiFiTransactionService();
