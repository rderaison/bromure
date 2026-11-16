// Trackpad wheel events with the legacy wheelDelta values Chrome on macOS
// reports.
//
// The host forwards trackpad scrolling into the guest as synthetic DevTools
// wheel events (Input.dispatchMouseEvent). Chromium on Linux gives every
// such event a whole wheel tick, so wheelDeltaY is ±120 whether the
// finger moved 0.5 px or 30 px. That is the signature of a notched mouse
// wheel, and smooth-scroll libraries that sniff it (SmoothScroll.js and its
// WordPress "Mousewheel Smooth Scroll" plugin, among others) then cancel
// every trackpad event and replace it with an accelerated 100 px+ animated
// step: one swipe ran several pages.
//
// Chrome on macOS derives wheelDelta from precise pixel deltas instead
// (ticks = pixels / 40, wheelDelta = ticks × 120, so −3 × delta), which
// those libraries recognise as a trackpad and leave to native scrolling.
//
// Only those injected events are rewritten. Measured in the guest, every
// real wheel event — a notched mouse through X or evdev/libinput, or a
// high-resolution wheel's partial notch — has wheelDelta == −delta
// (±120 for ±120 px, 30 for −30 px), while an injected event has
// wheelDelta ±120 whatever its pixel delta. So an event is treated as
// injected only when it is trusted (pages' own `new WheelEvent(...)` keep
// whatever they were built with), pixel-mode, and on some axis carries
// the ±120 tick against a pixel delta that isn't ±120. Everything else —
// physical wheels, line/page modes, synthetic events — keeps Chromium's
// values. An injected event of exactly ±120 px is indistinguishable from a
// notch and keeps the notch value, which is also what it amounts to.
(function () {
  "use strict";
  var proto = window.WheelEvent && WheelEvent.prototype;
  if (!proto) return;
  var original = {};
  ["wheelDeltaX", "wheelDeltaY", "wheelDelta"].forEach(function (name) {
    original[name] = Object.getOwnPropertyDescriptor(proto, name);
  });
  if (!original.wheelDeltaX || !original.wheelDeltaY || !original.wheelDelta) return;

  // `| 0` truncates toward zero, like Blink's float → int conversion; the
  // trailing `|| 0` turns −0 into 0.
  function macDelta(pixels) { return (-pixels * 3 | 0) || 0; }

  // The ±120 tick Chromium gives an injected event, against a pixel
  // delta that a real wheel would have reported as ∓delta.
  function injectedAxis(native, pixels) {
    return (native === 120 || native === -120) && pixels !== 120 && pixels !== -120;
  }
  function isInjected(event) {
    if (!event.isTrusted || event.deltaMode !== 0) return false;
    return injectedAxis(original.wheelDeltaY.get.call(event), event.deltaY) ||
           injectedAxis(original.wheelDeltaX.get.call(event), event.deltaX);
  }

  var getters = {
    get wheelDeltaX() {
      return isInjected(this) ? macDelta(this.deltaX)
                              : original.wheelDeltaX.get.call(this);
    },
    get wheelDeltaY() {
      return isInjected(this) ? macDelta(this.deltaY)
                              : original.wheelDeltaY.get.call(this);
    },
    get wheelDelta() {
      if (!isInjected(this)) return original.wheelDelta.get.call(this);
      // Blink: wheelDeltaY when non-zero, else wheelDeltaX.
      return macDelta(this.deltaY) || macDelta(this.deltaX);
    },
  };
  Object.keys(getters).forEach(function (name) {
    var get = Object.getOwnPropertyDescriptor(getters, name).get;
    Object.defineProperty(proto, name, {
      get: get,
      set: undefined,
      enumerable: original[name].enumerable,
      configurable: original[name].configurable,
    });
  });
})();
