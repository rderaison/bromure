// The server's `/state` snapshot (AutomationServer.buildStateSnapshot). Typed
// loosely on purpose: the server adds fields over time and older servers omit
// newer ones — every consumer must tolerate a missing field. Extend these as a
// view needs more (keep names exactly as on the wire).

export interface RemoteState {
  version: number;
  build?: { version?: string; build?: string; commit?: string; date?: string };
  supportsPush?: boolean;
  generation?: number;
  epoch?: string;
  workspaces: Workspace[];
  workspacesListed?: boolean;
  vms: VMInfo[];
  gridLayout?: { autoFill?: boolean; cells: any[] };
  automations?: { automations: any[]; runs: any[]; findings?: any[]; watches?: any[]; nextFires?: Record<string, string>; timeZone?: string };
  tasks?: { tasks: any[] };
  pendingPrompts?: any[];
  subscriptions?: Record<string, any>;
  securityTimeline?: any[];
  securityTimelineHead?: any;
  securityTimelineOldest?: number | null;
  securityTimelineOldestSeq?: number | null;
  securityTimelineEpoch?: string | null;
  localModels?: { unifiedMemGB?: number; models?: Record<string, any> };
  kubeClusters?: { clusters: any[]; registries?: any[]; connectors?: any[]; status: Record<string, any> };
  pendingRegistration?: any;
  registrationEnded?: any;
  registrationsEnded?: any[];
  agentSessions?: AgentSession[];
  delegations?: any[];
  agentRooms?: AgentRoom[];
  instructionPresets?: { id: string; name: string; text: string }[];
  pendingMachines?: any[];
  blockedMachines?: any[];
  vmnetSubnet?: string;
  vmnetGateway?: string;
  [k: string]: unknown;
}

export interface Workspace {
  id: string;
  name: string;
  color: string;          // ProfileColor rawValue ("blue")
  accentHex?: string;     // resolved UI color
  tool: string;           // default agent ("claude")
  state?: 'running' | 'off' | 'suspended' | 'booting' | string;
  readyTools?: { tool: string; authMode: string }[];
  compromised?: boolean;
  sandboxed?: boolean;
  cpuCount?: number; memoryGB?: number;
  comments?: string;
  [k: string]: unknown;
}

export interface VMTab {
  index: number; title?: string; active?: boolean; process?: string; tool?: string;
  [k: string]: unknown;
}

export interface VMInfo {
  id: string; name?: string; shortId?: string; state?: string; ip?: string; uptimeSeconds?: number;
  tabs?: VMTab[]; cpu?: number; load?: number; memUsedKB?: number; memTotalKB?: number;
  diskUsedKB?: number; diskTotalKB?: number; listeningPorts?: any[]; guestUnresponsive?: boolean;
  [k: string]: unknown;
}

export interface AgentSession {
  id: string;
  profileID: string;
  title: string;
  tool: string;
  cwd?: string;
  nickname?: string;
  createdAt?: string; activeAt?: string; lastSeenAt?: string; agentSeenAt?: string;
  endedAt?: string; archivedAt?: string; pausedAt?: string;
  windowIndex?: number; windowID?: string;
  userTitled?: boolean;
  awaitingAnswer?: boolean;
  roomID?: string;
  worktree?: any;
  [k: string]: unknown;
}

export interface AgentRoom { id: string; name: string; colorHex?: string; layout?: string; createdAt?: string; [k: string]: unknown }
