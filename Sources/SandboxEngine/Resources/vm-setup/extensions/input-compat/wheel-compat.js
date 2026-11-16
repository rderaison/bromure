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
// Report the same for pixel-mode events; line/page-mode events keep
// Chromium's own values.
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

  var getters = {
    get wheelDeltaX() {
      return this.deltaMode === 0 ? macDelta(this.deltaX)
                                  : original.wheelDeltaX.get.call(this);
    },
    get wheelDeltaY() {
      return this.deltaMode === 0 ? macDelta(this.deltaY)
                                  : original.wheelDeltaY.get.call(this);
    },
    get wheelDelta() {
      if (this.deltaMode !== 0) return original.wheelDelta.get.call(this);
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
