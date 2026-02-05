import { createRootRoute, Outlet } from "@tanstack/react-router";
import { TanStackRouterDevtools } from "@tanstack/react-router-devtools";
import RootProvider from "@/providers";
import { Toaster } from "@/components/sonner";
import "@/styles/globals.css";

export const Route = createRootRoute({
  component: RootLayout,
});

function RootLayout() {
  return (
    <RootProvider>
      {/* Responsive container - mobile-first with desktop support */}
      <div className="min-h-screen bg-black flex justify-center">
        <div className="w-full max-w-7xl bg-[#030305] min-h-screen flex flex-col relative overflow-hidden">
          {/* Background Effects - Liquid Aurora */}
          <div className="absolute inset-0 z-0 pointer-events-none overflow-hidden">
            {/* Deep Void Base */}
            <div className="absolute inset-0 bg-[#020204]" />

            {/* Liquid Mesh Gradients - The "Aurora" */}
            <div className="absolute top-[-10%] left-[-10%] w-[120vw] h-[120vw] md:w-[50vw] md:h-[50vw] bg-indigo-500/20 blur-[120px] rounded-full mix-blend-screen animate-aurora" />
            <div className="absolute top-[10%] right-[-10%] w-[140vw] h-[140vw] md:w-[60vw] md:h-[60vw] bg-cyan-600/15 blur-[120px] rounded-full mix-blend-screen animate-aurora delay-[2000ms]" />
            <div className="absolute bottom-[-10%] left-[20%] w-[150vw] h-[150vw] md:w-[70vw] md:h-[50vw] bg-violet-600/15 blur-[140px] rounded-full mix-blend-screen animate-aurora delay-[4000ms]" />

            {/* Subtle Noise Texture */}
            <div className="absolute inset-0 opacity-[0.03] mix-blend-overlay bg-noise pointer-events-none" />
          </div>

          <main className="flex-1 relative z-10">
            <Outlet />
          </main>
        </div>
      </div>
      <Toaster />
      <TanStackRouterDevtools />
      <style>{`
        .bg-noise {
          background-image: url("data:image/svg+xml,%3Csvg viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noiseFilter'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.7' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noiseFilter)' opacity='1'/%3E%3C/svg%3E");
        }
      `}</style>
    </RootProvider>
  );
}
