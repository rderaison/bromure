// FileExplorerViews.swift's FileExplorerPane: the right-side Files pane — the
// folder of the session (or machine tab) on stage as a tree with git-status
// coloring, ".." to go up, the changed-files filter, a drop target that
// copies files and folders in, Save to Downloads, and a detail split with a
// colored diff (line comments for the agent) or a preview.

import React, { useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { useHostCtx, usePersisted } from '../../app/hostContext';
import { useRemote } from '../../app/store';
import { useMenu, Spinner, Button, cx } from '../../ui/kit';
import { FileExplorerModel, STATUS_BADGE, STATUS_TINT, type FileNode, type DiffLine } from './fileModel';
import { collectDropped } from './tar';
import { Markdown } from './markdown';
import { SegPicker, SF } from './parts';
import { copyText, guestPath, joinPath, lastPathComponent, prettyGuestPath } from './util';
import './machines.css';

const MIN_WIDTH = 200, DEFAULT_WIDTH = 340;

/** The pane's context: the selected session's machine and folder, else the
 *  selected machine's active tab (sessionContext / activeTab). */
function useFileContext(): { profileID: string | null; cwd: string | null; repo: string | null } {
  const { host, selection } = useHostCtx();
  const sessions = useRemote(host, s => s.agentSessions);
  const vms = useRemote(host, s => s.vms);
  return useMemo(() => {
    let sid: string | undefined;
    if (selection.kind === 'session') sid = selection.sessionID;
    else if (selection.kind === 'room') sid = selection.zoomedSessionID;
    if (sid) {
      const s = sessions?.find(x => x.id === sid);
      if (s) return { profileID: s.profileID, cwd: guestPath(s.cwd), repo: null };
    }
    if (selection.kind === 'workspace' || selection.kind === 'docker') {
      const vm = vms?.find(v => v.id.toUpperCase() === selection.workspaceID.toUpperCase());
      const want = selection.kind === 'workspace' ? selection.windowIndex : undefined;
      const tab = vm?.tabs?.find(t => t.index === want) ?? vm?.tabs?.find(t => t.active) ?? vm?.tabs?.[0];
      const cwd = (tab?.cwd as string | undefined) ?? (vm ? '/home/ubuntu' : null);
      const repo = (tab?.repoRoot as string | undefined) && tab?.isGitRepo !== false ? (tab!.repoRoot as string) : null;
      return { profileID: selection.workspaceID, cwd, repo };
    }
    return { profileID: null, cwd: null, repo: null };
  }, [selection, sessions, vms]);
}

export function FilePane() {
  const { host, filePaneOpen, setFilePaneOpen } = useHostCtx();
  const [width, setWidth] = usePersisted('ac.remote.filePaneWidth', DEFAULT_WIDTH);
  const model = useMemo(() => new FileExplorerModel(host), [host]);
  useEffect(() => () => model.dispose(), [model]);
  useSyncExternalStore(model.subscribe, model.snapshot);
  const ctx = useFileContext();

  // Re-point on context change; park while closed.
  useEffect(() => {
    if (!filePaneOpen) { model.setLocation(null, null, null); return; }
    model.setLocation(ctx.profileID, ctx.cwd, ctx.repo);
  }, [model, filePaneOpen, ctx.profileID, ctx.cwd, ctx.repo]);
  // 4 s poll while showing.
  useEffect(() => {
    if (!filePaneOpen || !ctx.cwd) return;
    const t = setInterval(() => { void model.pollRefresh(); }, 4000);
    return () => clearInterval(t);
  }, [model, filePaneOpen, ctx.cwd, ctx.profileID]);
  // Auto-expand folders holding changes, once per repo.
  const autoRepo = useRef<string | null>(null);
  useEffect(() => {
    if (model.loading || !model.repoRoot || autoRepo.current === model.repoRoot) return;
    autoRepo.current = model.repoRoot;
    const dirs: string[] = [];
    const walk = (n: FileNode) => { if (n.isDir && n.containsChanges) { dirs.push(n.path); n.children.forEach(walk); } };
    model.rootNodes.forEach(walk);
    if (dirs.length) model.expand(dirs);
  }, [model, model.loading, model.repoRoot]);

  // Debug hook for scripted shots.
  useEffect(() => {
    const w = window as any;
    w.__bromure = { ...(w.__bromure ?? {}), files: model };
  }, [model]);

  const [drop, setDrop] = useState(false);
  const startResize = (e: React.MouseEvent) => {
    e.preventDefault();
    const sx = e.clientX, sw = width;
    const mm = (ev: MouseEvent) => setWidth(Math.min(900, sw - (ev.clientX - sx)));
    const mu = (ev: MouseEvent) => {
      window.removeEventListener('mousemove', mm); window.removeEventListener('mouseup', mu);
      const w = sw - (ev.clientX - sx);
      if (w < MIN_WIDTH) { setWidth(DEFAULT_WIDTH); setFilePaneOpen(false); }
    };
    window.addEventListener('mousemove', mm); window.addEventListener('mouseup', mu);
  };
  if (!filePaneOpen) return null;
  const w = Math.max(MIN_WIDTH, width);

  return (
    <aside className="fp" style={{ width: w, flexShrink: 0 }}
           onDragOver={e => { if (model.canTransfer && e.dataTransfer.types.includes('Files')) { e.preventDefault(); setDrop(true); } }}
           onDragLeave={e => { if (!e.currentTarget.contains(e.relatedTarget as Node)) setDrop(false); }}
           onDrop={async e => {
             e.preventDefault(); setDrop(false);
             if (!model.canTransfer) return;
             const items = await collectDropped(e.dataTransfer);
             void model.receive(items);
           }}>
      <div className="fp-resize" onMouseDown={startResize} />
      <Header model={model} />
      <div className="mc-divider" style={{ opacity: 0.5 }} />
      <Content model={model} />
      {drop && model.canTransfer && <div className="fp-drop" />}
    </aside>
  );
}

function Header({ model }: { model: FileExplorerModel }) {
  const root = model.root;
  const pretty = root ? prettyGuestPath(root) : null;
  const title = !pretty ? 'Files' : pretty === '~' || pretty === '/' ? pretty : lastPathComponent(pretty);
  const n = model.statuses.size;
  return (
    <div className="fp-head">
      <button className="fp-up" disabled={!model.canGoUp} title="Up to the enclosing folder" onClick={() => model.goUp()}><SF name="arrow.up" size={10} weight={600} /></button>
      <span className="fp-title mc-ellipsis" title={pretty ?? ''}>{title}</span>
      {model.transferText && <span className="fp-transfer mc-ellipsis">{model.transferText}</span>}
      {n > 0 && <span className="fp-count" title={`${n} changed files`}>{n}</span>}
      <span className="mc-spacer" />
      <button className="mc-icon-btn" title={model.changedOnly ? 'Show all files' : 'Show changed files only'}
              style={{ color: model.changedOnly ? 'var(--accent)' : undefined }} onClick={() => model.setChangedOnly(!model.changedOnly)}>
        <SF name={model.changedOnly ? 'line.3.horizontal.decrease.circle.fill' : 'line.3.horizontal.decrease.circle'} size={12} />
      </button>
      <button className="mc-icon-btn" title="Refresh now" onClick={() => void model.refresh()}><SF name="arrow.clockwise" size={11} /></button>
    </div>
  );
}

function Content({ model }: { model: FileExplorerModel }) {
  const [split, setSplit] = usePersisted('bromure.files.split', 0.5);
  const box = useRef<HTMLDivElement>(null);
  if (!model.root) return <Placeholder icon="folder.badge.questionmark" text="No session selected" />;
  if (model.loading && !model.rootNodes.length) return <div className="fp-placeholder"><Spinner /></div>;
  if (model.loadError && !model.rootNodes.length) return <Placeholder icon="exclamationmark.triangle" text={model.loadError} retry={() => void model.refresh()} />;
  if (!model.selectedPath) return <Tree model={model} />;
  const startSplit = (e: React.MouseEvent) => {
    e.preventDefault();
    const r = box.current!.getBoundingClientRect();
    const mm = (ev: MouseEvent) => setSplit(Math.min(0.85, Math.max(0.15, (ev.clientY - r.top) / r.height)));
    const mu = () => { window.removeEventListener('mousemove', mm); window.removeEventListener('mouseup', mu); };
    window.addEventListener('mousemove', mm); window.addEventListener('mouseup', mu);
  };
  return (
    <div ref={box} className="mc-col" style={{ flex: 1, minHeight: 0 }}>
      <div className="mc-col" style={{ flex: `${split} 1 0`, minHeight: 110 }}><Tree model={model} /></div>
      <div className="fp-split" onMouseDown={startSplit} />
      <div className="fp-detail" style={{ flex: `${1 - split} 1 0` }}><Detail model={model} /></div>
    </div>
  );
}

function Placeholder({ icon, text, retry }: { icon: string; text: string; retry?: () => void }) {
  return (
    <div className="fp-placeholder">
      <SF name={icon} size={24} className="mc-tertiary" />
      <span className="mc-secondary" style={{ fontSize: 11 }}>{text}</span>
      {retry && <Button size="small" onClick={retry}>Retry</Button>}
    </div>
  );
}

function flatten(nodes: FileNode[], expanded: Set<string>, depth = 0, out: { node: FileNode; depth: number }[] = []) {
  for (const n of nodes) {
    out.push({ node: n, depth });
    if (n.isDir && expanded.has(n.path)) flatten(n.children, expanded, depth + 1, out);
  }
  return out;
}

function Tree({ model }: { model: FileExplorerModel }) {
  const menu = useMenu();
  const copyPath = (p: string) => model.root && copyText(joinPath(model.root, p));
  const ctxMenu = (e: React.MouseEvent, path: string, isDir: boolean) => {
    e.preventDefault();
    menu(e, [
      ...(model.canTransfer && !isDir ? [{ label: 'Save to Downloads', action: () => void model.saveToDownloads(path) }] : []),
      { label: 'Copy Path', action: () => copyPath(path) },
      ...(isDir ? [{ label: 'Show This Folder', action: () => model.enter(path) }] : []),
    ]);
  };
  const row = (key: string, name: string, depth: number, isDir: boolean, path: string, status?: FileNode['status'], containsChanges = false) => (
    <div key={key} className={cx('fp-row', model.selectedPath === path && 'sel')} title={name}
         style={{ paddingLeft: depth * 12 + 4 }}
         onClick={() => (isDir ? model.toggleExpanded(path) : model.select(path))}
         onDoubleClick={() => { if (isDir) model.enter(path); }}
         onContextMenu={e => ctxMenu(e, path, isDir)}>
      {isDir
        ? <span style={{ width: 10, display: 'grid', placeItems: 'center', transform: model.expanded.has(path) ? 'rotate(90deg)' : undefined }} className="mc-tertiary"><SF name="chevron.right" size={8} weight={600} /></span>
        : <span style={{ width: 10 }} />}
      <span style={{ width: 14, display: 'grid', placeItems: 'center' }}>
        <SF name={isDir ? 'folder' : /\.(png|jpe?g|gif|webp|heic|svg|icns)$/i.test(name) ? 'photo' : /\.(md|markdown)$/i.test(name) ? 'doc.richtext' : 'doc.text'}
            size={10} color={isDir ? 'color-mix(in srgb, var(--accent) 80%, transparent)' : 'var(--label-secondary)'} />
      </span>
      <span className="mc-ellipsis" style={{ color: status ? STATUS_TINT[status] : undefined, textDecoration: status === 'deleted' ? 'line-through' : undefined, flex: 1 }}>{name}</span>
      {status ? <span className="fp-badge" style={{ color: STATUS_TINT[status] }}>{STATUS_BADGE[status]}</span>
        : containsChanges ? <span className="dot" style={{ width: 5, height: 5, background: 'color-mix(in srgb, var(--orange) 70%, transparent)' }} /> : null}
    </div>
  );
  const failedText = 'Git status failed here — changed files aren\'t marked';
  return (
    <div className="fp-tree">
      {model.changedOnly ? <>
        {model.statuses.size === 0 && <div className="fp-note" style={{ color: model.statusFailed ? 'var(--label-secondary)' : undefined }}>{model.statusFailed ? failedText : 'No changes'}</div>}
        {[...model.statuses.keys()].sort().map(p => row(p, p, 0, false, p, model.statuses.get(p)))}
      </> : <>
        {!model.rootNodes.length && !model.loading && <div className="fp-note">Empty folder — drop files here to add some.</div>}
        {flatten(model.rootNodes, model.expanded).map(({ node, depth }) => row(node.path, node.name, depth, node.isDir, node.path, node.status, node.containsChanges))}
      </>}
      {model.statusFailed && !(model.changedOnly && model.statuses.size === 0) && <div className="fp-note" style={{ fontSize: 10, color: 'var(--label-secondary)' }}>{failedText}</div>}
    </div>
  );
}

function Detail({ model }: { model: FileExplorerModel }) {
  const d = model.detail;
  const name = model.selectedPath ? lastPathComponent(model.selectedPath) : '';
  return <>
    <div className="fp-detail-head">
      <span className="mc-ellipsis" style={{ fontWeight: 600 }} title={model.selectedPath ?? ''}>{name}</span>
      {d.kind === 'diff' && d.doc.additions + d.doc.deletions > 0 && <>
        <span style={{ fontSize: 10, fontWeight: 600, color: 'var(--green)' }}>+{d.doc.additions}</span>
        <span style={{ fontSize: 10, fontWeight: 600, color: 'var(--red)' }}>−{d.doc.deletions}</span>
      </>}
      <span className="mc-spacer" />
      {model.selectionHasDiff && <SegPicker size="mini" value={model.detailMode} onChange={m => model.setDetailMode(m)}
                                            options={[{ value: 'diff', label: 'Diff' }, { value: 'preview', label: 'File' }]} />}
      <button className="mc-icon-btn" title="Close" onClick={() => model.select(null)}><SF name="xmark" size={9} weight={600} /></button>
    </div>
    <div className="mc-divider" style={{ opacity: 0.5 }} />
    <div className="fp-detail-body">
      {d.kind === 'loading' ? <div className="fp-placeholder" style={{ height: '100%' }}><Spinner /></div>
        : d.kind === 'diff' ? (d.doc.lines.length ? <DiffLines lines={d.doc.lines} /> : <Centered text="No changes against HEAD" />)
        : d.kind === 'markdown' ? <div style={{ padding: 12 }}><Markdown text={d.text} /></div>
        : d.kind === 'code' ? <pre className="fp-code">{d.text}</pre>
        : d.kind === 'image' ? <div style={{ padding: 10 }}><img src={d.url} alt={name} style={{ maxWidth: '100%', display: 'block' }} /></div>
        : d.kind === 'binary' ? <Centered text="Binary file" />
        : d.kind === 'tooLarge' ? <Centered text="File is too large to preview" />
        : d.kind === 'error' ? <Centered text={d.message} /> : null}
    </div>
  </>;
}

const Centered = ({ text }: { text: string }) => <div className="fp-placeholder" style={{ height: '100%' }}><span className="mc-secondary" style={{ fontSize: 11 }}>{text}</span></div>;

function DiffLines({ lines }: { lines: DiffLine[] }) {
  return (
    <div style={{ padding: '4px 0' }}>
      {lines.map(l => (
        <div key={l.id} className={cx('df-line', l.kind === 'addition' && 'df-add', l.kind === 'deletion' && 'df-del', l.kind === 'hunk' && 'df-hunk', l.kind === 'meta' && 'df-meta')}>
          <span className="df-ann" />
          <span className="df-gutter">{l.oldLine ?? ''}</span>
          <span className="df-gutter">{l.newLine ?? ''}</span>
          <span className="df-text">{l.text || ' '}</span>
        </div>
      ))}
    </div>
  );
}

