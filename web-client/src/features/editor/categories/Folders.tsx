// Folders — ProfileViews.swift `foldersSection` (+ `importedFilesSection`,
// exported for the Credentials pane, which is where the Swift shows it).
//
// The folders are paths on the machine that runs the VMs. The Mac editor
// browses them with an NSOpenPanel on the server's own disk; a remote client
// can't browse it, so — like the iOS editor — "Add folder…" asks for the
// server path in a prompt.

import React, { useState } from 'react';
import { Button } from '../../../ui/kit';
import { SF } from '../../../ui/icons';
import { useEditor } from '../ctx';
import { val } from '../model';
import { Caption, Headline } from '../ui';
import { RemoveButton, RowCard, TextPrompt } from './FoldersKit';

const MAX = 8;

export function FoldersPane() {
  const { doc, set } = useEditor();
  const paths = val<string[]>(doc, 'folderPaths');
  const [prompt, setPrompt] = useState(false);
  return (
    <div className="edm-pane" style={{ gap: 10 }}>
      <Caption>Add your personal projects and folders to mount in this workspace. Each one keeps its name inside, and you can add up to 8.</Caption>
      {paths.length === 0 ? (
        <div className="edm-empty">No folders shared.</div>
      ) : paths.map((p, i) => (
        <RowCard key={i}>
          <div className="edm-row">
            <SF name="folder" size={14} color="var(--label-secondary)" />
            <div style={{ display: 'flex', flexDirection: 'column', gap: 1, minWidth: 0, flex: 1 }}>
              <span className="edm-folder-name">{p.replace(/\/+$/, '').split('/').pop() || p}</span>
              <span className="edm-folder-path" title={p}><bdi>{p}</bdi></span>
            </div>
            <RemoveButton onClick={() => set('folderPaths', paths.filter((_, j) => j !== i))} />
          </div>
        </RowCard>
      ))}
      <div className="edm-trailing">
        <Button icon="plus" disabled={paths.length >= MAX} onClick={() => setPrompt(true)}>Add folder…</Button>
      </div>
      {prompt && (
        <TextPrompt title="Add a shared folder"
                    message="Enter the folder's absolute path on the server; it's mounted into the VM under its own name."
                    placeholder="/Users/you/Projects/app"
                    onCancel={() => setPrompt(false)}
                    onOK={v => {
                      setPrompt(false);
                      const path = v.trim();
                      if (path && !paths.includes(path) && paths.length < MAX) set('folderPaths', [...paths, path]);
                    }} />
      )}
    </div>
  );
}

/** ConfigScan.settingCount */
function settingCount(body: string): number {
  return body.split(/\r?\n/).filter(l => { const t = l.trim(); return t && !/^[#;[]/.test(t); }).length;
}

/** Config files carried over whole by the setup wizard (`importedFilesSection`). */
export function ImportedFilesSection() {
  const { doc, set } = useEditor();
  const files = val<{ path: string; contents?: string; strippedSecrets?: number; disabled?: string[] }[]>(doc, 'importedConfigFiles');
  if (!files.length) return null;
  const subtitle = (f: typeof files[number]) => {
    const n = settingCount(f.contents ?? '');
    const bits = [`${n} setting${n === 1 ? '' : 's'}`];
    if ((f.strippedSecrets ?? 0) > 0) bits.push(`${f.strippedSecrets} secret${f.strippedSecrets === 1 ? '' : 's'} left out`);
    if (f.disabled?.length) bits.push(`${f.disabled.join(', ')} disabled`);
    return bits.join(' · ');
  };
  return (
    <div className="edm-pane" style={{ gap: 6 }}>
      <Headline>Imported Config Files</Headline>
      {files.map(f => (
        <RowCard key={f.path}>
          <div className="edm-row" style={{ alignItems: 'flex-start' }}>
            <SF name="doc.text" size={14} color="var(--label-secondary)" />
            <div style={{ display: 'flex', flexDirection: 'column', gap: 1, flex: 1, minWidth: 0 }}>
              <span className="edm-mono12">~/{f.path}</span>
              <Caption>{subtitle(f)}</Caption>
            </div>
            <RemoveButton help="Remove this file from the workspace"
                          onClick={() => set('importedConfigFiles', files.filter(x => x.path !== f.path))} />
          </div>
        </RowCard>
      ))}
      <Caption>Copied into the VM as-is. Secrets were left out — those come in as credentials above, so the VM only ever sees a fake.</Caption>
    </div>
  );
}
