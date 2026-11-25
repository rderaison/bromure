// General — ProfileViews.swift `generalSection` (macOS Form .grouped) +
// `agentReachSection`.

import React from 'react';
import { PopUp, Switch } from '../../../ui/kit';
import { useEditor } from '../ctx';
import { PROFILE_COLORS, capitalize, val } from '../model';
import { Caption, CaptionTertiary } from '../ui';

const CLOSE_ACTIONS = [
  { value: 'background', label: 'Run in the background' },
  { value: 'suspend', label: 'Suspend' },
  { value: 'shutdown', label: 'Shut down' },
  { value: 'ask', label: 'Ask' },
];
const TASK_FINISH: Record<string, string> = { merge: 'Merge into the branch', pullRequest: 'Open a pull request' };
const KIMI: Record<string, string> = { neverAsk: 'Never ask', askWhenNeeded: 'Ask before sensitive actions' };

/** The grouped Form a few panes use (General, Appearance…): rounded cards of
 *  label | control rows. */
export function GForm({ children }: { children: React.ReactNode }) {
  return <div className="ed-gform">{children}</div>;
}
export function GSection({ children }: { children: React.ReactNode }) {
  return <div className="ed-gsection">{children}</div>;
}
export function GRow({ label, children, help, tall }: { label: React.ReactNode; children?: React.ReactNode; help?: string; tall?: boolean }) {
  return (
    <div className={'ed-grow' + (tall ? ' tall' : '')} title={help}>
      <div className="ed-grow-label">{label}</div>
      <div className="ed-grow-control">{children}</div>
    </div>
  );
}

export function GeneralPane() {
  const { doc, set, isTemplate, appTaskFinish, siblings } = useEditor();
  const taskFinish = doc.taskFinish as string | undefined;
  const reach = doc.agentReach as string[] | null | undefined;
  return (
    <GForm>
      <GSection>
        {!isTemplate && (
          <GRow label="Name">
            <input className="ed-plainfield" spellCheck={false} value={doc.name ?? ''} aria-label="Name"
                   onChange={e => set('name', e.target.value)} />
          </GRow>
        )}
        <GRow label="Color">
          <PopUp value={val<string>(doc, 'color')} onChange={v => set('color', v)}
                 options={PROFILE_COLORS.map(c => ({ value: c, label: capitalize(c) }))} />
        </GRow>
        <GRow label="When closing the window">
          <PopUp value={val<string>(doc, 'closeAction')} onChange={v => set('closeAction', v)} options={CLOSE_ACTIONS} />
        </GRow>
        {isTemplate ? (
          <GRow label="When a task is approved"
                help="What Review's main button does for a coding task: merge it into the branch it came from, or open a pull request. Each workspace and each task can choose otherwise.">
            <PopUp value={taskFinish ?? 'merge'} onChange={v => set('taskFinish', v)}
                   options={Object.entries(TASK_FINISH).map(([value, label]) => ({ value, label }))} />
          </GRow>
        ) : (
          <GRow label="When a task is approved"
                help="What Review's main button does for coding tasks in this workspace. Each task can still choose otherwise.">
            <PopUp value={taskFinish ?? ''} onChange={v => set('taskFinish', v || undefined)}
                   options={[{ value: '', label: `App default (${TASK_FINISH[appTaskFinish]})` },
                             ...Object.entries(TASK_FINISH).map(([value, label]) => ({ value, label }))]} />
          </GRow>
        )}
        <GRow label="Kimi approvals"
              help="Never ask: Kimi Code runs every command, edit and tool without stopping, and decides its own questions and plans — the workspace's VM and Bromure's guardrails are the safety boundary. Ask before sensitive actions (Kimi's “Ask When Needed” mode): ordinary commands and edits still run without asking; Kimi stops only before touching sensitive files (such as .env or SSH keys), running dangerous commands (such as rm -rf), or leaving Plan mode, and when it has a question for you. Applies from the next start or resume.">
          <PopUp value={val<string>(doc, 'kimiApprovals')} onChange={v => set('kimiApprovals', v)}
                 options={Object.entries(KIMI).map(([value, label]) => ({ value, label }))} />
        </GRow>
        {!isTemplate && (
          <>
            <GRow label="Start this VM at login">
              <Switch checked={val<boolean>(doc, 'bootAtStartup')} onChange={v => set('bootAtStartup', v)} />
            </GRow>
            <GRow label="Notes (optional)" tall>
              <NotesField value={val<string>(doc, 'comments')} onChange={v => set('comments', v)} />
            </GRow>
          </>
        )}
      </GSection>
      {!isTemplate && (
        <GSection>
          <div className="ed-greach">
            <div className="ed-headline">Reach</div>
            <Caption>Agents in this workspace can hand work to agents elsewhere (a delegation runs in the other workspace) and ask a session there by its @nickname; files travel along. Which workspaces they may reach:</Caption>
            <div className="ed-greach-toggle">
              <span>Every workspace</span>
              <Switch checked={reach == null} onChange={v => set('agentReach', v ? null : [])} />
            </div>
            {reach != null && (
              <>
                {reach.length === 0 && siblings.length > 0 && (
                  <CaptionTertiary>Agents here reach no other workspace until you tick one below (or turn on Every workspace).</CaptionTertiary>
                )}
                {siblings.length === 0
                  ? <CaptionTertiary>No other workspace yet — agents here can only reach each other.</CaptionTertiary>
                  : siblings.map(w => (
                    <div key={w.id} className="ed-greach-toggle sub">
                      <span>{w.name}</span>
                      <Switch checked={reach.includes(w.id)} onChange={on => set('agentReach', on
                        ? (reach.includes(w.id) ? reach : [...reach, w.id]) : reach.filter(x => x !== w.id))} />
                    </div>
                  ))}
              </>
            )}
          </div>
        </GSection>
      )}
    </GForm>
  );
}

/** The notes field: borderless, right-aligned in the grouped Form, growing
 *  2…6 lines; Shift-Return adds a line (Return saves the editor). */
function NotesField({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const lines = Math.min(6, Math.max(1, value.split('\n').length));
  return (
    <textarea className="ed-plainfield ed-notes" rows={lines} spellCheck={false} value={value}
              placeholder="Add a note about this workspace" aria-label="Notes (optional)"
              onChange={e => onChange(e.target.value)}
              data-return-saves="" />
  );
}
