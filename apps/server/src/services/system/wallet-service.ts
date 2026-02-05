import { PrivyClient } from "@privy-io/server-auth";
import {
  defineChain,
  encodeFunctionData,
  erc20Abi,
  parseUnits,
  type Address,
  type Chain,
} from "viem";
import { arbitrum, base, mainnet, optimism } from "viem/chains";

import {
  IEVMTransactionRequest,
  IEVMTransferRequest,
  IAccountData,
  ISignatureResult,
  IWalletGenerationResult,
} from "@/types/account";

const degenChain = defineChain({
  id: 666666666,
  name: "Degen Chain",
  nativeCurrency: {
    decimals: 18,
    name: "DEGEN",
    symbol: "DEGEN",
  },
  rpcUrls: {
    default: {
      http: ["https://rpc.degen.tips"],
    },
  },
  blockExplorers: {
    default: {
      name: "Degen Explorer",
      url: "https://explorer.degen.tips",
    },
  },
});

const CHAIN_CONFIGS: Record<string, Chain> = {
  ethereum: mainnet,
  base: base,
  arbitrum: arbitrum,
  optimism: optimism,
  degen: degenChain,
};

export function getChain(chainName: string): Chain {
  const chain = CHAIN_CONFIGS[chainName.toLowerCase()];
  if (!chain) {
    throw new Error(`Unsupported chain: ${chainName}`);
  }
  return chain;
}

function createPrivyClient(): PrivyClient {
  if (!process.env.PRIVY_APP_ID || !process.env.PRIVY_SECRET) {
    throw new Error("Privy credentials not found in environment variables");
  }

  return new PrivyClient(process.env.PRIVY_APP_ID, process.env.PRIVY_SECRET);
}

function getAuthConfig() {
  if (!process.env.XYLKSTREAM_WALLET_AUTH || !process.env.XYLKSTREAM_WALLET_AUTH_ID) {
    throw new Error("Privy auth config not found in environment variables");
  }

  return {
    authKeyId: process.env.XYLKSTREAM_WALLET_AUTH,
    keyQuorumId: process.env.XYLKSTREAM_WALLET_AUTH_ID,
  };
}

const client = createPrivyClient();

export const walletService = {
  async generateWallet(accountData: IAccountData): Promise<IWalletGenerationResult> {
    if (!accountData.id) {
      throw new Error("Account ID is required");
    }

    try {
      const { authKeyId } = getAuthConfig();

      const wallet = await client.walletApi.createWallet({
        chainType: "ethereum",
        owner: {
          publicKey: authKeyId,
        },
      });

      return {
        address: wallet.address,
        chain: accountData.chain,
        publicKey: wallet.id,
      };
    } catch (error) {
      throw new Error(
        `Failed to generate ${accountData.chain} wallet for account ${accountData.id}: ${error}`,
      );
    }
  },

  async getWalletAddress(accountData: IAccountData): Promise<string> {
    if (!accountData.id) {
      throw new Error("Account ID is required");
    }

    if (!accountData.privy_wallet_id) {
      throw new Error(`Privy wallet ID required to get ${accountData.chain} address`);
    }

    const wallet = await client.walletApi.getWallet({
      id: accountData.privy_wallet_id,
    });
    return wallet.address;
  },

  async signTransaction(
    accountData: IAccountData,
    transaction: IEVMTransactionRequest,
  ): Promise<ISignatureResult> {
    if (!accountData.id) {
      throw new Error("Account ID is required");
    }

    if (!accountData.privy_wallet_id) {
      throw new Error(`Privy wallet ID required for ${accountData.chain} transactions`);
    }

    try {
      const result = await client.walletApi.ethereum.signTransaction({
        walletId: accountData.privy_wallet_id,
        transaction: {
          to: transaction.to as `0x${string}`,
          value: (transaction.value || "0x0") as `0x${string}`,
          chainId: transaction.chainId,
          data: transaction.data as `0x${string}` | undefined,
          gasLimit: transaction.gasLimit as `0x${string}` | undefined,
          gasPrice: transaction.gasPrice as `0x${string}` | undefined,
          maxFeePerGas: transaction.maxFeePerGas as `0x${string}` | undefined,
          maxPriorityFeePerGas: transaction.maxPriorityFeePerGas as
            | `0x${string}`
            | undefined,
          nonce: transaction.nonce ? Number(transaction.nonce) : undefined,
        },
      });

      return {
        signature: result.signedTransaction,
        encoding: "rlp",
      };
    } catch (error) {
      throw new Error(
        `Failed to sign transaction for account ${accountData.id}: ${error}`,
      );
    }
  },

  async transfer(
    accountData: IAccountData,
    transferRequest: IEVMTransferRequest,
  ): Promise<ISignatureResult> {
    if (!accountData.id) {
      throw new Error("Account ID is required");
    }

    if (!accountData.privy_wallet_id) {
      throw new Error(`Privy wallet ID required for ${accountData.chain} transfer`);
    }

    const chain = getChain(accountData.chain);
    const rawTransaction = createTransferRequest(accountData.chain, transferRequest);

    return this.signTransaction(accountData, rawTransaction);
  },
};

// Utility function to create a unified transfer request
export function createTransferRequest(
  chainName: string,
  transfer: IEVMTransferRequest,
): IEVMTransactionRequest {
  const chain = getChain(chainName);

  if (transfer.type === "native") {
    return {
      to: transfer.to,
      value: transfer.value,
      chainId: chain.id,
      gasLimit: transfer.gasLimit,
      gasPrice: transfer.gasPrice,
      maxFeePerGas: transfer.maxFeePerGas,
      maxPriorityFeePerGas: transfer.maxPriorityFeePerGas,
      nonce: transfer.nonce,
    };
  } else {
    if (!transfer.decimals && transfer.decimals !== 0) {
      throw new Error(
        "Token decimals must be specified for ERC-20 transfers - never assume 18",
      );
    }
    const amountInUnits = parseUnits(transfer.amount!, transfer.decimals);
    const data = encodeFunctionData({
      abi: erc20Abi,
      functionName: "transfer",
      args: [transfer.to as Address, amountInUnits],
    });

    return {
      to: transfer.contractAddress!,
      value: "0x0",
      data: data,
      chainId: chain.id,
      gasLimit: transfer.gasLimit,
      gasPrice: transfer.gasPrice,
      maxFeePerGas: transfer.maxFeePerGas,
      maxPriorityFeePerGas: transfer.maxPriorityFeePerGas,
      nonce: transfer.nonce,
    };
  }
}
