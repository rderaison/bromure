import { describe, it, expect } from 'vitest';
import { isAgentSignInURL, parseCallbackPaste, deliverCallback, type ForwardChannel } from '../src/features/editor/categories/signIn';

const CLAUDE = (redirect: string, client = '9d1c250a-e61b-44d9-88ed-5944d1962f5e', host = 'claude.ai') =>
  `https://${host}/oauth/authorize?code=true&client_id=${client}&response_type=code&redirect_uri=${encodeURIComponent(redirect)}&scope=user%3Ainference&state=abc`;

describe('isAgentSignInURL (what a host-published sign-in page may open)', () => {
  it("opens the agent's own sign-in page with a loopback or code-page redirect", () => {
    expect(isAgentSignInURL(CLAUDE('http://localhost:36895/callback'), 'claude')).toBe(true);
    expect(isAgentSignInURL(CLAUDE('https://platform.claude.com/oauth/code/callback'), 'claude')).toBe(true);
    expect(isAgentSignInURL('https://auth.openai.com/codex/device', 'codex')).toBe(true);
    expect(isAgentSignInURL('https://portal.nousresearch.com/manage-subscription?user_code=AB-CD', 'nous')).toBe(true);
  });
  it('never anything else', () => {
    expect(isAgentSignInURL(CLAUDE('http://localhost:36895/callback'), 'codex')).toBe(false);          // another agent's page
    expect(isAgentSignInURL(CLAUDE('http://localhost:1/cb', 'someone-else'), 'claude')).toBe(false);  // another client
    expect(isAgentSignInURL(CLAUDE('https://evil.example/cb'), 'claude')).toBe(false);                // redirect off-loopback
    expect(isAgentSignInURL(CLAUDE('http://localhost:1/cb', undefined, 'claude.ai.evil.example'), 'claude')).toBe(false);
    expect(isAgentSignInURL('http://claude.ai/oauth/authorize', 'claude')).toBe(false);                // not https
    expect(isAgentSignInURL('https://user@auth.openai.com/codex/device', 'codex')).toBe(false);        // userinfo
    expect(isAgentSignInURL('https://192.168.1.1/codex/device', 'codex')).toBe(false);
    expect(isAgentSignInURL('https://portal.nousresearch.com/manage-subscription', 'nous')).toBe(false); // no code
    expect(isAgentSignInURL('not a url', 'claude')).toBe(false);
  });
});

describe('parseCallbackPaste', () => {
  it("takes the browser's localhost address on the VM's port", () => {
    expect(parseCallbackPaste('http://localhost:36895/callback?code=X&state=Y', 36895)).toEqual({ path: '/callback?code=X&state=Y' });
    expect(parseCallbackPaste('  localhost:36895/callback?code=X  ', 36895)).toEqual({ path: '/callback?code=X' });
    expect(parseCallbackPaste('http://127.0.0.1:36895/auth/callback?code=X', 36895)).toEqual({ path: '/auth/callback?code=X' });
  });
  it('refuses anything else', () => {
    for (const t of ['', 'http://localhost:1234/callback?code=X', 'https://localhost:36895/callback?code=X',
                     'http://evil.example:36895/callback?code=X', 'http://localhost:36895/callback', 'nonsense ::'])
      expect('error' in parseCallbackPaste(t, 36895)).toBe(true);
  });
});

describe('deliverCallback', () => {
  it('GETs the path on the VM loopback port and returns the status', async () => {
    let written = '';
    let closed = false;
    const ch: ForwardChannel = {
      write(d) { written += new TextDecoder().decode(d); queueMicrotask(() => ch.onData(new TextEncoder().encode('HTTP/1.1 302 Found\r\nLocation: https://x\r\n\r\n'))); },
      close() { closed = true; }, onData: () => {}, onClose: () => {},
    };
    expect(await deliverCallback(async () => ch, 36895, '/callback?code=X&state=Y')).toBe(302);
    expect(written).toBe('GET /callback?code=X&state=Y HTTP/1.1\r\nHost: localhost:36895\r\nUser-Agent: Bromure\r\nAccept: */*\r\nConnection: close\r\n\r\n');
    expect(closed).toBe(true);
  });
  it('fails when the VM closes without answering', async () => {
    const ch: ForwardChannel = { write() { queueMicrotask(() => ch.onClose()); }, close() {}, onData: () => {}, onClose: () => {} };
    await expect(deliverCallback(async () => ch, 1, '/cb?code=1')).rejects.toThrow(/without answering/);
  });
});
