import type { ReactNode } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { PrivyProvider } from "./privy-provider";
import { RpcSessionProvider } from "./rpc-session-provider";
import { ThemeProvider } from "./theme-provider";

interface RootProviderProps {
  children: ReactNode;
}

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      refetchOnWindowFocus: false,
      retry: 1,
    },
  },
});

export default function RootProvider({ children }: RootProviderProps) {
  return (
    <ThemeProvider>
      <QueryClientProvider client={queryClient}>
        <PrivyProvider>
          <RpcSessionProvider>{children}</RpcSessionProvider>
        </PrivyProvider>
      </QueryClientProvider>
    </ThemeProvider>
  );
}
