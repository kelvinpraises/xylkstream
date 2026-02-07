import {
  IEVMTransactionRequest,
  IEVMTransferRequest,
  ISignatureResult,
} from "@/types/account";

import type { AccountWallet } from "@/infrastructure/database/schema";
import {
  createEVMTransferRequest,
  generateEVMWallet,
  signEVMTransaction,
} from "@/services/system/wallet/chains/evm/evm-wallet";
import { generateSuiWallet } from "@/services/system/wallet/chains/sui/sui-wallet";
import { isEVMChain, isSuiChain, parseCAIP10 } from "@/services/system/wallet/shared/caip";
import { validateAccountId, validateChainId } from "@/services/system/wallet/shared/providers/base-provider";
import { createPrivyClient } from "@/services/system/wallet/shared/providers/privy-provider";
import { walletData } from "@/services/system/wallet/shared/wallet-data";

const client = createPrivyClient();

/**
 * Wallet Service - CAIP-Standardized Multi-Chain Wallet Management
 *
 * Uses CAIP standards:
 * - CAIP-2: Chain IDs (e.g., "eip155:8453", "sui:mainnet")
 * - CAIP-10: Account IDs (e.g., "eip155:8453:0x742d...")
 * - CAIP-19: Asset IDs (e.g., "eip155:8453/erc20:0x833...")
 */
export const walletService = {
  /**
   * Create a new wallet for an account on a specific chain
   */
  async createWallet(accountId: number, chainId: string): Promise<AccountWallet> {
    validateAccountId(accountId);
    validateChainId(chainId);

    // Check if wallet already exists
    const existing = await walletData.getWallet(accountId, chainId);
    if (existing) {
      return existing;
    }

    // Generate wallet based on chain type
    let result: { address: string; privyWalletId: string };

    if (isEVMChain(chainId)) {
      result = await generateEVMWallet(accountId, chainId, client);
    } else if (isSuiChain(chainId)) {
      result = await generateSuiWallet(accountId, chainId, client);
    } else {
      throw new Error(`Unsupported chain: ${chainId}`);
    }

    // Store in database
    return await walletData.createWallet({
      accountId,
      chainId,
      address: result.address,
      privyWalletId: result.privyWalletId,
    });
  },

  /**
   * Get wallet for account on specific chain
   */
  async getWallet(accountId: number, chainId: string): Promise<AccountWallet | null> {
    validateAccountId(accountId);
    validateChainId(chainId);

    return await walletData.getWallet(accountId, chainId);
  },

  /**
   * Get wallet address (CAIP-10 format)
   */
  async getAddress(accountId: number, chainId: string): Promise<string> {
    validateAccountId(accountId);
    validateChainId(chainId);

    const wallet = await walletData.getWalletOrThrow(accountId, chainId);
    return wallet.address; // Already in CAIP-10 format
  },

  /**
   * Get raw address (without CAIP-10 prefix)
   */
  async getRawAddress(accountId: number, chainId: string): Promise<string> {
    const caip10Address = await this.getAddress(accountId, chainId);
    const { address } = parseCAIP10(caip10Address);
    return address;
  },

  /**
   * List all wallets for an account
   */
  async listWallets(accountId: number): Promise<AccountWallet[]> {
    validateAccountId(accountId);
    return await walletData.listWallets(accountId);
  },

  /**
   * Sign a transaction
   */
  async signTransaction(
    accountId: number,
    chainId: string,
    transaction: IEVMTransactionRequest,
  ): Promise<ISignatureResult> {
    validateAccountId(accountId);
    validateChainId(chainId);

    const wallet = await walletData.getWalletOrThrow(accountId, chainId);

    if (isEVMChain(chainId)) {
      return await signEVMTransaction(
        accountId,
        chainId,
        transaction,
        wallet.privy_wallet_id,
        client,
      );
    } else if (isSuiChain(chainId)) {
      throw new Error("Sui transaction signing not yet implemented");
    } else {
      throw new Error(`Unsupported chain: ${chainId}`);
    }
  },

  /**
   * Transfer tokens or native currency
   */
  async transfer(
    accountId: number,
    chainId: string,
    transferRequest: IEVMTransferRequest,
  ): Promise<ISignatureResult> {
    validateAccountId(accountId);
    validateChainId(chainId);

    const wallet = await walletData.getWalletOrThrow(accountId, chainId);

    if (isEVMChain(chainId)) {
      const rawTransaction = createEVMTransferRequest(chainId, transferRequest);
      return await signEVMTransaction(
        accountId,
        chainId,
        rawTransaction,
        wallet.privy_wallet_id,
        client,
      );
    } else if (isSuiChain(chainId)) {
      throw new Error("Sui transfers not yet implemented");
    } else {
      throw new Error(`Unsupported chain: ${chainId}`);
    }
  },

  /**
   * Ensure wallet exists, create if not
   */
  async ensureWallet(accountId: number, chainId: string): Promise<AccountWallet> {
    validateAccountId(accountId);
    validateChainId(chainId);

    const existing = await walletData.getWallet(accountId, chainId);
    if (existing) {
      return existing;
    }

    return await this.createWallet(accountId, chainId);
  },
};
