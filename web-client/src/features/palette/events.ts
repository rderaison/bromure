// Cross-surface commands. The palette, the global shortcuts and the menus
// don't import the surfaces they open — they dispatch a window CustomEvent
// `bromure:open` with `{ what, ...args }`, and the surface that owns it
// listens (useOpenListener). Known `what` values:
//
//   palette            toggle the ⌘K command palette               (palette)
//   new-session        the new-session screen; { room? }           (newsession)
//   connect            back to "Connect to Remote Bromure"         (App route)
//   preferences        the server's Preferences (template)
//   security           Security (timeline)
//   trace              Trace Inspector
//   task-board         Coding Tasks board
//   automation-board   Automations board
//   machines           the Machines overview
//   machine            a machine's dashboard; { profileID }
//   settings           a machine's settings; { profileID }
//   branches           Branches window; { profileID }
//   new-room           "New Room…" prompt
//   new-machine        new workspace / machine editor
//   new-branch         New Branch… for a session; { sessionID }
//   review-branch      Review Changes for a session; { sessionID }
//   merge-branch       Merge into parent; { sessionID }
//   toggle-files       Files pane

import { useEffect, useRef } from 'react';

export interface OpenDetail { what: string; [k: string]: unknown }

export function openSurface(what: string, args: Record<string, unknown> = {}) {
  window.dispatchEvent(new CustomEvent<OpenDetail>('bromure:open', { detail: { what, ...args } }));
}

/** Listen for `bromure:open` events (the handler can change between renders). */
export function useOpenListener(handler: (d: OpenDetail) => void) {
  const ref = useRef(handler);
  ref.current = handler;
  useEffect(() => {
    const on = (e: Event) => { const d = (e as CustomEvent<OpenDetail>).detail; if (d?.what) ref.current(d); };
    window.addEventListener('bromure:open', on);
    return () => window.removeEventListener('bromure:open', on);
  }, []);
}
