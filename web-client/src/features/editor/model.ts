// The configuration editor's data model — `EditorCategory` and the Profile
// document as the fat client round-trips it (ProfileViews.swift,
// Profile.swift, FatClientController.settingsDocument).
//
// The draft is the wire document itself (GET /profiles/<id>?full=1, secrets
// blanked), edited in place. The Swift Profile encoder leaves defaults out, so
// every read goes through `val(doc, key)` which falls back to the decoder's
// default. Save sends only what changed (settingsDocument): a changed key, an
// explicit null for a key removed; a key as it opened stays out so the host
// keeps what it has (another window or the CLI may have changed it since).

export type Doc = Record<string, any>;

export type CategoryID =
  | 'general' | 'localModels' | 'fusion' | 'squelch' | 'folders' | 'credentials' | 'environment' | 'mcp'
  | 'tracing' | 'guardrails' | 'firewall' | 'supplyChain' | 'promptInjection' | 'pii'
  | 'appearance' | 'browser' | 'resources' | 'automation';

export type GroupID = 'Workspace' | 'Models' | 'Machine' | 'Security' | 'App';

export interface Category {
  id: CategoryID;
  /** rawValue — the sidebar label and the `bromure:open` category key. */
  label: string;
  group: GroupID;
  keywords: string;
  symbol: string;
  /** Gradient endpoints (top, bottom) measured from the native sidebar. */
  color: [string, string];
}

const C = {
  indigo: ['#8478ff', '#5a4ee5'], pink: ['#ff5078', '#f42449'], purple: ['#d555e5', '#b42ec7'],
  yellow: ['#ffd532', '#f4c000'], mint: ['#38d6c5', '#00bba7'], orange: ['#ffa755', '#f48423'],
  green: ['#56d877', '#24be4b'], teal: ['#38cfd9', '#00b1bd'], blue: ['#2f9aff', '#0076ef'],
  red: ['#ff5a5e', '#f42d30'], gray: ['#b0b0b4', '#8c8c91'], cyan: ['#38c8e7', '#00a9ce'],
} as const satisfies Record<string, readonly [string, string]>;

// Declaration order = EditorCategory.allCases (search keeps it; the sidebar
// groups it).
export const CATEGORIES: Category[] = [
  { id: 'general', label: 'General', group: 'Workspace', symbol: 'person.text.rectangle.fill', color: [...C.indigo],
    keywords: 'name color close login notes defaults task approved merge pull request kimi approvals never ask auto yolo sensitive reach delegation nickname' },
  { id: 'localModels', label: 'Models', group: 'Models', symbol: 'sparkles', color: [...C.purple],
    keywords: 'llm provider api key anthropic openai bedrock openrouter ollama vllm local subscription' },
  { id: 'fusion', label: 'Fusion', group: 'Models', symbol: 'bolt.fill', color: [...C.yellow],
    keywords: 'mount mac folders fusion' },
  { id: 'squelch', label: 'Squelch', group: 'Models', symbol: 'line.3.horizontal.decrease.circle.fill', color: [...C.mint],
    keywords: 'tokens noise output trim filter compress savings context cost test logs' },
  { id: 'folders', label: 'Folders', group: 'Machine', symbol: 'folder.fill', color: [...C.orange],
    keywords: 'shared folder mount directory' },
  { id: 'credentials', label: 'Credentials', group: 'Security', symbol: 'key.fill', color: [...C.green],
    keywords: 'keys tokens secrets ssh aws github password vault 1password' },
  { id: 'environment', label: 'Environment', group: 'Machine', symbol: 'terminal.fill', color: [...C.teal],
    keywords: 'env variables dotenv shell description auto mode safety servers staging production trusted' },
  { id: 'mcp', label: 'MCP', group: 'Machine', symbol: 'mcp', color: [...C.blue],
    keywords: 'tools servers mcp' },
  { id: 'tracing', label: 'Tracing', group: 'Security', symbol: 'doc.text.magnifyingglass', color: [...C.red],
    keywords: 'trace http log requests' },
  { id: 'guardrails', label: 'Guardrails', group: 'Security', symbol: 'exclamationmark.shield.fill', color: [...C.orange],
    keywords: 'credentials approval write policy kubernetes aws docker github destructive exfiltration' },
  { id: 'firewall', label: 'Sandbox Policy', group: 'Security', symbol: 'flame.fill', color: [...C.red],
    keywords: 'firewall sandbox openshell kernel sentry landlock egress outbound network connections block allow deny host port web methods interception proxy' },
  { id: 'supplyChain', label: 'Supply Chain', group: 'Security', symbol: 'shippingbox.fill', color: [...C.yellow],
    keywords: 'npm pypi packages age socket osv install scripts depi' },
  { id: 'promptInjection', label: 'Prompt Injection', group: 'Security', symbol: 'exclamationmark.triangle.fill', color: [...C.red],
    keywords: 'injection detector scan classifier' },
  { id: 'pii', label: 'PII Protection', group: 'Security', symbol: 'person.crop.circle.badge.checkmark', color: [...C.purple],
    keywords: 'privacy personal data names email phone gdpr redact anonymize pseudonymize' },
  { id: 'appearance', label: 'Appearance', group: 'Workspace', symbol: 'paintpalette.fill', color: [...C.pink],
    keywords: 'theme terminal font opacity dark' },
  { id: 'browser', label: 'Browser', group: 'Machine', symbol: 'globe', color: [...C.blue],
    keywords: 'chrome chromium web browser' },
  { id: 'resources', label: 'Resources', group: 'Machine', symbol: 'memorychip.fill', color: [...C.gray],
    keywords: 'cpu memory ram disk' },
  { id: 'automation', label: 'Automation', group: 'App', symbol: 'antenna.radiowaves.left.and.right', color: [...C.cyan],
    keywords: 'automation api control remote' },
];

export const GROUPS: GroupID[] = ['Workspace', 'Models', 'Machine', 'Security', 'App'];

/** Sidebar order within a group (the Swift `group` switch lists them in this order). */
export const GROUP_ORDER: Record<GroupID, CategoryID[]> = {
  Workspace: ['general', 'appearance'],
  Models: ['localModels', 'fusion', 'squelch'],
  Machine: ['folders', 'environment', 'mcp', 'browser', 'resources'],
  Security: ['credentials', 'tracing', 'guardrails', 'firewall', 'supplyChain', 'promptInjection', 'pii'],
  App: ['automation'],
};

export const category = (id: CategoryID) => CATEGORIES.find(c => c.id === id)!;

/** `bromure:open` / AppleScript-style key → category: case- and space-insensitive
 *  on the rawValue ("Sandbox Policy", "sandboxpolicy") or the id ("firewall"). */
export function resolveCategory(key?: string | null): CategoryID | undefined {
  if (!key) return undefined;
  const k = key.toLowerCase().replace(/[\s_-]/g, '');
  return CATEGORIES.find(c => c.label.toLowerCase().replace(/\s/g, '') === k || c.id.toLowerCase() === k)?.id;
}

/** The sidebar search: every word must appear in the label, keywords or group. */
export function searchCategories(visible: CategoryID[], q: string): CategoryID[] {
  const words = q.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) return visible;
  return visible.filter(id => {
    const c = category(id);
    const hay = `${c.label} ${c.keywords} ${c.group}`.toLowerCase();
    return words.every(w => hay.includes(w));
  });
}

// ── Profile document ────────────────────────────────────────────────────

/** `ProfileStore.templateID` — the Preferences template's fixed id. */
export const TEMPLATE_ID = 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB';

/** Profile.init(from:) defaults for keys the encoder leaves out. */
export const DEFAULTS: Doc = {
  folderPaths: [], color: 'blue', comments: '', memoryGB: 8, nativeTerminal: false,
  gitUserName: '', gitUserEmail: '', importedConfigFiles: [], useTerminalAppDefaults: true,
  fontLigatures: false, networkMode: 'nat', cursorShape: 'beam', cursorBlink: false, windowOpacity: 1.0,
  gitHTTPSCredentials: [], additionalTools: [], manualTokens: [], importedSSHKeys: [], environmentVariables: [],
  traceLevel: 'off', privateMode: false, browserPersistent: false, browserAllowUploads: true,
  browserAllowDownloads: true, browserWebcam: false, browserMicrophone: false, browserDisabled: false,
  fusionLegs: [], fusionJudgeLocal: false, modelRouting: 'cloud', subscriptionTokenSwap: 'unset', codexTokenSwap: 'unset',
  kubeconfigs: [], guardrails: {}, egressRules: '', networkPolicy: '', openShellProviders: [],
  openShellAdvisorMode: 'off', watchdogMode: 'off', disableTransparentProxy: false, strictCredentials: false,
  strictSandbox: false, kernelSentry: 'off', openShellCredentialPlaceholders: false, sandboxHomePackages: true,
  sandboxSystemPackages: true, disableExfiltrationAlerts: false, supplyChain: {}, promptInjection: {}, pii: {},
  squelch: {}, digitalOceanToken: '', linearToken: '', twilioCredential: {}, awsCredentials: {},
  bedrockEnabled: false, bedrockModelID: '', claudeGatewayModels: {}, dockerRegistries: [], httpDatabases: [],
  apiKeyRequiresApproval: false, digitalOceanTokenRequiresApproval: false, linearTokenRequiresApproval: false,
  sshKeyRequiresApproval: false, closeAction: 'ask', bootAtStartup: false, kimiApprovals: 'neverAsk',
  mcpServers: [], homeModel: 'virtiofs',
};

/** A field as the Swift Profile reads it: the document's value or its default. */
export function val<T = any>(doc: Doc, key: string): T {
  const v = doc[key];
  return (v === undefined || v === null ? DEFAULTS[key] : v) as T;
}

/** Transport-only keys the editor never sends back. */
const TRANSPORT_KEYS = new Set(['_secretsRedacted', 'configuredCredentialRefs']);

export function deepEqual(a: any, b: any): boolean {
  if (a === b) return true;
  if (typeof a !== typeof b || a === null || b === null || typeof a !== 'object') return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  if (Array.isArray(a)) return a.length === b.length && a.every((x, i) => deepEqual(x, b[i]));
  const ka = Object.keys(a), kb = Object.keys(b);
  return ka.length === kb.length && ka.every(k => deepEqual(a[k], b[k]));
}

/** FatClientController.settingsDocument: what the user changed, nothing else. */
export function settingsDocument(edited: Doc, opened: Doc): Doc {
  const out: Doc = {};
  for (const k of Object.keys(edited)) {
    if (TRANSPORT_KEYS.has(k)) continue;
    if (!deepEqual(edited[k], opened[k])) out[k] = edited[k] === undefined ? null : edited[k];
  }
  for (const k of Object.keys(opened)) {
    if (TRANSPORT_KEYS.has(k)) continue;
    if (!(k in edited) || edited[k] === undefined) out[k] = null;
  }
  // The last kube context removed: an explicit empty list (a null would leave
  // the host's contexts as they are).
  if ((edited.kubeconfigs ?? []).length === 0 && (opened.kubeconfigs ?? []).length > 0) out.kubeconfigs = [];
  return out;
}

/** The whole document for PUT /preferences and POST /profiles. */
export function wholeDocument(edited: Doc): Doc {
  const out: Doc = {};
  for (const [k, v] of Object.entries(edited)) if (!TRANSPORT_KEYS.has(k) && v !== undefined) out[k] = v;
  if (!out.kubeconfigs || out.kubeconfigs.length === 0) out.kubeconfigs = [];
  return out;
}

/** RemoteHostController.restartRequiringChanges — fields baked in at boot. */
export function restartRequiringChanges(old: Doc, now: Doc): boolean {
  return ['memoryGB', 'homeImageGB', 'networkMode', 'bridgedInterfaceID', 'folderPaths', 'tool', 'authMode',
    'additionalTools', 'sshPublicKey', 'importedSSHKeys', 'kubeconfigs', 'awsCredentials']
    .some(k => !deepEqual(val(old, k), val(now, k)));
}

/** Profile.Tool display names (Profile.swift `displayName`). */
export const TOOLS = ['claude', 'codex', 'grok', 'kimi', 'omp', 'hermes'] as const;
export type Tool = typeof TOOLS[number];
export const TOOL_NAME: Record<Tool, string> = {
  claude: 'Claude Code', codex: 'Codex', grok: 'Grok Build', kimi: 'Kimi Code', omp: 'Oh My Pi', hermes: 'Hermes Agent',
};
export const TOOL_SYMBOL: Record<Tool, string> = {
  claude: 'sparkles', codex: 'terminal.fill', grok: 'bolt.fill', kimi: 'moon.stars.fill', omp: 'option', hermes: 'paperplane',
};

export const PROFILE_COLORS = ['blue', 'red', 'green', 'orange', 'purple', 'pink', 'teal', 'gray'] as const;
export const capitalize = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
