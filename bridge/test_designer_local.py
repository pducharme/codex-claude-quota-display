import copy
import unittest
from unittest.mock import patch
from designer_local import MacStats, parse_stats, CAT
from designer import templates, default_config, validate


class LocalTests(unittest.TestCase):
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
