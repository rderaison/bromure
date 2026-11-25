// The coding agents a session can run (Profile.Tool). Avatars: sidebar/AgentAvatar.

export type ToolID = 'claude' | 'codex' | 'grok' | 'kimi' | 'omp' | 'hermes';

export interface AgentKind {
  id: ToolID;
  displayName: string;
  tint: string;
  /** Hermes starts only on a model the workspace names. */
  needsModelToStart: boolean;
  /** omp / Hermes: switched between providers by a setting. */
  switchesProvider: boolean;
}

export const AGENTS: AgentKind[] = [
  { id: 'claude', displayName: 'Claude Code', tint: '#D97757', needsModelToStart: false, switchesProvider: false },
  { id: 'codex', displayName: 'Codex', tint: '#2B2B2E', needsModelToStart: false, switchesProvider: false },
  { id: 'grok', displayName: 'Grok Build', tint: '#4B5563', needsModelToStart: false, switchesProvider: false },
  { id: 'kimi', displayName: 'Kimi Code', tint: '#4F46E5', needsModelToStart: false, switchesProvider: false },
  { id: 'omp', displayName: 'Oh My Pi', tint: '#0E9F6E', needsModelToStart: false, switchesProvider: true },
  { id: 'hermes', displayName: 'Hermes Agent', tint: '#7C5CFF', needsModelToStart: true, switchesProvider: true },
];

export function agentKind(tool: string | undefined): AgentKind {
  return AGENTS.find(a => a.id === tool) ?? { ...AGENTS[0], id: (tool ?? 'claude') as ToolID, displayName: tool ?? 'Agent' };
}
