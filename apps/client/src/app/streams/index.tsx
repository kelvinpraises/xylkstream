import { createFileRoute } from "@tanstack/react-router";
import { useState, useEffect } from "react";
import { Plus, Check, Loader2, StopCircle, Play, Copy, ExternalLink } from "lucide-react";
import { Button } from "@/components/button";
import { Input } from "@/components/input";
import { Card } from "@/components/card";
import { useContractDeployment, type ChainId } from "@/hooks/use-contract-deployment";
import { toast } from "sonner";
import {
  Drawer,
  DrawerContent,
  DrawerHeader,
  DrawerTitle,
  DrawerDescription,
  DrawerFooter,
} from "@/components/drawer";
import { Separator } from "@/components/separator";

export const Route = createFileRoute("/streams/")({
  component: StreamsPage,
});

// Demo data - stream collections with recipient details
const DEMO_STREAM_COLLECTIONS = [
  {
    id: "1",
    name: "q1 2026 team payments",
    totalOutflow: 0.0245,
    totalAmount: 50000,
    streamed: 12500,
    status: "active" as const,
    recipientCount: 3,
    token: "USDC",
    chain: "arbitrum",
    startDate: "2026-01-01",
    endDate: "2026-03-31",
    claimPageUrl: "https://xylkstream.app/claim/q1-team",
    recipients: [
      { address: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb", amount: 15000, claimed: 3750 },
      { address: "0x8ba1f109551bD432803012645Ac136ddd64DBA72", amount: 20000, claimed: 5000 },
      { address: "0xaB5801a7D398351b8bE11C439e05C5B3259aeC9B", amount: 15000, claimed: 3750 },
    ],
  },
  {
    id: "2",
    name: "marketing contractors",
    totalOutflow: 0.008,
    totalAmount: 20000,
    streamed: 20000,
    status: "paused" as const,
    recipientCount: 1,
    token: "USDC",
    chain: "base",
    startDate: "2025-12-01",
    endDate: "2026-02-28",
    claimPageUrl: "https://xylkstream.app/claim/marketing",
    recipients: [
      { address: "0x1234567890123456789012345678901234567890", amount: 20000, claimed: 20000 },
    ],
  },
  {
    id: "3",
    name: "development team",
    totalOutflow: 0.032,
    totalAmount: 80000,
    streamed: 35000,
    status: "active" as const,
    recipientCount: 3,
    token: "USDC",
    chain: "optimism",
    startDate: "2026-01-15",
    endDate: "2026-06-15",
    claimPageUrl: "https://xylkstream.app/claim/dev-team",
    recipients: [
      { address: "0xDEF1C0ded9bec7F1a1670819833240f027b25EfF", amount: 30000, claimed: 13125 },
      { address: "0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD", amount: 25000, claimed: 10937.5 },
      { address: "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45", amount: 25000, claimed: 10937.5 },
    ],
  },
];

// Wizard steps
const WIZARD_STEPS = [
  { id: "chain", title: "select chain", description: "choose deployment chain" },
  { id: "deploy", title: "deploy contract", description: "deploy or use existing" },
  { id: "details", title: "stream details", description: "name and configuration" },
  { id: "claim", title: "claim page", description: "setup recipient page" },
];

const CHAINS: { id: ChainId; name: string; type: string }[] = [
  { id: "arbitrum", name: "arbitrum", type: "evm-compatible" },
  { id: "base", name: "base", type: "evm-compatible" },
  { id: "optimism", name: "optimism", type: "evm-compatible" },
  { id: "sui", name: "sui", type: "move-based" },
];

function StreamWizard({ onClose }: { onClose: () => void }) {
  const [currentStep, setCurrentStep] = useState(0);
  const [formData, setFormData] = useState({
    chain: "" as ChainId | "",
    contractAddress: "",
    streamName: "",
    claimPageTitle: "",
    claimPageSubtitle: "",
  });
  
  const { isDeployed, isDeploying, deployToEVM, deployToSui, deployedContracts } = useContractDeployment();
  const [hasDeployment, setHasDeployment] = useState(false);

  // Check deployment status when chain changes
  useEffect(() => {
    if (formData.chain) {
      setHasDeployment(isDeployed(formData.chain));
    }
  }, [formData.chain, isDeployed]);

  const handleNext = async () => {
    // Validation
    if (currentStep === 0 && !formData.chain) {
      toast.error("please select a chain");
      return;
    }
    
    if (currentStep === 1 && !hasDeployment && !formData.contractAddress) {
      toast.error("please deploy a contract or enter an existing address");
      return;
    }

    if (currentStep === 2 && !formData.streamName) {
      toast.error("please enter a stream name");
      return;
    }

    if (currentStep < WIZARD_STEPS.length - 1) {
      setCurrentStep(currentStep + 1);
    } else {
      // Submit - create stream
      console.log("creating stream:", formData);
      toast.success("stream created successfully!");
      onClose();
    }
  };

  const handleBack = () => {
    if (currentStep > 0) {
      setCurrentStep(currentStep - 1);
    }
  };

  const handleDeploy = async () => {
    if (!formData.chain) return;

    if (formData.chain === "sui") {
      await deployToSui();
    } else {
      await deployToEVM(formData.chain);
    }
    
    // Refresh deployment status
    setHasDeployment(isDeployed(formData.chain));
  };

  return (
    <div className="fixed inset-0 bg-black/50 backdrop-blur-sm z-50 flex items-center justify-center p-4">
      <Card className="max-w-3xl w-full p-8">
        <div className="mb-8">
          <h2 className="text-2xl font-serif font-light mb-2 lowercase">create new stream</h2>
          <p className="text-sm text-muted-foreground">
            step {currentStep + 1} of {WIZARD_STEPS.length}
          </p>
        </div>

        {/* Progress Steps */}
        <div className="mb-8">
          <div className="flex items-center justify-between">
            {WIZARD_STEPS.map((step, index) => (
              <div key={step.id} className="flex items-center flex-1">
                <div className="flex flex-col items-center flex-1">
                  <div
                    className={`w-10 h-10 rounded-full flex items-center justify-center border-2 transition-colors ${
                      index <= currentStep
                        ? "bg-primary border-primary text-primary-foreground"
                        : "border-border text-muted-foreground"
                    }`}
                  >
                    {index < currentStep ? <Check className="w-5 h-5" /> : index + 1}
                  </div>
                  <div className="mt-2 text-center">
                    <div className="text-xs font-medium lowercase">{step.title}</div>
                    <div className="text-xs text-muted-foreground lowercase">{step.description}</div>
                  </div>
                </div>
                {index < WIZARD_STEPS.length - 1 && (
                  <div
                    className={`h-0.5 flex-1 mx-2 transition-colors ${
                      index < currentStep ? "bg-primary" : "bg-border"
                    }`}
                  />
                )}
              </div>
            ))}
          </div>
        </div>

        {/* Step Content */}
        <div className="min-h-[300px] mb-8">
          {currentStep === 0 && (
            <div className="space-y-4">
              <h3 className="text-lg font-medium lowercase">select blockchain</h3>
              <div className="grid grid-cols-2 gap-4">
                {CHAINS.map((chain) => (
                  <button
                    key={chain.id}
                    onClick={() => setFormData({ ...formData, chain: chain.id })}
                    className={`p-6 rounded-xl border-2 transition-all text-left ${
                      formData.chain === chain.id
                        ? "border-primary bg-primary/5"
                        : "border-border hover:border-primary/50"
                    }`}
                  >
                    <div className="text-lg font-medium lowercase">{chain.name}</div>
                    <div className="text-sm text-muted-foreground mt-1 lowercase">
                      {chain.type}
                    </div>
                    {formData.chain === chain.id && isDeployed(chain.id) && (
                      <div className="mt-2 flex items-center gap-1 text-xs text-primary">
                        <Check className="w-3 h-3" />
                        deployed
                      </div>
                    )}
                  </button>
                ))}
              </div>
            </div>
          )}

          {currentStep === 1 && (
            <div className="space-y-4">
              <h3 className="text-lg font-medium lowercase">deploy or connect</h3>
              
              {hasDeployment ? (
                <div className="p-4 rounded-lg border border-primary/30 bg-primary/5">
                  <div className="flex items-start gap-3">
                    <Check className="w-5 h-5 text-primary mt-0.5" />
                    <div>
                      <div className="font-medium lowercase mb-1">contract already deployed</div>
                      <div className="text-sm text-muted-foreground lowercase">
                        you have an existing deployment on {formData.chain}
                      </div>
                      {formData.chain && deployedContracts[formData.chain] && (
                        <div className="mt-2 text-xs font-mono text-muted-foreground">
                          {formData.chain === "sui" 
                            ? (deployedContracts[formData.chain] as any).packageId
                            : (deployedContracts[formData.chain] as any).addressDriver}
                        </div>
                      )}
                    </div>
                  </div>
                </div>
              ) : (
                <>
                  <p className="text-sm text-muted-foreground lowercase">
                    {formData.chain
                      ? `deploy a new contract on ${formData.chain} or connect to existing`
                      : "select a chain first"}
                  </p>
                  <div className="space-y-3">
                    <Button 
                      variant="outline" 
                      className="w-full justify-start h-auto p-4"
                      onClick={handleDeploy}
                      disabled={!formData.chain || isDeploying}
                    >
                      {isDeploying ? (
                        <Loader2 className="w-4 h-4 mr-2 animate-spin" />
                      ) : null}
                      <div className="text-left">
                        <div className="font-medium lowercase">
                          {isDeploying ? "deploying..." : "deploy new contract"}
                        </div>
                        <div className="text-xs text-muted-foreground lowercase">
                          create a fresh deployment on {formData.chain || "selected chain"}
                        </div>
                      </div>
                    </Button>
                    <div className="relative">
                      <div className="absolute inset-0 flex items-center">
                        <div className="w-full border-t border-border" />
                      </div>
                      <div className="relative flex justify-center text-xs uppercase">
                        <span className="bg-card px-2 text-muted-foreground">or</span>
                      </div>
                    </div>
                    <div>
                      <label className="text-sm font-medium lowercase mb-2 block">
                        existing contract address
                      </label>
                      <Input
                        placeholder="0x..."
                        value={formData.contractAddress}
                        onChange={(e) =>
                          setFormData({ ...formData, contractAddress: e.target.value })
                        }
                      />
                    </div>
                  </div>
                </>
              )}
            </div>
          )}

          {currentStep === 2 && (
            <div className="space-y-4">
              <h3 className="text-lg font-medium lowercase">stream details</h3>
              <div className="space-y-4">
                <div>
                  <label className="text-sm font-medium lowercase mb-2 block">
                    stream name
                  </label>
                  <Input
                    placeholder="e.g., q1 2026 team payments"
                    value={formData.streamName}
                    onChange={(e) => setFormData({ ...formData, streamName: e.target.value })}
                  />
                  <p className="text-xs text-muted-foreground mt-1 lowercase">
                    a descriptive name for this payment stream collection
                  </p>
                </div>
              </div>
            </div>
          )}

          {currentStep === 3 && (
            <div className="space-y-4">
              <h3 className="text-lg font-medium lowercase">claim page setup</h3>
              <p className="text-sm text-muted-foreground lowercase">
                create a page where recipients can view and claim their streams
              </p>
              <div className="space-y-4">
                <div>
                  <label className="text-sm font-medium lowercase mb-2 block">
                    page title
                  </label>
                  <Input
                    placeholder="e.g., team payments"
                    value={formData.claimPageTitle}
                    onChange={(e) =>
                      setFormData({ ...formData, claimPageTitle: e.target.value })
                    }
                  />
                </div>
                <div>
                  <label className="text-sm font-medium lowercase mb-2 block">
                    subtitle (optional)
                  </label>
                  <Input
                    placeholder="e.g., claim your vested tokens"
                    value={formData.claimPageSubtitle}
                    onChange={(e) =>
                      setFormData({ ...formData, claimPageSubtitle: e.target.value })
                    }
                  />
                </div>
              </div>
            </div>
          )}
        </div>

        {/* Actions */}
        <div className="flex items-center justify-between">
          <Button variant="ghost" onClick={onClose} className="lowercase">
            cancel
          </Button>
          <div className="flex gap-2">
            {currentStep > 0 && (
              <Button variant="outline" onClick={handleBack} className="lowercase">
                back
              </Button>
            )}
            <Button onClick={handleNext} className="lowercase">
              {currentStep === WIZARD_STEPS.length - 1 ? "create stream" : "next"}
            </Button>
          </div>
        </div>
      </Card>
    </div>
  );
}

// Stream detail drawer component
function StreamDetailDrawer({ 
  stream, 
  open, 
  onOpenChange 
}: { 
  stream: typeof DEMO_STREAM_COLLECTIONS[0] | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  if (!stream) return null;

  const progress = (stream.streamed / stream.totalAmount) * 100;

  const handleCopyAddress = (address: string) => {
    navigator.clipboard.writeText(address);
    toast.success("address copied to clipboard");
  };

  const handleCopyClaimPage = () => {
    navigator.clipboard.writeText(stream.claimPageUrl);
    toast.success("claim page url copied");
  };

  const handlePauseResume = () => {
    if (stream.status === "active") {
      toast.success("stream paused");
    } else {
      toast.success("stream resumed");
    }
  };

  const handleStop = () => {
    toast.success("stream stopped");
  };

  return (
    <Drawer open={open} onOpenChange={onOpenChange}>
      <DrawerContent>
        <DrawerHeader>
          <DrawerTitle className="lowercase">{stream.name}</DrawerTitle>
          <DrawerDescription className="lowercase">
            stream configuration and recipient details
          </DrawerDescription>
        </DrawerHeader>

        <div className="px-4 pb-4 overflow-y-auto max-h-[70vh]">
          <div className="max-w-2xl mx-auto">
          {/* Status and Progress */}
          <div className="mb-6">
            <div className="flex items-center gap-2 mb-3">
              <div
                className={`w-1.5 h-1.5 rounded-full ${
                  stream.status === "active"
                    ? "bg-white/70 shadow-[0_0_8px_rgba(255,255,255,0.4)]"
                    : "bg-muted-foreground/40"
                }`}
                style={
                  stream.status === "active"
                    ? { animation: "breathe 4s ease-in-out infinite" }
                    : undefined
                }
              />
              <span className="text-sm font-light lowercase">{stream.status}</span>
            </div>
            
            <div className="h-0.5 bg-muted rounded-full overflow-hidden mb-2">
              <div
                className="h-full bg-foreground/50 relative"
                style={{ width: `${progress}%` }}
              >
                {stream.status === "active" && (
                  <div
                    className="absolute inset-0 bg-gradient-to-r from-transparent via-white/20 to-transparent"
                    style={{ animation: "flow 2s infinite" }}
                  />
                )}
              </div>
            </div>
            <div className="text-xs text-muted-foreground lowercase">
              {stream.streamed.toLocaleString()} / {stream.totalAmount.toLocaleString()} {stream.token} ({progress.toFixed(0)}%)
            </div>
          </div>

          {/* Stream Details */}
          <div className="space-y-3 mb-6">
            <div className="grid grid-cols-2 gap-3">
              <div>
                <div className="text-xs text-muted-foreground lowercase mb-1">rate</div>
                <div className="text-base font-light font-mono">{stream.totalOutflow}<span className="text-xs text-muted-foreground ml-1">/s</span></div>
              </div>
              <div>
                <div className="text-xs text-muted-foreground lowercase mb-1">token</div>
                <div className="text-base font-light font-mono">{stream.token}</div>
              </div>
              <div>
                <div className="text-xs text-muted-foreground lowercase mb-1">chain</div>
                <div className="text-base font-light lowercase">{stream.chain}</div>
              </div>
              <div>
                <div className="text-xs text-muted-foreground lowercase mb-1">recipients</div>
                <div className="text-base font-light font-mono">{stream.recipientCount}</div>
              </div>
            </div>
          </div>

          <Separator className="my-4" />

          {/* Claim Page */}
          <div className="mb-6">
            <div className="text-sm font-light lowercase mb-2">claim page</div>
            <div className="flex items-center gap-2 p-2 rounded-lg bg-muted/30">
              <code className="text-xs flex-1 truncate font-light">{stream.claimPageUrl}</code>
              <Button
                variant="ghost"
                size="sm"
                onClick={handleCopyClaimPage}
                className="shrink-0 h-6 w-6 p-0"
              >
                <Copy className="w-3 h-3" />
              </Button>
              <Button
                variant="ghost"
                size="sm"
                onClick={() => window.open(stream.claimPageUrl, "_blank")}
                className="shrink-0 h-6 w-6 p-0"
              >
                <ExternalLink className="w-3 h-3" />
              </Button>
            </div>
          </div>

          <Separator className="my-4" />

          {/* Recipients */}
          <div>
            <div className="text-sm font-light lowercase mb-3">recipients</div>
            <div className="space-y-2">
              {stream.recipients.map((recipient, index) => {
                const recipientProgress = (recipient.claimed / recipient.amount) * 100;
                return (
                  <div key={index} className="p-3 rounded-lg bg-muted/30">
                    <div className="flex items-start justify-between mb-2">
                      <div className="flex-1 min-w-0">
                        <code className="text-xs text-muted-foreground block truncate font-light">
                          {recipient.address}
                        </code>
                      </div>
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => handleCopyAddress(recipient.address)}
                        className="shrink-0 ml-2 h-6 w-6 p-0"
                      >
                        <Copy className="w-3 h-3" />
                      </Button>
                    </div>
                    <div className="space-y-1">
                      <div className="flex items-center justify-between text-xs">
                        <span className="text-muted-foreground lowercase">claimed</span>
                        <span className="font-mono font-light">{recipient.claimed.toLocaleString()} / {recipient.amount.toLocaleString()}</span>
                      </div>
                      <div className="h-0.5 bg-muted rounded-full overflow-hidden">
                        <div
                          className="h-full bg-foreground/50"
                          style={{ width: `${recipientProgress}%` }}
                        />
                      </div>
                    </div>
                  </div>
                );
              })}
            </div>
          </div>
          </div>
        </div>

        <DrawerFooter>
          <div className="flex gap-2">
            <Button
              variant="outline"
              className="flex-1 lowercase"
              onClick={handlePauseResume}
            >
              {stream.status === "active" ? (
                <>
                  <StopCircle className="w-4 h-4 mr-2" />
                  pause stream
                </>
              ) : (
                <>
                  <Play className="w-4 h-4 mr-2" />
                  resume stream
                </>
              )}
            </Button>
            <Button
              variant="outline"
              className="flex-1 lowercase text-destructive hover:text-destructive"
              onClick={handleStop}
            >
              <StopCircle className="w-4 h-4 mr-2" />
              stop stream
            </Button>
          </div>
        </DrawerFooter>
      </DrawerContent>
    </Drawer>
  );
}

function StreamsPage() {
  const [wizardOpen, setWizardOpen] = useState(false);
  const [selectedStream, setSelectedStream] = useState<typeof DEMO_STREAM_COLLECTIONS[0] | null>(null);
  const [drawerOpen, setDrawerOpen] = useState(false);

  const handleStreamClick = (stream: typeof DEMO_STREAM_COLLECTIONS[0]) => {
    setSelectedStream(stream);
    setDrawerOpen(true);
  };

  return (
    <div className="w-full max-w-7xl mx-auto">
      {/* Header */}
      <div className="mb-8">
        <div className="flex items-end justify-between mb-6">
          <div>
            <h1 className="text-4xl md:text-5xl font-serif font-light tracking-tight text-foreground mb-3">
              Streams
            </h1>
            <p className="text-muted-foreground text-lg lowercase">
              manage your payment stream collections
            </p>
          </div>
          <button
            onClick={() => setWizardOpen(true)}
            className="px-8 py-4 text-lg rounded-full bg-gradient-to-r from-[#0B1221] to-[#0f172a] border border-cyan-500/30 text-white font-medium hover:border-cyan-400/60 transition-all shadow-[0_0_25px_-8px_rgba(6,182,212,0.4)] hover:shadow-[0_0_35px_-5px_rgba(6,182,212,0.6)] flex items-center gap-2"
          >
            <Plus className="w-4 h-4" />
            <span className="lowercase">new stream</span>
          </button>
        </div>
      </div>

      {/* Stream Collections */}
      <div className="grid md:grid-cols-2 lg:grid-cols-3 gap-6">
        {DEMO_STREAM_COLLECTIONS.map((collection) => {
          const progress = (collection.streamed / collection.totalAmount) * 100;
          return (
            <Card
              key={collection.id}
              onClick={() => handleStreamClick(collection)}
              className="group relative p-6 border border-border hover:border-primary/30 transition-all cursor-pointer"
            >
              {/* Collection Header */}
              <div className="mb-6">
                <h3 className="text-lg font-light text-foreground mb-3 lowercase">
                  {collection.name}
                </h3>
                <div className="flex items-center gap-2">
                  <div
                    className={`w-1.5 h-1.5 rounded-full ${
                      collection.status === "active"
                        ? "bg-white/70 shadow-[0_0_8px_rgba(255,255,255,0.4)]"
                        : "bg-muted-foreground/40"
                    }`}
                    style={
                      collection.status === "active"
                        ? {
                            animation: "breathe 4s ease-in-out infinite",
                          }
                        : undefined
                    }
                  />
                  <span className="text-xs text-muted-foreground lowercase">
                    {collection.recipientCount} recipients
                  </span>
                </div>
              </div>

              {/* Stats */}
              <div className="grid grid-cols-2 gap-4 mb-6">
                <div>
                  <div className="text-xs text-muted-foreground lowercase mb-1">streamed</div>
                  <div className="text-lg font-light font-mono">
                    {collection.streamed.toLocaleString()}
                  </div>
                </div>
                <div>
                  <div className="text-xs text-muted-foreground lowercase mb-1">rate</div>
                  <div className="text-lg font-light font-mono">
                    {collection.totalOutflow}
                    <span className="text-xs text-muted-foreground ml-1">/s</span>
                  </div>
                </div>
              </div>

              {/* Progress Bar */}
              <div>
                <div className="h-0.5 bg-muted rounded-full overflow-hidden">
                  <div
                    className="h-full bg-foreground/50 relative"
                    style={{ width: `${progress}%` }}
                  >
                    {collection.status === "active" && (
                      <div
                        className="absolute inset-0 bg-gradient-to-r from-transparent via-white/20 to-transparent"
                        style={{
                          animation: "flow 2s infinite",
                        }}
                      />
                    )}
                  </div>
                </div>
                <div className="text-xs text-muted-foreground mt-2 lowercase">{progress.toFixed(0)}%</div>
              </div>
            </Card>
          );
        })}
      </div>

      {/* Wizard */}
      {wizardOpen && <StreamWizard onClose={() => setWizardOpen(false)} />}
      
      {/* Stream Detail Drawer */}
      <StreamDetailDrawer 
        stream={selectedStream} 
        open={drawerOpen} 
        onOpenChange={setDrawerOpen} 
      />

      <style>{`
        @keyframes breathe {
          0%, 100% { opacity: 0.5; transform: scale(1); }
          50% { opacity: 1; transform: scale(1.2); }
        }
        @keyframes flow {
          0% { transform: translateX(-100%); }
          100% { transform: translateX(100%); }
        }
      `}</style>
    </div>
  );
}
