// The security windows of a mirrored host: Security (Overview + Timeline,
// with the network-lineage sheet), the Trace Inspector (⇧⌘I), and the
// host's decision prompts (consent, compromise) shown as sheets.
//
// Open from anywhere: `openSecurity(wm, host, tab?)`,
// `openTraceInspector(wm, host, workspaceID?)`, or
//   window.dispatchEvent(new CustomEvent('bromure:open', { detail: { what: 'security' | 'trace' | 'lineage', … } }))
// which `SecurityEventBridge` (mounted in HostWindow) turns into windows.

export { openSecurity, openTraceInspector, SecurityEventBridge } from './bridge';
export { confirmCompromiseRemedy } from './prompts/PromptsOverlay';
export { securityStore } from './model';
export type { SecEvent } from './model';
