// The mirror window's titlebar strip (52pt, unified toolbar): the window
// controls area on the left (Electron draws working traffic lights; the
// hosted app leaves the strip empty — the browser owns the window), and the
// trailing control cluster — UnifiedToolbarBar / RemoteToolbarBar
// (UnifiedSessionWindow.swift, FatClientController.swift): the Terminal ⇄
// Chat pill, the machine menu (colour + name + chevron), the browser globe
// and the Files pane toggle. A session whose machine is asleep (and the
// new-session screen) keep the same controls in the same places, dimmed.
//
// The whole strip is an Electron drag region; every control opts out.
//
// Events EMITTED (window CustomEvent 'bromure:open'):
//   settings      { profileID }   machine menu › Settings…
//   trace         { profileID }   machine menu › Inspect Trace
//   toggle-browser                 the globe (⌃⌘B)
// Selection: machine menu › Machine Details → select({kind:'workspace', workspaceID}).

import React, { useMemo } from 'react';
import { shell, electron, isMac } from '../../platform';
import { Lights } from '../../app/windows';
import { useHostCtx } from '../../app/hostContext';
import { useRemote, useHost, closeConnection } from '../../app/store';
import { account } from '../connect/account';
import { MenuBar } from '../menubar/MenuBar';
import { useMenu, cx, type MenuItem } from '../../ui/kit';
import { SF } from '../../ui/icons';
import { useListModel } from '../sidebar/Sidebar';
import { workspaceActions, openSurface } from '../sidebar/actions';
import * as M from '../sidebar/model';
import './toolbar.css';

const ctrlCmd = isMac ? '⌃⌘' : 'Ctrl+Alt+';
const optCmd = isMac ? '⌥⌘' : 'Ctrl+Alt+';

export function Toolbar() {
  return (
    <div className="tb" data-shell={shell}>
      {shell === 'electron'
        ? <div className="tb-lights"><Lights onClose={() => electron!.windowControl('close')} onMinimize={() => electron!.windowControl('minimize')} onZoom={() => electron!.windowControl('maximize')} /></div>
        : <div style={{ width: 78 }} />}
      <MenuBar />
      <ServerMenu />
      <div className="tb-flex" />
      <ToolbarBar />
    </div>
  );
}

/** Which server this window mirrors, and the way out of it: connect to
 *  another server, disconnect, sign out of bromure.io. (On the Mac these live
 *  in the menu bar — Workspaces › Connect to Remote Bromure… — which a web
 *  window doesn't have.) */
function ServerMenu() {
  const { host } = useHostCtx();
  useHost(host);
  const menu = useMenu();
  const signedIn = !!account.get().record;
  const sc = isMac ? '⇧⌘K' : 'Ctrl+Shift+K';
  const live = host.status === 'connected';
  const open = (e: React.MouseEvent) => {
    const items: MenuItem[] = [
      { header: host.target.name },
      { label: 'Connect to Another Server…', icon: 'network', shortcut: sc, action: () => openSurface('connect') },
      { label: 'Disconnect', icon: 'xmark.circle', action: () => { closeConnection(host.target.id); location.hash = '#/'; } },
    ];
    if (signedIn) items.push({ separator: true }, {
      label: 'Sign Out of bromure.io', icon: 'rectangle.portrait.and.arrow.right', destructive: true,
      action: async () => { closeConnection(host.target.id); await account.signOut(); location.hash = '#/'; },
    });
    menu((e.currentTarget as HTMLElement).getBoundingClientRect(), items, 240);
  };
  return (
    <button className="tb-server" onClick={open} title="Connected server: connect to another, disconnect or sign out">
      <span className="tb-server-dot" style={{ background: live ? 'var(--green)' : host.status === 'failed' ? 'var(--red)' : 'var(--orange)' }} />
      <span className="tb-server-name">{host.target.name}</span>
      <SF name="chevron.down" size={9} weight={700} />
    </button>
  );
}

function ToolbarBar() {
  const { host, selection, select, viewMode, setViewMode, filePaneOpen, setFilePaneOpen } = useHostCtx();
  const sessions = useRemote(host, s => s.agentSessions) ?? [];
  const m = useListModel();

  const session = selection.kind === 'session' ? sessions.find(s => s.id === selection.sessionID) : undefined;
  const sessionOnStage = selection.kind === 'session' || selection.kind === 'new-session';
  // The machine the bar acts on: the session's own, else the selected machine.
  const profileID = selection.kind === 'session' ? session?.profileID
    : selection.kind === 'workspace' || selection.kind === 'docker' ? selection.workspaceID : undefined;
  const entry = profileID ? m.entries.find(e => e.id === profileID) : undefined;
  const restingRow = !entry && selection.kind === 'session' && profileID ? m.rows.find(r => r.id === profileID) : undefined;
  const placeholder = !!restingRow || selection.kind === 'new-session';
  const terminalShown = viewMode === 'terminal';
  // A machine's tab that hosts a session: the way back to it.
  const activeIndex = selection.kind === 'workspace' ? (selection.windowIndex ?? entry?.tabs.find(t => t.active)?.index) : undefined;
  const hostedSession = selection.kind === 'workspace' && entry
    ? sessions.find(s => s.profileID === entry.id && s.windowIndex === activeIndex && !M.isDeleted(s) && !M.hasEnded(s))
    : undefined;

  const toggleBrowser = () => openSurface('toggle-browser');
  const toggleFiles = () => setFilePaneOpen(!filePaneOpen);
  const toggleLinux = () => {
    if (selection.kind === 'session') { setViewMode(terminalShown ? 'chat' : 'terminal'); return; }
    if (hostedSession) { setViewMode('chat'); select({ kind: 'session', sessionID: hostedSession.id }); }
  };

  const globeHelp = `Show or hide the agentic browser (${ctrlCmd}B)`;
  const filesHelp = `Show or hide the Files pane (${ctrlCmd}E)`;
  return (
    <div className="tb-bar">
      {placeholder && <>
        <LinuxPill back={false} disabled onClick={() => {}} help="The Linux machine behind this session — available while it runs" />
        {restingRow && <MachineMenu name={restingRow.name} accentHex={restingRow.accentHex} profileID={restingRow.id} running={false} />}
        <HeaderIcon system="globe" help={globeHelp} disabled onClick={() => {}} />
        <HeaderIcon system="sidebar.right" help={filesHelp} active={filePaneOpen} onClick={toggleFiles} />
      </>}
      {selection.kind === 'room' && <>
        <HeaderIcon system="globe" help={globeHelp} onClick={toggleBrowser} />
        <HeaderIcon system="sidebar.right" help={filesHelp} active={filePaneOpen} onClick={toggleFiles} />
      </>}
      {entry && selection.kind !== 'new-session' && <>
        {!sessionOnStage && <FusionToggle entry={entry} />}
        {selection.kind === 'session'
          ? <LinuxPill back={false} chat={terminalShown} onClick={toggleLinux} />
          : hostedSession && <LinuxPill back onClick={toggleLinux} />}
        <MachineMenu name={entry.name} accentHex={m.rows.find(r => r.id === entry.id)?.accentHex ?? entry.accentHex} profileID={entry.id}
                     running ip={entry.ip} />
        <HeaderIcon system="globe" help={globeHelp} onClick={toggleBrowser} />
        <HeaderIcon system="sidebar.right" help={filesHelp} active={filePaneOpen} onClick={toggleFiles} />
      </>}
    </div>
  );
}

function HeaderIcon({ system, help, active, disabled, onClick }: { system: string; help: string; active?: boolean; disabled?: boolean; onClick: () => void }) {
  return (
    <button className={cx('tb-icon', active && 'active')} title={help} disabled={disabled} onClick={onClick}>
      <SF name={system} size={16} />
    </button>
  );
}

function LinuxPill({ back, chat, disabled, help, onClick }: { back: boolean; chat?: boolean; disabled?: boolean; help?: string; onClick: () => void }) {
  const label = back ? 'Session' : chat ? 'Chat' : 'Terminal';
  const tip = help ?? (back ? `Back to the session this terminal hosts (${optCmd}U)`
    : chat ? `Show this session as a chat (${optCmd}U)` : `Show this session's terminal (${optCmd}U)`);
  return (
    <button className="tb-pill" disabled={disabled} title={tip} onClick={onClick}>
      <SF name={back || chat ? 'text.bubble' : 'terminal'} size={14} />
      <span>{label}</span>
    </button>
  );
}

function FusionToggle({ entry }: { entry: M.VMEntry }) {
  const { host } = useHostCtx();
  const configurable = entry.vm.fusionConfigurable === true;
  const engaged = entry.vm.fusionEngaged === true;
  return (
    <button className="tb-icon" disabled={!configurable}
            title={configurable ? (engaged ? 'Fusion engaged — click to disengage' : 'Fusion available — click to engage') : 'Enable at least two models to use Fusion'}
            onClick={() => host.send('POST', `/vms/${encodeURIComponent(entry.id)}/fusion`, { engaged: !engaged })}>
      <SF name={configurable ? 'bolt.fill' : 'bolt'} size={16}
          color={!configurable ? 'var(--label-secondary)' : engaged ? 'var(--yellow)' : 'var(--label)'} />
    </button>
  );
}

function MachineMenu({ name, accentHex, profileID, running, ip }: { name: string; accentHex: string; profileID: string; running: boolean; ip?: string }) {
  const { host, select } = useHostCtx();
  const menu = useMenu();
  const wa = useMemo(() => workspaceActions(host), [host]);
  const open = (e: React.MouseEvent<HTMLButtonElement>) => {
    const r = e.currentTarget.getBoundingClientRect();
    const alt = e.altKey;
    const items: MenuItem[] = [];
    if (!running) items.push({ label: 'Not running — starts with your next message', disabled: true }, { separator: true });
    items.push({ label: 'Settings…', icon: 'gearshape', action: () => openSurface('settings', { profileID }) });
    items.push({ label: 'Machine Details', icon: 'cpu', action: () => select({ kind: 'workspace', workspaceID: profileID }) });
    if (ip && running) items.push({ label: `Copy IP Address (${ip})`, icon: 'network', action: () => { navigator.clipboard?.writeText(ip).catch(() => {}); } });
    if (running) {
      items.push({ separator: true });
      items.push({ label: 'Inspect Trace', icon: 'doc.text.magnifyingglass', action: () => openSurface('trace', { profileID }) });
      items.push({ separator: true });
      items.push(alt ? { label: 'Force Reboot', icon: 'bolt.circle', action: () => wa.reboot(profileID, name, true) }
                     : { label: 'Reboot', icon: 'arrow.clockwise.circle', action: () => wa.reboot(profileID, name, false) });
    }
    menu(new DOMRect(r.left, r.bottom, r.width, 0), items);
  };
  return (
    <button className="tb-machine" onClick={open} title="The machine: its settings, trace, reboot…">
      <span className="tb-machine-dot" style={{ background: accentHex, opacity: running ? 1 : 0.4 }} />
      <span className="tb-machine-name">{name}</span>
      <SF name="chevron.down" size={10} weight={700} className="tb-machine-chev" />
    </button>
  );
}
