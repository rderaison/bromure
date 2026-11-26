// SSHChannel.eof() must not overtake data still queued for the peer's window:
// the network tunnel half-closes a channel as soon as the local program does,
// often with the tail of a request or upload still waiting on a window adjust.

import { describe, it, expect } from 'vitest';
import { SSHChannel, type SSHConnection } from '../src/core/ssh/client';

const DATA = 94, EOF = 96, CLOSE = 97; // RFC 4254 message numbers

function channel(window: number) {
  const sent: { type: number; len: number }[] = [];
  const conn = {
    sendPacket: (p: Uint8Array) => {
      // CHANNEL_DATA: byte type, u32 channel, string data (u32 length + bytes)
      const len = p[0] === DATA ? new DataView(p.buffer, p.byteOffset + 5, 4).getUint32(0) : 0;
      sent.push({ type: p[0], len });
    },
    finishChannel: (ch: SSHChannel) => { ch.closed = true; },
  } as unknown as SSHConnection;
  const ch = new SSHChannel(conn, 0);
  ch.remoteWindow = window;
  return { ch, sent };
}

/** What the peer's window adjust does (SSHConnection's CHANNEL_WINDOW_ADJUST). */
function adjust(ch: SSHChannel, n: number) { ch.remoteWindow += n; ch.flush(); }

describe('SSHChannel.eof', () => {
  it('waits for the bytes still queued on the peer\'s window', () => {
    const { ch, sent } = channel(10);
    ch.write(new Uint8Array(30));          // 10 go out, 20 wait for the window
    ch.eof();                              // the local program half-closed
    expect(sent.map(s => s.type)).toEqual([DATA]);
    expect(ch.queuedBytes).toBe(20);

    adjust(ch, 15);                        // 15 more: still 5 queued, no EOF yet
    expect(sent.map(s => s.type)).toEqual([DATA, DATA]);

    adjust(ch, 100);                       // the rest, THEN the EOF
    expect(sent.map(s => s.type)).toEqual([DATA, DATA, DATA, EOF]);
    expect(sent.filter(s => s.type === DATA).reduce((n, s) => n + s.len, 0)).toBe(30);

    adjust(ch, 100);                       // only one EOF
    ch.eof();
    expect(sent.filter(s => s.type === EOF)).toHaveLength(1);
  });

  it('is immediate with nothing queued, and refuses writes after it', () => {
    const { ch, sent } = channel(100);
    ch.write(new Uint8Array(5));
    ch.eof();
    expect(sent.map(s => s.type)).toEqual([DATA, EOF]);
    ch.write(new Uint8Array(5));
    expect(sent.map(s => s.type)).toEqual([DATA, EOF]);
  });

  it('refuses writes while its EOF waits, and drains them in order', () => {
    const { ch, sent } = channel(0);
    ch.write(new Uint8Array(8));
    ch.eof();
    ch.write(new Uint8Array(8));           // after eof(): not sent, ever
    adjust(ch, 100);
    expect(sent.map(s => s.type)).toEqual([DATA, EOF]);
    expect(sent[0].len).toBe(8);
  });

  it('a close still aborts (no EOF after it)', () => {
    const { ch, sent } = channel(0);
    ch.write(new Uint8Array(8));
    ch.eof();
    ch.close();
    adjust(ch, 100);
    expect(sent.map(s => s.type)).toEqual([CLOSE]);
  });
});
