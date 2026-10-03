Native menu shortcut routing

The native-tabs guest Openbox configuration must be updated together with tab-agent.py. Existing Linux images have no Ctrl-O/Ctrl-N grab, so host-only shortcut dispatch cannot reliably prevent Chromium's file dialog when VZ owns keyboard input.

The host routes guest tokens through the actual app menu on the originating window. Cmd-O preserves File > Open Trace; Cmd-N creates a shared profile window; Shift-Cmd-N uses the private-window action. Cmd-P keeps the native printing pipeline. Editing, zoom, and find remain in-page.

Verification: ARM64 Release build and actual AppKit menu dispatch (eight mapped chords; disabled actions do not execute). Physical VZ keyboard acceptance is not claimed by the standalone menu test.
