// Finding: the input-compat extension rewrote ordinary mouse-wheel deltas.
// It must give Chrome-on-macOS wheelDelta values only to the host's
// injected trackpad events, and keep Chromium's own values for physical
// wheels, line/page-mode events and events a page constructs itself.
//
// The fake WheelEvent reproduces what Chromium reports in the guest
// (measured at device scale 1 and 2): real wheels — notched, through X or
// evdev, or a high-resolution wheel's partial notch — have
// wheelDelta == −delta; DevTools-injected events have wheelDelta ±120
// whatever their pixel delta; constructed events are untrusted.
//
// Run: node --test Tests/input-compat-wheel.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const src = readFileSync(new URL(
  "../Sources/SandboxEngine/Resources/vm-setup/extensions/input-compat/wheel-compat.js",
  import.meta.url), "utf8");

/** Load wheel-compat.js over a Blink-like WheelEvent; returns the class. */
function load() {
  const ctx = vm.createContext({});
  vm.runInContext(`
    function WheelEvent(init) {
      this.deltaX = init.deltaX || 0;
      this.deltaY = init.deltaY || 0;
      this.deltaMode = init.deltaMode || 0;
      Object.defineProperty(this, "isTrusted", { value: init.trusted !== false });
      this._nx = init.nativeX || 0;
      this._ny = init.nativeY || 0;
    }
    Object.defineProperty(WheelEvent.prototype, "wheelDeltaX",
      { get() { return this._nx; }, enumerable: true, configurable: true });
    Object.defineProperty(WheelEvent.prototype, "wheelDeltaY",
      { get() { return this._ny; }, enumerable: true, configurable: true });
    Object.defineProperty(WheelEvent.prototype, "wheelDelta",
      { get() { return this._ny || this._nx; }, enumerable: true, configurable: true });
    var window = globalThis;
  `, ctx);
  vm.runInContext(src, ctx);
  return ctx.WheelEvent;
}

const tick = (px) => (px > 0 ? -120 : px < 0 ? 120 : 0);
const sign = (o) => [o.wheelDeltaX, o.wheelDeltaY, o.wheelDelta];

test("injected trackpad events get Chrome-on-macOS values (−3 × delta)", () => {
  const W = load();
  assert.deepEqual(sign(new W({ deltaY: 22, nativeY: tick(22) })), [0, -66, -66]);
  assert.deepEqual(sign(new W({ deltaY: 0.5, nativeY: tick(0.5) })), [0, -1, -1]);
  assert.deepEqual(sign(new W({ deltaY: 100, nativeY: tick(100) })), [0, -300, -300]);
  assert.deepEqual(sign(new W({ deltaX: -10, nativeX: tick(-10) })), [30, 0, 30]);
  assert.equal(Object.is(new W({ deltaY: -0.2, nativeY: tick(-0.2) }).wheelDeltaY, -0), false);
});

test("physical wheels keep Chromium's values", () => {
  const W = load();
  // Notches (X core button or evdev REL_WHEEL), one or coalesced.
  assert.deepEqual(sign(new W({ deltaY: 120, nativeY: -120 })), [0, -120, -120]);
  assert.deepEqual(sign(new W({ deltaY: -120, nativeY: 120 })), [0, 120, 120]);
  assert.deepEqual(sign(new W({ deltaY: 240, nativeY: -240 })), [0, -240, -240]);
  // High-resolution wheels' partial notches.
  assert.deepEqual(sign(new W({ deltaY: -30, nativeY: 30 })), [0, 30, 30]);
  assert.deepEqual(sign(new W({ deltaY: 45, nativeY: -45 })), [0, -45, -45]);
  assert.deepEqual(sign(new W({ deltaX: 120, nativeX: -120 })), [-120, 0, -120]);
});

test("line/page-mode and page-constructed events keep their own values", () => {
  const W = load();
  assert.deepEqual(sign(new W({ deltaY: 3, deltaMode: 1, nativeY: -120 })), [0, -120, -120]);
  assert.deepEqual(sign(new W({ deltaY: 1, deltaMode: 2, nativeY: -120 })), [0, -120, -120]);
  // new WheelEvent("wheel", { deltaY: 100, wheelDeltaY: -120 }) in a page.
  assert.deepEqual(sign(new W({ deltaY: 100, nativeY: -120, trusted: false })), [0, -120, -120]);
});

test("getters keep their descriptor shape", () => {
  const W = load();
  for (const name of ["wheelDeltaX", "wheelDeltaY", "wheelDelta"]) {
    const d = Object.getOwnPropertyDescriptor(W.prototype, name);
    assert.equal(d.enumerable, true);
    assert.equal(d.configurable, true);
    assert.equal(d.get.name, "get " + name);
  }
});
