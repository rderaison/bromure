// BeautifiedSessionView (the live chat) and SessionRestView (a paused /
// archived session's read-back + "your next message picks it up"), with the
// ChatComposer, the "/" command palette and "@" mentions, file drops/paste,
// and the strip of messages that couldn't be typed.

import React, { useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { SF } from '../../../ui/icons';
import { cx, Spinner } from '../../../ui/kit';
import { useHostCtx } from '../../../app/hostContext';
import { useRemote } from '../../../app/store';
import type { AgentSession } from '../../../core/remote/types';
import type { TranscriptItem } from '../transcript/types';
import { ChatModel, dropImagePaths } from './model';
import { layoutRows, isActivity, isHostAside, switchboardStrip, type Row } from './rows';
import { analyzeSwitchboard, switchboardAliases, itemsIn, effectiveFilter, threadHeaders, threadInk, type ThreadedConversation, type SwitchboardThread } from './switchboard';
import { appearance } from '../../../app/appearance';
import {
  TranscriptItemView, ActivityGroupView, TurnChangesView, QuestionBatchCard, ThinkingRow, StreamingCaret, LongMessageBar, TodoListView,
} from './ItemViews';
import { matchCommands, peerCandidates, mentionQuery, matchMentions, completeMention, type SlashCommand } from './slash';
import { sessionCommand, openSurface } from '../../sidebar/actions';
import { isArchived } from '../../sidebar/model';
import { isMod } from '../../../platform';
import { ScratchTerminalDrawer } from '../../terminal/ScratchTerminalDrawer';
import './chat.css';

// ── Model hook ──────────────────────────────────────────────────────────

const models = new Map<string, { m: ChatModel; refs: number }>();
/** One model per session+mode, shared by every view of it (a room's cell
 *  and its composer), polling while any is mounted. */
function useChatModel(sessionID: string, mode: 'live' | 'copy'): ChatModel {
  const { host } = useHostCtx();
  const key = host.target.id + ':' + sessionID + ':' + mode;
  const m = useMemo(() => {
    let x = models.get(key);
    if (!x) {
      x = { m: new ChatModel(host, sessionID, mode, () => host.state?.agentSessions?.find(s => s.id === sessionID)), refs: 0 };
      models.set(key, x);
    }
    return x.m;
  }, [key, host, sessionID, mode]);
  useEffect(() => {
    const e = models.get(key) ?? { m, refs: 0 };
    models.set(key, e);
    e.refs++;
    m.start();
    return () => { if (--e.refs <= 0) { m.stop(); models.delete(key); } };
  }, [m, key]);
  return m;
}

// ── Scroll that follows the tail ────────────────────────────────────────

function useTailFollow(dep: unknown) {
  const ref = useRef<HTMLDivElement>(null);
  const sticky = useRef(true);
  useLayoutEffect(() => {
    const el = ref.current;
    if (el && sticky.current) el.scrollTop = el.scrollHeight;
  }, [dep]);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const onScroll = () => { sticky.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40; };
    const ro = new ResizeObserver(() => { if (sticky.current) el.scrollTop = el.scrollHeight; });
    el.addEventListener('scroll', onScroll);
    ro.observe(el);
    if (el.firstElementChild) ro.observe(el.firstElementChild);
    return () => { el.removeEventListener('scroll', onScroll); ro.disconnect(); };
  }, []);
  return ref;
}

// ── Transcript rows ─────────────────────────────────────────────────────

function Rows({ items, working, model, conv, onPick }: {
  items: TranscriptItem[]; working: boolean; model: ChatModel; conv?: { c: ThreadedConversation; filtered: boolean } | null; onPick?: (id: string) => void;
}) {
  const dark = useSyncExternalStore(appearance.subscribe, appearance.effective) === 'dark';
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const snap = useSyncExternalStore(model.subscribe, model.get);
  const { select, setViewMode } = useHostCtx();
  const live = model.pendingQuestions(items);
  const liveIDs = new Set(live.map(i => i.id));
  const visible = items.filter(i => i.kind.t !== 'todo' && !liveIDs.has(i.id));
  const layout = useMemo(() => layoutRows(visible, expanded), [visible, expanded]);
  const last = layout.rows[layout.rows.length - 1];
  const liveRun = working && last?.t === 'activity' ? last.id : null;
  const lastUser = [...visible].reverse().find(i => i.kind.t === 'userText' && !isHostAside(i.kind.text))?.id;
  const toggle = (id: string) => setExpanded(s => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n; });
  void select; void setViewMode; void lastUser;
  const headers = useMemo(() => conv && !conv.filtered ? threadHeaders(conv.c, layout.rows) : null, [conv, layout]);
  const rowView = (r: Row): React.ReactNode => {
    if (r.t === 'activity') return <ActivityGroupView key={r.id} items={r.items} live={r.id === liveRun} />;
    if (r.t === 'changes') return <TurnChangesView key={r.id} changes={r.changes} onOpen={() => openSurface('review', { sessionID: model['sessionID'], files: r.changes.files, since: r.changes.since })} />;
    const k = r.item.kind;
    if (conv && k.t === 'userText') {
      const notice = switchboardStrip(k.text);
      if (notice != null) {
        const t = conv.c.threads.find(x => x.id === conv.c.threadsOf.get(r.item.id)?.[0]);
        return <SwitchboardNoticeLine key={r.id} text={notice} thread={t} time={r.item.timestamp} dark={dark} onPick={onPick} />;
      }
    }
    const long = layout.longs.get(r.item.id);
    const imgs = k.t === 'userText' ? dropImagePaths(k.text).map(p => snap.images[p]).filter(Boolean) : [];
    return (
      <MessageChrome key={r.id} item={r.item} copy={long?.whole ?? layout.replies.get(r.item.id)}>
        <TranscriptItemView item={r.item} images={imgs} />
        {long && <LongMessageBar m={long} onToggle={() => toggle(long.itemID)} />}
      </MessageChrome>
    );
  };
  return (
    <>
      {layout.rows.map(r => {
        const hdr = headers?.get(r.id);
        const threads = hdr && conv ? hdr.map(k => conv.c.threads.find(t => t.id === k)).filter((t): t is SwitchboardThread => !!t) : [];
        if (!threads.length) return rowView(r);
        return <React.Fragment key={r.id}><ThreadHeader threads={threads} dark={dark} onPick={onPick} />{rowView(r)}</React.Fragment>;
      })}
      {live.length > 0 && (
        <QuestionBatchCard key={'q:' + live.map(i => (i.kind as any).q.question).join('\u001f')}
          questions={live.map(i => (i.kind as any).q)} onSubmit={keys => model.answerQuestions(keys)} />
      )}
    </>
  );
}

/** MessageChrome: on hover, the time and Copy. */
function MessageChrome({ item, copy, children }: { item: TranscriptItem; copy?: string; children: React.ReactNode }) {
  const [copied, setCopied] = useState(false);
  const k = item.kind;
  const text = copy ?? (k.t === 'userText' || k.t === 'assistantText' ? k.text : '');
  if (!(k.t === 'userText' || k.t === 'assistantText') || (k.t === 'userText' && isHostAside(k.text))) return <>{children}</>;
  return (
    <div className="chat-msg">
      {children}
      <div className="chat-msg-tools">
        {item.timestamp != null && <span className="chat-msg-time">{new Date(item.timestamp).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}</span>}
        <button title={k.t === 'assistantText' ? 'Copy the whole reply as Markdown' : 'Copy'}
                onClick={() => { navigator.clipboard?.writeText(text); setCopied(true); setTimeout(() => setCopied(false), 1200); }}>
          <SF name={copied ? 'checkmark' : 'doc.on.doc'} size={11} />
        </button>
      </div>
    </div>
  );
}

// ── Composer ────────────────────────────────────────────────────────────

export function ChatComposer({ placeholder, text, setText, onSend, disabled, busy, working, onStop, accent, autofocus,
                               canSendEmpty, onKey, onFiles }: {
  placeholder: string; text: string; setText: (t: string) => void; onSend: () => void; disabled?: boolean; busy?: boolean;
  working?: boolean; onStop?: () => void; accent: string; autofocus?: boolean; canSendEmpty?: boolean;
  onKey?: (e: React.KeyboardEvent<HTMLTextAreaElement>) => boolean; onFiles?: (f: File[]) => void;
}) {
  const ta = useRef<HTMLTextAreaElement>(null);
  const [focused, setFocused] = useState(false);
  const sendable = !disabled && !busy && (canSendEmpty || !!text.trim());
  useLayoutEffect(() => {
    const el = ta.current; if (!el) return;
    el.style.height = '0px';
    const line = 13.5 * 1.2 + 3;
    el.style.height = Math.min(Math.max(24, el.scrollHeight), Math.round(line * 12)) + 'px';
  }, [text]);
  useEffect(() => {
    if (autofocus && !document.activeElement?.closest('input, textarea, [contenteditable]')) ta.current?.focus();
    // The focus ring follows the element even while the window is inactive.
    if (document.activeElement === ta.current) setFocused(true);
  }, [autofocus]);
  return (
    <div className={cx('chat-composer', focused && 'focused')} style={{ ['--composer-accent' as any]: accent }}
         onMouseDown={e => { if (e.target === e.currentTarget) { e.preventDefault(); ta.current?.focus(); } }}>
      <textarea ref={ta} className="chat-composer-text" value={text} placeholder={placeholder} disabled={disabled}
                rows={1} spellCheck autoFocus={autofocus}
                onFocus={() => setFocused(true)} onBlur={() => setFocused(false)}
                onChange={e => setText(e.target.value)}
                onPaste={e => {
                  const files = [...e.clipboardData.files];
                  if (files.length && onFiles) { e.preventDefault(); onFiles(files); }
                }}
                onKeyDown={e => {
                  if (onKey?.(e)) return;
                  if (e.key === 'Escape' && working && onStop) { e.preventDefault(); onStop(); return; }
                  if (e.key === 'Enter' && !e.shiftKey && !e.altKey && !e.nativeEvent.isComposing) {
                    e.preventDefault(); if (sendable) onSend();
                  } else if (e.key === 'Enter' && isMod(e)) { e.preventDefault(); if (sendable) onSend(); }
                }} />
      <div className="chat-composer-foot">
        <span className="chat-composer-hint">{working ? '⎋ stop   ⏎ send   ⇧⏎ newline' : '⏎ send   ⇧⏎ newline'}</span>
        <span style={{ flex: 1 }} />
        {working ? (
          <button className="chat-composer-stop" onClick={onStop} title="Stop the agent (Esc)"><SF name="stop.fill" size={11} weight={700} /></button>
        ) : (
          <button className="chat-composer-send" disabled={!sendable} onClick={() => sendable && onSend()} title="Send (⏎)"
                  style={sendable ? { background: accent } : undefined}>
            {busy ? <Spinner size={14} /> : <SF name="arrow.up" size={12} weight={700} />}
          </button>
        )}
      </div>
    </div>
  );
}

/** SlashCommandPalette — commands, or sessions for "@". */
function Palette({ rows, highlighted, title, agent, prefix, onPick, onHover }: {
  rows: (SlashCommand & { tag?: string })[]; highlighted: number; title: string; agent: string; prefix: string;
  onPick: (c: SlashCommand) => void; onHover: (i: number) => void;
}) {
  const listRef = useRef<HTMLDivElement>(null);
  useEffect(() => { listRef.current?.children[highlighted]?.scrollIntoView({ block: 'nearest' }); }, [highlighted]);
  return (
    <div className="chat-palette">
      <div className="chat-palette-head">
        <span className="chat-palette-title">{title}</span>
        <span className="tertiary">·</span>
        <span className="secondary">{agent}</span>
        <span style={{ flex: 1 }} />
        <span className="tertiary chat-palette-count">{rows.length}</span>
      </div>
      <div className="chat-palette-list" ref={listRef} style={{ height: 36 * Math.min(7, Math.max(1, rows.length)) + 6 }}>
        {rows.map((c, i) => (
          <div key={c.source + ':' + c.name} className={cx('chat-palette-row', i === highlighted && 'on')}
               onMouseDown={e => { e.preventDefault(); onPick(c); }} onMouseEnter={() => onHover(i)}>
            <span className="mono chat-palette-name">{prefix}{c.name}</span>
            <span className="chat-palette-desc">{c.description}</span>
            {(c.tag || c.source !== 'builtIn') && <span className="chat-palette-tag">{c.tag ?? c.source}</span>}
          </div>
        ))}
      </div>
    </div>
  );
}

function AttachmentChips({ files, onRemove }: { files: File[]; onRemove: (i: number) => void }) {
  const urls = useMemo(() => files.map(f => f.type.startsWith('image/') ? URL.createObjectURL(f) : null), [files]);
  useEffect(() => () => urls.forEach(u => u && URL.revokeObjectURL(u)), [urls]);
  return (
    <div className="chat-attachments">
      {files.map((f, i) => (
        <div key={i} className="chat-attachment" title={f.name}>
          {urls[i] ? <img src={urls[i]!} alt="" /> : <span className="chat-attachment-ph"><SF name="doc" size={14} /></span>}
          <span className="chat-attachment-name">{f.name}</span>
          <button onClick={() => onRemove(i)} title="Remove"><SF name="xmark.circle.fill" size={13} /></button>
        </div>
      ))}
    </div>
  );
}

/** The composer with its palettes, attachments and held-messages strip. */
const TERM_COMMAND: SlashCommand = { name: 'term', description: "Open a terminal here, in this session's folder", source: 'bromure', tag: 'Bromure' };

function ComposerArea({ model, session, accent, mode, onRestSend, placeholder: ph, restStatus }: {
  model: ChatModel; session: AgentSession; accent: string; mode: 'live' | 'rest'; onRestSend?: (text: string) => void; placeholder?: string; restStatus?: string | null;
}) {
  const snap = useSyncExternalStore(model.subscribe, model.get);
  const { host } = useHostCtx();
  const sessions = useRemote(host, s => s.agentSessions) ?? [];
  const workspaces = useRemote(host, s => s.workspaces) ?? [];
  const [text, setText] = useState('');
  const [files, setFiles] = useState<File[]>([]);
  const [hi, setHi] = useState(0);
  // /term — a shell of its own in this session's folder (ScratchTerminalDrawer).
  const [termShown, setTermShown] = useState(false);
  const canTerm = mode === 'live';
  useEffect(() => {
    if (!canTerm) return;
    const on = (e: KeyboardEvent) => { if (e.ctrlKey && !e.metaKey && !e.altKey && e.key === '`') { e.preventDefault(); setTermShown(v => !v); } };
    window.addEventListener('keydown', on);
    return () => window.removeEventListener('keydown', on);
  }, [canTerm]);
  const palQuery = text.startsWith('/') && !text.includes(' ') && !text.includes('\n') ? text.slice(1) : null;
  const menQuery = palQuery == null ? mentionQuery(text) : null;
  const peers = useMemo(() => menQuery == null ? [] : matchMentions(menQuery,
    peerCandidates(sessions as any, session.id, id => workspaces.find(w => w.id === id)?.name ?? '')), [menQuery, sessions, workspaces, session.id]);
  const rows: (SlashCommand & { tag?: string })[] = palQuery != null && mode === 'live' ? matchCommands(palQuery, canTerm ? [TERM_COMMAND, ...snap.slash] : snap.slash)
    : menQuery != null ? peers.map(p => ({ name: p.nick, description: p.title + (p.workspace ? ' · ' + p.workspace : ''), source: 'builtIn' as const, tag: p.assigned ? undefined : 'new name' }))
    : [];
  useEffect(() => setHi(0), [palQuery, menQuery]);
  useEffect(() => {
    const on = (e: Event) => { const d = (e as CustomEvent).detail; if (d?.session === session.id && mode === 'live') setFiles(x => [...x, ...d.files]); };
    window.addEventListener('bromure:chat-drop', on);
    return () => window.removeEventListener('bromure:chat-drop', on);
  }, [session.id, mode]);
  const pick = (c: SlashCommand) => {
    if (menQuery != null) {
      const p = peers.find(x => x.nick === c.name);
      if (p && !p.assigned) sessionCommand(host, p.sessionID, 'nickname', { nickname: p.nick });
      setText(completeMention(text, c.name));
      return;
    }
    const t = '/' + c.name + (c.takesArgument ? ' ' : '');
    if (c.source === 'bromure' && c.name === 'term') { setText(''); setTermShown(true); return; }
    setText(t);
    if (!c.takesArgument) { send(t); }
  };
  const send = async (raw = text) => {
    if (mode === 'rest') {
      const t = raw.trim();
      if (!t) return;
      setText('');
      onRestSend?.(t);
      return;
    }
    const f = files;
    if (!f.length && canTerm && ['/term', '/terminal'].includes(raw.trim().toLowerCase())) { setText(''); setTermShown(true); return; }
    setText(''); setFiles([]);
    await model.send(raw, f);
  };
  const onKey = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (!rows.length) return false;
    if (e.key === 'ArrowDown') { e.preventDefault(); setHi(h => (h + 1) % rows.length); return true; }
    if (e.key === 'ArrowUp') { e.preventDefault(); setHi(h => (h - 1 + rows.length) % rows.length); return true; }
    if (e.key === 'Tab' || (e.key === 'Enter' && !e.shiftKey)) { e.preventDefault(); pick(rows[Math.min(hi, rows.length - 1)]); return true; }
    if (e.key === 'Escape') { e.preventDefault(); setText(menQuery != null ? text.slice(0, Math.max(text.lastIndexOf(' '), text.lastIndexOf('\n')) + 1) : ''); return true; }
    return false;
  };
  const live = mode === 'live';
  const placeholder = ph ?? (live ? `Message ${snap.agentName}… (or drop files)` : `Message ${snap.agentName}…`);
  return (
    <>
      {rows.length > 0 && (
        <div className="chat-palette-wrap">
          <Palette rows={rows} highlighted={Math.min(hi, rows.length - 1)} prefix={menQuery != null ? '@' : '/'}
                   title={menQuery != null ? 'Sessions' : 'Commands'} agent={menQuery != null ? 'sessions you can ask' : snap.agentName}
                   onPick={pick} onHover={setHi} />
        </div>
      )}
      {termShown && canTerm && (
        <ScratchTerminalDrawer workspaceID={session.profileID} sessionKey={session.id} cwd={session.cwd ?? '~'}
                               maxHeight={Math.max(160, Math.round(window.innerHeight * 0.5))} accent={accent}
                               onHide={() => setTermShown(false)} onClose={() => setTermShown(false)} />
      )}
      <div className="chat-divider" />
      <div className="chat-bottom">
        {!live && restStatus && (
          <div className="chat-rest-line"><Spinner size={10} /><span>{restStatus}</span></div>
        )}
        {!live && !restStatus && (
          <div className="chat-rest-line">
            <SF name={isArchived(session) ? 'archivebox' : 'pause.circle'} size={11} color="var(--label-secondary)" />
            <span>{isArchived(session) ? 'Archived. Your next message brings it back and carries on from here.'
              : 'Paused. Your next message picks it up from here.'}</span>
          </div>
        )}
        {snap.held.length > 0 && (
          <div className="chat-held">
            {snap.held.map(h => (
              <div key={h.id} className="chat-held-row">
                <SF name={h.failure ? 'exclamationmark.triangle.fill' : 'clock'} size={11} color={h.failure ? 'var(--orange)' : 'var(--label-secondary)'} />
                <div className="chat-vstack" style={{ flex: 1, minWidth: 0, gap: 2 }}>
                  <span className="chat-held-text">{h.text}</span>
                  <span className="chat-held-why">{h.failure ?? (h.awaitingAnswer ? 'Waiting — the agent is asking you something. Answer it, then this goes in.' : 'Queued')}</span>
                </div>
                <button className="chat-linkbtn" onClick={() => { setText(text ? h.text + '\n\n' + text : h.text); model.dropHeld(h.id); }}>Edit</button>
                <button className="chat-iconbtn" title="Delete" onClick={() => model.dropHeld(h.id)}><SF name="xmark" size={10} /></button>
              </div>
            ))}
          </div>
        )}
        {files.length > 0 && <AttachmentChips files={files} onRemove={i => setFiles(fs => fs.filter((_, k) => k !== i))} />}
        <ChatComposer placeholder={placeholder} text={text} setText={setText} onSend={() => send()} accent={accent}
                      autofocus={live} busy={snap.sending} working={live && snap.working} onStop={() => model.interrupt()}
                      canSendEmpty={files.length > 0} onKey={onKey}
                      onFiles={live ? fs => setFiles(x => [...x, ...fs]) : undefined} />
      </div>
    </>
  );
}

// ── The chat ────────────────────────────────────────────────────────────

/** The live chat (BeautifiedSessionView) or a read-back with the rest
 *  footer (SessionRestView): same rows, same composer. */
export function ChatView({ session, accent, mode, parts = 'all', placeholder, restStatus }: {
  session: AgentSession; accent: string; mode: 'live' | 'fixture' | 'rest'; parts?: 'all' | 'transcript' | 'composer'; placeholder?: string;
  /** Rest mode: a session on its way back (launching, or live with no tab yet) says so instead of "Paused". */
  restStatus?: string | null;
}) {
  const model = useChatModel(session.id, mode === 'live' ? 'live' : 'copy');
  const snap = useSyncExternalStore(model.subscribe, model.get);
  const { host } = useHostCtx();
  const [dropping, setDropping] = useState(false);
  const scroller = useTailFollow(snap.items.length + ':' + snap.working + ':' + (snap.items[snap.items.length - 1]?.id ?? ''));
  const composerMode = mode === 'rest' ? 'rest' : 'live';
  const lastIsReply = snap.items[snap.items.length - 1]?.kind.t === 'assistantText';
  const lastIsActivity = snap.items.length > 0 && isActivity(snap.items[snap.items.length - 1]);
  const todo = [...snap.items].reverse().find(i => i.kind.t === 'todo');
  const empty = snap.items.length === 0;
  const sb = useSwitchboard(session, snap.items);
  const [threadFilter, setThreadFilter] = useState<string | null>(null);
  const dark = useSyncExternalStore(appearance.subscribe, appearance.effective) === 'dark';
  const shownItems = sb.c ? itemsIn(sb.c, threadFilter) : snap.items;
  const conv = sb.c ? { c: sb.c, filtered: effectiveFilter(sb.c, threadFilter) != null } : null;
  const composer = (
    <ComposerArea model={model} session={session} accent={accent} mode={composerMode} placeholder={placeholder} restStatus={restStatus}
                  onRestSend={t => sessionCommand(host, session.id, 'resume', { message: t })} />
  );
  if (parts === 'composer') return <div className="chat chat-composer-only">{composer}</div>;
  return (
    <div className={cx('chat', dropping && 'dropping')}
         onDragOver={e => { if (composerMode === 'live' && e.dataTransfer.types.includes('Files')) { e.preventDefault(); setDropping(true); } }}
         onDragLeave={e => { if (e.currentTarget === e.target) setDropping(false); }}
         onDrop={e => { e.preventDefault(); setDropping(false); const f = [...e.dataTransfer.files]; if (f.length) window.dispatchEvent(new CustomEvent('bromure:chat-drop', { detail: { session: session.id, files: f } })); }}>
      {sb.c && sb.c.threads.length > 0 && (
        <ThreadBar c={sb.c} filter={threadFilter} setFilter={setThreadFilter} waiting={sb.waiting} dark={dark} />
      )}
      <div className="chat-scroll" ref={scroller}>
        <div className="chat-column">
          {(snap.canLoadEarlier) && (
            <button className="chat-earlier" disabled={snap.loadingEarlier} onClick={() => model.loadEarlier()}>
              {snap.loadingEarlier ? <><Spinner size={12} /> Loading earlier conversation… ({mb(snap.heldBytes)} of {mb(snap.fileSize)})</>
                : <><SF name="arrow.up.circle" size={12} /> Load earlier conversation</>}
            </button>
          )}
          {empty && !snap.working ? (
            <div className="chat-empty">
              {snap.loadIssue ? (
                <>
                  <SF name={snap.loadIssue === 'failed' ? 'exclamationmark.triangle' : 'questionmark.folder'} size={22} color="var(--label-secondary)" />
                  <span>{snap.loadIssue === 'failed' ? "Couldn't load this conversation — the machine didn't answer in time." : "This session's conversation wasn't found on its machine."}</span>
                  <button className="btn small" onClick={() => model.retry()}>Retry</button>
                </>
              ) : snap.loading ? (
                <><Spinner size={18} /><span>{mode === 'rest' ? 'Reading the conversation…' : 'Loading transcript…'}</span></>
              ) : mode === 'rest' ? (
                (session.openingMessage as string) ? <TranscriptItemView item={{ id: 'open', kind: { t: 'userText', text: session.openingMessage as string } }} /> : null
              ) : (
                <><SF name="text.bubble" size={30} color="var(--label-tertiary)" /><span>{snap.agentName} is ready. Say what you need.</span></>
              )}
            </div>
          ) : (
            <>
              <Rows items={shownItems} working={snap.working} model={model} conv={conv} onPick={setThreadFilter} />
              {snap.working && !lastIsActivity && (lastIsReply ? <StreamingCaret /> : <ThinkingRow since={snap.workingSince} />)}
            </>
          )}
        </div>
      </div>
      {todo && todo.kind.t === 'todo' && composerMode === 'live' && (
        <div className="chat-todo-pin"><TodoListView title={todo.kind.title} rows={todo.kind.rows} /></div>
      )}
      {parts === 'all' && composer}
    </div>
  );
}

const mb = (n: number) => n >= 1e6 ? (n / 1e6).toFixed(1) + ' MB' : Math.round(n / 1e3) + ' KB';


// ── Switchboard threads (SwitchboardThreads.swift) ──────────────────────

const Swatch = ({ t, dark }: { t: SwitchboardThread; dark: boolean }) =>
  <span className="sb-swatch" style={{ background: threadInk(t.hue, dark) }} />;

/** SwitchboardThreadHeader: where the conversation turns to a chain. */
function ThreadHeader({ threads, dark, onPick }: { threads: SwitchboardThread[]; dark: boolean; onPick?: (id: string) => void }) {
  return (
    <div className="sb-thead">
      {threads.map(t => (
        <button key={t.id} className="sb-thead-name" title="Show only this thread" onClick={() => onPick?.(t.id)}>
          <Swatch t={t} dark={dark} /><span style={{ color: threadInk(t.hue, dark) }}>{t.name}</span>
        </button>
      ))}
      <span className="sb-thead-rule" style={{ background: `color-mix(in srgb, ${threadInk(threads[0].hue, dark)} 30%, transparent)` }} />
    </div>
  );
}

/** SwitchboardNoticeLine: a host notice, one quiet line. */
function SwitchboardNoticeLine({ text, thread, time, dark, onPick }: {
  text: string; thread?: SwitchboardThread; time?: number; dark: boolean; onPick?: (id: string) => void;
}) {
  let rest = text;
  if (thread) for (const f of [`“${thread.name}” `, `${thread.name} `]) if (rest.startsWith(f)) { rest = rest.slice(f.length); break; }
  return (
    <div className="sb-notice">
      {thread && (
        <button className="sb-thead-name" title="Show only this thread" onClick={() => onPick?.(thread.id)}>
          <Swatch t={thread} dark={dark} /><span style={{ color: threadInk(thread.hue, dark) }}>{thread.name}</span>
        </button>
      )}
      <span className="sb-notice-text">{rest}</span>
      <span style={{ flex: 1 }} />
      {time != null && <span className="sb-notice-time">{new Date(time).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}</span>}
    </div>
  );
}

/** SwitchboardThreadBar: every chain, one click to read only it. */
function ThreadBar({ c, filter, setFilter, waiting, dark }: {
  c: ThreadedConversation; filter: string | null; setFilter: (f: string | null) => void; waiting: Set<string>; dark: boolean;
}) {
  const eff = effectiveFilter(c, filter);
  const chip = (key: string, selected: boolean, label: string, onClick: () => void, t?: SwitchboardThread) => {
    const ink = t ? threadInk(t.hue, dark) : 'var(--label)';
    return (
      <button key={key} className={cx('sb-chip', selected && 'on')} onClick={onClick}
              style={selected ? { background: `color-mix(in srgb, ${ink} 14%, transparent)`, borderColor: `color-mix(in srgb, ${ink} 60%, transparent)` } : undefined}>
        {t && <Swatch t={t} dark={dark} />}
        <span>{label}</span>
        {t && <span className="sb-chip-count">{t.count}</span>}
        {t?.sessionID && waiting.has(t.sessionID) && <span style={{ color: 'var(--red)' }}>Needs you</span>}
      </button>
    );
  };
  return (
    <div className="sb-bar">
      {chip('all', eff == null, 'All', () => setFilter(null))}
      {c.threads.map(t => chip(t.id, filter === t.id, t.name, () => setFilter(filter === t.id ? null : t.id), t))}
    </div>
  );
}

/** The Switchboard's threading for a chat, or null for any other session. */
function useSwitchboard(session: AgentSession, items: TranscriptItem[]) {
  const { host } = useHostCtx();
  const sessions = useRemote(host, s => s.agentSessions);
  const isSB = session.role === 'switchboard';
  const aliasKey = isSB ? (sessions ?? []).map(s => `${s.id}|${s.nickname ?? ''}|${s.title}|${s.deletedAt ?? ''}`).join('\n') : '';
  const aliases = useMemo(() => isSB ? switchboardAliases(sessions ?? []) : [], [aliasKey]); // eslint-disable-line react-hooks/exhaustive-deps
  const c = useMemo(() => isSB ? analyzeSwitchboard(items, aliases) : null, [isSB, items, aliases]);
  const waiting = useMemo(() => new Set((sessions ?? []).filter(s => s.awaitingAnswer === true).map(s => s.id)), [sessions]);
  return { c, waiting };
}
