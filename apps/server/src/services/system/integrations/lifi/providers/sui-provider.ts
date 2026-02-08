import { Sui } from '@lifi/sdk';
import { walletService } from '@/services/system/wallet/wallet-service';

/**
 * Create LI.FI Sui provider using wallet service
 */
export function createSuiProvider(accountId: number, chainId: string) {
  return Sui({
    getWalletClient: async () => {
      return {
        getAddress: async () => {
          const wallet = await walletService.getWallet(accountId, chainId);
          if (!wallet) {
            throw new Error(`No wallet found for account ${accountId} on chain ${chainId}`);
          }
          return wallet.address;
        },
        signTransaction: async (transaction: any) => {
          // Use wallet service to sign
          const result = await walletService.signTransaction(accountId, chainId, transaction);
          return {
            signature: result.signature,
            transaction,
          };
        },
        signAndExecuteTransaction: async (transaction: any) => {
          // Use wallet service to sign and execute
          const result = await walletService.signTransaction(accountId, chainId, transaction);
          return {
            digest: result.signature, // Use signature as digest for now
            effects: {},
          };
        },
      } as any;
    },
  } as any);
}
