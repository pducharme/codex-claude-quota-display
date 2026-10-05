import functools
import http.server
import json
import os
import platform
import plistlib
import shutil
import subprocess
import tempfile
import threading
import unittest
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path

from finish_appcast import finish_appcast

BRIDGE = Path(__file__).resolve().parent
FEED = BRIDGE.parent / "appcast.xml"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
NS = {"s": SPARKLE}


def enclosures(data):
    return {item.findtext("s:version", namespaces=NS): dict(item.find("enclosure").attrib)
            for item in ET.fromstring(data).findall("./channel/item") if item.find("enclosure") is not None}


class AppcastCompatibilityTest(unittest.TestCase):
    def test_preserves_archives_signatures_and_critical_threshold(self):
        before = FEED.read_bytes()
        after = finish_appcast(before)
        self.assertEqual(enclosures(before), enclosures(after))
        def critical(data):
            return [dict(node.attrib) for node in ET.fromstring(data).findall(".//s:criticalUpdate", NS)]
        self.assertEqual(critical(before), critical(after))
        document = ET.fromstring(after)
        self.assertFalse(document.findall(".//s:informationalUpdate", NS))
        for item in document.findall("./channel/item"):
            if item.find("enclosure") is not None:
                self.assertIsNotNone(item.find("s:minimumUpdateVersion", NS))

    def test_repeat_publication_keeps_one_manual_fallback(self):
        data = finish_appcast(finish_appcast(FEED.read_bytes()))
        items = ET.fromstring(data).findall("./channel/item")
        self.assertEqual(len([item for item in items if item.find("enclosure") is None]), 1)
        self.assertIsNone(items[1].find("s:minimumUpdateVersion", NS))
        self.assertEqual(items[0].findtext("s:version", namespaces=NS), items[1].findtext("s:version", namespaces=NS))

    def test_does_not_lower_an_existing_minimum_version(self):
        root = ET.fromstring(finish_appcast(FEED.read_bytes()))
        item = root.find("./channel/item")
        item.find("s:minimumUpdateVersion", NS).text = "2.0.0"
        updated = ET.fromstring(finish_appcast(ET.tostring(root)))
        self.assertEqual(updated.find("./channel/item/s:minimumUpdateVersion", NS).text, "2.0.0")

    def test_refuses_to_change_an_unknown_informational_policy(self):
        root = ET.fromstring(FEED.read_bytes())
        item = root.find("./channel/item")
        informational = ET.SubElement(item, "{" + SPARKLE + "}informationalUpdate")
        ET.SubElement(informational, "{" + SPARKLE + "}belowVersion").text = "2.0.0"
        with self.assertRaises(ValueError):
            finish_appcast(ET.tostring(root))


@unittest.skipUnless(platform.system() == "Darwin", "Sparkle SDK requires macOS")
class SparkleMetadataTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="quota sparkle metadata ")
        cls.root = Path(cls.temporary.name)
        sparkle = os.environ.get("QUOTA_TEST_SPARKLE_ROOT")
        if not sparkle:
            sparkle = subprocess.check_output([str(BRIDGE / "prepare_sparkle.sh")], text=True).strip()
        cls.sparkle = Path(sparkle)
        cls.probe = cls.root / "feed-probe"
        subprocess.run(["/usr/bin/clang", "-fobjc-arc", "-framework", "AppKit", "-F" + str(cls.sparkle),
                        "-framework", "Sparkle", "-Wl,-rpath," + str(cls.sparkle),
                        str(BRIDGE / "test_sparkle_feed.m"), "-o", str(cls.probe)], check=True,
                       capture_output=True, text=True)
        cls.host_template = {"CFBundleExecutable": "Probe", "CFBundleName": "Quota Sparkle Test",
            "CFBundlePackageType": "APPL", "SUEnableAutomaticChecks": True, "SUAutomaticallyUpdate": False,
            "SUPublicEDKey": "+Itrot6/r0s+Bi+4FJTQ2QLbo9Af6t7iDoSSm1tqiOI="}

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def check_feed(self, data, version, bundle_name="Quota Display.app"):
        directory = self.root / str(uuid.uuid4())
        directory.mkdir()
        (directory / "appcast.xml").write_bytes(data)
        archives = directory / "archives"
        archives.mkdir()
        host = directory / bundle_name
        (host / "Contents/MacOS").mkdir(parents=True)
        shutil.copyfile(self.probe, host / "Contents/MacOS/Probe")
        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_GET(self):
                if self.path != "/appcast.xml":
                    self.send_error(404)
                    return
                super().do_GET()
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(directory)))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = "http://127.0.0.1:{}/appcast.xml".format(server.server_port)
        info = dict(self.host_template, CFBundleIdentifier="org.quota-display.test." + uuid.uuid4().hex,
                    CFBundleVersion=version, CFBundleShortVersionString=version, SUFeedURL=url)
        (host / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        try:
            result = subprocess.run([str(self.probe), str(host), url, str(archives)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout)
            return json.loads(result.stdout), archives
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_reproduces_legacy_metadata_failure_with_secure_decoding(self):
        root = ET.fromstring(finish_appcast(FEED.read_bytes()))
        first = root.find("./channel/item")
        first.remove(first.find("s:minimumUpdateVersion", NS))
        informational = ET.SubElement(first, "{" + SPARKLE + "}informationalUpdate")
        ET.SubElement(informational, "{" + SPARKLE + "}belowVersion").text = "1.0.7"
        # Sparkle's XML parser recognizes the standard sparkle prefix.
        ET.register_namespace("sparkle", SPARKLE)
        result, _ = self.check_feed(ET.tostring(root), "1.1.9")
        first = result["round_trips"][0]
        self.assertTrue(first["encoded"])
        self.assertFalse(first["decoded"])
        self.assertEqual(first["error_code"], 4864)

    def test_fixed_metadata_survives_restart_and_interrupted_archive(self):
        result, archives = self.check_feed(finish_appcast(FEED.read_bytes()), "1.1.9", "Quota Display Menu.app")
        self.assertTrue(result["round_trips"])
        for item in result["round_trips"]:
            self.assertTrue(item["decoded"])
            self.assertTrue(item["url_preserved"])
        for path in archives.glob("*.archive"):
            decoded = subprocess.run([str(self.probe), "--decode", str(path)], capture_output=True, text=True, timeout=5)
            self.assertEqual(decoded.returncode, 0)
        good = (archives / "0.archive").read_bytes()
        interrupted = archives / "interrupted.archive"
        interrupted.write_bytes(good[:len(good) // 2])
        rejected = subprocess.run([str(self.probe), "--decode", str(interrupted)], capture_output=True, text=True, timeout=5)
        self.assertNotEqual(rejected.returncode, 0)
        interrupted.write_bytes(good)
        resumed = subprocess.run([str(self.probe), "--decode", str(interrupted)], capture_output=True, text=True, timeout=5)
        self.assertEqual(resumed.returncode, 0)

    def test_minimum_version_and_manual_fallback_selection(self):
        fixed = finish_appcast(FEED.read_bytes())
        latest = ET.fromstring(fixed).findtext("./channel/item/s:version", namespaces=NS)
        for version, informational in [("1.0.6", True), ("1.0.7", False), ("1.1.9", False)]:
            with self.subTest(version=version):
                result, _ = self.check_feed(fixed, version)
                self.assertEqual(result["offered_version"], latest)
                self.assertEqual(result["informational"], informational)
        current, _ = self.check_feed(fixed, latest)
        self.assertTrue(current["no_update"])
        self.assertIsNone(current["offered_version"])


if __name__ == "__main__":
    unittest.main()
