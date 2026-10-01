"""RandR resize decisions and scheduling without changing a real display."""

from pathlib import Path
import tempfile
import unittest

from test_guest_graphics import load_script

resize = load_script("resize-watcher")

FIXTURE = """Screen 0: minimum 320 x 200, current 960 x 658, maximum 8192 x 8192
Virtual-1-1 connected (normal left inverted right x axis y axis)
   1024x768      60.00+
Virtual-2 connected primary 960x658+0+0 (normal left inverted right x axis y axis) 0mm x 0mm
   960x658       59.96*+
   4096x2160     60.00 59.94
"""


class Recorder:
    def __init__(self, query=FIXTURE, failure=None):
        self.query, self.failure, self.calls = query, failure, []

    def __call__(self, args):
        self.calls.append(list(args))
        if self.failure and self.failure(args):
            return 1, ""
        if args == ["xrandr", "--query"]:
            return 0, self.query
        if args[0] == "gtf":
            return 0, f'  Modeline "{args[1]}x{args[2]}_{args[3]}.00" 100 960 980 1000 1100 658 660 662 680 -HSync +Vsync\n'
        return 0, ""


class ResizeWatcherTests(unittest.TestCase):
    def test_inactive_builtin_is_never_selected_or_enabled(self):
        outputs = resize.parse_outputs(FIXTURE)
        self.assertIsNone(outputs[0]["geometry"])
        self.assertEqual(resize.select_output(outputs, None, True)["name"], "Virtual-2")
        recorder = Recorder()
        controller = resize.ResizeController(recorder, lambda: (True, 60))
        controller.update()
        self.assertEqual(recorder.calls, [["xrandr", "--query"]])

    def test_preferred_mode_change_resizes_only_active_output(self):
        recorder = Recorder(FIXTURE.replace("   960x658       59.96*+", "   800x586       60.00+\n   960x658       59.96*"))
        controller = resize.ResizeController(recorder, lambda: (True, 60))
        controller.update()
        self.assertEqual(recorder.calls[-1], ["xrandr", "--output", "Virtual-2", "--mode", "800x586",
                                              "--primary", "--pos", "0x0", "--fb", "800x586"])

    def test_custom_primary_and_origin_are_corrected_without_size_change(self):
        recorder = Recorder(FIXTURE.replace("primary 960x658+0+0", "960x658+1024+0"))
        resize.ResizeController(recorder, lambda: (True, 60)).update()
        self.assertIn("--primary", recorder.calls[-1])
        self.assertEqual(recorder.calls[-1][-4:], ["--pos", "0x0", "--fb", "960x658"])

    def test_stale_root_size_is_corrected_for_normalized_pointer_coordinates(self):
        recorder = Recorder(FIXTURE.replace("current 960 x 658", "current 1920 x 1080"))
        resize.ResizeController(recorder, lambda: (True, 60)).update()
        self.assertEqual(recorder.calls[-1][-2:], ["--fb", "960x658"])

    def test_no_guess_for_ambiguous_or_inactive_custom_outputs(self):
        for text in (FIXTURE.replace("960x658+0+0", ""),
                     FIXTURE.replace("Virtual-1-1 connected", "Virtual-1-1 connected 1024x768+960+0")):
            recorder = Recorder(text)
            resize.ResizeController(recorder, lambda: (True, 60)).update()
            self.assertEqual(recorder.calls, [["xrandr", "--query"]])

    def test_software_resize_preserves_layout_policy(self):
        recorder = Recorder(FIXTURE.replace("960x658       59.96*+", "800x586       60.00+\n   960x658       59.96*"))
        resize.ResizeController(recorder, lambda: (False, 60)).update()
        self.assertEqual(recorder.calls[-1], ["xrandr", "--output", "Virtual-2", "--mode", "800x586"])

    def test_high_hz_creation_and_retirement(self):
        recorder = Recorder()
        controller = resize.ResizeController(recorder, lambda: (True, 120))
        controller.update()
        self.assertIn(["xrandr", "--addmode", "Virtual-2", "960x658_120.00"], recorder.calls)
        self.assertEqual(controller.owned_modes, {("Virtual-2", "960x658_120.00")})
        recorder.query = FIXTURE.replace("960x658       59.96*+", "800x586       60.00+\n   960x658_120.00 120.00*")
        controller.update()
        self.assertIn(["xrandr", "--delmode", "Virtual-2", "960x658_120.00"], recorder.calls)
        self.assertEqual(controller.owned_modes, {("Virtual-2", "800x586_120.00")})

    def test_high_hz_failure_falls_back_and_does_not_loop(self):
        recorder = Recorder(failure=lambda args: "--mode" in args and args[4].endswith("_120.00"))
        controller = resize.ResizeController(recorder, lambda: (True, 120))
        controller.update()
        mode_calls = [args for args in recorder.calls if "--mode" in args]
        self.assertEqual([args[4] for args in mode_calls], ["960x658_120.00", "960x658"])
        recorder.calls.clear()
        controller.update()
        self.assertEqual(recorder.calls, [["xrandr", "--query"]])

    def test_config_parser_does_not_execute_shell(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "env"
            config.write_text("BROKEN='\nGRAPHICS_BACKEND=virgl\nexport DISPLAY_HZ=120\n")
            self.assertEqual(resize.settings(config), (True, 120))
            config.write_text("DISPLAY_HZ='$(touch /should-not-run)'\n")
            self.assertEqual(resize.settings(config), (False, 60))

    def test_event_burst_coalesces_and_idle_does_not_query(self):
        now, updates = [0.0], []

        class Events:
            times = [0.001, 0.005, 0.01, 0.02, 0.04]

            def wait(self, timeout):
                if now[0] > 2:
                    raise StopIteration
                if self.times and self.times[0] <= now[0] + timeout:
                    now[0] = self.times.pop(0)
                    return True
                now[0] += timeout
                return False

        class Controller:
            def update(self):
                updates.append(now[0])

        with self.assertRaises(StopIteration):
            resize.watch(Events(), Controller(), clock=lambda: now[0], signature=lambda: None)
        self.assertEqual(len(updates), 3)
        self.assertAlmostEqual(updates[1], 1 / 30)
        self.assertAlmostEqual(updates[2], 2 / 30)

    def test_claim_config_change_triggers_update_without_randr_event(self):
        now, updates = [0.0], []

        class Events:
            def wait(self, timeout):
                now[0] += timeout
                if now[0] > 2:
                    raise StopIteration
                return False

        class Controller:
            def update(self):
                updates.append(now[0])

        with self.assertRaises(StopIteration):
            resize.watch(Events(), Controller(), clock=lambda: now[0],
                         signature=lambda: int(now[0] >= 1))
        self.assertEqual(updates, [0.0, 1.0])


if __name__ == "__main__":
    unittest.main()
