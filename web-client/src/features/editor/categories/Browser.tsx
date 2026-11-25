// Browser — ProfileViews.swift `browserSection`.
//
// The "Browser image" block (BrowserImageInstaller) reports and downloads the
// image on the Mac the app runs on; a remote client has no browser image of
// its own to manage, so — like the iOS editor — it's left out.

import React from 'react';
import { useEditor } from '../ctx';
import { val } from '../model';
import { Caption, Divider, InfoTip } from '../ui';
import { MacCheck, SymLabel } from './FoldersKit';

export function BrowserPane() {
  const { doc, set } = useEditor();
  const disabled = val<boolean>(doc, 'browserDisabled');
  const policy = val<string>(doc, 'networkPolicy');
  const usesOpenShell = policy.trim() !== '';
  const processSection = policy.split('\n').some(l => l.startsWith('process:') && !l.startsWith('process: null') && !l.startsWith('process: ~'));
  const sandboxed = val<boolean>(doc, 'strictSandbox') || processSection || usesOpenShell;
  const check = (key: string, symbol: string, label: string) => (
    <MacCheck checked={val<boolean>(doc, key)} disabled={disabled} onChange={v => set(key, v)}>
      <SymLabel symbol={symbol}>{label}</SymLabel>
    </MacCheck>
  );
  return (
    <div className="edm-pane" style={{ gap: 12 }}>
      <Caption md>{'This workspace has an embedded Chromium browser its agents can drive (navigate, click, type, screenshot, read the network log and console) through the built-in `browser` MCP server. The browser runs in its own disposable VM.'}</Caption>

      <div className="edm-pane" style={{ gap: 4 }}>
        <div className="edm-row">
          <MacCheck checked={!disabled} onChange={v => set('browserDisabled', !v)}>
            <SymLabel symbol="globe">Web browser</SymLabel>
          </MacCheck>
          <InfoTip text={'The browser runs in its own VM, outside this workspace\'s network policy: an agent driving it can reach any website, whatever the policy allows. Turn it off for a sandboxed workspace whose agents must stay inside its allowed list — the browser pane stays empty and the agents\' `browser` tools refuse. Takes effect at once; a running browser is closed.'} />
        </div>
        {disabled
          ? <Caption>Off: no browser for the user or the agents.</Caption>
          : sandboxed && <Caption style={{ color: 'var(--orange)' }}>This workspace is sandboxed, but the browser isn't: it can reach any website.</Caption>}
      </div>

      <Divider />

      <div className="edm-pane" style={{ gap: 4 }}>
        {check('browserPersistent', 'person.badge.key.fill', 'Stay signed in to websites')}
        <Caption style={disabled ? { opacity: 0.45 } : undefined}>Off (default) → the browser starts from a clean profile every time and forgets everything when the window closes — fully ephemeral. On → cookies, logins, and history are kept on an encrypted per-workspace disk (~/Library/Application Support/BromureAC/browser-profiles/), so the agent stays signed in to sites between sessions.</Caption>
      </div>

      <Divider />

      <div className="edm-pane" style={{ gap: 4 }}>
        <div className="edm-section-caps" style={disabled ? { opacity: 0.45 } : undefined}>PERMISSIONS</div>
        {check('browserAllowUploads', 'arrow.up.doc.fill', 'Allow file uploads')}
        {check('browserAllowDownloads', 'arrow.down.doc.fill', 'Allow file downloads')}
        {check('browserWebcam', 'video.fill', 'Allow camera')}
        {check('browserMicrophone', 'mic.fill', 'Allow microphone')}
        <Caption style={disabled ? { opacity: 0.45 } : undefined}>Uploads and downloads are on by default. The camera and microphone are off by default — turning one on exposes that host device to pages the browser (and the agent) opens, and keeps WebRTC enabled. Changes take effect the next time the browser opens; an open browser is restarted to apply them.</Caption>
      </div>

      <Divider />
    </div>
  );
}
