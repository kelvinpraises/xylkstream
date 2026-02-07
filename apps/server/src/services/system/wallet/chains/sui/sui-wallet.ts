import { PrivyClient } from "@privy-io/server-auth";
import { validateAccountId } from "@/services/system/wallet/shared/providers/base-provider";
import { getAuthConfig } from "@/services/system/wallet/shared/providers/privy-provider";
import { WalletGenerationError } from "@/services/system/wallet/shared/errors";

export async function generateSuiWallet(
  accountId: number,
  chainId: string,
  privyClient: PrivyClient
): Promise<{ address: string; privyWalletId: string }> {
  validateAccountId(accountId);

  try {
    const { authKeyId } = getAuthConfig();

    const wallet = await privyClient.walletApi.createWallet({
      chainType: 'sui' as any,
      owner: {
        publicKey: authKeyId,
      },
    });

    return {
      address: wallet.address,
      privyWalletId: wallet.id,
    };
  } catch (error) {
    throw new WalletGenerationError(
      `Failed to generate Sui wallet for account ${accountId}: ${error}`,
      accountId,
      chainId
    );
  }
}

export async function getSuiWalletAddress(
  accountId: number,
  privyWalletId: string,
  privyClient: PrivyClient
): Promise<string> {
  validateAccountId(accountId);

  try {
    const wallet = await privyClient.walletApi.getWallet({ id: privyWalletId });
    return wallet.address;
  } catch (error) {
    throw new Error(`Failed to get Sui wallet address: ${error}`);
  }
}

export async function getSuiWalletClient(
  accountId: number,
  privyWalletId: string,
  privyClient: PrivyClient
) {
  validateAccountId(accountId);

  const wallet = await privyClient.walletApi.getWallet({ id: privyWalletId });

  return {
    address: wallet.address,
    signTransaction: async (transaction: any) => {
      // Placeholder for Privy Sui signing
      // Will be implemented when Privy exposes Sui signing methods
      return {
        signature: 'signed-transaction',
        transaction,
      };
    },
    signAndExecuteTransaction: async (transaction: any) => {
      return {
        digest: 'transaction-digest',
        effects: {},
      };
    },
  };
}
