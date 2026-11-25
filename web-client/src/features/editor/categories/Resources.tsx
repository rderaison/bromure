// Resources — ProfileViews.swift `resourcesSection`, `homeSizeSection`,
// StorageStackView / StorageLayerRow, fed by the server's measurement
// (GET /profiles/<id>?storage=1 → ctx.storage, FatClientController.fetchStorageContext).
// As in the fat client, erasing / resetting / restoring storage is done on the
// server Mac: the buttons show, disabled, with that explanation.

import React, { useEffect, useState } from 'react';
import { SF } from '../../../ui/icons';
import { useEditor } from '../ctx';
import type { StorageInfo } from '../ctx';
import { val } from '../model';
import { Caption, Divider, Headline, formatBytes } from '../ui';
import { RadioGroup, Stepper, relativeAge } from './FoldersKit';

const MIN_HOME_GB = 8;
const REMOTE_HELP = 'Erasing and restoring storage is done on the server Mac.';

export function ResourcesPane() {
  const { doc, set, update, mode, storage, refreshStorage, opened } = useEditor();
  // Each time the pane shows, the storage is measured again.
  useEffect(() => { refreshStorage(); }, [refreshStorage]);
  const real = mode === 'workspace' && storage;
  const memory = val<number>(doc, 'memoryGB');
  const network = val<'nat' | 'bridged'>(doc, 'networkMode');
  return (
    <div className="edm-pane" style={{ gap: 16 }}>
      <div className="edm-pane" style={{ gap: 6 }}>
        <Headline>Storage</Headline>
        <Caption>Three layers stack to make this workspace's environment. The bottom is shared and immutable; the top two are yours and can be erased independently.</Caption>
        {real
          ? <StorageStack s={storage!} />
          : <Caption>Storage controls only apply to real workspaces. They appear in each workspace's editor when you create or edit one.</Caption>}
      </div>

      {val<string>(doc, 'homeModel') === 'ext4' && (
        <>
          <Divider />
          <HomeSize storage={storage} setting={doc.homeImageGB ?? null} saved={opened.homeImageGB ?? null}
                    onChange={gb => update(d => { if (gb == null) delete d.homeImageGB; else d.homeImageGB = gb; })} />
        </>
      )}

      <Divider />

      <div className="edm-pane" style={{ gap: 6 }}>
        <Headline>Memory</Headline>
        <div className="edm-row" style={{ gap: 8 }}>
          <span className="ed-body">VM RAM: {memory} GB</span>
          <Stepper value={memory} min={2} max={32} step={2} onChange={v => set('memoryGB', v)} />
        </div>
        <Caption>Bump this if Claude / Codex feels sluggish or rust builds OOM.</Caption>
      </div>

      <Divider />

      <div className="edm-pane" style={{ gap: 6 }}>
        <Headline>Network</Headline>
        <RadioGroup value={network} onChange={v => set('networkMode', v)}
                    options={[{ value: 'nat', label: 'NAT' }, { value: 'bridged', label: 'Bridged' }]} />
        {network === 'bridged'
          ? <Caption>The VM gets a LAN-routable IP via DHCP on an interface the server picks (it falls back to NAT when none is bridgeable).</Caption>
          : <Caption>VM sits behind NAT. Egress works; nothing on your LAN can reach it.</Caption>}
      </div>
    </div>
  );
}

function HomeSize({ storage, setting, saved, onChange }: {
  storage: StorageInfo | null; setting: number | null; saved: number | null; onChange: (gb: number | null) => void;
}) {
  const existing = storage && storage.homeCapacity > 0 ? Math.floor(storage.homeCapacity / 2 ** 30) : null;
  const def = storage?.defaultHomeGB ?? 16;
  const current = existing ?? def;
  const floor = existing ?? MIN_HOME_GB;
  const shown = setting != null ? Math.max(setting, floor) : current;
  const settingFor = (v: number) => { const gb = Math.min(1024, Math.max(floor, v)); return gb === current && saved == null ? null : gb; };
  const [text, setText] = useState<string | null>(null);
  return (
    <div className="edm-pane" style={{ gap: 6 }}>
      <Headline>Home folder size</Headline>
      <div className="edm-row">
        <input className="field ed-field edm-numfield" style={{ width: 72, flex: "none" }} inputMode="numeric" aria-label="Home folder size" value={text ?? String(shown)}
               onChange={e => setText(e.target.value)}
               onBlur={() => { const n = parseInt(text ?? '', 10); if (!isNaN(n)) onChange(settingFor(n)); setText(null); }}
               onKeyDown={e => { if (e.key === 'Enter') (e.target as HTMLInputElement).blur(); }} />
        <span className="ed-body">GB</span>
        <Stepper value={shown} min={floor} max={1024} step={8} onChange={v => onChange(settingFor(v))} />
      </div>
      <Caption>{existing == null
        ? `From ${floor} GB up to 1024 GB. The home is created at this size when the workspace first starts; after that it can grow but not shrink. The disk image only takes the space its files use.`
        : `From ${current} GB (its current size — a home can't shrink) up to 1024 GB. A bigger home takes effect the next time the workspace starts. The disk image only takes the space its files use.`}</Caption>
    </div>
  );
}

function StorageStack({ s }: { s: StorageInfo }) {
  const homeImage = s.hasHome && s.homeIsImage;
  const homeMeta = !s.hasHome ? 'Not yet created.'
    : s.homeModified ? `Active ${relativeAge(new Date(s.homeModified))}.` : 'Quiet — no recent activity.';
  const diskMeta = !s.hasDisk ? 'Not yet cloned.' : s.baseVersion ? `Cloned from base v${s.baseVersion}.` : 'Cloned from base.';
  const baseParts: string[] = [];
  if (s.baseVersion) baseParts.push(`v${s.baseVersion}`);
  if (s.baseBuildDate) baseParts.push(`built ${new Date(s.baseBuildDate).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })}`);
  return (
    <div className="edm-stack">
      <Layer accent={['#ffb340', '#ff9500']} symbol="house.fill" symColor="var(--orange)" title="Your home folder"
             subtitle={homeImage
               ? 'Project clones, dotfiles, .ssh keys, npm-global, .cargo, shell history — on a private ext4 disk image that shrinks as files are deleted.'
               : 'Project clones, dotfiles, .ssh keys, npm-global, .cargo, shell history, anything in /home/ubuntu.'}
             meta={homeMeta} size={s.homeBytes} actions={[{ label: 'Erase home…', destructive: true }]} />
      <Layer accent={['#3395ff', '#007aff']} symbol="internaldrive.fill" symColor="var(--blue)" title="Workspace system disk"
             subtitle="A read-write copy of the base OS, just for this workspace. Holds anything you `sudo apt install`, edits to /etc and /var, system-level config."
             meta={diskMeta} size={s.diskBytes} actions={[{ label: 'Reset to base…', destructive: true }]} />
      <Layer accent={['#a4a4a8', '#8e8e93']} symbol="cube.fill" symColor="var(--gray)" title="Base OS image"
             subtitle="Ubuntu Noble + Node, Claude Code, Codex, gh, glab, fonts. Shared by every workspace, immutable at runtime."
             meta={baseParts.length ? baseParts.join(' · ') : 'Built once per app version.'} size={s.baseBytes}
             note="Rebuild via the app menu (∼5–10 min)." noteHelp="Affects every workspace, so it's parked outside this editor." />
    </div>
  );
}

function Layer({ accent, symbol, symColor, title, subtitle, meta, size, actions, note, noteHelp }: {
  accent: [string, string]; symbol: string; symColor: string; title: string; subtitle: string; meta: string; size: number;
  actions?: { label: string; destructive?: boolean }[]; note?: string; noteHelp?: string;
}) {
  return (
    <div className="edm-layer">
      <div className="edm-layer-edge" style={{ background: `linear-gradient(${accent[0]}, ${accent[1]})` }} />
      <div className="edm-layer-body">
        <div className="edm-layer-head">
          <span className="edm-layer-sym" style={{ color: symColor }}><SF name={symbol} size={15} color={symColor} /></span>
          <span className="edm-layer-title">{title}</span>
          <span className="edm-layer-size">{size ? formatBytes(size) : '—'}</span>
        </div>
        <Caption>{subtitle}</Caption>
        <div className="edm-layer-meta" style={actions?.length ? undefined : { minHeight: 0 }}>
          <span className="ed-caption">{meta}</span>
          {actions?.map(a => <button key={a.label} className="btn small" disabled title={REMOTE_HELP}>{a.label}</button>)}
        </div>
        {note && <span className="ed-caption" style={{ color: 'var(--label-tertiary)' }} title={noteHelp}>{note}</span>}
      </div>
    </div>
  );
}
