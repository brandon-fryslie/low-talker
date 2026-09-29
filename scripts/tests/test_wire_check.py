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
DEALLOC = "2026-09-29 06:21:25.387 Db LowTalker Dev[64449:7621766] [com.apple.network:] -[NWConcrete_nw_path_evaluator dealloc] E05285C4-726C-4125-9A50-4F115FB3B15C"
HEARD = "2026-09-28 22:42:43.012 Df LowTalker Dev[74593:65ec5d0] [ai.promptctl.low-talker.dev:dictation] heard 7 words 657 ms after key-up, 1 actions into com.googlecode.iterm2: <private>"
SERVING = ("2026-09-29 00:44:55.277 Df LowTalker Dev Input Method[67215:6c34705] [ai.promptctl.low-talker.dev.inputmethod.dictation:inputmethod] "
           "development serving ai.promptctl.low-talker.dev.inputmethod.dictation_Connection, answering inserts on ai.promptctl.low-talker.dev.inputmethod.dictation.insert")
INSERT = ("2026-09-28 23:34:45.562 Df LowTalker Dev Input Method[74748:6ad11ca] [ai.promptctl.low-talker.dev.inputmethod.dictation:inputmethod] "
          "insert of 126 characters: inserted(characters: 126, into: \"com.googlecode.iterm2\"), with com.googlecode.iterm2 in front")
APP_CONNECTION = "2026-09-29 06:21:26.000 I  LowTalker Dev[64449:7621767] [com.apple.network:connection] nw_connection_create_with_id [C1] create connection to Hostname#a1ec356a:443"
IM_TASK = "2026-09-29 06:21:26.000 Df LowTalker Dev Input Method[67215:1] [com.apple.CFNetwork:Summary] Task <1>.<1> summary for task success"
# nscurl's uncategorised flow and socket work in the capture the allow list was measured
# from, logged here as if the app had done it.
APP_FLOW = ("2026-09-29 06:21:12.676 Db LowTalker Dev[64449:762018a] [com.apple.network:] nw_path_evaluator_create_flow_inner "
            "Added flow 14AB0D9F-BDF5-4A83-8795-5C816F6988AE to 6C497CE1-69AA-42C8-9A7E-7E5E4D3F2215")
APP_SOCKET = "2026-09-29 06:21:12.678 Db LowTalker Dev[64449:762018a] [com.apple.network:] nw_fd_wrapper_create Created <fd_wrapper 12, guarded: false>"
OTHER_APP_CONNECTION = "2026-09-29 06:21:26.000 I  Notes[73869:1] [com.apple.network:connection] nw_connection_create_with_id [C44] create connection to IPv4#4726c695:143"
# The release app's name is a prefix of the development app's, so a prefix match would take
# one's traffic for the other's.
DEV_CONNECTION_UNDER_RELEASE = APP_CONNECTION.replace("LowTalker Dev[", "LowTalker Dev Nightly[")

WATCHED = (CONTROL, SETTINGS, PATH, DEALLOC, READY, SERVING, HEARD, INSERT)


class WireCheckJudgeTests(unittest.TestCase):
    def judge(self, *lines, app="LowTalker Dev", input_method="LowTalker Dev Input Method"):
        with tempfile.TemporaryDirectory() as directory:
            capture = Path(directory) / "capture.log"
            capture.write_text("\n".join((HEADER,) + lines) + "\n")
            return subprocess.run([str(checker), "judge", str(capture), app, input_method], capture_output=True, text=True)

    def assertFailsQuoting(self, line):
        result = self.judge(*WATCHED, line)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(line, result.stderr)

    def test_a_launch_and_dictation_with_path_evaluations_only_passes(self):
        result = self.judge(*WATCHED, PATH, HEARD, INSERT)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("LowTalker Dev and LowTalker Dev Input Method: no network work through a launch of each and 2 dictation(s); "
                      "2 path evaluation(s)", result.stdout)

    def test_a_connection_by_the_app_fails_and_quotes_it(self):
        self.assertFailsQuoting(APP_CONNECTION)

    def test_a_task_by_the_input_method_fails_and_quotes_it(self):
        self.assertFailsQuoting(IM_TASK)

    def test_flow_work_under_a_path_name_fails(self):
        self.assertFailsQuoting(APP_FLOW)

    def test_an_uncategorised_line_outside_the_allow_list_fails(self):
        self.assertFailsQuoting(APP_SOCKET)

    def test_a_path_line_outside_the_allow_list_fails(self):
        self.assertFailsQuoting(APP_FLOW.replace("[com.apple.network:]", "[com.apple.network:path]"))

    def test_a_dictation_before_the_relaunch_is_not_counted(self):
        result = self.judge(CONTROL, HEARD, INSERT, READY, SERVING)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("holds no dictation", result.stderr)

    def test_an_insert_before_the_input_method_started_is_not_counted(self):
        result = self.judge(CONTROL, INSERT, READY, SERVING, HEARD)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("taking a dictation's text", result.stderr)

    def test_another_processs_connection_is_not_the_apps(self):
        result = self.judge(*WATCHED, OTHER_APP_CONNECTION)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_process_whose_name_extends_the_apps_is_not_the_app(self):
        result = self.judge(*WATCHED, DEV_CONNECTION_UNDER_RELEASE)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_capture_that_missed_the_control_proves_nothing(self):
        result = self.judge(*WATCHED[1:])
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("no connection from the nscurl control", result.stderr)

    def test_a_capture_without_the_model_load_fails(self):
        result = self.judge(*(line for line in WATCHED if line != READY))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("model ready", result.stderr)

    def test_a_capture_without_a_dictation_fails(self):
        result = self.judge(*(line for line in WATCHED if line != HEARD))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("holds no dictation", result.stderr)

    def test_a_capture_without_the_input_method_starting_fails(self):
        result = self.judge(*(line for line in WATCHED if line != SERVING))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("never shows LowTalker Dev Input Method starting", result.stderr)

    def test_a_capture_without_the_input_method_taking_text_fails(self):
        result = self.judge(*(line for line in WATCHED if line != INSERT))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("taking a dictation's text", result.stderr)


if __name__ == "__main__":
    unittest.main()
