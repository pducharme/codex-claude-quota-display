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
from urllib.error import HTTPError, URLError
from unittest.mock import Mock, patch

from quota_bridge import (
    QuotaState,
    Diagnostics,
    ProviderFailure,
    codex_provider_failure,
    filtered_provider_failure,
    http_provider_failure,
    QuotaHandler,
    command_path,
    parse_claude_api_usage,
    parse_claude_banked_resets,
    ClaudeAuthenticationRequired,
    ClaudeDesktopRefreshRequired,
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
    def test_provider_failure_classifies_protocol_codes_without_raw_data(self):
        expected = {-32700: "invalid_request", -32600: "invalid_request",
                    -32601: "unsupported_operation", -32602: "invalid_request",
                    -32603: "internal_error", -32099: "unknown", -32000: "unknown"}
        for code, reason in expected.items():
            with self.subTest(code=code):
                error = codex_provider_failure("quota_read", {"code": code,
                    "message": "Bearer test-secret account@example.test HTTP 401",
                    "data": {"token": "test-secret", "conversation": "private text"}})
                self.assertEqual(error.provider_failure, {
                    "stage": "quota_read", "transport": "jsonrpc_stdio",
                    "rpc_method": "account/rateLimits/read", "rpc_error_code": code, "reason": reason})
                self.assertEqual(str(error), "Codex rejected rate-limit request")
                self.assertNotIn("test-secret", json.dumps(error.__dict__))
        error = codex_provider_failure("initialize", {"code": -32601})
        self.assertEqual(error.provider_failure["rpc_method"], "initialize")
        self.assertNotIn("http_status", error.provider_failure)
        overloaded = codex_provider_failure("quota_read", {
            "code": -32001, "message": "Server overloaded; retry later."})
        self.assertEqual(overloaded.provider_failure["reason"], "service_unavailable")
        for message in ["codex account authentication required to read rate limits",
                        "chatgpt authentication required to read rate limits"]:
            self.assertEqual(codex_provider_failure("quota_read", {
                "code": -32600, "message": message}).provider_failure["reason"], "authentication_required")
        wrong_code = codex_provider_failure("quota_read", {
            "code": -32601, "message": "Server overloaded; retry later."})
        self.assertEqual(wrong_code.provider_failure["reason"], "unsupported_operation")

    def test_provider_failure_rejects_malformed_and_unrecognized_fields(self):
        for payload in [None, [], "Bearer test-secret", {}, {"code": True},
                        {"code": "-32603"}, {"code": -32603.0}, {"code": 401},
                        {"code": -32100}, {"code": -31999}, {"code": {"secret": "test-secret"}}]:
            failure = codex_provider_failure("quota_read", payload).provider_failure
            self.assertEqual(failure["reason"], "unknown")
            self.assertNotIn("rpc_error_code", failure)
            self.assertNotIn("http_status", failure)
        for payload in [None, [], {}, {"stage": []}, {"stage": "quota_read", "transport": {}},
                        {"stage": "initialize", "transport": "http", "http_status": 401}]:
            self.assertIsNone(filtered_provider_failure(payload))
        context = filtered_provider_failure({"stage": "quota_read", "transport": "jsonrpc_stdio",
            "rpc_error_code": -32603, "reason": ["test-secret"],
            "rpc_method": "private-method", "http_status": 401, "message": "test-secret"})
        self.assertEqual(context["reason"], "unknown")
        self.assertEqual(set(context), {"stage", "transport", "rpc_method", "rpc_error_code", "reason"})
        for status in [None, True, "401", 401.0, 99, 600, [], {}]:
            self.assertIsNone(http_provider_failure(status))
        for status, reason in [(401, "authentication_required"), (403, "authentication_required"),
                               (429, "rate_limited"), (503, "service_unavailable"),
                               (400, "invalid_request"), (405, "unsupported_operation"), (418, "unknown")]:
            self.assertEqual(http_provider_failure(status)["reason"], reason)

    def test_codex_rejection_captures_stage_and_cleans_up_real_pipe(self):
        popen = subprocess.Popen
        for stage in ["initialize", "quota_read"]:
            responses = [{"id": 1, "error": {"code": -32603, "message": "Bearer test-secret"}}]
            if stage == "quota_read":
                responses = [{"id": 1, "result": {}},
                             {"id": 2, "error": {"code": -32601, "data": {"token": "test-secret"}}}]
            output = "".join(json.dumps(item) + "\n" for item in responses)
            processes = []
            def spawn(*_args, **kwargs):
                process = popen([sys.executable, "-c",
                    f"import os,time; os.write(1, {output.encode()!r}); time.sleep(3)"], **kwargs)
                processes.append(process)
                return process
            with patch("quota_bridge.command_path", return_value="fake-codex"), \
                 patch("quota_bridge.subprocess.Popen", side_effect=spawn):
                with self.assertRaises(ProviderFailure) as caught:
                    read_codex(timeout=1)
                self.assertEqual(caught.exception.provider_failure["stage"], stage)
                self.assertNotIn("test-secret", str(caught.exception))
                self.assertIsNotNone(processes[0].poll())
                self.assertTrue(processes[0].stdin.closed and processes[0].stdout.closed)

    def test_provider_failure_telemetry_revalidates_context_and_preserves_throttle(self):
        with tempfile.TemporaryDirectory() as directory:
            reporter = Diagnostics(enabled=True)
            reporter.disabled_path = Path(directory) / "disabled"
            error = codex_provider_failure("quota_read", {"code": -32601})
            error.provider_failure.update(message="test-secret", data={"token": "test-secret"},
                                          rpc_method="private-method", http_status=401)
            with patch("quota_bridge.threading.Thread") as thread, \
                 patch("quota_bridge.time.monotonic", return_value=1000) as clock:
                reporter.capture("provider_refresh", error, "codex")
                event = thread.call_args.kwargs["args"][0]
                self.assertEqual(event["fingerprint"], ["provider_refresh", "codex", "provider_rejected"])
                self.assertEqual(event["contexts"]["provider_failure"]["reason"], "unsupported_operation")
                self.assertNotIn("test-secret", json.dumps(event))
                self.assertNotIn("http_status", event["contexts"]["provider_failure"])
                changed = codex_provider_failure("initialize", {"code": -32603})
                clock.return_value = 1899
                reporter.capture("provider_refresh", changed, "codex")
                self.assertEqual(thread.call_count, 1)
                clock.return_value = 1900
                reporter.capture("provider_refresh", changed, "codex")
                self.assertEqual(thread.call_count, 2)
                reporter.disabled_path.touch()
                reporter.capture("provider_refresh", error, "claude")
                self.assertEqual(thread.call_count, 2)
            with patch("quota_bridge.urlopen") as send:
                reporter.send(event)
                send.assert_not_called()
            reporter.disabled_path.unlink()
            reporter.enabled = False
            with patch("quota_bridge.threading.Thread") as thread, patch("quota_bridge.urlopen") as send:
                reporter.capture("provider_refresh", error, "codex")
                reporter.send(event)
                thread.assert_not_called()
                send.assert_not_called()

    def test_http_failure_telemetry_uses_status_without_headers_body_or_url(self):
        with tempfile.TemporaryDirectory() as directory:
            reporter = Diagnostics(enabled=True)
            reporter.disabled_path = Path(directory) / "disabled"
            error = HTTPError("https://private.test/?token=test-secret", 429, "test-secret",
                              {"Authorization": "Bearer test-secret"}, io.BytesIO(b"private conversation"))
            with patch("quota_bridge.threading.Thread") as thread:
                reporter.capture("provider_refresh", error, "claude")
                event = thread.call_args.kwargs["args"][0]
                self.assertEqual(event["contexts"]["provider_failure"], http_provider_failure(429))
                for secret in ["test-secret", "private.test", "Authorization", "private conversation"]:
                    self.assertNotIn(secret, json.dumps(event))
                reporter.capture("weather_refresh", error, "weather")
                self.assertNotIn("provider_failure", thread.call_args.kwargs["args"][0]["contexts"])

    def test_claude_reset_bank_counts_available_grants_and_cache_keeps_them(self):
        grant = {"id": "offer", "resets_total": 2, "resets_left": 2,
                 "ends_at": "2026-10-22T16:00:00Z", "paused": False}
        bank = {"eligible": True, "grants": [grant, grant.copy(),
            dict(grant, id="used", resets_left=0), dict(grant, id="paused", paused=True),
            dict(grant, id="expired", ends_at="1970-01-01T00:00:01Z")]}
        parsed = parse_claude_banked_resets(bank, now=1000)
        self.assertEqual(parsed["available_count"], 2)
        self.assertEqual([x["expires_at"] for x in parsed["expirations"]], [1792684800]*2)
        self.assertEqual(parse_claude_banked_resets({"eligible": True, "grants": []})["available_count"], 0)
        for invalid in [None, {}, {"eligible": False, "grants": []},
                        {"eligible": True, "grants": [dict(grant, resets_left=True)]},
                        {"eligible": True, "grants": [dict(grant, resets_left=3)]},
                        {"eligible": True, "grants": [dict(grant, ends_at="2026-10-22T16:00:00")]}]:
            self.assertIsNone(parse_claude_banked_resets(invalid))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cache.json"
            cache = {"updated_at": 1000, "five_hour": {"used_percent": 4}, "cedar_ember": bank}
            path.write_text(json.dumps(cache))
            self.assertEqual(read_claude_desktop_cache(path, now=1000)["banked_resets"], parsed)
            del cache["cedar_ember"]
            path.write_text(json.dumps(cache))
            self.assertIsNone(read_claude_desktop_cache(path, now=1000)["banked_resets"])

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

    def test_codex_waits_for_initialization_and_reports_rejection_or_exit(self):
        popen = subprocess.Popen
        handshake = '''
import json, os, sys, time
request = os.read(0, 65536)
assert request.count(b'\\n') == 1
assert json.loads(request)['method'] == 'initialize'
print('{"id":1,"result":{}}', flush=True)
assert json.loads(sys.stdin.readline())['method'] == 'initialized'
assert json.loads(sys.stdin.readline())['method'] == 'account/rateLimits/read'
print('{"id":2,"result":{}}', flush=True)
time.sleep(3)
'''
        for script, expected in [(handshake, None),
                                 ('print(\'{"id":1,"error":{"message":"private"}}\', flush=True)', 'initialization'),
                                 ('pass', 'closed')]:
            with patch("quota_bridge.command_path", return_value="fake-codex"), \
                 patch("quota_bridge.subprocess.Popen", side_effect=lambda *_args, **kwargs:
                       popen([sys.executable, "-c", script], **kwargs)):
                if expected:
                    with self.assertRaisesRegex(RuntimeError, expected):
                        read_codex(timeout=1)
                else:
                    self.assertIn("weekly", read_codex(timeout=1))

    @patch("quota_bridge.time.sleep")
    @patch("quota_bridge.diagnostics.capture")
    def test_transient_provider_failure_retries_once_and_keeps_last_good_values(self, capture, sleep):
        state = QuotaState()
        windows = {"five_hour": {"used_percent": 42, "resets_at": 2000}}
        for error in [TimeoutError(), ConnectionResetError(), URLError(TimeoutError())]:
            reader = Mock(side_effect=[error, windows])
            state.refresh_provider("codex", reader)
            self.assertEqual(reader.call_count, 2)
            self.assertEqual(state.providers["codex"]["status"], "ok")
            capture.assert_not_called()
        previous = state.providers["codex"].copy()
        reader = Mock(side_effect=TimeoutError())
        state.refresh_provider("codex", reader)
        self.assertEqual(reader.call_count, 2)
        self.assertEqual(state.providers["codex"]["status"], "stale")
        self.assertEqual(state.providers["codex"]["updated_at"], previous["updated_at"])
        self.assertEqual(state.providers["codex"]["five_hour"], windows["five_hour"])
        capture.assert_called_once()
        for error in [HTTPError("", 401, "", {}, None), HTTPError("", 429, "", {}, None), ValueError()]:
            reader = Mock(side_effect=error)
            state.refresh_provider("claude", reader)
            reader.assert_called_once()

    @patch("quota_bridge.diagnostics.capture")
    def test_authentication_incident_stays_visible_and_reports_again_after_recovery(self, capture):
        state = QuotaState()
        reader = Mock(side_effect=ClaudeAuthenticationRequired("private"))
        for _ in range(3):
            state.refresh_provider("claude", reader)
        self.assertEqual(reader.call_count, 1)
        capture.assert_called_once()
        provider = state.payload()["providers"]["claude"]
        self.assertEqual(provider["status"], "error")
        self.assertEqual(provider["error_reason"], "authentication_required")
        state.providers["claude"].pop("error_reason")  # Explicit reconnection for an in-memory bridge.
        state.refresh_provider("claude", lambda: {"five_hour": {"used_percent": 4}})
        self.assertNotIn("error_reason", state.providers["claude"])
        state.refresh_provider("claude", reader)
        self.assertEqual(capture.call_count, 2)
        self.assertEqual(state.providers["claude"]["status"], "stale")
        self.assertEqual(state.providers["claude"]["five_hour"]["used_percent"], 4)

    @patch("quota_bridge.read_codex", return_value={})
    @patch("quota_bridge.read_claude", return_value={})
    @patch("quota_bridge.diagnostics.capture")
    def test_claude_disabled_and_authentication_pause_survive_restart(self, capture, claude, codex):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "display.json"
            disabled = path.with_name("claude-disabled")
            blocked = path.with_name("claude-authentication-required")
            state = QuotaState(display_path=path)
            disabled.touch()
            state.refresh()
            claude.assert_not_called()
            codex.assert_called_once()
            capture.assert_not_called()
            disabled.unlink()
            claude.side_effect = ClaudeAuthenticationRequired()
            state.refresh()
            self.assertTrue(blocked.exists())
            self.assertEqual(claude.call_count, 1)
            capture.assert_called_once()
            state = QuotaState(display_path=path)
            self.assertEqual(state.payload()["providers"]["claude"]["error_reason"], "authentication_required")
            state.refresh()
            self.assertEqual(claude.call_count, 1)
            blocked.unlink()  # The Companion clears this only after successful authentication.
            claude.side_effect = None
            state.refresh()
            self.assertEqual(claude.call_count, 2)
            self.assertEqual(state.payload()["providers"]["claude"]["status"], "ok")
            self.assertNotIn("error_reason", state.providers["claude"])

    @patch("quota_bridge.diagnostics.capture")
    def test_claude_hiding_cancels_retry_and_unwritable_auth_state_still_blocks(self, capture):
        with tempfile.TemporaryDirectory() as directory:
            state = QuotaState(display_path=Path(directory) / "display.json")
            disabled = Path(directory) / "claude-disabled"
            reader = Mock(side_effect=TimeoutError())
            with patch("quota_bridge.time.sleep", side_effect=lambda _: disabled.touch()):
                state.refresh_provider("claude", reader)
            reader.assert_called_once()
            capture.assert_not_called()
            disabled.unlink()
            reader = Mock(side_effect=ClaudeAuthenticationRequired())
            with patch("quota_bridge.Path.touch", side_effect=PermissionError()):
                state.refresh_provider("claude", reader)
            state.refresh_provider("claude", reader)
            reader.assert_called_once()
            self.assertFalse(state.claude_polling_enabled())
            self.assertEqual(state.payload()["providers"]["claude"]["error_reason"], "authentication_required")

    @patch("quota_bridge.read_claude", return_value={})
    @patch("quota_bridge.read_codex", side_effect=[TimeoutError("test"), TimeoutError("test"), {}])
    @patch("quota_bridge.diagnostics.capture")
    @patch("quota_bridge.time.sleep")
    def test_failed_refresh_reports_and_next_cycle_recovers(self, sleep, capture, codex, claude):
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

    @patch("quota_bridge.shutil.which", return_value=None)
    @patch("quota_bridge.subprocess.run")
    def test_codex_bundle_supports_current_and_legacy_paths(self, run, _which):
        with tempfile.TemporaryDirectory(prefix="quota codex ") as directory:
            app = Path(directory) / "ChatGPT.app"
            paths = ("Contents/Resources/codex-cli/bin/codex", "Contents/Resources/codex")
            run.return_value.stdout = str(app) + "\n"
            for relative in reversed(paths):
                command = app / relative
                command.parent.mkdir(parents=True, exist_ok=True)
                command.write_text("#!/bin/sh\nexit 0\n")
                command.chmod(0o700)
                self.assertEqual(command_path("codex", bundle_id="com.openai.codex", bundle_paths=paths), str(command))
                self.assertEqual(command_path("codex", installed=(app / p for p in paths)), str(command))
            (app / paths[0]).chmod(0o600)
            self.assertEqual(command_path("codex", bundle_id="com.openai.codex", bundle_paths=paths), str(app / paths[1]))

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
    @patch("quota_bridge.Path.exists", return_value=False)
    def test_claude_api_fallback_and_expired_credentials(self, _authorized, opener, oauth, _cache):
        oauth.return_value = {"accessToken": "test-token", "expiresAt": (time.time() + 3600) * 1000,
                              "subscriptionType": "max", "rateLimitTier": "default_claude_max_5x"}
        for tier, expected in (("20x", "Max 20X"), ("5x", "Max 5X")):
            opener.return_value.open.side_effect = [
                io.BytesIO(b'{"five_hour":{"utilization":12}}'),
                io.BytesIO(json.dumps({"organization": {
                    "organization_type": "claude_max", "rate_limit_tier": "default_claude_max_" + tier,
                }}).encode()),
            ]
            usage = read_claude()
            self.assertEqual(usage["five_hour"]["used_percent"], 12)
            self.assertEqual(usage["plan"], expected)
        request = opener.return_value.open.call_args_list[-2].args[0]
        self.assertEqual(request.full_url, "https://api.anthropic.com/api/oauth/usage")
        self.assertEqual(request.get_header("Authorization"), "Bearer test-token")
        profile_request = opener.return_value.open.call_args.args[0]
        self.assertEqual(profile_request.full_url, "https://api.anthropic.com/api/oauth/profile")
        self.assertEqual(profile_request.get_header("Authorization"), "Bearer test-token")
        opener.assert_called_with(NoCredentialRedirect)
        self.assertIsNone(NoCredentialRedirect().redirect_request(None, None, 302, "", {}, "https://other.test"))
        for unavailable in [HTTPError(profile_request.full_url, 503, "", {}, None), io.BytesIO(b'[]')]:
            opener.return_value.open.side_effect = [io.BytesIO(b'{"five_hour":{"utilization":12}}'), unavailable]
            usage = read_claude()
            self.assertEqual(usage["five_hour"]["used_percent"], 12)
            self.assertIsNone(usage["plan"])
        opener.return_value.open.side_effect = HTTPError(request.full_url, 401, "", {}, None)
        with self.assertRaises(ClaudeAuthenticationRequired) as caught:
            read_claude()
        self.assertEqual(caught.exception.provider_failure, http_provider_failure(401))
        for credentials in [{}, {"accessToken": "expired", "expiresAt": 1}]:
            oauth.return_value = credentials
            opener.reset_mock()
            with self.assertRaises(ClaudeAuthenticationRequired):
                read_claude()
            opener.assert_not_called()

    @patch("quota_bridge.read_claude_desktop_cache", side_effect=FileNotFoundError())
    @patch("quota_bridge.read_claude_oauth")
    @patch("quota_bridge.Path.exists", return_value=True)
    @patch("quota_bridge.diagnostics.capture")
    def test_desktop_cache_startup_never_blocks_or_switches_to_cli_account(self, capture, _authorized, oauth, _cache):
        with self.assertRaises(ClaudeDesktopRefreshRequired):
            read_claude()
        oauth.assert_not_called()
        state = QuotaState()
        state.refresh_provider("claude", read_claude)
        self.assertTrue(state.claude_polling_enabled())
        self.assertEqual(state.providers["claude"]["status"], "loading")
        capture.assert_not_called()
        state.refresh_provider("claude", lambda: {"five_hour": {"used_percent": 8}})
        state.refresh_provider("claude", read_claude)
        self.assertEqual(state.providers["claude"]["status"], "stale")
        self.assertEqual(state.providers["claude"]["five_hour"]["used_percent"], 8)
        self.assertTrue(state.claude_polling_enabled())

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
