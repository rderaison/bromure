// The mirror window for one remote Bromure (RemoteHostWindow): titlebar/
// toolbar strip, resizable sidebar, the stage, the Files pane, and the
// reconnecting veil. Feature modules fill each region.

import React, { useEffect, useRef, useState } from 'react';
import type { RemoteHost } from '../core/remote/host';
import { HostCtxProvider, useHostCtx, usePersisted } from './hostContext';
import { WindowHost } from './windows';
import { useHost } from './store';
import { Toolbar } from '../features/toolbar/Toolbar';
import { Sidebar } from '../features/sidebar/Sidebar';
import { Stage } from '../features/stage/Stage';
import { ErrorBoundary } from './ErrorBoundary';
import { ReconnectingVeil } from '../features/connect/ReconnectingVeil';
import { TerminalDevHarness } from '../features/terminal/DevHarness';   // dev-only (?term= / ?room=)
import { EditorEventBridge } from '../features/editor';
import { SecurityEventBridge } from '../features/security';
import { GlobalShortcuts, PaletteHost } from '../features/palette';
import { NewSessionHost } from '../features/newsession';
import { BoardsEventBridge } from '../features/boards';
import { IntegrationBridge } from './IntegrationBridge';
import { FilePane, MachinesEventBridge } from '../features/machines';
import './hostWindow.css';

export function HostWindow({ host }: { host: RemoteHost }) {
  useHost(host);
  return (
    <HostCtxProvider host={host}>
      <WindowHost>
        <HostWindowBody />
      </WindowHost>
    </HostCtxProvider>
  );
}

const SIDEBAR_MIN = 220, SIDEBAR_MAX = 420, SIDEBAR_DEFAULT = 259, SIDEBAR_RAIL = 44, SIDEBAR_COLLAPSE_AT = 160;

function HostWindowBody() {
  const { host, sidebarCollapsed, setSidebarCollapsed, selection, select } = useHostCtx();
  const [width, setWidth] = usePersisted('bromure.sidebarWidth', SIDEBAR_DEFAULT);
  const [drag, setDrag] = useState(false);
  const startResize = (e: React.MouseEvent) => {
    e.preventDefault(); setDrag(true);
    const sx = e.clientX, sw = width;
    // Past the minimum it snaps to the 44pt icon rail; back past it expands (fat client).
    const mm = (ev: MouseEvent) => {
      const w = (sidebarCollapsed ? SIDEBAR_RAIL : sw) + ev.clientX - sx;
      if (w < SIDEBAR_COLLAPSE_AT) { setSidebarCollapsed(true); return; }
      setSidebarCollapsed(false);
      setWidth(Math.max(SIDEBAR_MIN, Math.min(SIDEBAR_MAX, w)));
    };
    const mu = () => { setDrag(false); window.removeEventListener('mousemove', mm); window.removeEventListener('mouseup', mu); };
    window.addEventListener('mousemove', mm); window.addEventListener('mouseup', mu);
  };
  return (
    <div className="hw">
      <Toolbar />
      <div className="hw-main">
        {(
          <aside className="hw-sidebar" style={{ width: sidebarCollapsed ? SIDEBAR_RAIL : width }}>
            <ErrorBoundary name="sidebar"><Sidebar /></ErrorBoundary>
            <div className={'hw-divider' + (drag ? ' dragging' : '')} onMouseDown={startResize} />
          </aside>
        )}
        <main className="hw-stage"><ErrorBoundary name="stage" resetKey={JSON.stringify(selection)} onReset={() => select({ kind: 'home' })}><Stage /></ErrorBoundary><TerminalDevHarness /></main>
        <FilePane />
      </div>
      <EditorEventBridge />
      <SecurityEventBridge />
      <BoardsEventBridge />
      <IntegrationBridge />
      <MachinesEventBridge />
      <GlobalShortcuts /><PaletteHost /><NewSessionHost />
      {(host.status === 'reconnecting' || host.status === 'connecting' || host.status === 'failed') && <ReconnectingVeil />}
    </div>
  );
}
