// What every pane of the configuration editor gets: the draft document and
// how to change it, plus what the host told us around it. One context per
// editor window (ProfileEditorView's @State + the closures its host passes).

import { createContext, useContext } from 'react';
import type { RemoteHost } from '../../core/remote/host';
import type { Doc, CategoryID } from './model';

export type EditorMode = 'workspace' | 'new' | 'preferences';

export interface StorageInfo {
  baseBytes: number; baseVersion?: string; baseBuildDate?: string;
  hasDisk: boolean; diskBytes: number; hasHome: boolean; homeBytes: number; homeCapacity: number;
  homeIsImage: boolean; homeModified?: string; isRunning: boolean; defaultHomeGB?: number;
}

export interface EditorCtxValue {
  host: RemoteHost;
  mode: EditorMode;
  /** The workspace being edited (absent for Preferences and a new workspace). */
  workspaceID?: string;
  /** The draft (the wire document, secrets blanked). Read fields with `val()`. */
  doc: Doc;
  /** The document as the editor opened it (the save diff's baseline). */
  opened: Doc;
  /** Set one top-level field. */
  set: (key: string, value: any) => void;
  /** Change the draft through a mutable copy (nested edits). */
  update: (fn: (d: Doc) => void) => void;
  /** Preferences: the template (no Name, no per-machine rows). */
  isTemplate: boolean;
  isNew: boolean;
  /** Server-computed credential ids (`configuredCredentialRefs`): blanked
   *  secrets would otherwise hide every secret-bearing credential. */
  credentialRefs: string[];
  /** The other workspaces on this host (reach policy, MCP delegation…). */
  siblings: { id: string; name: string }[];
  /** The host's global model settings (GET /models/settings): a workspace's
   *  Models pane inherits from them; Preferences edits them (draft). */
  globalModels: Doc;
  /** Preferences only: edit the global model settings draft (PUT on Save). */
  setGlobalModels?: (fn: (m: Doc) => void) => void;
  /** The workspace's storage layers as the server measures them (Resources). */
  storage: StorageInfo | null;
  refreshStorage: () => void;
  /** The host's app default for "When a task is approved" (its template's). */
  appTaskFinish: 'merge' | 'pullRequest';
  /** "Generate SSH key" on save (Credentials). */
  generateSSH: boolean;
  setGenerateSSH: (v: boolean) => void;
  /** A pane that can't be saved as it is (a broken OpenShell policy…) says so
   *  under its key; any such key disables Save. null clears it. */
  setInvalid: (key: string, reason: string | null) => void;
  /** Sandbox Policy: the rules changed — put them in force now (the host puts
   *  the opening ones back unless the editor is saved). */
  firewallEdited: (rules: string) => void;
  /** Switch the sidebar to another pane ("set it up in Preferences › Models"…). */
  select: (c: CategoryID) => void;
  /** Open the host's Preferences on a pane (links from a workspace editor). */
  openPreferences: (c?: CategoryID) => void;
  hostName: string;
}

export const EditorCtx = createContext<EditorCtxValue | null>(null);
export function useEditor(): EditorCtxValue {
  const v = useContext(EditorCtx);
  if (!v) throw new Error('useEditor outside the editor');
  return v;
}
