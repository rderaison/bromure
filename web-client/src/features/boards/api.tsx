// Coding Tasks + Automations: the boards, their editors and their windows.
//
//   openTaskBoard(wm, host)              the coding kanban (⇧⌘T)
//   openNewTask(wm, host)                the board with a blank task's editor
//   openAutomationBoard(wm, host, tab?)  the Automations hub (⇧⌘A), Runs tab by default
//   openAutomationEditor(wm, host, id?)  the automation editor window (new when no id)
//
// Anything can ask for them with
//   window.dispatchEvent(new CustomEvent('bromure:open', { detail: { what, id? } }))
// what: 'task-board' | 'automation-board' | 'new-task' | 'new-automation' | 'automation'
// (handled by <BoardsEventBridge/>, mounted once per host window). The board
// views are exported too, for a stage that wants to show them in place (the
// native app's stage surface).

import React, { useEffect } from 'react';
import type { RemoteHost } from '../../core/remote/host';
import { useHostCtx } from '../../app/hostContext';
import { useWindows, type WindowSpec } from '../../app/windows';
import { TaskBoardView } from './TaskBoard';
import { AutomationHubView, type HubTab } from './AutomationHub';
import { openAutomationEditor } from './AutomationEditor';
import { openRunWindow } from './RunWindow';
import { openTaskReview, openTaskTranscript } from './TaskReview';
import { ConfirmHost } from './kanban';

type WM = { open: (w: WindowSpec) => void; close: (id: string) => void };

/** The stage area of the native main window (1320×944 minus sidebar and toolbar). */
const BOARD_W = 1100, BOARD_H = 820;

export function openTaskBoard(wm: WM, host: RemoteHost, newTask = false) {
  wm.open({
    id: 'task-board', title: 'Coding Tasks', width: BOARD_W, height: BOARD_H, minWidth: 520, minHeight: 360,
    render: () => <TaskBoardView host={host} newTaskToken={newTask ? Date.now() : undefined} />,
  });
}
export const openNewTask = (wm: WM, host: RemoteHost) => openTaskBoard(wm, host, true);

export function openAutomationBoard(wm: WM, host: RemoteHost, tab?: HubTab) {
  wm.open({
    id: 'automation-board', title: 'Automations', width: BOARD_W, height: BOARD_H, minWidth: 560, minHeight: 360,
    render: () => <AutomationHubView host={host} initialTab={tab} />,
  });
}

export { openAutomationEditor, openRunWindow, openTaskReview, openTaskTranscript, TaskBoardView, AutomationHubView };

/** Opens the boards on `bromure:open` events; hosts the boards' confirmation dialogs. */
export function BoardsEventBridge() {
  const { host, select } = useHostCtx();
  const wm = useWindows();
  useEffect(() => {
    const on = (e: Event) => {
      const d = (e as CustomEvent).detail ?? {};
      switch (d.what) {
        // On the stage, like the Mac window (openTaskBoard/openAutomationBoard
        // remain for a detached window).
        case 'task-board': select({ kind: 'task-board' }); break;
        case 'new-task': select({ kind: 'task-board', newTaskToken: Date.now() }); break;
        case 'automation-board': select({ kind: 'automation-board', tab: d.tab }); break;
        case 'new-automation': openAutomationEditor(wm, host, undefined, d.trigger); break;
        case 'automation': openAutomationEditor(wm, host, d.id); break;
        case 'automation-run': if (d.id) openRunWindow(wm, host, d.id); break;
        case 'task-review': if (d.id) openTaskReview(wm, host, d.id); break;
      }
    };
    window.addEventListener('bromure:open', on);
    (window as any).__bromure = { ...((window as any).__bromure ?? {}), boards: {
      taskBoard: () => select({ kind: 'task-board' }), newTask: () => select({ kind: 'task-board', newTaskToken: Date.now() }),
      automationBoard: (tab?: HubTab) => select({ kind: 'automation-board', tab }), automationEditor: (id?: string) => openAutomationEditor(wm, host, id),
      run: (id: string) => openRunWindow(wm, host, id), review: (id: string) => openTaskReview(wm, host, id), transcript: (id: string) => openTaskTranscript(wm, host, id),
    } };
    return () => window.removeEventListener('bromure:open', on);
  }, [wm, host]);
  return <ConfirmHost />;
}
