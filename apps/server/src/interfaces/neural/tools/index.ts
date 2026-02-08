import * as accountTools from "@/interfaces/neural/tools/account";
import * as journalTools from "@/interfaces/neural/tools/journal";
import * as streamTools from "@/interfaces/neural/tools/stream";
import * as swapTools from "@/interfaces/neural/tools/swap";
import * as bridgeTools from "@/interfaces/neural/tools/bridge";
import * as multichainTools from "@/interfaces/neural/tools/multichain";

export const allTools = {
  ...accountTools,
  ...journalTools,
  ...streamTools,
  ...swapTools,
  ...bridgeTools,
  ...multichainTools,
};
