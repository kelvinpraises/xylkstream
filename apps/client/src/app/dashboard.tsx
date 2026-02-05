import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { usePrivy } from "@privy-io/react-auth";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/card";
import { Button } from "@/components/button";
import {
  Activity,
  DollarSign,
  TrendingUp,
  Sparkles,
  Plus,
  Loader2,
  ArrowUpRight,
} from "lucide-react";
import { useLogout, useStreams, useAccount } from "@/hooks";
import { BottomNav } from "@/components/bottom-nav";
import { useMemo } from "react";
import { formatCurrency, formatRelativeTime, truncateAddress } from "@/utils";

export const Route = createFileRoute("/dashboard")({
  component: DashboardPage,
});

function DashboardPage() {
  const { user } = usePrivy();
  const navigate = useNavigate();
  const logout = useLogout();
  const { data: streams, isLoading: streamsLoading } = useStreams();
  const { data: account, isLoading: accountLoading } = useAccount();

  const stats = useMemo(() => {
    if (!streams) {
      return {
        activeStreams: 0,
        totalVested: 0,
        yieldEarned: 0,
        avgYieldAPY: 0,
      };
    }

    const activeStreams = streams.filter(
      (s) => s.status === "ACTIVE" || s.status === "PENDING"
    ).length;

    const totalVested = streams.reduce((sum, s) => sum + s.amount, 0);
    const yieldEarned = streams.reduce((sum, s) => sum + s.yieldEarned, 0);

    // Calculate average APY (simplified - would need time-weighted calculation in production)
    const avgYieldAPY = totalVested > 0 ? (yieldEarned / totalVested) * 100 : 0;

    return {
      activeStreams,
      totalVested,
      yieldEarned,
      avgYieldAPY,
    };
  }, [streams]);

  const recentStreams = useMemo(() => {
    if (!streams) return [];
    return streams.slice(0, 5);
  }, [streams]);

  const isLoading = streamsLoading || accountLoading;

  return (
    <div className="min-h-screen p-4 md:p-8 pb-24">
      {/* Header */}
      <div className="mb-6 md:mb-8">
        <div className="flex items-center justify-between mb-2">
          <h1 className="text-2xl md:text-3xl font-serif font-light text-white">
            Dashboard
          </h1>
          <Button
            onClick={logout}
            variant="ghost"
            size="sm"
            className="text-slate-400 hover:text-white"
          >
            Logout
          </Button>
        </div>
        <p className="text-sm text-slate-400">
          Welcome back, {truncateAddress(user?.wallet?.address || "Anon")}
        </p>
      </div>

      {/* Stats Grid */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3 md:gap-4 mb-6 md:mb-8">
        <Card className="bg-white/5 border-white/10 backdrop-blur-sm">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-normal text-slate-400 flex items-center gap-2">
              <Activity className="w-4 h-4" />
              Active Streams
            </CardTitle>
          </CardHeader>
          <CardContent>
            {isLoading ? (
              <Loader2 className="w-6 h-6 animate-spin text-slate-400" />
            ) : (
              <p className="text-2xl md:text-3xl font-semibold text-white">
                {stats.activeStreams}
              </p>
            )}
          </CardContent>
        </Card>

        <Card className="bg-white/5 border-white/10 backdrop-blur-sm">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-normal text-slate-400 flex items-center gap-2">
              <DollarSign className="w-4 h-4" />
              Total Vested
            </CardTitle>
          </CardHeader>
          <CardContent>
            {isLoading ? (
              <Loader2 className="w-6 h-6 animate-spin text-slate-400" />
            ) : (
              <p className="text-2xl md:text-3xl font-semibold text-white">
                {formatCurrency(stats.totalVested)}
              </p>
            )}
          </CardContent>
        </Card>

        <Card className="bg-white/5 border-white/10 backdrop-blur-sm">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-normal text-slate-400 flex items-center gap-2">
              <Sparkles className="w-4 h-4" />
              Yield Earned
            </CardTitle>
          </CardHeader>
          <CardContent>
            {isLoading ? (
              <Loader2 className="w-6 h-6 animate-spin text-slate-400" />
            ) : (
              <p className="text-2xl md:text-3xl font-semibold text-white">
                {formatCurrency(stats.yieldEarned)}
              </p>
            )}
          </CardContent>
        </Card>

        <Card className="bg-white/5 border-white/10 backdrop-blur-sm">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-normal text-slate-400 flex items-center gap-2">
              <TrendingUp className="w-4 h-4" />
              Avg Yield APY
            </CardTitle>
          </CardHeader>
          <CardContent>
            {isLoading ? (
              <Loader2 className="w-6 h-6 animate-spin text-slate-400" />
            ) : (
              <p className="text-2xl md:text-3xl font-semibold text-white">
                {stats.avgYieldAPY.toFixed(2)}%
              </p>
            )}
          </CardContent>
        </Card>
      </div>

      {/* Recent Streams */}
      <Card className="bg-white/5 border-white/10 backdrop-blur-sm mb-6">
        <CardHeader>
          <div className="flex items-center justify-between">
            <CardTitle className="text-white">Recent Streams</CardTitle>
            <Button
              onClick={() => navigate({ to: "/streams" })}
              variant="ghost"
              size="sm"
              className="text-cyan-400 hover:text-cyan-300"
            >
              View All
              <ArrowUpRight className="w-4 h-4 ml-1" />
            </Button>
          </div>
        </CardHeader>
        <CardContent>
          {isLoading ? (
            <div className="flex items-center justify-center py-12">
              <Loader2 className="w-8 h-8 animate-spin text-cyan-400" />
            </div>
          ) : recentStreams.length === 0 ? (
            <div className="flex flex-col items-center justify-center py-12">
              <div className="relative mb-6">
                <div className="absolute inset-0 bg-gradient-to-r from-cyan-500/20 to-blue-500/20 blur-2xl rounded-full" />
                <div className="relative bg-gradient-to-br from-cyan-500/10 to-blue-500/10 p-6 rounded-full border border-cyan-500/20">
                  <Sparkles className="w-12 h-12 text-cyan-400" />
                </div>
              </div>
              <h3 className="text-white font-medium text-lg mb-2">No streams yet</h3>
              <p className="text-slate-400 text-sm text-center mb-6 max-w-xs">
                Create your first vesting stream and start earning yield on unvested funds!
              </p>
              <Button
                onClick={() => navigate({ to: "/streams/create" })}
                className="bg-gradient-to-r from-cyan-600 to-blue-600 hover:from-cyan-500 hover:to-blue-500 text-white border-0 flex items-center gap-2"
              >
                <Plus className="w-4 h-4" />
                Create Stream
              </Button>
            </div>
          ) : (
            <div className="space-y-3">
              {recentStreams.map((stream) => (
                <button
                  key={stream.id}
                  onClick={() => navigate({ to: `/stream/${stream.id}` })}
                  className="w-full text-left p-3 md:p-4 rounded-lg bg-white/5 hover:bg-white/10 border border-white/10 transition-colors"
                >
                  <div className="flex items-start justify-between mb-2">
                    <div className="flex-1">
                      <h4 className="text-white font-medium text-sm md:text-base">
                        {truncateAddress(stream.recipientAddress)}
                      </h4>
                      <p className="text-slate-400 text-xs md:text-sm">
                        {formatCurrency(stream.amount)} • {stream.asset}
                      </p>
                    </div>
                    <span
                      className={`text-xs px-2 py-1 rounded-full ${getStatusColor(stream.status)}`}
                    >
                      {stream.status}
                    </span>
                  </div>
                  <div className="flex items-center gap-3 text-xs text-slate-500">
                    <span>Yield: {formatCurrency(stream.yieldEarned)}</span>
                    <span>•</span>
                    <span>{formatRelativeTime(stream.createdAt)}</span>
                  </div>
                </button>
              ))}
            </div>
          )}
        </CardContent>
      </Card>

      {/* Bottom Navigation */}
      <BottomNav />
    </div>
  );
}

function getStatusColor(status: string) {
  switch (status) {
    case "PENDING":
      return "bg-yellow-500/20 text-yellow-400";
    case "ACTIVE":
      return "bg-green-500/20 text-green-400";
    case "PAUSED":
      return "bg-blue-500/20 text-blue-400";
    case "COMPLETED":
      return "bg-purple-500/20 text-purple-400";
    case "CANCELLED":
      return "bg-red-500/20 text-red-400";
    default:
      return "bg-slate-500/20 text-slate-400";
  }
}
