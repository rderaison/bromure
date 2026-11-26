import { describe, it, expect } from 'vitest';
import { FileExplorerModel } from '../src/features/machines/fileModel';

// Regression (CWE-362): the Files pane keeps one model across selections and
// its file ops followed the CURRENT workspace. An upload into workspace A
// whose source failed after the user switched to B sent its cleanup
// `remove` for the same path to B (deleting B's file); closing the pane made
// the cleanup fail and left the partial file in A. A transfer's writes and
// cleanup now all go to the workspace it started on.

function fakeHost() {
  const ops: string[] = [];
  const host = {
    guestExec: async () => '',
    guestFileOp: async (ws: string, op: Record<string, any>) => { ops.push(`${ws} ${op.op}`); return {}; },
  };
  return { ops, host: host as any };
}

/** A file whose bytes fail after the first chunk — after `meanwhile` ran. */
function failingFile(meanwhile: () => void): File {
  let n = 0;
  const stream = () => new ReadableStream<Uint8Array>({
    pull(c) {
      // One full chunk (6 MB): written to the guest before the source fails.
      if (n++ === 0) { c.enqueue(new Uint8Array(6 * 1024 * 1024)); return; }
      meanwhile();
      c.error(new Error('source read failed'));
    },
  });
  return { name: 'big.bin', size: 12 * 1024 * 1024, stream } as unknown as File;
}

describe('Files pane transfers stay on their workspace', () => {
  for (const [what, next] of [['the user picks another workspace', 'B'], ['the pane closes', null]] as const) {
    it(`a failed upload cleans up in the workspace it wrote to when ${what}`, async () => {
      const { ops, host } = fakeHost();
      const m = new FileExplorerModel(host);
      m.setLocation('A', '/home/ubuntu', null);
      await new Promise(r => setTimeout(r, 0));
      ops.length = 0;
      await m.receive([{ name: 'big.bin', isDir: false, file: failingFile(() => m.setLocation(next, next ? '/home/ubuntu' : null, null)) }]);
      const transfer = ops.filter(o => / (write|remove|rename)$/.test(o));
      expect(transfer.some(o => o.endsWith(' remove'))).toBe(true);           // the partial copy is removed…
      expect(transfer.every(o => o.startsWith('A '))).toBe(true);             // …in A, never in B
    });
  }
});
