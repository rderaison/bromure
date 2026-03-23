// Block WebRTC IP leak by replacing RTCPeerConnection with a no-op stub.
// This extension is only loaded when both webcam and microphone are disabled.

(function () {
  "use strict";

  function BlockedPeerConnection() {
    throw new DOMException(
      "RTCPeerConnection is disabled by policy.",
      "NotAllowedError"
    );
  }
  BlockedPeerConnection.prototype = RTCPeerConnection.prototype;
  BlockedPeerConnection.generateCertificate = function () {
    return Promise.reject(
      new DOMException(
        "RTCPeerConnection is disabled by policy.",
        "NotAllowedError"
      )
    );
  };

  Object.defineProperty(window, "RTCPeerConnection", {
    value: BlockedPeerConnection,
    writable: false,
    configurable: false,
  });
  Object.defineProperty(window, "webkitRTCPeerConnection", {
    value: BlockedPeerConnection,
    writable: false,
    configurable: false,
  });
})();
