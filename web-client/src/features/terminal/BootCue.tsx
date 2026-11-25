// BootAnimationView.swift's dive HUD: shown over a workspace's terminal
// while its VM boots and the guest tmux roster hasn't landed. Black field,
// a soft accent glow, the workspace name in tracked mono caps, a sweeping
// scan packet (or a determinate bar), an optional status line, and a slow
// scanline sheen. The fat client never shows the watchdog failure panels
// (its onReset / onKeepWaiting are no-ops), so neither does the web.

import React from 'react';

export function BootCue({ name, accentHex, statusText, progress }: {
  name: string; accentHex?: string; statusText?: string | null; progress?: number | null;
}) {
  const accent = /^#[0-9a-f]{6}$/i.test(accentHex ?? '') ? accentHex! : '#38f9d7';
  return (
    <div className="term-boot" style={{ ['--boot-accent' as any]: accent }}>
      <div className="term-boot-glow" />
      <div className="term-boot-vignette" />
      <div className="term-boot-hud">
        <div className="term-boot-name">{name ? name.toUpperCase() : 'WORKSPACE'}</div>
        {progress != null ? (
          <div className="term-boot-track">
            <div className="term-boot-fill" style={{ width: `max(4px, ${Math.min(1, Math.max(0, progress)) * 100}%)` }} />
          </div>
        ) : (
          <div className="term-boot-track"><div className="term-boot-packet" /></div>
        )}
        {statusText ? <div className="term-boot-status">{statusText}</div> : null}
      </div>
      <div className="term-boot-scan" />
    </div>
  );
}
