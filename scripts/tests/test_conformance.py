"""scripts/conformance judged against a server that answers 200 {"text": ""} to everything,
which a suite that passed would pass anything, and against its own reference endpoint, which
answers as OpenAI did and must pass every check. Its passing against api.openai.com needs the
funded key, so it is run by hand (low-serve-axq.50m)."""
import json
import os
import subprocess
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

suite = Path(__file__).resolve().parent.parent / "conformance"


class Empty(BaseHTTPRequestHandler):
    def answer(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        body = b'{"text": ""}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = answer

    def log_message(self, *args):
        pass


class ConformanceTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Empty)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/v1"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def run_suite(self, *args, env=None):
        return subprocess.run([str(suite), "check", self.url, *args], capture_output=True, text=True,
                              timeout=120, env={**os.environ, **(env or {})})

    def test_every_check_fails_against_a_server_that_hears_nothing(self):
        result = self.run_suite("--token-env", "CONFORMANCE_TOKEN", env={"CONFORMANCE_TOKEN": "sk-test"})
        self.assertEqual(result.returncode, 1, result.stderr)
        *lines, summary = result.stdout.splitlines()
        summary = json.loads(summary)
        self.assertEqual(summary["counts"], {"pass": 0, "fail": 10, "skip": 0})
        reasons = {r["check"]: r["reason"] for r in summary["results"]}
        self.assertIn("does not have hello, world", reasons["rest json"])
        self.assertIn("answered 200, not 400", reasons["rest empty file is 400"])
        self.assertIn("answered 200, not 401", reasons["rest no token is 401"])
        self.assertIn("answered 200, not 101", reasons["realtime exchange"])
        self.assertEqual(lines, [f"fail  {name}: {reason}" for name, reason in reasons.items()])

    def test_without_a_token_the_token_checks_are_skipped_and_said(self):
        summary = json.loads(self.run_suite().stdout.splitlines()[-1])
        skipped = [r["check"] for r in summary["results"] if r["outcome"] == "skip"]
        self.assertEqual(skipped, ["rest no token is 401", "rest wrong token is 401",
                                   "realtime wrong token is an error then close 3000"])

    def test_every_check_passes_against_the_reference_endpoint(self):
        env = {**os.environ, "CONFORMANCE_TOKEN": "sk-test"}
        reference = subprocess.Popen([str(suite), "serve", "--token-env", "CONFORMANCE_TOKEN"], stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, text=True, env=env)
        self.addCleanup(reference.stdout.close)
        self.addCleanup(reference.wait)
        self.addCleanup(reference.kill)
        url = json.loads(reference.stdout.readline())["url"]
        result = subprocess.run([str(suite), "check", url, "--token-env", "CONFORMANCE_TOKEN"], capture_output=True,
                                text=True, timeout=120, env=env)
        summary = json.loads(result.stdout.splitlines()[-1])
        self.assertEqual(summary["counts"], {"pass": 10, "fail": 0, "skip": 0}, result.stdout)
        self.assertEqual(result.returncode, 0)

    def test_a_base_url_that_is_not_http_stops_the_run(self):
        result = subprocess.run([str(suite), "check", "127.0.0.1:8000/v1"], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("is not an http(s) base URL", result.stderr)

    def test_a_named_token_variable_that_is_unset_stops_the_run(self):
        result = self.run_suite("--token-env", "CONFORMANCE_UNSET_TOKEN", env={"CONFORMANCE_UNSET_TOKEN": ""})
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("CONFORMANCE_UNSET_TOKEN, which is not set", result.stderr)


if __name__ == "__main__":
    unittest.main()
