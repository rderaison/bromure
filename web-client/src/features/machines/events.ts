// `bromure:open` helpers for the machines surface.

export function openMachinesSurface(what: string, args: Record<string, unknown> = {}) {
  window.dispatchEvent(new CustomEvent('bromure:open', { detail: { what, ...args } }));
}
