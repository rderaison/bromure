// RemoteStagePlaceholderView (FatClientController.swift): the stage's backdrop
// while nothing is on it — and, before the host's first /state, a
// "Connecting…" cue. The stage mounts it when the selection is empty.

import React from 'react';
import { useHostCtx } from '../../app/hostContext';
import { useHost } from '../../app/store';
import { Spinner } from '../../ui/kit';
import './sidebar.css';

export function StagePlaceholder(_props: {} = {}) {
  const { host } = useHostCtx();
  useHost(host);
  return (
    <div className="stage-placeholder">
      {!host.state && (
        <div className="stage-placeholder-inner">
          <Spinner size={20} />
          <div className="stage-placeholder-title">Connecting…</div>
          <div className="stage-placeholder-sub">Waiting for the host's first update.</div>
        </div>
      )}
    </div>
  );
}
export default StagePlaceholder;
