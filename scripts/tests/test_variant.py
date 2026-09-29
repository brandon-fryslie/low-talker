"""scripts/variant, fed entitlements the way make-pkg feeds it a signed app's."""
import plistlib
import subprocess
import unittest
from pathlib import Path

reader = Path(__file__).resolve().parent.parent / "variant"

# What every app build signs in, the offline build's whole set.
SANDBOX = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.device.audio-input": True,
    "com.apple.security.temporary-exception.mach-register.global-name": ["ai.promptctl.low-talker.hotkey"],
    "com.apple.security.temporary-exception.mach-lookup.global-name": ["ai.promptctl.low-talker.inputmethod.dictation.insert"],
}


class VariantTests(unittest.TestCase):
    def read(self, entitlements):
        return subprocess.run([str(reader)], input=plistlib.dumps(entitlements), capture_output=True)

    def assertVariant(self, entitlements, variant):
        result = self.read(entitlements)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.decode(), variant + "\n")

    def assertNeither(self, entitlements):
        result = self.read(entitlements)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"neither the offline nor the network build", result.stderr)

    def test_no_network_key_is_offline(self):
        self.assertVariant(SANDBOX, "offline")

    def test_the_server_key_alone_is_network(self):
        self.assertVariant({**SANDBOX, "com.apple.security.network.server": True}, "network")

    def test_a_client_key_is_neither(self):
        self.assertNeither({**SANDBOX, "com.apple.security.network.client": True})
        self.assertNeither({**SANDBOX, "com.apple.security.network.server": True, "com.apple.security.network.client": True})

    def test_a_server_key_set_false_is_neither(self):
        self.assertNeither({**SANDBOX, "com.apple.security.network.server": False})

    def test_input_that_is_not_a_plist_fails(self):
        result = subprocess.run([str(reader)], input=b"", capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")


if __name__ == "__main__":
    unittest.main()
