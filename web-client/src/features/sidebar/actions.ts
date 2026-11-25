// The fat client's SessionStageActions + the sidebar's workspace verbs
// (RemoteHostWindow.baseSessionStageActions / makeSidebar in
// FatClientController.swift), over the same server routes.

import type { RemoteHost } from '../../core/remote/host';
import { seg } from '../../core/remote/host';
import type { AgentSession } from '../../core/remote/types';
import type { StageSelection } from '../../app/hostContext';
import { branchNeedsWord, branchSummary, isAgentLive, initialSession, type ListModel } from './model';
import { showAlert, confirmAlert } from './Dialogs';

/** `bromure:open` — see the event list at the top of Sidebar.tsx. */
export function openSurface(what: string, args: Record<string, unknown> = {}) {
  window.dispatchEvent(new CustomEvent('bromure:open', { detail: { what, ...args } }));
}

export interface ActionCtx {
  host: RemoteHost;
  selection: StageSelection;
  select: (s: StageSelection) => void;
  sessions: () => AgentSession[];
  model: () => ListModel;
}

export function sessionCommand(host: RemoteHost, id: string, action: string, body?: unknown) {
  host.send('POST', `/agent-sessions/${seg(id)}/${action}`, body ?? {});
}

async function roomCommand(host: RemoteHost, id: string | null, action: string, body: unknown = {}): Promise<any | null> {
  try {
    const r = await host.request('POST', '/agent-rooms/' + (id ? seg(id) + '/' : '') + action, body);
    host.refreshSoon();
    return r;
  } catch (e) { console.warn('room', action, e); host.refreshSoon(); return null; }
}

/** After a session leaves the stage (deleted / discarded): the new-session screen. */
function leaveStage(c: ActionCtx, id: string) {
  if (c.selection.kind === 'session' && c.selection.sessionID === id) {
    c.select({ kind: 'new-session' });
    openSurface('new-session');
  }
}

async function askBranchFate(c: ActionCtx, s: AgentSession, deleting: boolean) {
  const branch = s.worktreeBranch as string | undefined;
  if (!branch) return;
  const info = s.branchInfo as any;
  const empty = !!info && !(info.ahead > 0) && !(info.changed > 0);
  const sum = branchSummary(s);
  const title = deleting ? `Delete “${s.title}” — and its branch?` : `Archive “${s.title}” — and its branch?`;
  const msg = empty
    ? `Nothing was done on ${branch} yet, so there's nothing to lose by removing it.`
    : `${branch} has work that isn't merged${sum ? ' (' + sum + ')' : ''}. Keep it to merge or pick it up later, or discard it.`;
  const keep = { label: 'Keep Branch', value: 'keep' };
  const discard = { label: 'Discard Branch', value: 'discard', destructive: !empty };
  const v = await showAlert(title, msg, [...(empty ? [discard, keep] : [keep, discard]), { label: 'Cancel', value: 'cancel' }]);
  if (!v) return;
  if (v === 'discard') sessionCommand(c.host, s.id, 'branch-discard');
  else { sessionCommand(c.host, s.id, 'branch-keep'); sessionCommand(c.host, s.id, deleting ? 'delete' : 'archive'); }
  if (deleting || v === 'discard') leaveStage(c, s.id);
}

export function sessionActions(c: ActionCtx) {
  const find = (id: string) => c.sessions().find(s => s.id === id);
  return {
    resume: (id: string) => sessionCommand(c.host, id, 'resume'),
    close: (id: string) => sessionCommand(c.host, id, 'close'),
    archive: (id: string) => {
      const s = find(id);
      if (s && branchNeedsWord(s)) { askBranchFate(c, s, false); return; }
      sessionCommand(c.host, id, 'archive');
    },
    unarchive: (id: string) => sessionCommand(c.host, id, 'unarchive'),
    delete: async (id: string) => {
      const s = find(id);
      if (!s) return;
      if (branchNeedsWord(s)) { askBranchFate(c, s, true); return; }
      if (isAgentLive(s, c.model())) {
        const ok = await confirmAlert(`Delete “${s.title}”?`, 'The agent stops and the session leaves the list. Its folder stays on the machine.', 'Delete');
        if (!ok) return;
      }
      sessionCommand(c.host, id, 'delete');
      leaveStage(c, id);
    },
    setNickname: (id: string, nick: string, reclaim: boolean) => sessionCommand(c.host, id, 'nickname', { nickname: nick, reclaim }),
    mergeBranch: (id: string, into: string | null, squash: boolean, removeAfter: boolean) =>
      sessionCommand(c.host, id, 'branch-merge', { squash, removeAfter, ...(into ? { into } : {}) }),
    branchPullRequest: (id: string) => sessionCommand(c.host, id, 'branch-pr'),
    discardBranch: async (id: string) => {
      const s = find(id);
      const branch = s?.worktreeBranch as string | undefined;
      if (!s || !branch) return;
      const sum = branchSummary(s);
      const ok = await confirmAlert(`Discard “${s.title}”?`,
        `The branch ${branch} and its checkout are deleted with the session${sum ? ' (' + sum + ')' : ''}. This can't be undone.`, 'Discard', true);
      if (!ok) return;
      sessionCommand(c.host, id, 'branch-discard');
      leaveStage(c, id);
    },
    openSwitchboard: async () => {
      const sb = c.sessions().find(s => s.role === 'switchboard' && !s.deletedAt && !s.roomID);
      if (sb && !(sb.endedAt && sb.windowIndex == null) && sb.windowIndex != null) { c.select({ kind: 'session', sessionID: sb.id }); return; }
      try {
        const r = await c.host.request('POST', '/agent-sessions/switchboard', {});
        c.host.refreshSoon();
        if (r?.id) c.select({ kind: 'session', sessionID: r.id });
      } catch (e) { console.warn('switchboard', e); }
    },
    openLinux: (id: string) => {
      const s = find(id);
      if (!s) return;
      c.select({ kind: 'workspace', workspaceID: s.profileID, windowIndex: s.windowIndex as number | undefined });
    },
    editMachine: (profileID: string) => openSurface('settings', { profileID }),
    // Rooms
    openRoom: (id: string) => c.select({ kind: 'room', roomID: id }),
    newRoom: async (name: string, sessionID?: string) => {
      const r = await roomCommand(c.host, null, 'create', { name, sessions: sessionID ? [sessionID] : [] });
      if (r?.id) c.select({ kind: 'room', roomID: r.id });
    },
    moveToRoom: (sessionID: string, roomID: string | null) =>
      roomCommand(c.host, null, 'move', { session: sessionID, ...(roomID ? { room: roomID } : {}) }),
    renameRoom: (id: string, name: string) => roomCommand(c.host, id, 'rename', { name }),
    setRoomColor: (id: string, hex: string) => roomCommand(c.host, id, 'color', { hex }),
    archiveRoom: (id: string) => roomCommand(c.host, id, 'archive'),
    unarchiveRoom: (id: string) => roomCommand(c.host, id, 'unarchive'),
    ungroupRoom: (id: string) => {
      if (c.selection.kind === 'room' && c.selection.roomID === id) selectInitial(c);
      roomCommand(c.host, id, 'ungroup');
    },
    deleteRoom: async (id: string, name: string) => {
      const ok = await confirmAlert(`Delete “${name}” and every session in it?`,
        'Their agents stop and the sessions leave the list. Their folders stay on the machines. To keep the sessions, ungroup the room instead.', 'Delete Room', true);
      if (!ok) return;
      if (c.selection.kind === 'room' && c.selection.roomID === id) selectInitial(c);
      roomCommand(c.host, id, 'delete');
    },
    newSessionInRoom: (id: string) => { c.select({ kind: 'new-session', roomID: id }); openSurface('new-session', { room: id }); },
    groupSessions: async (dragged: string, onto: string) => {
      const r = await roomCommand(c.host, null, 'group', { dragged, onto });
      if (r?.id) c.select({ kind: 'room', roomID: r.id });
    },
  };
}
export type SessionActions = ReturnType<typeof sessionActions>;

export function selectInitial(c: ActionCtx) {
  const s = initialSession(c.sessions(), c.model());
  if (s) c.select({ kind: 'session', sessionID: s.id });
  else { c.select({ kind: 'new-session' }); openSurface('new-session'); }
}

// ── workspace (VM) verbs ─────────────────────────────────────────────────

export const workspaceActions = (host: RemoteHost) => ({
  start: (id: string) => host.send('POST', '/vms', { profile: id, detach: true }),
  shutdown: (id: string) => host.send('DELETE', `/vms/${seg(id)}`, { action: 'shutdown' }),
  suspend: (id: string) => host.send('DELETE', `/vms/${seg(id)}`, { action: 'suspend' }),
  reboot: async (id: string, name: string, force: boolean) => {
    const ok = force
      ? await confirmAlert(`Force reboot “${name}”?`, "Cuts the machine's power at once and boots it fresh, like pulling the plug: anything unsaved inside it is lost. For a machine that doesn't respond.", 'Force Reboot')
      : await confirmAlert(`Reboot “${name}”?`, 'Shuts the machine down cleanly and boots it fresh. Everything running inside it stops. (Hold Alt while choosing Reboot to force it.)', 'Reboot');
    if (ok) host.send('POST', `/vms/${seg(id)}/reboot`, { mode: force ? 'hard' : 'soft' });
  },
  newTab: (id: string) => host.send('POST', `/sessions/${seg(id)}/tab`, { action: 'new' }),
  selectTab: (id: string, index: number) => host.send('POST', `/sessions/${seg(id)}/tab`, { action: 'select', index }),
  closeTab: (id: string, index: number) => host.send('POST', `/sessions/${seg(id)}/tab`, { action: 'close', index }),
  deleteWorkspace: async (id: string, name: string) => {
    const ok = await confirmAlert(`Delete workspace “${name}”?`, 'Removes its disk, settings, and SSH key. The mounted host folder is untouched.', 'Delete', true);
    if (!ok) return;
    try { await host.request('DELETE', `/profiles/${seg(id)}`); host.refreshSoon(); }
    catch (e: any) { await showAlert(`Couldn't delete “${name}”`, e?.message || "The server didn't answer.", [{ label: 'OK', value: 'ok', default: true }]); }
  },
  compromise: async (id: string, name: string, remedy: 'wipe' | 'clear') => {
    const [title, msg, button] = remedy === 'wipe'
      ? [`Wipe “${name}”?`, "Its system disk, home, and saved state are erased; its settings and credentials stay, and so do the project folders it mounts. It's no longer marked compromised and boots fresh next time.", 'Wipe']
      : [`Clear the compromised mark on “${name}”?`, 'Only if it was a false alarm: the workspace starts on its current disk and home, without the wipe, as if nothing had happened. The leak itself was blocked either way; the Security Timeline keeps the event.', 'Clear Mark'];
    const v = await showAlert(title, msg, [{ label: button, value: 'ok', destructive: true }, { label: 'Cancel', value: 'cancel', default: true }]);
    if (v !== 'ok') return;
    try { await host.request('POST', `/profiles/${seg(id)}/compromised`, { action: remedy }); host.refreshSoon(); }
    catch (e: any) {
      await showAlert(remedy === 'wipe' ? `Couldn't wipe “${name}”` : `Couldn't clear the mark on “${name}”`, e?.message || "The server didn't answer.", [{ label: 'OK', value: 'ok', default: true }]);
    }
  },
});
