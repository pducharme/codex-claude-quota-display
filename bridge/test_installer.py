#!/usr/bin/env python3
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path


class PythonPreflightTest(unittest.TestCase):
    def test_real_python_required_before_installation(self):
        package = Path(__file__).parent / "package"
        with tempfile.TemporaryDirectory(prefix="quota installer ") as directory:
            root = Path(directory)
            candidates = [root / name for name in ("homebrew-python", "local-python", "tools-python")]
            selector = root / "xcode-select"
            selector.write_text("#!/bin/sh\nexit 1\n")
            selector.chmod(0o755)
            script = (package / "find_python.sh").read_text()
            for path, fake in zip(("/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/Library/Developer/CommandLineTools/usr/bin/python3"), candidates):
                script = script.replace(path, shlex.quote(str(fake)))
            script = script.replace("/usr/bin/xcode-select", shlex.quote(str(selector)))
            probe = root / "find_python.sh"
            probe.write_text(script)
            preinstall = root / "preinstall"
            preinstall.write_text((package / "preinstall").read_text())

            def run(path):
                return subprocess.run(["/bin/sh", str(path)], capture_output=True, text=True, timeout=5)

            self.assertEqual(run(probe).returncode, 1)
            missing = run(preinstall)
            self.assertEqual(missing.returncode, 1)
            self.assertIn("Python 3.9", missing.stderr)
            self.assertIn("Aucun fichier", missing.stderr)
            candidates[0].write_text("#!/bin/sh\nexit 1\n")
            candidates[0].chmod(0o755)
            self.assertEqual(run(probe).returncode, 1)
            candidates[2].write_text("#!/bin/sh\nexit 0\n")
            candidates[2].chmod(0o755)
            self.assertEqual(run(probe).stdout.strip(), str(candidates[2]))
            self.assertEqual(run(preinstall).returncode, 0)
            candidates[0].write_text("#!/bin/sh\nexit 0\n")
            self.assertEqual(run(probe).stdout.strip(), str(candidates[0]))
            for candidate in candidates:
                candidate.unlink(missing_ok=True)
            developer = root / "Xcode.app/Contents/Developer"
            python = developer / "usr/bin/python3"
            python.parent.mkdir(parents=True)
            python.write_text("#!/bin/sh\nexit 0\n")
            python.chmod(0o755)
            selector.write_text("#!/bin/sh\nprintf '%s\\n' " + shlex.quote(str(developer)) + "\n")
            self.assertEqual(run(probe).stdout.strip(), str(python))


if __name__ == "__main__":
    unittest.main()
