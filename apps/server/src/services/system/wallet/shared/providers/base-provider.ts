export function validateAccountId(accountId: number): void {
  if (!accountId || accountId <= 0 || !Number.isInteger(accountId)) {
    throw new Error(`Invalid account ID: ${accountId}`);
  }
}

export function validateChainId(chainId: string): void {
  if (!chainId || typeof chainId !== 'string' || !chainId.includes(':')) {
    throw new Error(`Invalid chain ID: ${chainId}. Expected CAIP-2 format (e.g., "eip155:8453")`);
  }
}
