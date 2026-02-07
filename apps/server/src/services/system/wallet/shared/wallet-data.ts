import { db } from "@/infrastructure/database/turso-connection";
import type { AccountWallet } from "@/infrastructure/database/schema";
import { validateAccountId, validateChainId } from "@/services/system/wallet/shared/providers/base-provider";
import { WalletNotFoundError } from "@/services/system/wallet/shared/errors";
import { formatCAIP10 } from "@/services/system/wallet/shared/caip";

/**
 * Wallet Data Access Layer
 * Handles all database operations for account_wallets table
 */

export interface CreateWalletParams {
  accountId: number;
  chainId: string; // CAIP-2
  address: string; // Raw address
  privyWalletId: string;
}

export const walletData = {
  /**
   * Create a new wallet for an account
   */
  async createWallet(params: CreateWalletParams): Promise<AccountWallet> {
    validateAccountId(params.accountId);
    validateChainId(params.chainId);

    const caip10Address = formatCAIP10(params.chainId, params.address);

    const result = await db
      .insertInto("account_wallets")
      .values({
        account_id: params.accountId,
        chain_id: params.chainId,
        address: caip10Address,
        privy_wallet_id: params.privyWalletId,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      })
      .returningAll()
      .executeTakeFirstOrThrow();

    return result as AccountWallet;
  },

  /**
   * Get wallet for account on specific chain
   */
  async getWallet(accountId: number, chainId: string): Promise<AccountWallet | null> {
    validateAccountId(accountId);
    validateChainId(chainId);

    const wallet = await db
      .selectFrom("account_wallets")
      .selectAll()
      .where("account_id", "=", accountId)
      .where("chain_id", "=", chainId)
      .executeTakeFirst();

    return wallet as AccountWallet | null;
  },

  /**
   * Get wallet or throw error
   */
  async getWalletOrThrow(accountId: number, chainId: string): Promise<AccountWallet> {
    const wallet = await this.getWallet(accountId, chainId);
    
    if (!wallet) {
      throw new WalletNotFoundError(accountId, chainId);
    }

    return wallet;
  },

  /**
   * List all wallets for an account
   */
  async listWallets(accountId: number): Promise<AccountWallet[]> {
    validateAccountId(accountId);

    const wallets = await db
      .selectFrom("account_wallets")
      .selectAll()
      .where("account_id", "=", accountId)
      .orderBy("created_at", "desc")
      .execute();

    return wallets as AccountWallet[];
  },

  /**
   * Check if wallet exists
   */
  async walletExists(accountId: number, chainId: string): Promise<boolean> {
    const wallet = await this.getWallet(accountId, chainId);
    return wallet !== null;
  },

  /**
   * Delete wallet
   */
  async deleteWallet(accountId: number, chainId: string): Promise<void> {
    validateAccountId(accountId);
    validateChainId(chainId);

    await db
      .deleteFrom("account_wallets")
      .where("account_id", "=", accountId)
      .where("chain_id", "=", chainId)
      .execute();
  },

  /**
   * Update wallet address (if it changes)
   */
  async updateWalletAddress(
    accountId: number,
    chainId: string,
    newAddress: string
  ): Promise<void> {
    validateAccountId(accountId);
    validateChainId(chainId);

    const caip10Address = formatCAIP10(chainId, newAddress);

    await db
      .updateTable("account_wallets")
      .set({
        address: caip10Address,
        updated_at: new Date().toISOString(),
      })
      .where("account_id", "=", accountId)
      .where("chain_id", "=", chainId)
      .execute();
  },
};
