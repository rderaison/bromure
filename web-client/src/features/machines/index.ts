// Machines surface: machine dashboards (VM / Docker / Kubernetes / registry),
// the Machines overview, the Files pane, the Branches and Review windows.
//
//   <MachineStage selection/>      stage for workspace / docker / machines / grid / cluster / registry
//   <FilePane/>                    the right-side Files pane (useHostCtx().filePaneOpen)
//   <MachinesEventBridge/>         `bromure:open` routing (see EventBridge.tsx)
//   openBranches(wm, host, workspaceID)
//   openSessionReview(wm, host, sessionID, {files?, since?})

import type { useWindows } from '../../app/windows';
export type WindowsAPI = ReturnType<typeof useWindows>;

export { MachineStage } from './MachineStage';
export { FilePane } from './FilePane';
export { MachinesEventBridge } from './EventBridge';
export { openBranchesWindow as openBranches } from './Branches';
export { openSessionReviewWindow as openSessionReview } from './Review';
