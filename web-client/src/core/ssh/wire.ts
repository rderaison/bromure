// SSH binary encoding (RFC 4251 §5): byte, boolean, uint32, string, mpint,
// name-list. Shared by the transport, auth and connection layers.

const enc = new TextEncoder();
const dec = new TextDecoder();

export function utf8(s: string): Uint8Array { return enc.encode(s); }
export function fromUtf8(b: Uint8Array): string { return dec.decode(b); }

export function concat(...parts: Uint8Array[]): Uint8Array {
  let n = 0;
  for (const p of parts) n += p.length;
  const out = new Uint8Array(n);
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

export class Writer {
  private buf = new Uint8Array(256);
  private len = 0;

  private ensure(n: number) {
    if (this.len + n <= this.buf.length) return;
    let cap = this.buf.length * 2;
    while (cap < this.len + n) cap *= 2;
    const nb = new Uint8Array(cap);
    nb.set(this.buf.subarray(0, this.len));
    this.buf = nb;
  }
  byte(v: number): this { this.ensure(1); this.buf[this.len++] = v & 0xff; return this; }
  bool(v: boolean): this { return this.byte(v ? 1 : 0); }
  u32(v: number): this {
    this.ensure(4);
    this.buf[this.len++] = (v >>> 24) & 0xff; this.buf[this.len++] = (v >>> 16) & 0xff;
    this.buf[this.len++] = (v >>> 8) & 0xff;  this.buf[this.len++] = v & 0xff;
    return this;
  }
  raw(b: Uint8Array): this { this.ensure(b.length); this.buf.set(b, this.len); this.len += b.length; return this; }
  string(b: Uint8Array | string): this {
    const bytes = typeof b === 'string' ? utf8(b) : b;
    return this.u32(bytes.length).raw(bytes);
  }
  nameList(names: string[]): this { return this.string(names.join(',')); }
  /** mpint from an unsigned big-endian magnitude. */
  mpint(mag: Uint8Array): this {
    let i = 0;
    while (i < mag.length && mag[i] === 0) i++;
    let m = mag.subarray(i);
    if (m.length > 0 && (m[0] & 0x80)) m = concat(new Uint8Array([0]), m);
    return this.string(m);
  }
  bytes(): Uint8Array { return this.buf.slice(0, this.len); }
}

export class Reader {
  off = 0;
  constructor(readonly buf: Uint8Array) {}
  get remaining(): number { return this.buf.length - this.off; }
  private need(n: number) { if (this.off + n > this.buf.length) throw new Error('SSH: truncated message'); }
  byte(): number { this.need(1); return this.buf[this.off++]; }
  bool(): boolean { return this.byte() !== 0; }
  u32(): number {
    this.need(4);
    const b = this.buf, o = this.off;
    this.off += 4;
    return ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) >>> 0;
  }
  raw(n: number): Uint8Array { this.need(n); const v = this.buf.subarray(this.off, this.off + n); this.off += n; return v; }
  string(): Uint8Array { return this.raw(this.u32()); }
  text(): string { return fromUtf8(this.string()); }
  nameList(): string[] { const s = this.text(); return s ? s.split(',') : []; }
  rest(): Uint8Array { return this.raw(this.remaining); }
}

export function toBase64(b: Uint8Array): string {
  let s = '';
  for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000));
  return btoa(s);
}
export function fromBase64(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
export function toHex(b: Uint8Array): string {
  return Array.from(b, x => x.toString(16).padStart(2, '0')).join('');
}
export function equalBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i];
  return d === 0;
}
