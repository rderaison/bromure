# Native tab tear-off (macOS 27)

The browser uses the MIT-licensed `maceip/liquid-tabs` Swift package, pinned in
`ThirdParty/LiquidTabs/UPSTREAM.txt`. Its AppKit strip supplies drag previews,
reordering, tear-off and Escape cancellation. The existing address editor,
history completion and site information stay in the toolbar; the draggable
strip appears beneath it, like Safari's separate tab layout.

The strip is enabled only for a macOS 27 shared Metal browser whose guest
advertises `tabDetachProtocolVersion: 1`. Older hosts/images retain their
existing tab bar. A tear-off must leave at least one tab in its source window.
Display capacity and desktop pixel limits remain unchanged.

The host sends `detach` on the existing per-VM 5832 controller with the exact
source window ID, CDP target ID, free scanout and complete topology. The guest
uses the already installed file-picker extension's existing debugger permission
to map the target to a Chromium tab ID, then `chrome.windows.create({tabId})`.
It adds no extension permissions or content scripts. Chromium and Google Chrome
use the same installed extension (the existing Chrome enterprise CRX policy
path is unchanged). No URL clone, browser restart or new profile/VM is involved.

Guest and host observe the original target's new window ownership before
accepting the move. Lost replies never replay the move; the host can adopt an
observed unbound destination. A rejected move restores the unused output.
The existing shared-owner close/shutdown path manages both windows.

## Reproduce

Rebuild the browser and image (image version is unchanged). The guest module
`shared_windows.py` is already installed by the normal image setup recipe.

```
python3 tools/gpu/test-shared-windows.py
python3 -m unittest discover -s Tests/GuestGraphicsTests
python3 tools/gpu/test-shared-shutdown.py
```

For the signed-app live diagnostic, install the current guest module in a
private image and run `gpu-browser --native-chrome --shared-native-windows
--shared-native-window-count 1 --shared-scanouts 2 --liquid-tab-detach-check
--seconds 65 --guest-probe tools/gpu/guest-liquid-tab-lifecycle.py ...`.
This drives actual AppKit library handlers with synthetic events, checks Escape
cancellation, original target/page state, same VM, and source-window close with
the detached window surviving. It is not a physical mouse/trackpad test.
