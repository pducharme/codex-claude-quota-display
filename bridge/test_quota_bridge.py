#!/usr/bin/env python3
import json
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest.mock import patch
from zoneinfo import ZoneInfo

from quota_bridge import (
    QuotaState,
    command_path,
    parse_claude_usage,
    parse_codex_limits,
    read_claude,
    read_claude_desktop_cache,
    read_claude_plan,
    read_weather,
)


class QuotaParsingTest(unittest.TestCase):
    @patch("quota_bridge.shutil.which", return_value=None)
    @patch("quota_bridge.subprocess.run")
    def test_command_path_uses_interactive_shell(self, run, _which):
        with tempfile.TemporaryDirectory() as directory:
            command = Path(directory) / "provider-cli"
            command.write_text("#!/bin/sh\n")
            command.chmod(0o700)
            run.return_value.stdout = f"shell startup text\n{command}\n"
            self.assertEqual(command_path("provider-cli"), str(command))

    def test_codex_windows_are_mapped_by_duration(self):
        result = {
            "rateLimits": {
                "planType": "pro",
                "primary": {
                    "usedPercent": 23,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_800_000_000,
                },
                "secondary": {
                    "usedPercent": 48,
                    "windowDurationMins": 300,
                    "resetsAt": 1_799_000_000,
                },
            },
            "rateLimitResetCredits": {
                "availableCount": 2,
                "credits": [
                    {
                        "resetType": "codexRateLimits",
                        "status": "available",
                        "expiresAt": 1_810_000_000,
                    },
                    {
                        "resetType": "codexRateLimits",
                        "status": "available",
                        "expiresAt": 1_805_000_000,
                    },
                    {
                        "resetType": "codexRateLimits",
                        "status": "used",
                        "expiresAt": 1_800_000_000,
                    },
                ],
            },
        }
        windows = parse_codex_limits(result)
        self.assertEqual(windows["five_hour"]["used_percent"], 48)
        self.assertEqual(windows["weekly"]["used_percent"], 23)
        self.assertEqual(windows["plan"], "Pro 20X")
        self.assertEqual(
            parse_codex_limits({"rateLimits": {"planType": "plus"}})["plan"],
            "Plus",
        )
        self.assertEqual(
            parse_codex_limits({"rateLimits": {"planType": "prolite"}})["plan"],
            "Pro 5X",
        )
        self.assertEqual(windows["banked_resets"]["available_count"], 2)
        self.assertEqual(
            [
                reset["expires_at"]
                for reset in windows["banked_resets"]["expirations"]
            ],
            [1_805_000_000, 1_810_000_000],
        )

    def test_claude_usage_and_reset_are_parsed(self):
        text = """\
Current session: 12% used · resets 2am (America/Toronto)
Current week (all models): 39% used · resets Jul 28 at 11:59am (America/Toronto)
Current week (Fable): 81% used · resets Jul 28 at 11:59am (America/Toronto)
"""
        now = datetime(2026, 7, 26, 8, 0, tzinfo=ZoneInfo("America/Toronto"))
        windows = parse_claude_usage(text, now)
        self.assertEqual(windows["five_hour"]["used_percent"], 12)
        self.assertEqual(windows["weekly"]["used_percent"], 39)
        self.assertEqual(windows["fable_weekly"]["used_percent"], 81)
        self.assertEqual(
            windows["weekly"]["resets_at"],
            int(
                datetime(
                    2026, 7, 28, 11, 59, tzinfo=ZoneInfo("America/Toronto")
                ).timestamp()
            ),
        )
        self.assertEqual(
            windows["fable_weekly"]["resets_at"],
            windows["weekly"]["resets_at"],
        )

    def test_fresh_claude_desktop_cache_is_parsed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "claude-desktop-quotas.json"
            path.write_text(json.dumps({
                "updated_at": 1_000,
                "plan": "Max 5X",
                "five_hour": {"used_percent": 12.8, "resets_at": 2_000},
                "weekly": {"used_percent": 39, "resets_at": 3_000},
                "fable_weekly": {"used_percent": 81, "resets_at": 3_000},
            }))
            windows = read_claude_desktop_cache(path, now=1_100)
            self.assertEqual(windows["five_hour"]["used_percent"], 12)
            self.assertEqual(windows["plan"], "Max 5X")
            with self.assertRaises(ValueError):
                read_claude_desktop_cache(path, now=2_000)

    @patch("quota_bridge.read_claude_desktop_cache")
    @patch("quota_bridge.command_path", return_value="/usr/local/bin/claude")
    @patch("quota_bridge.subprocess.run")
    def test_claude_cli_fills_fable_missing_from_desktop_cache(
        self, run, _command_path, desktop_cache
    ):
        desktop_cache.return_value = {
            "five_hour": {"used_percent": 42, "resets_at": 2_000},
            "weekly": {"used_percent": 51, "resets_at": 3_000},
            "fable_weekly": {"used_percent": None, "resets_at": None},
            "plan": "Max 5X",
        }
        run.return_value.returncode = 0
        run.return_value.stdout = """\
Current session: 43% used
Current week (all models): 52% used
Current week (Fable): 65% used · resets Sep 8 at 12pm (America/Toronto)
"""
        windows = read_claude()
        self.assertEqual(windows["five_hour"]["used_percent"], 42)
        self.assertEqual(windows["weekly"]["used_percent"], 51)
        self.assertEqual(windows["fable_weekly"]["used_percent"], 65)

    @patch("quota_bridge.subprocess.run")
    def test_claude_plan_uses_keychain_tier(self, run):
        run.return_value.returncode = 0
        for subscription, tier, expected in (
            ("pro", "default_claude_pro", "Pro"),
            ("max", "default_claude_max_5x", "Max 5X"),
            ("max", "default_claude_max_20x", "Max 20X"),
        ):
            run.return_value.stdout = json.dumps(
                {
                    "claudeAiOauth": {
                        "subscriptionType": subscription,
                        "rateLimitTier": tier,
                    }
                }
            )
            self.assertEqual(read_claude_plan(), expected)

    @patch("quota_bridge._read_json")
    def test_weather_has_location_current_conditions_and_five_days(self, read_json):
        read_json.side_effect = [
            {
                "results": [
                    {
                        "name": "Sherbrooke",
                        "admin1": "Québec",
                        "latitude": 45.4,
                        "longitude": -71.9,
                    }
                ]
            },
            {
                "current": {
                    "temperature_2m": 21.9,
                    "apparent_temperature": 24.2,
                    "weather_code": 0,
                },
                "daily": {
                    "time": [
                        "2026-07-26",
                        "2026-07-27",
                        "2026-07-28",
                        "2026-07-29",
                        "2026-07-30",
                    ],
                    "temperature_2m_min": [12, 13, 14, 15, 16],
                    "temperature_2m_max": [22, 23, 24, 25, 26],
                    "weather_code": [0, 2, 61, 71, 95],
                },
            },
        ]
        weather = read_weather("Sherbrooke")
        self.assertEqual((weather["city"], weather["region"]), ("Sherbrooke", "QC"))
        self.assertEqual(weather["condition"], "ENSOLEILLE")
        self.assertEqual(weather["apparent_temperature_c"], 24.2)
        self.assertEqual(len(weather["forecast"]), 5)

    @patch("quota_bridge.read_codex")
    @patch("quota_bridge.read_claude")
    def test_forced_refresh_updates_both_providers(self, claude, codex):
        codex.return_value = {
            "five_hour": {"used_percent": 10, "resets_at": 1},
            "weekly": {"used_percent": 20, "resets_at": 2},
        }
        claude.return_value = {
            "five_hour": {"used_percent": 30, "resets_at": 3},
            "weekly": {"used_percent": 40, "resets_at": 4},
            "fable_weekly": {"used_percent": 50, "resets_at": 4},
        }
        state = QuotaState("192.168.1.252:8788")
        self.assertTrue(state.refresh())
        payload = state.payload()
        self.assertFalse(payload["refresh"]["active"])
        self.assertEqual(payload["refresh"]["generation"], 1)
        self.assertEqual(payload["providers"]["codex"]["status"], "ok")
        self.assertEqual(payload["providers"]["claude"]["status"], "ok")
        self.assertEqual(
            payload["api"],
            {"status": "online", "address": "192.168.1.252:8788"},
        )
        self.assertEqual(
            payload["providers"]["claude"]["fable_weekly"]["used_percent"],
            50,
        )

    def test_display_settings_are_validated_and_persisted(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "display.json"
            state = QuotaState("192.168.1.27:8788", path)
            self.assertEqual(state.set_display({"codex": True, "claude": False}), {
                "codex": True,
                "claude": False,
            })
            self.assertEqual(QuotaState(display_path=path).payload()["display"], {
                "codex": True,
                "claude": False,
            })
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(ValueError):
                state.set_display({"codex": False, "claude": False})


if __name__ == "__main__":
    unittest.main()
