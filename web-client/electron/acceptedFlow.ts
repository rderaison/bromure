// Flow control for an accepted loopback connection (a model sign-in's OAuth
// callback, spliced to an SSH forward channel by the renderer). Any local
// process may connect while a sign-in listens, so neither direction may
// buffer without bound:
//   local → renderer: at most HIGH bytes are sent and not yet acked before
//     the socket stops being read (the renderer acks once its SSH channel has
//     taken them); reading resumes below LOW.
//   renderer → local: when the socket's buffer is full the renderer is told
//     `pause` (it pauses its channel; the SSH window then holds the VM),
//     `resume` on drain; a socket holding more than MAX_BUFFERED unread is
//     closed.
// No Electron here (main.ts wires it), so it's testable with plain sockets.

import type net from 'node:net';

export const FLOW_HIGH = 1 << 20;
export const FLOW_LOW = 256 << 10;
export const MAX_BUFFERED = 8 << 20;

export type FlowEvent = { kind: 'data'; data: Uint8Array } | { kind: 'pause' } | { kind: 'resume' };

export interface AcceptedFlow {
  /** Start reading (the renderer's stream is wired). */
  start(): void;
  /** The renderer's channel took `n` bytes. */
  ack(n: number): void;
  /** Bytes for the local program. */
  write(data: Uint8Array): void;
}

export function acceptedFlow(s: net.Socket, emit: (e: FlowEvent) => void): AcceptedFlow {
  let inflight = 0;
  let readPaused = false;
  let writeHeld = false;
  return {
    start() {
      s.on('data', (d: Buffer) => {
        emit({ kind: 'data', data: new Uint8Array(d.buffer, d.byteOffset, d.length) });
        inflight += d.length;
        if (inflight > FLOW_HIGH && !readPaused) { readPaused = true; s.pause(); }
      });
      s.on('drain', () => { if (writeHeld) { writeHeld = false; emit({ kind: 'resume' }); } });
    },
    ack(n: number) {
      inflight = Math.max(0, inflight - (Number.isFinite(n) && n > 0 ? n : 0));
      if (readPaused && inflight < FLOW_LOW) { readPaused = false; s.resume(); }
    },
    write(data: Uint8Array) {
      if (s.destroyed) return;
      if (s.write(data)) return;
      if (s.writableLength > MAX_BUFFERED) { s.destroy(); return; }   // not reading: closed
      if (!writeHeld) { writeHeld = true; emit({ kind: 'pause' }); }
    },
  };
}
