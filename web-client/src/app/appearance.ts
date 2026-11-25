// Light/dark: follows the OS unless the user picked one (View › Appearance);
// sets <html data-theme> which theme.css keys off.

type Pref = 'system' | 'light' | 'dark';
const KEY = 'bromure.appearance';
const listeners = new Set<() => void>();
let pref: Pref = (() => { try { return (localStorage.getItem(KEY) as Pref) || 'system'; } catch { return 'system'; } })();
const forced = new URLSearchParams(location.search).get('appearance') as Pref | null;
const mq = window.matchMedia('(prefers-color-scheme: dark)');

function effective(): 'light' | 'dark' {
  const p = forced ?? pref;
  return p === 'system' ? (mq.matches ? 'dark' : 'light') : p;
}
function apply() { document.documentElement.dataset.theme = effective(); for (const l of [...listeners]) l(); }
mq.addEventListener('change', apply);
apply();

export const appearance = {
  pref: () => pref,
  effective,
  set(p: Pref) { pref = p; try { localStorage.setItem(KEY, p); } catch {} apply(); },
  subscribe(l: () => void) { listeners.add(l); return () => listeners.delete(l); },
};
