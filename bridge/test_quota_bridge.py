#!/usr/bin/env python3
import json
import io
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
from urllib.error import HTTPError
from unittest.mock import patch

from quota_bridge import (
    QuotaState,
    Diagnostics,
    QuotaHandler,
    command_path,
    parse_claude_api_usage,
    ClaudeAuthenticationRequired,
    NoCredentialRedirect,
    parse_codex_limits,
    read_claude,
    read_codex,
    read_claude_desktop_cache,
    read_claude_plan,
    read_weather,
    rain_summary,
    token_from,
)


class QuotaParsingTest(unittest.TestCase):
    def test_rain_forecast_never_treats_missing_or_invalid_values_as_dry(self):
        data = dict(current=dict(time="2026-09-21T23:15"), hourly=dict(
            time=[f"2026-09-22T{h:02}:00" for h in range(6)], rain=[0]*6, showers=[0]*6))
        self.assertEqual(rain_summary(data), "Pas de pluie prévue · 6 h")
        data["hourly"]["showers"][0] = 0.3
        self.assertEqual(rain_summary(data), "Pluie prévue · 23 h–00 h")
        for bad in (None, -1, float("nan")):
            data["hourly"]["rain"][3] = bad
            self.assertEqual(rain_summary(data), "Prévision pluie indisponible")
        data["hourly"]["rain"] = [0]*5
        self.assertEqual(rain_summary(data), "Prévision pluie indisponible")
        self.assertEqual(rain_summary({}), "Prévision pluie indisponible")

    def test_codex_partial_lines_time_out_and_buffered_messages_are_consumed(self):
        popen = subprocess.Popen
        # A real pipe verifies both a partial line and several JSON lines in one OS read.
        for output, succeeds in [('{"id":2', False),
                                  ('{"id":1}\n{"id":2,"result":{}}\n', True)]:
            processes = []
            def spawn(*_args, **kwargs):
                process = popen([sys.executable, "-c",
                    f"import os,time; os.write(1, {output.encode()!r}); time.sleep(3)"], **kwargs)
                processes.append(process)
                return process
            with patch("quota_bridge.command_path", return_value="fake-codex"), \
                 patch("quota_bridge.subprocess.Popen", side_effect=spawn):
                started = time.monotonic()
                if succeeds:
                    self.assertIn("weekly", read_codex(timeout=0.2))
                else:
                    with self.assertRaises(TimeoutError):
                        read_codex(timeout=0.2)
                self.assertLess(time.monotonic() - started, 2)
                self.assertIsNotNone(processes[0].poll())
                self.assertTrue(processes[0].stdin.closed and processes[0].stdout.closed)

    def test_diagnostics_scrub_secrets_throttle_and_respect_opt_out(self):
        with tempfile.TemporaryDirectory() as directory:
            reporter = Diagnostics(enabled=True)
            reporter.disabled_path = Path(directory) / "disabled"
            with patch("quota_bridge.threading.Thread") as thread:
                error = RuntimeError("Bearer secret-token user@example.test /Users/private")
                reporter.capture("provider_refresh", error, "claude", time.time() - 1000)
                event = thread.call_args.kwargs["args"][0]
                encoded = json.dumps(event)
                for secret in ["secret-token", "user@example", "/Users/private", "Bearer"]:
                    self.assertNotIn(secret, encoded)
                self.assertEqual(event["extra"]["last_success_age_seconds"], 1000)
                reporter.capture("provider_refresh", error, "claude")
                self.assertEqual(thread.call_count, 1)
                reporter.disabled_path.touch()
                reporter.capture("refresh_loop", error)
                self.assertEqual(thread.call_count, 1)
                reporter.disabled_path.unlink()
            with patch("quota_bridge.urlopen", side_effect=HTTPError("", 429, "", {"Retry-After": "1800"}, None)):
                self.assertIsNone(reporter.send(event))
            with patch("quota_bridge.threading.Thread") as thread:
                reporter.capture("refresh_loop", error)
                thread.assert_not_called()
            reporter.enabled = False
            with patch("quota_bridge.urlopen") as send:
                reporter.send(event)
                send.assert_not_called()

    @patch("quota_bridge.read_claude", return_value={})
    @patch("quota_bridge.read_codex", side_effect=[TimeoutError("test"), {}])
    @patch("quota_bridge.diagnostics.capture")
    def test_failed_refresh_reports_and_next_cycle_recovers(self, capture, codex, claude):
        state = QuotaState()
        state.refresh()
        self.assertFalse(state.refreshing)
        self.assertEqual(state.payload()["providers"]["codex"]["status"], "error")
        self.assertEqual(capture.call_args.args[0], "provider_refresh")
        state.refresh()
        self.assertEqual(state.payload()["providers"]["codex"]["status"], "ok")
        self.assertEqual(state.refresh_generation, 2)
        with patch("quota_bridge.threading.Thread.start", side_effect=RuntimeError("thread failed")):
            state.refresh()
            self.assertFalse(state.refreshing)
            with self.assertRaises(RuntimeError):
                state.start_refresh()
            self.assertFalse(state.refreshing)

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

    def test_claude_json_quota_windows_and_invalid_cli_cost_output(self):
        windows = parse_claude_api_usage({
            "five_hour": {"utilization": 12.8, "resets_at": "2026-09-13T20:00:00Z"},
            "seven_day": {"utilization": 39, "resets_at": "2026-09-18T20:00:00+00:00"},
            "limits": [{"kind": "weekly_scoped", "scope": {"model": {"display_name": "Fable"}},
                        "percent": 81, "resets_at": "2026-09-18T20:00:00.000Z"}],
        })
        self.assertEqual(windows["five_hour"], {"used_percent": 12, "resets_at": 1789329600})
        self.assertEqual(windows["weekly"]["used_percent"], 39)
        self.assertEqual(windows["fable_weekly"]["used_percent"], 81)
        self.assertEqual(windows["weekly"]["resets_at"], windows["fable_weekly"]["resets_at"])
        for invalid in ["Total cost: $0.0000\nUsage: 0 input, 0 output", {}, [],
                        {"five_hour": {"utilization": True}},
                        {"five_hour": {"utilization": float("nan")}},
                        {"five_hour": {"utilization": 101}}]:
            with self.assertRaises(ValueError):
                parse_claude_api_usage(invalid)

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
    @patch("quota_bridge.read_claude_oauth")
    def test_desktop_cache_never_mixes_a_different_cli_account(self, oauth, desktop_cache):
        desktop_cache.return_value = {
            "five_hour": {"used_percent": 42, "resets_at": 2000},
            "weekly": {"used_percent": 51, "resets_at": 3000},
            "fable_weekly": {"used_percent": None, "resets_at": None},
            "plan": "Max 5X",
        }
        self.assertEqual(read_claude(), desktop_cache.return_value)
        oauth.assert_not_called()

    @patch("quota_bridge.read_claude_desktop_cache", side_effect=FileNotFoundError())
    @patch("quota_bridge.read_claude_oauth")
    @patch("quota_bridge.build_opener")
    def test_claude_api_fallback_and_expired_credentials(self, opener, oauth, _cache):
        oauth.return_value = {"accessToken": "test-token", "expiresAt": (time.time() + 3600) * 1000,
                              "subscriptionType": "max", "rateLimitTier": "default_claude_max_5x"}
        opener.return_value.open.return_value = io.BytesIO(b'{"five_hour":{"utilization":12}}')
        self.assertEqual(read_claude()["five_hour"]["used_percent"], 12)
        request = opener.return_value.open.call_args.args[0]
        self.assertEqual(request.full_url, "https://api.anthropic.com/api/oauth/usage")
        self.assertEqual(request.get_header("Authorization"), "Bearer test-token")
        opener.assert_called_with(NoCredentialRedirect)
        self.assertIsNone(NoCredentialRedirect().redirect_request(None, None, 302, "", {}, "https://other.test"))
        opener.return_value.open.side_effect = HTTPError(request.full_url, 401, "", {}, None)
        with self.assertRaises(ClaudeAuthenticationRequired):
            read_claude()
        for credentials in [{}, {"accessToken": "expired", "expiresAt": 1}]:
            oauth.return_value = credentials
            opener.reset_mock()
            with self.assertRaises(ClaudeAuthenticationRequired):
                read_claude()
            opener.assert_not_called()

    @patch("quota_bridge.read_codex", return_value={})
    @patch("quota_bridge.read_claude", return_value={})
    def test_remote_mode_skips_providers_and_switching_back_resumes(self, claude, codex):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "display.json"
            source = path.with_name("source-host")
            source.write_text("http://source.example:8788\n")
            state = QuotaState(display_path=path)
            self.assertFalse(state.refresh())
            self.assertFalse(state.start_refresh())
            self.assertFalse(state.payload()["refresh"]["enabled"])
            self.assertFalse(state.refresh_status()["enabled"])
            codex.assert_not_called()
            claude.assert_not_called()
            source.write_text("")
            self.assertTrue(state.refresh())
            self.assertTrue(state.payload()["refresh"]["enabled"])
            codex.assert_called_once()
            claude.assert_called_once()
            def fail_after_switch():
                source.write_text("source.example:8788")
                raise ValueError("old local request")
            with patch("quota_bridge.diagnostics.capture") as capture:
                state.refresh_provider("claude", fail_after_switch)
                capture.assert_not_called()

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
                "sleep": None,
            })
            self.assertEqual(QuotaState(display_path=path).payload()["display"], {
                "codex": True,
                "claude": False,
                "sleep": None,
            })
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(ValueError):
                state.set_display({"codex": False, "claude": False})

    def test_sleep_schedule_api_persistence_validation_and_legacy_clients(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "display.json"
            path.write_text('{"codex":true,"claude":false}')
            state = QuotaState(display_path=path)
            self.assertIsNone(state.payload()["display"]["sleep"])

            class Handler(QuotaHandler):
                token_path = Path(directory) / "token"
                def log_message(self, *_args):
                    pass

            Handler.token_path.write_text("test-api-token-1234")
            Handler.state = state
            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            self.addCleanup(thread.join)
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)

            def request(method, route, value=None, authorized=True):
                connection = HTTPConnection(*server.server_address, timeout=2)
                headers = {"Authorization": "Bearer test-api-token-1234"} if authorized else {}
                connection.request(method, route, json.dumps(value) if value is not None else None, headers)
                response = connection.getresponse()
                result = response.status, json.loads(response.read())
                connection.close()
                return result

            schedule = {"enabled": True, "start_minute": 1380, "end_minute": 420,
                        "timezone": "America/Toronto", "tz": "untrusted-rule"}
            self.assertEqual(request("POST", "/v1/display", {"sleep": schedule}, False)[0], 401)
            self.assertIsNone(state.payload()["display"]["sleep"])
            status, body = request("POST", "/v1/display", {"sleep": schedule})
            self.assertEqual(status, 200)
            saved = body["display"]["sleep"]
            self.assertEqual(saved["tz"], "EST5EDT,M3.2.0,M11.1.0")
            self.assertFalse(body["display"]["claude"])
            self.assertEqual(QuotaState(display_path=path).payload()["display"]["sleep"], saved)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            # Old Companion requests must never erase an existing sleep schedule.
            self.assertEqual(request("POST", "/v1/display", {"codex": False, "claude": True})[0], 200)
            self.assertEqual(request("GET", "/v1/quotas")[1]["display"]["sleep"], saved)
            for invalid in ({"enabled": "yes"}, {"start_minute": True},
                            {"start_minute": -1}, {"end_minute": 1440},
                            {"end_minute": 1380}, {"timezone": "../../etc/passwd"},
                            {"timezone": "Missing/Zone"}):
                self.assertEqual(request("POST", "/v1/display", {"sleep": {**schedule, **invalid}})[0], 400)
                self.assertEqual(state.payload()["display"]["sleep"], saved)
            before = path.read_bytes()
            with patch("quota_bridge.os.replace", side_effect=OSError("disk error")):
                self.assertEqual(request("POST", "/v1/display", {"sleep": None})[0], 400)
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(state.payload()["display"]["sleep"], saved)
            self.assertEqual(request("POST", "/v1/display", {"sleep": {**saved, "enabled": False}})[0], 200)
            self.assertFalse(QuotaState(display_path=path).payload()["display"]["sleep"]["enabled"])

    def test_api_key_changes_without_restart_and_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "token"
            original = token_from(path)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(token_from(path), original)

            class Handler(QuotaHandler):
                token_path = path
                state = QuotaState()
                def log_message(self, *_args):
                    pass

            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                def status(key):
                    connection = HTTPConnection(*server.server_address, timeout=2)
                    connection.request("GET", "/v1/quotas", headers={"Authorization": "Bearer " + key})
                    response = connection.getresponse()
                    response.read()
                    connection.close()
                    return response.status

                self.assertEqual(status(original), 200)
                replacement = "restored-api-key-123456"
                path.write_text(replacement + "\n")
                self.assertEqual(status(original), 401)
                self.assertEqual(status(replacement), 200)
                self.assertEqual(status("é" * 20), 401)
                for invalid in ["short", "api key with spaces", "é" * 20, "x" * 257]:
                    path.write_text(invalid)
                    self.assertEqual(status(replacement), 401)
                path.unlink()
                self.assertEqual(status(replacement), 401)
                self.assertFalse(path.exists())
            finally:
                server.shutdown()
                server.server_close()
                thread.join()


if __name__ == "__main__":
    unittest.main()
