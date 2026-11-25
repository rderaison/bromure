// Network lineage sheet — port of NetworkLineageView.swift: the whole chain
// behind a network flow, as a vertical stack of connected steps
// (reasoning → tool call → processes → flow → decision), plus the other flows
// the same tool call caused. Opened from the Security Timeline (double-click a
// row with lineage).

import React, { useEffect, useState } from 'react';
import { Button, Sheet, cx } from '../../../ui/kit';
import { SF } from '../../../ui/icons';
import type { SecEvent } from '../model';
import { flowLineage, layerName, lineageTint, decisionLabel, type FlowLineage, type Proc } from './lineage';
import './lineage.css';

export function NetworkLineageSheet({ events, focus, onClose }: { events: SecEvent[]; focus: SecEvent; onClose: () => void }) {
  return (
    <Sheet width={760} height={Math.min(1012, window.innerHeight - 80)} onClose={onClose}>
      <NetworkLineageView events={events} focus={focus} onClose={onClose} />
    </Sheet>
  );
}

/** The sheet's content (also rendered full-window by the fixture). */
export function NetworkLineageView({ events, focus: initial, onClose }: { events: SecEvent[]; focus: SecEvent; onClose: () => void }) {
  const [focus, setFocus] = useState(initial);
  useEffect(() => setFocus(initial), [initial]);
  const l = flowLineage(focus, events);
  // Return = Done (keyboardShortcut(.defaultAction)).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Enter' && !(e.target as HTMLElement)?.closest?.('input, textarea')) { e.preventDefault(); onClose(); }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);
  return (
    <div className="lin-sheet">
      {l ? (
        <>
          <Header l={l} />
          <div className="lin-scroll">
            <Steps key={focus.id} l={l} onFocus={setFocus} />
          </div>
        </>
      ) : (
        <div className="empty-state lin-empty">
          <SF name="point.3.connected.trianglepath.dotted" size={34} />
          <h3>No lineage recorded for this event</h3>
        </div>
      )}
      <div className="lin-footer">
        <Button variant="prominent" onClick={onClose}>Done</Button>
      </div>
    </div>
  );
}

const dest = (l: FlowLineage) => (l.port > 0 ? `${l.destination}:${l.port}` : l.destination);
const fmtTime = (t: number) => new Date(t).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit', second: '2-digit' });
const fmtDateTime = (t: number) => {
  const d = new Date(t);
  return `${d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })} at ${fmtTime(t)}`;
};

function Header({ l }: { l: FlowLineage }) {
  const tint = lineageTint(l.decision);
  return (
    <div className="lin-header">
      <div className="lin-header-icon" style={{ ['--tint' as any]: tint }}>
        <SF name="point.3.connected.trianglepath.dotted" size={20} weight={600} />
      </div>
      <div className="lin-header-text">
        <div className="lin-title selectable" title={dest(l)}>{dest(l)}</div>
        <div className="lin-subtitle">
          <span>{fmtDateTime(l.event.time)}</span>
          {l.event.workspace && <><span>·</span><span>{l.event.workspace}</span></>}
        </div>
      </div>
      <DecisionBadge decision={l.decision} />
    </div>
  );
}

function Steps({ l, onFocus }: { l: FlowLineage; onFocus: (e: SecEvent) => void }) {
  return (
    <div className="lin-steps">
      <ReasoningStep l={l} />
      <ToolStep l={l} />
      <ProcessStep l={l} />
      <FlowStep l={l} />
      <DecisionStep l={l} />
      {l.siblings.length > 0 && <Siblings l={l} onFocus={onFocus} />}
    </div>
  );
}

function Step({ icon, tint, title, accessory, dimmed, last, children }: {
  icon: string; tint: string; title: string; accessory?: React.ReactNode; dimmed?: boolean; last?: boolean; children: React.ReactNode;
}) {
  return (
    <div className={cx('lin-step', dimmed && 'dimmed', last && 'last')} style={{ ['--tint' as any]: tint }}>
      {!last && <div className="lin-rail" />}
      <div className="lin-step-icon"><SF name={icon} size={15} weight={600} /></div>
      <div className="lin-card">
        <div className="lin-card-title"><span>{title}</span>{accessory}</div>
        {children}
      </div>
    </div>
  );
}

function Labeled({ label, icon, children }: { label: string; icon: string; children: React.ReactNode }) {
  return (
    <div className="lin-labeled">
      <div className="lin-label"><SF name={icon} size={11} weight={600} /><span>{label}</span></div>
      {children}
    </div>
  );
}

function Chip({ text, tint }: { text: string; tint: string }) {
  return <span className="lin-chip" style={{ ['--tint' as any]: tint }}>{text}</span>;
}

function DecisionBadge({ decision }: { decision: string }) {
  return <span className="lin-badge" style={{ ['--tint' as any]: lineageTint(decision) }}>{decisionLabel(decision)}</span>;
}

function ReasoningStep({ l }: { l: FlowLineage }) {
  const [expanded, setExpanded] = useState(false);
  return (
    <Step icon="brain.head.profile" tint="var(--purple)" title="Why" dimmed={l.reasoning == null && l.prompt == null && l.intent == null}>
      <div className="lin-why">
        {l.prompt != null && (
          <Labeled label="Prompt" icon="person.fill">
            <div className={cx('lin-callout selectable', !expanded && 'clamp4')}>{l.prompt}</div>
          </Labeled>
        )}
        {(l.reasoning != null || (l.prompt == null && l.intent == null)) && (
          <Labeled label="Reasoning" icon="brain">
            {l.reasoning != null ? (
              <div className="lin-reasoning">
                <div className={cx('lin-callout selectable', !expanded && 'clamp5')}>{l.reasoning}</div>
                {l.reasoning.length > 320 && (
                  <button className="btn link lin-more" onClick={() => setExpanded(!expanded)}>{expanded ? 'Show less' : 'Show more'}</button>
                )}
              </div>
            ) : (
              <div className="lin-callout lin-muted">
                {l.toolUseID == null
                  ? 'Not traced to an agent\'s tool call.'
                  : 'The model went straight to the call: it wrote nothing first, and returned its thinking (if any) without readable text.'}
              </div>
            )}
          </Labeled>
        )}
        {l.intent != null && (
          <Labeled label="Stated intent" icon="quote.bubble">
            <div className="lin-callout selectable lin-italic">{l.intent}</div>
          </Labeled>
        )}
      </div>
    </Step>
  );
}

function ToolStep({ l }: { l: FlowLineage }) {
  const conf = l.confidence == null ? null
    : l.confidence === 'exact' ? 'exact match' : l.confidence === 'likely' ? 'likely match' : l.confidence;
  return (
    <Step icon="wrench.and.screwdriver" tint="var(--indigo)" title={l.tool ? `Tool call · ${l.tool}` : 'Tool call'}
          accessory={conf ? <Chip text={conf} tint="var(--indigo)" /> : undefined} dimmed={l.toolUseID == null}>
      {l.command != null ? <CodeBlock text={l.command} />
        : l.toolUseID != null ? <div className="lin-callout lin-muted">A tool call without a shell command.</div>
        : <div className="lin-callout lin-muted">Started outside any tool call the AI proxy saw (a background service, a build step the agent didn't run directly, or a process older than the session).</div>}
    </Step>
  );
}

function ProcessStep({ l }: { l: FlowLineage }) {
  const [showAll, setShowAll] = useState(false);
  const procs = l.processes;
  const collapsed = !showAll && procs.length > 6;
  const shown: (Proc | null)[] = collapsed ? [...procs.slice(0, 2), null, ...procs.slice(-3)] : procs;
  const leaf = procs[procs.length - 1]?.id;
  return (
    <Step icon="terminal" tint="var(--orange)" title={`Processes · ${procs.length}`} dimmed={procs.length === 0}>
      {procs.length === 0 ? (
        <div className="lin-callout lin-muted">The kernel sentry didn't report the process (it may be off in this workspace).</div>
      ) : (
        <div className="lin-procs">
          {shown.map((p, depth) => p ? <ProcessRow key={p.id} proc={p} depth={depth} isLeaf={p.id === leaf} /> : (
            <button key="more" className="btn link lin-more-procs" style={{ marginLeft: depth * 18 + 22 }} onClick={() => setShowAll(true)}>
              <SF name="ellipsis" size={11} /> {procs.length - 5} more
            </button>
          ))}
        </div>
      )}
    </Step>
  );
}

function ProcessRow({ proc, depth, isLeaf }: { proc: Proc; depth: number; isLeaf: boolean }) {
  return (
    <div className="lin-proc" style={{ paddingLeft: depth * 18 }}>
      {depth > 0 && <span className="lin-elbow">└</span>}
      <div className="lin-proc-body">
        <div className="lin-proc-line">
          <span className={cx('lin-comm', isLeaf && 'leaf')}>{proc.comm}</span>
          <span className="lin-pid">{proc.pid}</span>
          {proc.exe && !proc.exe.endsWith('/' + proc.comm) && <span className="lin-exe" title={proc.exe}>{proc.exe}</span>}
        </div>
        {proc.argv && proc.argv !== proc.comm && <div className="lin-argv selectable" title={proc.argv}>{proc.argv}</div>}
      </div>
    </div>
  );
}

function FlowStep({ l }: { l: FlowLineage }) {
  return (
    <Step icon="arrow.up.right.circle.fill" tint="var(--teal)" title="Network flow">
      <div className="lin-grid">
        <span className="lin-k">Protocol</span>
        <span className="lin-chips">
          <Chip text={l.proto || '—'} tint="var(--teal)" />
          {l.viaProxy && <Chip text="via proxy" tint="var(--gray)" />}
          {l.count > 1 && <Chip text={`×${l.count}`} tint="var(--gray)" />}
        </span>
        <span className="lin-k">Destination</span><span className="lin-v selectable">{dest(l)}</span>
        {l.ip != null && <><span className="lin-k">Address</span><span className="lin-v selectable">{l.ip}</span></>}
        {l.dev != null && <><span className="lin-k">Interface</span><span className="lin-v selectable">{l.dev}</span></>}
        {l.sport != null && <><span className="lin-k">{l.proto === 'ICMP' ? 'Echo id' : 'Source port'}</span><span className="lin-v">{l.sport}</span></>}
      </div>
    </Step>
  );
}

function DecisionStep({ l }: { l: FlowLineage }) {
  return (
    <Step icon={l.decision === 'deny' ? 'xmark.shield.fill' : 'checkmark.shield.fill'} tint={lineageTint(l.decision)} title="Decision" last>
      <div className="lin-decision">
        <div className="lin-chips gap8">
          <DecisionBadge decision={l.decision} />
          {l.layer && <Chip text={layerName(l.layer)} tint="var(--gray)" />}
        </div>
        {l.reason && <div className="lin-callout selectable">{l.reason}</div>}
        {l.decision === 'raw' && <div className="lin-caption">Sent through a raw packet socket, below the guest's network stack. The firewall and proxy still apply to the traffic it carries.</div>}
        {l.decision === 'unfiltered' && <div className="lin-caption">The firewall filters TCP and UDP; this protocol passes without a rule.</div>}
      </div>
    </Step>
  );
}

function Siblings({ l, onFocus }: { l: FlowLineage; onFocus: (e: SecEvent) => void }) {
  return (
    <div className="lin-siblings">
      <div className="lin-siblings-title">Other flows from this tool call · {l.siblings.length}</div>
      <div className="lin-sibling-list">
        {l.siblings.map(e => {
          const s = flowLineage(e, []);
          return (
            <button key={e.id} className="lin-sibling" onClick={() => onFocus(e)}>
              <span className="lin-dot" style={{ background: lineageTint(s?.decision ?? '') }} />
              <span className="lin-sib-proto">{s?.proto ?? ''}</span>
              <span className="lin-sib-dest truncate">{s ? dest(s) : ''}</span>
              <span className="spacer" />
              <span className="lin-sib-comm">{s?.processes[s.processes.length - 1]?.comm ?? ''}</span>
              <span className="lin-sib-time">{fmtTime(e.time)}</span>
              <SF name="chevron.right" size={11} className="lin-sib-chev" />
            </button>
          );
        })}
      </div>
    </div>
  );
}

function CodeBlock({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <div className="lin-code">
      <div className="lin-code-text selectable">{text}</div>
      <button className="btn borderless lin-copy" title="Copy" onClick={() => {
        navigator.clipboard?.writeText(text).catch(() => {});
        setCopied(true);
        setTimeout(() => setCopied(false), 1200);
      }}>
        <SF name={copied ? 'checkmark' : 'doc.on.doc'} size={15} />
      </button>
    </div>
  );
}
