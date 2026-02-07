import { EVM } from '@lifi/sdk';
import { createWalletClient, http, type WalletClient } from 'viem';
import { base, mainnet, arbitrum, optimism } from 'viem/chains';
import { walletService } from '@/services/system/wallet/wallet-service';
import { parseCAIP2 } from '@/services/system/wallet/shared/utils/caip';

/**
 * Chain ID to viem chain mapping
 */
const CHAIN_MAP: Record<number, any> = {
  1: mainnet,
  8453: base,
  42161: arbitrum,
  10: optimism,
};

/**
 * Create LI.FI EVM provider using wallet service
 */
export function createEVMProvider(accountId: number, chainId: string) {
  return EVM({
    getWalletClient: async (): Promise<WalletClient> => {
      // Get wallet from wallet service
      const wallet = await walletService.getWallet(accountId, chainId);
      
      if (!wallet) {
        throw new Error(`No wallet found for account ${accountId} on chain ${chainId}`);
      }
      
      // Parse chain ID from CAIP-2
      const { reference } = parseCAIP2(chainId);
      const numericChainId = parseInt(reference, 10);
      
      // Get viem chain config
      const chain = CHAIN_MAP[numericChainId] || base;
      
      // Create wallet client
      const walletClient = createWalletClient({
        account: wallet.address as `0x${string}`,
        chain,
        transport: http(),
      });
      
      return walletClient;
    },
  });
}
