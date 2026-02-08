import { RadioGroup, RadioGroupItem } from "@/components/radio-group";
import { Label } from "@/components/label";
import { Card } from "@/components/card";
import { Badge } from "@/components/badge";
import { CheckCircle2 } from "lucide-react";

interface StepBlockchainProps {
  selectedChain: "sepolia" | "sui" | null;
  onSelectChain: (chain: "sepolia" | "sui") => void;
  isDeployed: (chain: "sepolia" | "sui") => boolean;
}

export function StepBlockchain({ selectedChain, onSelectChain, isDeployed }: StepBlockchainProps) {
  return (
    <div className="space-y-6">
      <div>
        <h3 className="text-lg font-medium mb-2">Select Blockchain</h3>
        <p className="text-sm text-muted-foreground">
          Choose which blockchain to deploy your stream on
        </p>
      </div>

      <RadioGroup value={selectedChain || ""} onValueChange={(value) => onSelectChain(value as "sepolia" | "sui")}>
        <Card className="p-4 cursor-pointer hover:border-primary transition-colors">
          <div className="flex items-start space-x-3">
            <RadioGroupItem value="sepolia" id="sepolia" className="mt-1" />
            <Label htmlFor="sepolia" className="flex-1 cursor-pointer">
              <div className="flex items-center justify-between mb-2">
                <div className="flex items-center gap-2">
                  <span className="font-medium">Sepolia (Ethereum Testnet)</span>
                  {isDeployed("sepolia") && (
                    <Badge variant="secondary" className="gap-1">
                      <CheckCircle2 className="w-3 h-3" />
                      Deployed
                    </Badge>
                  )}
                </div>
              </div>
              <p className="text-sm text-muted-foreground">
                EVM-compatible chain with Drips protocol and Uniswap v4 yield strategies
              </p>
              <div className="mt-3 flex gap-4 text-xs text-muted-foreground">
                <span>• Gas: ~0.001 ETH</span>
                <span>• Finality: ~15s</span>
                <span>• Assets: ETH, USDC, DAI</span>
              </div>
            </Label>
          </div>
        </Card>

        <Card className="p-4 cursor-pointer hover:border-primary transition-colors">
          <div className="flex items-start space-x-3">
            <RadioGroupItem value="sui" id="sui" className="mt-1" />
            <Label htmlFor="sui" className="flex-1 cursor-pointer">
              <div className="flex items-center justify-between mb-2">
                <div className="flex items-center gap-2">
                  <span className="font-medium">Sui Testnet</span>
                  {isDeployed("sui") && (
                    <Badge variant="secondary" className="gap-1">
                      <CheckCircle2 className="w-3 h-3" />
                      Deployed
                    </Badge>
                  )}
                </div>
              </div>
              <p className="text-sm text-muted-foreground">
                High-performance Move-based chain with DeepBook yield strategies
              </p>
              <div className="mt-3 flex gap-4 text-xs text-muted-foreground">
                <span>• Gas: ~0.0001 SUI</span>
                <span>• Finality: ~1s</span>
                <span>• Assets: SUI, USDC</span>
              </div>
            </Label>
          </div>
        </Card>
      </RadioGroup>
    </div>
  );
}
