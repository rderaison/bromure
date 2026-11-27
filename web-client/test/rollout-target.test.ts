import { describe, it, expect } from 'vitest';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// Regression: Jenkinsfile.client-web picked the rollout target out of the
// WEB_CLIENT_ROLLOUT credential by keeping the LAST deploy/<name> and
// namespace it saw among any words, so a stale extra token
// ("… deploy/web-client -n bromure deploy/api") restarted deploy/api and left
// the web client untouched. Only the documented forms are accepted now.

const script = fileURLToPath(new URL('../ci/web/rollout-target.sh', import.meta.url));
const parse = (target: string) => {
  const r = spawnSync('sh', [script, target], { encoding: 'utf8' });
  return r.status === 0 ? r.stdout.trim() : null;
};

describe('rollout-target.sh (Jenkinsfile.client-web)', () => {
  it('accepts "<namespace> <deployment>" and the kubectl rollout restart line', () => {
    expect(parse('bromure web-client')).toBe('bromure web-client');
    expect(parse('kubectl rollout restart deploy/web-client -n bromure')).toBe('bromure web-client');
    expect(parse('kubectl rollout restart -n bromure deployment/web-client')).toBe('bromure web-client');
    expect(parse('kubectl rollout restart deployments/web-client --namespace bromure')).toBe('bromure web-client');
    expect(parse('kubectl rollout restart deployment.apps/web-client --namespace=bromure')).toBe('bromure web-client');
    expect(parse('kubectl rollout restart deploy/web-client -nbromure')).toBe('bromure web-client');
  });

  it('refuses a second resource instead of restarting the last one', () => {
    expect(parse('kubectl rollout restart deploy/web-client -n bromure deploy/api')).toBeNull();
  });

  it('refuses a repeated namespace, unknown words, other commands and missing parts', () => {
    for (const t of [
      'kubectl rollout restart deploy/web-client --namespace=bromure -n other',
      'kubectl rollout restart deploy/web-client -n bromure --context prod',
      'kubectl rollout restart deploy/web-client -n bromure extra',
      'kubectl rollout undo deploy/web-client -n bromure',
      'rollout restart deploy/web-client -n bromure',
      'kubectl rollout restart deploy/web-client',
      'kubectl rollout restart -n bromure',
      'kubectl rollout restart deploy/web-client -n',
      'kubectl rollout restart deploy/Web_Client -n bromure',
      'bromure deploy/api',
      '-n web-client',
      'bromure',
      '',
    ]) expect(parse(t), t).toBeNull();
  });

  it('says what it accepts when it refuses', () => {
    const r = spawnSync('sh', [script, 'nonsense here now'], { encoding: 'utf8' });
    expect(r.status).not.toBe(0);
    expect(r.stdout).toBe('');
    expect(r.stderr).toMatch(/WEB_CLIENT_ROLLOUT must be/);
  });
});
