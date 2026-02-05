import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { usePrivy } from "@privy-io/react-auth";
import { useEffect } from "react";
import { Button } from "@/components/button";

export const Route = createFileRoute("/")({
  component: LoginPage,
});

function LoginPage() {
  const { ready, authenticated, login } = usePrivy();
  const navigate = useNavigate();

  useEffect(() => {
    if (ready && authenticated) {
      navigate({ to: "/dashboard" });
    }
  }, [ready, authenticated, navigate]);

  return (
    <div className="flex flex-col items-center justify-center min-h-screen px-6 text-white">
      {/* Logo/Title */}
      <div className="mb-12 text-center">
        <h1 className="text-6xl md:text-7xl font-serif font-light tracking-tight mb-4 italic text-transparent bg-clip-text bg-gradient-to-r from-cyan-100 via-white to-indigo-200">
          Xylkstream
        </h1>
        <p className="text-lg md:text-xl text-blue-100/60 font-light">
          Vesting with automated yield
        </p>
      </div>

      {/* Login Button */}
      <Button
        onClick={login}
        disabled={!ready}
        className="px-8 py-6 text-lg rounded-full bg-gradient-to-r from-[#0B1221] to-[#0f172a] border border-cyan-500/30 text-white font-medium hover:border-cyan-400/60 transition-all shadow-[0_0_25px_-8px_rgba(6,182,212,0.4)] hover:shadow-[0_0_35px_-5px_rgba(6,182,212,0.6)]"
      >
        {!ready ? "Loading..." : "Connect Wallet"}
      </Button>

      {/* Info Text */}
      <p className="mt-8 text-sm text-slate-400 text-center max-w-md px-4">
        Stream payments to anyone while AI agents automatically deploy idle capital to
        the highest-yield markets across Sui and EVM chains
      </p>

      {/* Features */}
      <div className="mt-16 grid grid-cols-1 md:grid-cols-3 gap-6 max-w-4xl w-full px-4">
        <div className="text-center">
          <div className="text-3xl mb-2">💰</div>
          <h3 className="text-white font-medium mb-1">Automated Yield</h3>
          <p className="text-slate-400 text-sm">
            Your unvested funds earn yield automatically
          </p>
        </div>
        <div className="text-center">
          <div className="text-3xl mb-2">⚡</div>
          <h3 className="text-white font-medium mb-1">Real-time Optimization</h3>
          <p className="text-slate-400 text-sm">
            AI agents move capital to highest-yield markets
          </p>
        </div>
        <div className="text-center">
          <div className="text-3xl mb-2">🔌</div>
          <h3 className="text-white font-medium mb-1">Hot-swappable Strategies</h3>
          <p className="text-slate-400 text-sm">
            Change yield strategies without interrupting streams
          </p>
        </div>
      </div>
    </div>
  );
}
