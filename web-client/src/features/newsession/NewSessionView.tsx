// "New session" (SessionStageViews.swift NewSessionView): the one question,
// then the composer — agent, machine, where, instructions chips — and Start.
// Starting posts /agent-sessions/start (FatClientController.startSession);
// the new session is selected once the mirror has it.

import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { SF } from '../../ui/icons';
import { Button, Popover, Segmented, Sheet, Spinner, cx, useMenu, useTooltip } from '../../ui/kit';
import { useHostCtx } from '../../app/hostContext';
import { useRemote } from '../../app/store';
import { isMac } from '../../platform';
import type { RemoteState, Workspace } from '../../core/remote/types';
import { AGENTS, agentKind, type ToolID } from './agents';
import { AgentAvatar } from '../sidebar/AgentAvatar';
import { isSwitchboard, isDeleted } from '../sidebar/model';

/** "~/clock", never /home/ubuntu/clock (prettyGuestPath). */
function prettyGuestPath(p: string) {
  const home = '/home/ubuntu';
  if (!p || p === home || p === '~') return '~';
  return p.startsWith(home + '/') ? '~' + p.slice(home.length) : p;
}
import { openSurface } from '../palette/events';
import { FolderPickerSheet } from './FolderPicker';
import { InstructionPresetEditor } from './InstructionPresetEditor';
import './newsession.css';

export const GREETINGS = [
  'What can I help you with?', 'What are we building today?', "Let's build something.", "What's on your mind?",
  'Where should we start?', 'What would you like to make?', 'Ready when you are.', "What's the plan?",
  "Let's get to work.", 'What shall we tackle first?', 'Tell me what you need.', 'What are we working on?',
  "Let's make something great.", 'What needs doing?', "What's next?", 'Got something in mind?',
  "Let's ship something.", 'What should we fix today?', 'Where do we begin?', 'What can we improve?',
  "Let's write some code.", 'What are you working on?', "What's the task?", "Let's dig in.",
  'What do you want to build?', "Let's solve something.", 'What are we shipping today?', 'Ready to build?',
  "What's the idea?", "Let's start something new.",
];

type Where = 'home' | 'folder' | 'repository';
const WHERE_TITLE: Record<Where, string> = { home: 'Fresh folder', folder: 'A folder', repository: 'A repository' };

const LAST_PROFILE = 'bromure.sessions.lastProfileID';
const LAST_TOOL = 'bromure.sessions.lastTool';
const pref = {
  get: (k: string) => { try { return localStorage.getItem(k); } catch { return null; } },
  set: (k: string, v: string) => { try { localStorage.setItem(k, v); } catch {} },
};

interface Attachment { name: string; data: string; isImage: boolean; url?: string }

export interface RecentStart { profileID: string; tool: string; folder: string }

/** "~/hello-260915-1830": a folder the server minted for a fresh-folder session. */
function isSynthesizedFolder(path: string) {
  const cut = path.lastIndexOf('/');
  const parent = cut < 0 ? '' : path.slice(0, cut);
  if (parent !== '~' && parent !== '/home/ubuntu') return false;
  return /^[\p{L}\p{N}-]+-(\d{6}|\d{4})-\d{4}(-\d+)?$/u.test(path.slice(cut + 1));
}

export function recentStarts(st: RemoteState, limit = 3): RecentStart[] {
  const out: RecentStart[] = [];
  const sessions = [...(st.agentSessions ?? [])].sort((a, b) => (Date.parse(b.createdAt ?? '') || 0) - (Date.parse(a.createdAt ?? '') || 0));
  for (const s of sessions) {
    if (isDeleted(s) || isSwitchboard(s) || !st.workspaces.some(w => w.id === s.profileID)) continue;
    const cwd = s.cwd ?? '';
    const home = !cwd || cwd === '~' || cwd === '/home/ubuntu' || isSynthesizedFolder(cwd);
    const r = { profileID: s.profileID, tool: s.tool, folder: home ? '' : cwd };
    if (!out.some(o => o.profileID === r.profileID && o.tool === r.tool && o.folder === r.folder)) out.push(r);
    if (out.length === limit) break;
  }
  return out;
}

export function recentFolders(st: RemoteState, pid: string): string[] {
  const seen: string[] = [];
  for (const s of st.agentSessions ?? []) {
    if (s.profileID !== pid || s.cwd === '~') continue;
    const p = prettyGuestPath(s.cwd ?? '');
    if (!seen.includes(p)) seen.push(p);
    if (seen.length >= 6) break;
  }
  return seen;
}

/** CodingTask.repoName(fromCloneURL:) */
function repoName(url: string): string | null {
  const u = url.trim().replace(/\/+$/, '').replace(/\.git$/, '');
  if (!u) return null;
  const last = u.split(/[/:]/).pop() ?? '';
  return /^[A-Za-z0-9._-]+$/.test(last) && last !== '.' && last !== '..' ? last : null;
}
function shortRepoURL(url: string) {
  return url.trim().replace(/^https?:\/\//, '').replace(/^git@/, '').replace(/\.git$/, '').replace(/^github\.com[/:]/, '');
}

const isRunning = (w?: Workspace) => w?.state === 'running' || w?.state === 'booting';
function machineTools(w: Workspace): string[] {
  const extra = ((w.additionalTools as any[] | undefined) ?? []).map(t => typeof t === 'string' ? t : t?.tool).filter(Boolean);
  return [w.tool, ...extra.filter((t: string) => t !== w.tool)];
}

export interface NewSessionViewProps {
  /** Start inside a room (the room's "+"): back to its grid afterwards. */
  room?: string;
  onCancel: () => void;
  onStarted: (sessionID: string) => void;
}

export function NewSessionView({ room, onCancel, onStarted }: NewSessionViewProps) {
  const { host } = useHostCtx();
  const st = useRemote(host, s => s);
  const profiles = st?.workspaces ?? [];
  const tip = useTooltip();

  const initialPID = useMemo(() => {
    const remembered = pref.get(LAST_PROFILE);
    return profiles.find(p => p.id === remembered)?.id ?? profiles.find(p => isRunning(p))?.id ?? profiles[0]?.id ?? '';
  }, [profiles.length > 0]); // eslint-disable-line react-hooks/exhaustive-deps
  const [profileID, setProfileID] = useState(initialPID);
  useEffect(() => { if (!profileID && initialPID) setProfileID(initialPID); }, [initialPID, profileID]);
  const profile = profiles.find(p => p.id === profileID);
  const rememberedTool = (pid: string) => pref.get(`${LAST_TOOL}.${pid}`);
  const [tool, setTool] = useState<string>(() => rememberedTool(initialPID) ?? profiles.find(p => p.id === initialPID)?.tool ?? pref.get(LAST_TOOL) ?? 'claude');
  const pickProfile = (pid: string) => {
    setProfileID(pid);
    const t = rememberedTool(pid) ?? profiles.find(p => p.id === pid)?.tool;
    if (t) setTool(t);
  };

  const [place, setPlace] = useState<Where>('home');
  const [folder, setFolder] = useState('');
  const [repoURL, setRepoURL] = useState('');
  const derived = useRef<string | null>(null);
  const [message, setMessage] = useState('');
  const [instructionsID, setInstructionsID] = useState<string | null>(null);
  const [greeting] = useState(() => GREETINGS[Math.floor(Math.random() * GREETINGS.length)]);
  const [attachments, setAttachments] = useState<Attachment[]>([]);
  const [dropTargeted, setDropTargeted] = useState(false);
  const [popover, setPopover] = useState<{ which: 'agent' | 'machine' | 'where' | 'instructions'; anchor: DOMRect } | null>(null);
  const [folderPicker, setFolderPicker] = useState(false);
  const [editingPresets, setEditingPresets] = useState(false);
  const [starting, setStarting] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const [focused, setFocused] = useState(false);
  const textRef = useRef<HTMLTextAreaElement>(null);

  const presets = st?.instructionPresets;
  const picked = presets?.find(p => p.id === instructionsID) ?? null;
  useEffect(() => { if (instructionsID && presets && !presets.some(p => p.id === instructionsID)) setInstructionsID(null); }, [presets, instructionsID]);

  const configured: string[] = profile
    ? (profile.readyTools ? profile.readyTools.map(t => t.tool) : AGENTS.map(a => a.id))
    : [];
  const agentNeedsModel = agentKind(tool).needsModelToStart && !!profile && !configured.includes(tool);

  const effectiveFolder = (() => {
    const f = folder.trim();
    if (place === 'home') return '~';
    if (place === 'folder') return f || '~';
    if (f) return f;
    const n = repoName(repoURL);
    return n ? '~/' + n : '';
  })();
  const canStart = !!profile && !agentNeedsModel && !starting
    && (place !== 'repository' || (!!repoURL.trim() && !!effectiveFolder && effectiveFolder !== '~'));

  const whereLabel = place === 'home' ? WHERE_TITLE.home
    : place === 'folder' ? (folder.trim() || WHERE_TITLE.folder)
    : (repoURL.trim() ? shortRepoURL(repoURL) : WHERE_TITLE.repository);

  useEffect(() => {
    const n = repoName(repoURL);
    if (!n) return;
    const f = folder.trim();
    if (!f || f === derived.current) { const v = '~/' + n; setFolder(v); derived.current = v; }
  }, [repoURL]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => { textRef.current?.focus(); const t = setTimeout(() => textRef.current?.focus(), 150); return () => clearTimeout(t); }, []);
  useLayoutEffect(() => {
    const el = textRef.current; if (!el) return;
    el.style.height = '0px';
    el.style.height = Math.min(Math.max(el.scrollHeight, 66), 14 * 23 + 8) + 'px';
  }, [message]);

  const start = async () => {
    if (!canStart) return;
    pref.set(LAST_PROFILE, profileID);
    pref.set(LAST_TOOL, tool);
    pref.set(`${LAST_TOOL}.${profileID}`, tool);
    const body: Record<string, unknown> = { profile: profileID, tool, cwd: effectiveFolder };
    if (picked?.text) body.instructions = picked.text;
    if (room) body.room = room;
    if (place === 'repository' && repoURL.trim()) body.cloneURL = repoURL.trim();
    if (message) body.message = message;
    if (attachments.length) body.attachments = attachments.map(a => ({ name: a.name, data: a.data, isImage: a.isImage }));
    setStarting(true);
    try {
      const r = await host.request<any>('POST', '/agent-sessions/start', body,
        { timeoutMs: 150_000, allowError: true, headers: { 'X-Bromure-Console-Idle-Ms': '0' } });
      host.refreshSoon();
      if (!r?.id) {
        setFailure(r?.error || 'The server didn\'t answer. Check the connection and try again.');
        return;
      }
      onStarted(r.id);
    } catch (e: any) {
      setFailure(e?.status ? (e.message || `The server answered HTTP ${e.status}.`) : 'The server didn\'t answer. Check the connection and try again.');
    } finally {
      setStarting(false);
    }
  };

  const addFiles = async (files: FileList | File[]) => {
    const out: Attachment[] = [];
    for (const f of Array.from(files)) {
      const buf = new Uint8Array(await f.arrayBuffer());
      let bin = '';
      for (let i = 0; i < buf.length; i += 0x8000) bin += String.fromCharCode(...buf.subarray(i, i + 0x8000));
      const isImage = f.type.startsWith('image/');
      out.push({ name: f.name, data: btoa(bin), isImage, url: isImage ? URL.createObjectURL(f) : undefined });
    }
    if (out.length) setAttachments(a => [...a, ...out]);
  };

  const onKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey && !e.altKey && !e.nativeEvent.isComposing) { e.preventDefault(); start(); }
    else if (e.key === 'Escape') { e.preventDefault(); onCancel(); }
  };
  const openPop = (which: 'agent' | 'machine' | 'where' | 'instructions') => (e: React.MouseEvent) => {
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    setPopover(p => p?.which === which ? null : { which, anchor: r });
  };

  if (!st) return <div className="ns"><div className="ns-loading"><Spinner /></div></div>;

  const recents = recentStarts(st);
  const folders = recentFolders(st, profileID).slice(0, 4);
  const footnote = isMac
    ? 'Runs in an isolated machine of its own. Nothing on your Mac is touched.'
    : 'Runs in an isolated machine of its own on your Mac, not on this device.';

  return (
    <div className="ns" onKeyDown={e => { if (e.key === 'Escape' && !popover && !folderPicker && !editingPresets) onCancel(); }}>
      <div className="ns-column">
        <div className="ns-top-spacer" />
        <div className="ns-greeting">{profiles.length ? greeting : "Let's set up a machine first."}</div>
        {!profiles.length ? (
          <div className="ns-first">
            <SF name="desktopcomputer" size={30} weight={300} className="ns-first-icon" />
            <div className="ns-first-body">
              <div className="ns-first-title">Set up your first machine</div>
              <div className="ns-first-text">An isolated Linux machine with the agents and keys you choose. Sessions run inside it — nothing on your Mac is touched.</div>
              <Button variant="prominent" size="large" icon="plus" onClick={() => openSurface('new-machine')}>Create a machine</Button>
            </div>
          </div>
        ) : (<>
          <div className={cx('ns-composer', focused && 'focused', dropTargeted && 'drop')}
               onDragOver={e => { if (e.dataTransfer.types.includes('Files')) { e.preventDefault(); setDropTargeted(true); } }}
               onDragLeave={() => setDropTargeted(false)}
               onDrop={e => { e.preventDefault(); setDropTargeted(false); addFiles(e.dataTransfer.files); }}>
            {attachments.length > 0 && (
              <div className="ns-attachments">
                {attachments.map((a, i) => (
                  <div key={i} className="ns-attachment">
                    {a.url ? <img src={a.url} alt="" /> : (
                      <div className="ns-attachment-ph"><SF name="doc.text" size={18} /><span>{a.name}</span></div>
                    )}
                    <button className="ns-attachment-x" {...tip.bind('Remove attachment')}
                            onClick={() => setAttachments(list => list.filter((_, j) => j !== i))}>
                      <SF name="xmark.circle.fill" size={15} />
                    </button>
                  </div>
                ))}
              </div>
            )}
            <textarea ref={textRef} className="ns-message" value={message} rows={3} spellCheck={false}
                      placeholder={`Ask for anything — or just press Return to open ${agentKind(tool).displayName}.`}
                      onChange={e => setMessage(e.target.value)} onKeyDown={onKeyDown}
                      onFocus={() => setFocused(true)} onBlur={() => setFocused(false)}
                      onPaste={e => { if (e.clipboardData.files.length) { e.preventDefault(); addFiles(e.clipboardData.files); } }} />
            <div className="ns-chips">
              <Chip help="The agent that runs this session" onClick={openPop('agent')} tip={tip}>
                <AgentAvatar tool={tool} size={16} />
                <span className="ns-chip-text nowrap">{agentKind(tool).displayName}</span>
              </Chip>
              <Chip help={isRunning(profile) ? 'The machine it runs on — running' : 'The machine it runs on — asleep, wakes up when you start'}
                    onClick={openPop('machine')} tip={tip}>
                <span className="ns-square" style={{ background: profile?.accentHex ?? '#888888' }} />
                <span className="ns-chip-text" style={{ maxWidth: 160 }}>{profile?.name ?? 'Machine'}</span>
                {isRunning(profile) && <span className="ns-run-dot" />}
              </Chip>
              <Chip help="Where it works: a fresh folder, one of yours, or a repository to check out" onClick={openPop('where')} tip={tip} shrink>
                <SF name={place === 'repository' ? 'arrow.down.circle' : 'folder'} size={12} className="secondary" />
                <span className="ns-chip-text middle" style={{ maxWidth: 220 }}><MiddleTruncate text={whereLabel} /></span>
              </Chip>
              {presets && (
                <Chip help="Instructions added to the agent's system prompt (“You are a…”)" onClick={openPop('instructions')} tip={tip}>
                  <SF name="person.text.rectangle" size={12} style={{ color: picked ? 'var(--accent)' : 'var(--label-secondary)' }} />
                  <span className="ns-chip-text" style={{ maxWidth: 160 }}>{picked?.name ?? 'No instructions'}</span>
                </Chip>
              )}
              <FitHint text={isMac ? '⏎ start   ⇧⏎ newline' : '↵ start   ⇧↵ newline'} />
              <button className={cx('ns-start', canStart && 'on')} disabled={!canStart} onClick={start}
                      aria-label="Start" {...tip.bind('Start the session (⏎)')}>
                {starting ? <Spinner size={12} /> : <span>Start</span>}
                <SF name="arrow.up" size={12} weight={700} />
              </button>
            </div>
            {dropTargeted && <div className="ns-drop-hint"><SF name="arrow.down.doc" size={14} /> Drop to attach</div>}
          </div>
          {agentNeedsModel && (
            <div className="ns-needs-model">
              <SF name="exclamationmark.triangle.fill" size={13} color="var(--yellow)" />
              {agentKind(tool).displayName} has no model set up on this machine. Choose one in the machine's settings › Models.
            </div>
          )}
          {recents.length > 1 && (
            <div className="ns-recent-starts">
              {recents.map((r, i) => {
                const name = profiles.find(p => p.id === r.profileID)?.name ?? '';
                const on = profileID === r.profileID && tool === r.tool && (r.folder ? place === 'folder' && folder === r.folder : place === 'home');
                return (
                  <button key={i} className={cx('ns-recent-start', on && 'on')}
                          {...tip.bind(`${agentKind(r.tool).displayName} on ${name}, in ${r.folder || 'Fresh folder'}`)}
                          onClick={() => { setProfileID(r.profileID); setTool(r.tool); if (r.folder) { setPlace('folder'); setFolder(r.folder); } else { setPlace('home'); setFolder(''); } }}>
                    <AgentAvatar tool={r.tool} size={18} />
                    <span className="ns-recent-start-text">
                      <span className="ns-recent-start-name">{name}</span>
                      <span className="ns-recent-start-folder">{r.folder ? r.folder.split('/').pop() : 'Fresh folder'}</span>
                    </span>
                  </button>
                );
              })}
            </div>
          )}
          {folders.length > 0 && (
            <div className="ns-recent">
              <span className="ns-recent-label">Recent</span>
              {folders.map(p => {
                const on = place === 'folder' && folder === p;
                return (
                  <button key={p} className={cx('ns-recent-folder', on && 'on')}
                          {...tip.bind((on ? 'Working in this folder — click to start in a new folder instead' : 'Work in this folder again') + '\n' + p)}
                          onClick={() => { if (on) { setPlace('home'); setFolder(''); } else { setPlace('folder'); setFolder(p); } }}>
                    <SF name="folder" size={11} />
                    <span className="ns-head-trunc"><bdi>{p}</bdi></span>
                  </button>
                );
              })}
            </div>
          )}
          <div className="ns-footnote">{footnote}</div>
        </>)}
        <div className="ns-bottom-spacer" />
      </div>

      {popover?.which === 'agent' && (
        <Popover anchor={popover.anchor} onClose={() => setPopover(null)} width={300}>
          <div className="ns-pop-list">
            {AGENTS.map(a => {
              const isConfigured = configured.includes(a.id);
              const blocked = !isConfigured && a.needsModelToStart;
              const sel = a.id === tool;
              return (
                <button key={a.id} className={cx('ns-pop-row', sel && 'on')} disabled={blocked} style={{ opacity: blocked ? 0.45 : 1 }}
                        {...tip.bind(blocked ? `${a.displayName} has no model set up on this machine. Choose one in the machine's settings › Models.` : undefined)}
                        onClick={() => { setTool(a.id as ToolID); setPopover(null); }}>
                  <AgentAvatar tool={a.id} size={26} />
                  <span className="ns-pop-text">
                    <span className={cx('ns-pop-title', sel && 'sel')}>{a.displayName}</span>
                    <span className="ns-pop-sub">{isConfigured ? 'Ready' : blocked ? 'No model set up (settings › Models)'
                      : a.switchesProvider ? 'Pick a model provider when it starts' : 'Sign in when it starts'}</span>
                  </span>
                  {sel && <SF name="checkmark" size={12} weight={600} color="var(--accent)" />}
                </button>
              );
            })}
          </div>
        </Popover>
      )}
      {popover?.which === 'machine' && (
        <Popover anchor={popover.anchor} onClose={() => setPopover(null)} width={320}>
          <div className="ns-pop-list" style={{ maxHeight: Math.min(440, profiles.length * 46 + 12 + 50), overflowY: 'auto' }}>
            {profiles.map(p => {
              const running = isRunning(p);
              const sel = p.id === profileID;
              return (
                <button key={p.id} className={cx('ns-pop-row', sel && 'on')} onClick={() => { pickProfile(p.id); setPopover(null); }}>
                  <span className="ns-machine-icon" style={{ background: p.accentHex ?? '#888', opacity: running ? 0.9 : 0.35 }}>
                    <SF name="desktopcomputer" size={13} weight={500} />
                  </span>
                  <span className="ns-pop-text">
                    <span className={cx('ns-pop-title', sel && 'sel')}>{p.name}</span>
                    <span className="ns-pop-sub">{machineTools(p).map(t => agentKind(t).displayName).join(' · ')}</span>
                  </span>
                  {sel ? <SF name="checkmark" size={12} weight={600} color="var(--accent)" /> : running ? <span className="ns-run-dot big" /> : null}
                </button>
              );
            })}
            <div className="ns-pop-divider" />
            <button className="ns-pop-row short" onClick={() => { setPopover(null); openSurface('new-machine'); }}>
              <span className="ns-machine-icon dashed"><SF name="plus" size={12} weight={600} /></span>
              <span className="ns-pop-title">New machine…</span>
            </button>
          </div>
        </Popover>
      )}
      {popover?.which === 'where' && (
        <Popover anchor={popover.anchor} onClose={() => setPopover(null)} width={420}>
          <div className="ns-where" onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); setPopover(null); } }}>
            <Segmented value={place} onChange={setPlace}
                       options={(['home', 'folder', 'repository'] as Where[]).map(w => ({ value: w, label: WHERE_TITLE[w] }))} />
            {place === 'home' && <div className="ns-where-note">A fresh folder of its own in the machine's home, named after your message.</div>}
            {place === 'folder' && (<>
              <div className="ns-where-row">
                <PathField value={folder} onChange={setFolder} prompt="~/my-project" />
                <Button onClick={() => { setPopover(null); setTimeout(() => setFolderPicker(true), 150); }}>Choose…</Button>
                {recentFolders(st, profileID).filter(p => p !== folder).length > 0 && (
                  <RecentMenu items={recentFolders(st, profileID).filter(p => p !== folder)} onPick={setFolder} />
                )}
              </div>
              <div className="ns-where-note">A folder inside the machine — created if it doesn't exist yet.</div>
            </>)}
            {place === 'repository' && (<>
              <div className="ns-path">
                <SF name="arrow.down.circle" size={12} className="secondary" />
                <input value={repoURL} placeholder="https://github.com/org/repo.git" spellCheck={false} autoFocus
                       onChange={e => setRepoURL(e.target.value)} />
              </div>
              <div className="ns-where-row">
                <span className="ns-where-into">into</span>
                <PathField value={folder} onChange={setFolder} prompt="~/repo" />
              </div>
              <div className="ns-where-note">Checked out with the machine's git credentials or SSH key. If the folder already holds the repository, it's used as is.</div>
            </>)}
            <div className="ns-where-done"><Button variant="prominent" onClick={() => setPopover(null)}>Done</Button></div>
          </div>
        </Popover>
      )}
      {popover?.which === 'instructions' && presets && (
        <Popover anchor={popover.anchor} onClose={() => setPopover(null)} width={320}>
          <div className="ns-pop-list" style={{ maxHeight: 420, overflowY: 'auto' }}>
            {[{ id: null as string | null, name: 'No instructions', text: 'The agent as it comes' }, ...presets].map(p => {
              const sel = p.id === (picked?.id ?? null);
              return (
                <button key={p.id ?? 'none'} className={cx('ns-pop-row auto', sel && 'on')} onClick={() => { setInstructionsID(p.id); setPopover(null); }}>
                  <span className="ns-pop-text">
                    <span className={cx('ns-pop-title', sel && 'sel')}>{p.name}</span>
                    <span className="ns-pop-sub two">{p.text}</span>
                  </span>
                  {sel && <SF name="checkmark" size={12} weight={600} color="var(--accent)" />}
                </button>
              );
            })}
            <div className="ns-pop-divider" />
            <button className="ns-pop-row short" onClick={() => { setPopover(null); setEditingPresets(true); }}>
              <span style={{ width: 22, display: 'grid', placeItems: 'center' }}><SF name="square.and.pencil" size={14} /></span>
              <span className="ns-pop-title">Edit instructions…</span>
            </button>
          </div>
        </Popover>
      )}
      {folderPicker && profile && (
        <FolderPickerSheet profileID={profile.id} machineName={profile.name} start={folder.trim()}
                           onPick={p => { setPlace('folder'); setFolder(p); }} onClose={() => setFolderPicker(false)} />
      )}
      {editingPresets && presets && (
        <InstructionPresetEditor presets={presets} initial={instructionsID} onClose={() => setEditingPresets(false)} />
      )}
      {failure !== null && (
        <Sheet width={420} onClose={() => setFailure(null)}>
          <div className="ns-alert">
            <SF name="exclamationmark.triangle.fill" size={34} color="var(--yellow)" />
            <div className="ns-alert-title">Couldn't start the session</div>
            {failure && <div className="ns-alert-text">{failure}</div>}
          </div>
          <div className="sheet-footer"><Button variant="prominent" autoFocus onClick={() => setFailure(null)}>OK</Button></div>
        </Sheet>
      )}
      {tip.node}
    </div>
  );
}

function Chip({ help, onClick, children, tip, shrink }: {
  help: string; onClick: (e: React.MouseEvent) => void; children: React.ReactNode;
  tip: ReturnType<typeof useTooltip>; shrink?: boolean;
}) {
  return (
    <button className={cx('ns-chip', shrink && 'shrink')} onClick={onClick} {...tip.bind(help)}>
      {children}
      <SF name="chevron.down" size={9} weight={700} className="ns-chip-chev" />
    </button>
  );
}

/** Middle truncation ("…/rooms/checkout-revamp") for the Where chip. */
function MiddleTruncate({ text }: { text: string }) {
  const ref = useRef<HTMLSpanElement>(null);
  const [shown, setShown] = useState(text);
  useLayoutEffect(() => {
    const el = ref.current?.parentElement; if (!el) return;
    setShown(text);
    requestAnimationFrame(() => {
      if (!ref.current || el.scrollWidth <= el.clientWidth + 0.5) return;
      let keep = text.length - 1;
      let s = text;
      while (keep > 4) {
        const head = Math.ceil(keep / 2), tail = Math.floor(keep / 2);
        s = text.slice(0, head) + '…' + text.slice(text.length - tail);
        ref.current.textContent = s;
        if (el.scrollWidth <= el.clientWidth + 0.5) break;
        keep--;
      }
      setShown(s);
    });
  }, [text]);
  return <span ref={ref}>{shown}</span>;
}

/** The "⏎ start ⇧⏎ newline" hint: whole or not at all (ViewThatFits). */
function FitHint({ text }: { text: string }) {
  const ref = useRef<HTMLSpanElement>(null);
  const [fits, setFits] = useState(true);
  useLayoutEffect(() => {
    const el = ref.current; if (!el) return;
    const check = () => setFits(el.scrollWidth <= el.clientWidth + 0.5);
    check();
    const ro = new ResizeObserver(check);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return <span className="ns-hint-slot"><span ref={ref} className="ns-hint" style={{ visibility: fits ? 'visible' : 'hidden' }}>{text}</span></span>;
}

function PathField({ value, onChange, prompt }: { value: string; onChange: (v: string) => void; prompt: string }) {
  return (
    <div className="ns-path" style={{ flex: 1 }}>
      <SF name="folder" size={12} className="secondary" />
      <input value={value} placeholder={prompt} spellCheck={false} onChange={e => onChange(e.target.value)} />
    </div>
  );
}

function RecentMenu({ items, onPick }: { items: string[]; onPick: (p: string) => void }) {
  const menu = useMenu();
  return <Button variant="borderless" icon="clock"
                 onClick={e => menu((e.currentTarget as HTMLElement).getBoundingClientRect(), items.map(p => ({ label: p, action: () => onPick(p) })))}>Recent</Button>;
}

