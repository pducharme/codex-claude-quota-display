import copy
import unittest
from unittest.mock import patch
from designer_local import (
    MacStats,
    MacControls,
    AudioOutput,
    parse_stats,
    CAT,
    bmp_pixels,
    artwork_pixels,
)
from designer import templates, default_config, validate


class LocalTests(unittest.TestCase):
    def test_artwork_pixel_order_rgb565_and_malformed_bmp(self):
        import struct

        header = b"BM" + struct.pack("<IHHI", 54 + 3072, 0, 0, 54)
        header += struct.pack("<IiiHHIIiiII", 40, 32, 32, 1, 24, 0, 3072, 0, 0, 0, 0)
        # BMP starts with its bottom row: blue bottom half, red top half.
        data = header + bytes([255, 0, 0]) * 512 + bytes([0, 0, 255]) * 512
        self.assertEqual(bmp_pixels(data), "f800" * 512 + "001f" * 512)
        for bad in (data[:-1], b"bad", data[:10] + struct.pack("<I", 0) + data[14:]):
            with self.assertRaises(ValueError):
                bmp_pixels(bad)

    @unittest.skipUnless(
        __import__("sys").platform == "darwin", "Native macOS image conversion"
    )
    def test_native_artwork_conversion_preserves_orientation_and_colours(self):
        import struct, zlib

        def chunk(name, data):
            return (
                struct.pack(">I", len(data))
                + name
                + data
                + struct.pack(">I", zlib.crc32(name + data))
            )

        scanlines = (b"\0" + bytes([255, 0, 0]) * 32) * 16 + (
            b"\0" + bytes([0, 0, 255]) * 32
        ) * 16
        png = (
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 32, 32, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(scanlines))
            + chunk(b"IEND", b"")
        )
        self.assertEqual(artwork_pixels(png), "f800" * 512 + "001f" * 512)
        wide = (
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 32, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress((b"\0" + bytes([255, 0, 0]) * 64) * 32))
            + chunk(b"IEND", b"")
        )
        self.assertEqual(
            artwork_pixels(wide), "0000" * 256 + "f800" * 512 + "0000" * 256
        )
        with self.assertRaises(ValueError):
            artwork_pixels(b"x" * 2_000_001)

    def test_mac_commands_use_only_selected_shortcuts_and_report_failures(self):
        import subprocess
        from types import SimpleNamespace
        from unittest.mock import Mock

        calls = []

        def runner(args, **kwargs):
            calls.append((args, kwargs))
            return SimpleNamespace(stdout="Lecture\nLumière $(touch nope)\n --help\n")

        audio = Mock()
        audio.read.return_value = dict(volume=None, muted=None)
        controls = MacControls(audio, runner)
        self.assertEqual(controls.values({})["source.volume"], "Fixe")
        controls.action("volume_up", {})
        audio.change.assert_called_once_with("volume_up")
        options = dict(shortcut="Lumière $(touch nope)", playback_shortcut="Lecture")
        controls.action("shortcut", options)
        self.assertEqual(
            calls[-1][0], ["/usr/bin/shortcuts", "run", options["shortcut"]]
        )
        self.assertNotIn("shell", calls[-1][1])
        controls.action("play_pause", options)
        self.assertEqual(calls[-1][0][-1], "Lecture")
        before = len(calls)
        with self.assertRaises(ValueError):
            controls.action("arbitrary", options)
        self.assertEqual(len(calls), before)
        for name in ("missing", "--help"):
            with self.assertRaises(ValueError):
                controls.action("shortcut", dict(shortcut=name))
            self.assertEqual(calls[-1][0], ["/usr/bin/shortcuts", "list"])
        controls.runner = Mock(
            side_effect=[
                SimpleNamespace(stdout="Lecture"),
                subprocess.TimeoutExpired("shortcuts", 15),
            ]
        )
        with self.assertRaises(ValueError):
            controls.action("play_pause", options)
        self.assertEqual(
            controls.runner.call_count, 2
        )  # No replay of a possibly completed action.
        # Reject unknown audio commands before loading CoreAudio or touching output.
        with self.assertRaises(ValueError):
            AudioOutput.__new__(AudioOutput).change("other")

    def test_stats_parser_rates_resets_and_unavailable(self):
        top = "CPU usage: 20.0% user, 10.0% sys, 70.0% idle\nPhysMem: 12G used (2G wired, 1G compressor), 4G unused."
        net = "Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll\nen0 1500 <Link#1> ab 1 0 2048 1 0 4096 0\nen0 1500 127.0.0.1 ab 1 0 2048 1 0 4096 0\nlo0 1500 <Link#2> 127 1 0 100000 1 0 100000 0"
        values, prior = parse_stats(top, net, now=10)
        self.assertEqual(values["source.cpu"], "30 %")
        self.assertEqual(values["source.memory"], "12.0 Go")
        self.assertEqual(values["source.progress"], 75)
        self.assertEqual(prior[1], [2048, 4096])
        values, _ = parse_stats(top, net, (8, [0, 0]), now=10)
        self.assertEqual(values["source.network"], "1 / 2 Ko/s")
        values, _ = parse_stats(top, net, (8, [10000, 10000]), now=10)
        self.assertEqual(values["source.network"], "0 / 0 Ko/s")
        with self.assertRaises(ValueError):
            parse_stats("broken", net)
        mac = MacStats()
        with patch("designer_local.subprocess.run", side_effect=OSError()):
            mac.poll()
        self.assertEqual(
            mac.values(), {"source.status": "Statistiques du Mac indisponibles"}
        )

    def test_pixels_roundtrip_rejects_malformed_drawings(self):
        config = default_config()
        config["pages"] = [
            next(p for p in templates() if p["name"] == "Pixel art / compagnon")
        ]
        self.assertEqual(validate(config)["pages"][0]["blocks"][0]["pixels"], CAT)
        for pixels in ["0" * 255, "0" * 257, "x" * 256, ["0"] * 256]:
            bad = copy.deepcopy(config)
            bad["pages"][0]["blocks"][0]["pixels"] = pixels
            with self.assertRaises(ValueError):
                validate(bad)


if __name__ == "__main__":
    unittest.main()
