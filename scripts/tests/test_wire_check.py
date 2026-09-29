"""scripts/wire-check's judge, against captures made of lines a real run logged."""
import subprocess
import tempfile
import unittest
from pathlib import Path

checker = Path(__file__).resolve().parent.parent / "wire-check"

HEADER = "Timestamp               Ty Process[PID:TID]"
CONTROL = "2026-09-29 06:21:12.617 I  nscurl[62822:7620183] [com.apple.network:connection] nw_connection_create_with_id [C1] create connection to Hostname#a1ec356a:443"
READY = "2026-09-29 06:21:25.891 I  LowTalker Dev[64449:7621760] [ai.promptctl.low-talker.dev:engine] model: ready (large-v3-v20240930_turbo_632MB) after 2 s"
PATH = ("2026-09-29 06:21:25.386 Df LowTalker Dev[64449:7621767] [com.apple.network:path] nw_path_evaluator_start "
        "[E05285C4-726C-4125-9A50-4F115FB3B15C <NULL> generic, multipath service: handover, attribution: developer]")
SETTINGS = "2026-09-29 06:21:25.385 Df LowTalker Dev[64449:7621767] [com.apple.network:] networkd_settings_read_from_file initialized networkd settings by reading plist directly"
HEARD = "2026-09-28 22:42:43.012 Df LowTalker Dev[74593:65ec5d0] [ai.promptctl.low-talker.dev:dictation] heard 7 words 657 ms after key-up, 1 actions into com.googlecode.iterm2: <private>"
APP_CONNECTION = "2026-09-29 06:21:26.000 I  LowTalker Dev[64449:7621767] [com.apple.network:connection] nw_connection_create_with_id [C1] create connection to Hostname#a1ec356a:443"
IM_TASK = "2026-09-29 06:21:26.000 Df LowTalker Dev Input Method[67215:1] [com.apple.CFNetwork:Summary] Task <1>.<1> summary for task success"
OTHER_APP_CONNECTION = "2026-09-29 06:21:26.000 I  Notes[73869:1] [com.apple.network:connection] nw_connection_create_with_id [C44] create connection to IPv4#4726c695:143"


class WireCheckJudgeTests(unittest.TestCase):
    def judge(self, *lines):
        with tempfile.TemporaryDirectory() as directory:
            capture = Path(directory) / "capture.log"
            capture.write_text("\n".join((HEADER,) + lines) + "\n")
            return subprocess.run([str(checker), "judge", str(capture), "LowTalker Dev"], capture_output=True, text=True)

    def test_a_launch_and_dictation_with_path_evaluations_only_passes(self):
        result = self.judge(CONTROL, SETTINGS, PATH, PATH, READY, HEARD, HEARD)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("LowTalker Dev: no connection through a launch and 2 dictation(s); 2 path evaluation(s)", result.stdout)

    def test_a_connection_by_the_app_fails_and_quotes_it(self):
        result = self.judge(CONTROL, READY, APP_CONNECTION, HEARD)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(APP_CONNECTION, result.stderr)

    def test_a_task_by_the_input_method_counts_as_the_apps(self):
        result = self.judge(CONTROL, READY, IM_TASK, HEARD)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(IM_TASK, result.stderr)

    def test_another_processs_connection_is_not_the_apps(self):
        result = self.judge(CONTROL, OTHER_APP_CONNECTION, READY, HEARD)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_capture_that_missed_the_control_proves_nothing(self):
        result = self.judge(READY, HEARD)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("no connection from the nscurl control", result.stderr)

    def test_a_capture_without_the_model_load_fails(self):
        result = self.judge(CONTROL, HEARD)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("model ready", result.stderr)

    def test_a_capture_without_a_dictation_fails(self):
        result = self.judge(CONTROL, READY, PATH)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("holds no dictation", result.stderr)


if __name__ == "__main__":
    unittest.main()
