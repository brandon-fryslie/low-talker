"""scripts/notices, run as the app build runs it, against SBOMs built here."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

generator = Path(__file__).resolve().parent.parent / "notices"


def library(name, version, *licenses, vendored=()):
    component = {"type": "library", "name": name, "version": version, "licenses": list(licenses)}
    if vendored:
        component["components"] = list(vendored)
    return component


def spdx(id, text=None):
    license = {"id": id}
    if text is not None:
        license["text"] = {"contentType": "text/plain", "content": text}
    return {"license": license}


class NoticesTests(unittest.TestCase):
    def write(self, *components):
        with tempfile.TemporaryDirectory() as directory:
            bom, output = Path(directory) / "bom.cdx.json", Path(directory) / "notices.txt"
            bom.write_text(json.dumps({"bomFormat": "CycloneDX", "components": list(components)}))
            result = subprocess.run([str(generator), str(bom), str(output)], capture_output=True, text=True)
            return result, output.read_text() if output.exists() else None

    def test_every_component_and_its_text_is_written_vendored_ones_included(self):
        result, notices = self.write(library("host", "1.0", spdx("MIT", "Copyright (c) Host\n"),
                                             vendored=[library("inner", "2.0", spdx("Apache-2.0", "Copyright Inner\n"))]),
                                     library("other", "3.0", spdx("MIT", "Copyright (c) Other\n")))
        self.assertEqual(result.returncode, 0, result.stderr)
        for line in ("host 1.0", "Copyright (c) Host", "host 1.0, vendoring inner 2.0", "Copyright Inner", "other 3.0", "Copyright (c) Other"):
            self.assertIn(line, notices.splitlines())

    def test_a_component_without_text_fails_naming_it_and_writes_nothing(self):
        result, notices = self.write(library("host", "1.0", spdx("MIT", "Copyright (c) Host\n"), vendored=[library("inner", "2.0", spdx("MIT"))]))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("carries no license text for host 1.0, vendoring inner 2.0;", result.stderr)
        self.assertIsNone(notices)

    def test_a_component_with_no_license_at_all_fails(self):
        result, _ = self.write(library("mystery", "0.1"))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("carries no license text for mystery 0.1;", result.stderr)

    def test_one_license_without_text_among_several_fails(self):
        result, _ = self.write(library("dual", "1.0", spdx("MIT", "Copyright (c) Dual\n"), spdx("Apache-2.0")))
        self.assertEqual(result.returncode, 1, result.stdout)

    def test_no_components_fails(self):
        result, _ = self.write()
        self.assertEqual(result.returncode, 1, result.stdout)


if __name__ == "__main__":
    unittest.main()
