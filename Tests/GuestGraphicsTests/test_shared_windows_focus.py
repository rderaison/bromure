"""Shared-window focus: a failure after Chromium activated the window must
be reported as activated, so the host still delivers input to it; a failure
of the activation itself must not."""

import unittest

from test_guest_graphics import load_script

shared = load_script("shared_windows")

TARGET = {"id": "A" * 32, "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/x"}


def controller(browser_call, page_call=lambda *a, **k: {}, focus_observer=lambda *a: None):
    c = shared.Controller(list_targets=lambda: [], browser_call=browser_call,
                          page_call=page_call, focus_observer=focus_observer)
    c.groups = {7: [dict(TARGET)]}
    return c


def browser(process_info=({"id": 42, "type": "browser"},), fail=None):
    def call(method, params):
        if method == fail:
            return None  # Controller.call turns this into "CDP call failed: <method>"
        if method == "SystemInfo.getProcessInfo":
            return {"processInfo": list(process_info)}
        return {}
    return call


class SharedWindowFocusTests(unittest.TestCase):
    def assert_activated_failure(self, c):
        with self.assertRaises(shared.FocusUnconfirmed) as caught:
            c.focus(7)
        self.assertEqual(shared.focus_reply_fields({"cmd": "focus"}, caught.exception),
                         {"focusActivated": True})

    def test_activation_failure_is_not_activated(self):
        c = controller(browser(fail="Target.activateTarget"))
        with self.assertRaises(RuntimeError) as caught:
            c.focus(7)
        self.assertNotIsInstance(caught.exception, shared.FocusUnconfirmed)
        self.assertEqual(shared.focus_reply_fields({"cmd": "focus"}, caught.exception),
                         {"focusActivated": False})

    def test_page_focus_failure_after_activation(self):
        self.assert_activated_failure(controller(browser(), page_call=lambda *a, **k: None))

    def test_process_probe_failure_after_activation(self):
        self.assert_activated_failure(controller(browser(process_info=())))
        self.assert_activated_failure(controller(browser(fail="SystemInfo.getProcessInfo")))

    def test_focus_observer_error_after_activation(self):
        def observer(target, remaining):
            raise RuntimeError("X focus observation failed: no display")
        c = controller(browser(), focus_observer=observer)
        with self.assertRaises(shared.FocusUnconfirmed) as caught:
            c.focus(7)
        self.assertIn("X focus observation failed", str(caught.exception))

    def test_success_records_evidence(self):
        evidence = {"browserPID": 42, "xWindow": 1}
        c = controller(browser(), focus_observer=lambda *a: evidence)
        self.assertEqual(c.focus(7), TARGET["id"])
        self.assertEqual(c.focus_evidence, evidence)

    def test_other_commands_get_no_focus_field(self):
        self.assertEqual(shared.focus_reply_fields({"cmd": "resize"}, RuntimeError("x")), {})
        self.assertEqual(shared.focus_reply_fields(None, RuntimeError("x")), {})


if __name__ == "__main__":
    unittest.main()
