// A model sign-in (Claude, ChatGPT, …) run on the HOST in a throwaway VM:
// what the client may open, and how the provider's loopback callback gets back
// to the CLI waiting in that VM. The provider redirects the user's browser to
// the redirect_uri the guest CLI chose — http://localhost:<port>/callback —
// which only the CLI's listener inside the VM can answer. The macOS client
// listens on that port locally and tunnels it (RegistrationCallbackTunnel);
// Electron does the same; a hosted page can't listen, so the user pastes the
// address the browser ended on and the client delivers it through the same
// `forward <vmIP> <port>` channel.

// ── which sign-in pages open (AgentScreen.signInPages / GuestURLGate) ─────

interface Page { kind: 'device' | 'authorize'; hosts: string[]; paths: string[]; clientIDs?: string[]; codePages?: string[]; requiredQuery?: string }
const CLAUDE_CLIENT_ID = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
const CLAUDE: Page[] = [{ kind: 'authorize', hosts: ['claude.ai', 'claude.com', 'platform.claude.com', 'console.anthropic.com'],
  paths: ['/oauth/authorize', '/cai/oauth/authorize'], clientIDs: [CLAUDE_CLIENT_ID], codePages: ['platform.claude.com', 'console.anthropic.com'] }];
const CODEX: Page[] = [
  { kind: 'device', hosts: ['auth.openai.com'], paths: ['/codex/device'] },
  { kind: 'authorize', hosts: ['auth.openai.com'], paths: ['/oauth/authorize'] },
];
const PAGES: Record<string, Page[]> = {
  claude: CLAUDE, codex: CODEX,
  grok: [
    { kind: 'device', hosts: ['accounts.x.ai', 'auth.x.ai'], paths: ['/oauth2/device'] },
    { kind: 'authorize', hosts: ['accounts.x.ai', 'auth.x.ai'], paths: ['/oauth2/auth', '/oauth2/authorize'] },
  ],
  kimi: [{ kind: 'device', hosts: ['auth.kimi.ai', 'kimi.ai', 'www.kimi.ai', 'auth.kimi.com', 'kimi.com', 'www.kimi.com'],
    paths: ['/device', '/authorize_device', '/code/authorize_device', '/api/oauth/authorize_device'] }],
  nous: [{ kind: 'device', hosts: ['portal.nousresearch.com'], paths: ['/manage-subscription'], requiredQuery: 'user_code' }],
};
const isLoopbackHost = (h: string) => h === 'localhost' || h === '127.0.0.1' || h === '[::1]' || h === '::1';

/** Whether the sign-in URL the host published for `agent` (the registration's
 *  provider: claude, codex, grok, kimi, nous) is that agent's own sign-in page
 *  — exact https host and path, its own client, a loopback (or its own code
 *  page) redirect. Anything else is never opened: a guest could otherwise
 *  point the user's browser anywhere, the LAN and loopback included. */
export function isAgentSignInURL(raw: string, agent: string): boolean {
  let u: URL;
  try { u = new URL(raw); } catch { return false; }
  if (u.protocol !== 'https:' || u.username || u.password) return false;
  const host = u.hostname.toLowerCase(), path = u.pathname.toLowerCase();
  for (const p of PAGES[agent] ?? []) {
    if (!p.hosts.includes(host) || !p.paths.includes(path)) continue;
    if (p.requiredQuery && !u.searchParams.get(p.requiredQuery)) continue;
    if (p.kind === 'device') return true;
    if (p.clientIDs && !p.clientIDs.includes(u.searchParams.get('client_id') ?? '')) continue;
    let r: URL;
    try { r = new URL(u.searchParams.get('redirect_uri') ?? ''); } catch { continue; }
    const rh = r.hostname.toLowerCase();
    if (isLoopbackHost(rh) || (r.protocol === 'https:' && (p.codePages ?? []).includes(rh))) return true;
  }
  return false;
}

// ── the loopback callback ─────────────────────────────────────────────────

/** The path + query of a pasted callback address, or an error to show. Only
 *  `http://localhost:<port>/…` (or 127.0.0.1) on the port the VM's CLI is
 *  waiting on is accepted — it's delivered to nothing else. */
export function parseCallbackPaste(text: string, port: number): { path: string } | { error: string } {
  const t = text.trim();
  if (!t) return { error: 'Paste the address your browser ended on.' };
  let u: URL;
  try { u = new URL(/^[a-z]+:\/\//i.test(t) ? t : 'http://' + t); } catch { return { error: 'That isn’t an address.' }; }
  if (u.protocol !== 'http:' || !isLoopbackHost(u.hostname.toLowerCase()) || Number(u.port || 80) !== port) {
    return { error: `That isn’t the sign-in’s return address (http://localhost:${port}/…).` };
  }
  if (!u.search) return { error: 'That address has no sign-in result in it — copy the whole address from the address bar.' };
  return { path: u.pathname + u.search };
}

/** A byte channel to the VM's loopback port (`forward <vmIP> <port>`). */
export interface ForwardChannel {
  write(d: Uint8Array): void; close(): void; resume?(): void;
  onData: (d: Uint8Array) => void; onClose: () => void; onEOF?: () => void;
}

/** Deliver the callback to the CLI in the VM as the browser would have (a
 *  GET on its loopback listener) and return the HTTP status it answers. */
export async function deliverCallback(open: () => Promise<ForwardChannel>, port: number, path: string, timeoutMs = 20000): Promise<number> {
  const ch = await open();
  const req = `GET ${path} HTTP/1.1\r\nHost: localhost:${port}\r\nUser-Agent: Bromure\r\nAccept: */*\r\nConnection: close\r\n\r\n`;
  return new Promise<number>((resolve, reject) => {
    let head = '', done = false;
    const dec = new TextDecoder();
    const finish = (status?: number, err?: Error) => {
      if (done) return; done = true; clearTimeout(timer);
      try { ch.close(); } catch {}
      if (status) resolve(status); else reject(err ?? new Error('The sign-in machine closed the connection without answering.'));
    };
    const timer = setTimeout(() => finish(undefined, new Error('The sign-in machine didn’t answer.')), timeoutMs);
    ch.onData = d => {
      head += dec.decode(d, { stream: true });
      const m = /^HTTP\/1\.[01] (\d{3})/.exec(head);
      if (m) finish(Number(m[1]));
      else if (head.length > 4096) finish(undefined, new Error('The sign-in machine’s answer wasn’t HTTP.'));
    };
    ch.onClose = () => finish();
    ch.onEOF = () => finish();
    ch.resume?.();
    ch.write(new TextEncoder().encode(req));
  });
}
