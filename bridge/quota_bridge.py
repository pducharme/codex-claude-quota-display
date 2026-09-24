#!/usr/bin/env python3
"""Read local Codex/Claude subscription limits and expose a tiny LAN API."""

import argparse
import hmac
import json
import math
import os
import platform
import secrets
import selectors
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import traceback
import uuid
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener, urlopen
from urllib.error import HTTPError
from zoneinfo import TZPATH, ZoneInfo, ZoneInfoNotFoundError
from designer import Designer

APP_VERSION = "1.1.6"
DIAGNOSTICS_URL = "https://glitchtip.bestnetwork.cloud/api/5/store/"
DIAGNOSTICS_KEY = "6825de160b8646f48e7ec8a1bfd3b943"  # Public ingestion key, not an API credential.


class Diagnostics:
    def __init__(self, enabled=False):
        self.enabled = enabled
        self.disabled_path = Path.home() / "Library/Application Support/Quota Display/diagnostics-disabled"
        self.lock = threading.Lock()
        self.last_sent = {}
        self.retry_at = 0
        self.started = time.monotonic()
        self.session = uuid.uuid4().hex

    def capture(self, operation, error, provider="bridge", last_success=None):
        if not self.enabled or self.disabled_path.exists():
            return
        # Construct a small allowlisted payload; never serialize exceptions, locals or CLI output.
        kind = next((name for cls, name in (
            (ClaudeAuthenticationRequired, "authentication_required"),
            (subprocess.TimeoutExpired, "timeout"), (TimeoutError, "timeout"),
            (FileNotFoundError, "unavailable"), (json.JSONDecodeError, "invalid_json"),
            (ValueError, "invalid_data"), (OSError, "os_error"),
            (RuntimeError, "provider_rejected"),
        ) if isinstance(error, cls)), "unexpected_error")
        now = time.monotonic()
        fingerprint = (operation, provider, kind)
        with self.lock:
            if now < self.retry_at or now - self.last_sent.get(fingerprint, -float("inf")) < 900:
                return
            self.last_sent[fingerprint] = now
        event = {
            "event_id": uuid.uuid4().hex, "timestamp": time.time(), "platform": "python",
            "level": "error", "release": "quota-display@" + APP_VERSION,
            "environment": "production", "logger": "quota-display.bridge",
            "message": f"{operation}: {provider}: {kind}",
            "fingerprint": list(fingerprint),
            "tags": {"component": "bridge", "provider": provider, "operation": operation, "source_mode": "local"},
            "contexts": {
                "os": {"name": "macOS", "version": platform.mac_ver()[0]},
                "runtime": {"name": "Python", "version": platform.python_version()},
            },
            "extra": {"session": self.session, "uptime_seconds": int(now - self.started),
                      "last_success_age_seconds": max(0, int(time.time() - last_success)) if last_success else None},
            "exception": {"values": [{"type": kind, "value": f"{operation}: {provider}",
                "stacktrace": {"frames": [
                    {"filename": Path(frame.filename).name, "function": frame.name, "lineno": frame.lineno}
                    for frame in traceback.extract_tb(error.__traceback__)[-12:]
                ]}}]},
        }
        try:
            threading.Thread(target=self.send, args=(event,), daemon=True).start()
        except RuntimeError:
            pass  # Diagnostics must not stop the refresh loop if a thread cannot start.

    def send(self, event):
        if not self.enabled or self.disabled_path.exists():
            return
        request = Request(DIAGNOSTICS_URL, data=json.dumps(event).encode(), headers={
            "Content-Type": "application/json",
            "X-Sentry-Auth": f"Sentry sentry_version=7, sentry_key={DIAGNOSTICS_KEY}",
        })
        try:
            with urlopen(request, timeout=5) as response:
                return response.status
        except Exception as error:
            delay = 60
            if isinstance(error, HTTPError) and error.code == 429:
                try:
                    delay = max(900, float(error.headers.get("Retry-After", "900")))
                except ValueError:
                    delay = 900
            with self.lock:
                self.retry_at = time.monotonic() + delay
            # ponytail: drop failed diagnostics; no disk queue or retry worker.
            return None


diagnostics = Diagnostics()

EMPTY_WINDOWS = {
    "five_hour": {"used_percent": None, "resets_at": None},
    "weekly": {"used_percent": None, "resets_at": None},
    "fable_weekly": {"used_percent": None, "resets_at": None},
}


def _window(used=None, reset=None):
    used = None if used is None else max(0, min(100, int(used)))
    return {
        "used_percent": used,
        "resets_at": None if reset is None else int(reset),
    }


def parse_codex_limits(result):
    """Map Codex primary/secondary windows by duration, never by position."""
    snapshots = result.get("rateLimitsByLimitId") or {}
    limits = snapshots.get("codex") or result.get("rateLimits") or {}
    windows = {key: value.copy() for key, value in EMPTY_WINDOWS.items()}
    windows["plan"] = {
        "plus": "Plus",
        "prolite": "Pro 5X",
        "pro": "Pro 20X",
    }.get(limits.get("planType"))

    for candidate in (limits.get("primary"), limits.get("secondary")):
        if not isinstance(candidate, dict):
            continue
        duration = candidate.get("windowDurationMins")
        if duration is None:
            continue
        if 240 <= int(duration) <= 360:
            key = "five_hour"
        elif 9_000 <= int(duration) <= 11_000:
            key = "weekly"
        else:
            continue
        windows[key] = _window(
            candidate.get("usedPercent"), candidate.get("resetsAt")
        )
    reset_credits = result.get("rateLimitResetCredits") or {}
    expirations = []
    for credit in reset_credits.get("credits") or []:
        if (
            isinstance(credit, dict)
            and credit.get("status") == "available"
            and credit.get("resetType") == "codexRateLimits"
            and credit.get("expiresAt") is not None
        ):
            expires_at = int(credit["expiresAt"])
            expirations.append(
                {
                    "expires_at": expires_at,
                    "expires_local": datetime.fromtimestamp(expires_at)
                    .astimezone()
                    .strftime("%Y-%m-%d %H:%M"),
                }
            )
    expirations.sort(key=lambda value: value["expires_at"])
    windows["banked_resets"] = {
        "available_count": len(expirations),
        "expirations": expirations,
    }
    return windows


def read_claude_oauth():
    try:
        result = subprocess.run(
            [
                "/usr/bin/security",
                "find-generic-password",
                "-s",
                "Claude Code-credentials",
                "-w",
            ],
            text=True,
            capture_output=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {}
    if result.returncode != 0:
        return {}
    try:
        oauth = json.loads(result.stdout).get("claudeAiOauth") or {}
    except (AttributeError, json.JSONDecodeError):
        return {}
    return oauth if isinstance(oauth, dict) else {}


def read_claude_plan(oauth=None):
    oauth = read_claude_oauth() if oauth is None else oauth
    organization = oauth.get("organization") or {}
    tier = str(organization.get("rate_limit_tier") or oauth.get("rate_limit_tier")
               or oauth.get("rateLimitTier") or "").lower()
    subscription = str(organization.get("subscription_type") or oauth.get("subscription_type")
                       or organization.get("organization_type") or oauth.get("subscriptionType")
                       or tier).lower()
    if "max" in subscription:
        return "Max 20X" if "20x" in tier else "Max 5X" if "5x" in tier else "Max"
    return "Pro" if "pro" in subscription else None


class NoCredentialRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # Never forward an OAuth token to a redirected origin.


class ClaudeAuthenticationRequired(RuntimeError):
    pass


def parse_claude_api_usage(source):
    if not isinstance(source, dict):
        raise ValueError("Claude usage response is not an object")
    def window(value):
        if not isinstance(value, dict):
            return _window()
        used = value.get("utilization", value.get("percent"))
        if type(used) not in (int, float) or not math.isfinite(used) or not 0 <= used <= 100:
            return _window()
        reset = None
        try:
            date = datetime.fromisoformat(value["resets_at"].replace("Z", "+00:00"))
            if date.tzinfo is not None:
                reset = int(date.timestamp())
        except (KeyError, AttributeError, ValueError, OverflowError):
            pass
        return _window(used, reset)
    fable = source.get("seven_day_fable")
    limits = source.get("limits")
    for limit in limits if isinstance(limits, list) else []:
        if not isinstance(limit, dict) or limit.get("kind") != "weekly_scoped":
            continue
        scope = limit.get("scope")
        model = scope.get("model") if isinstance(scope, dict) else None
        if isinstance(model, dict) and str(model.get("display_name", "")).casefold() == "fable":
            fable = limit
            break
    windows = {"five_hour": window(source.get("five_hour")),
               "weekly": window(source.get("seven_day")), "fable_weekly": window(fable)}
    if all(value["used_percent"] is None for value in windows.values()):
        raise ValueError("Claude usage response has no quota windows")
    return windows


def parse_claude_banked_resets(source, now=None):
    """Normalize the read-only Claude settings bank; unsupported is not zero."""
    if not isinstance(source, dict) or source.get("eligible") is not True:
        return None
    grants = source.get("grants")
    if not isinstance(grants, list):
        return None
    now = time.time() if now is None else now
    expirations, seen = [], set()
    for grant in grants:
        if not isinstance(grant, dict):
            return None
        identifier = grant.get("id")
        if not isinstance(identifier, str) or not identifier:
            return None
        if identifier in seen:
            continue
        seen.add(identifier)
        left, total = grant.get("resets_left"), grant.get("resets_total")
        if type(left) is not int or type(total) is not int or not 0 <= left <= total <= 1000:
            return None
        if not left or grant.get("paused") is True:
            continue
        try:
            date = datetime.fromisoformat(grant["ends_at"].replace("Z", "+00:00"))
            if date.tzinfo is None:
                return None
            expires_at = int(date.timestamp())
        except (KeyError, AttributeError, ValueError, OverflowError):
            return None
        if expires_at > now:
            expirations.extend({"expires_at": expires_at,
                                "expires_local": date.astimezone().strftime("%Y-%m-%d %H:%M")}
                               for _ in range(left))
    expirations.sort(key=lambda value: value["expires_at"])
    return {"available_count": len(expirations), "expirations": expirations}


def read_claude_desktop_cache(
    path=None, now=None, max_age=900
):
    """Read the non-secret quota snapshot produced by the macOS menu app."""
    path = path or (
        Path.home()
        / "Library/Application Support/Quota Display/claude-desktop-quotas.json"
    )
    value = json.loads(Path(path).read_text())
    updated_at = value.get("updated_at")
    now = int(time.time() if now is None else now)
    if not isinstance(updated_at, int) or not 0 <= now - updated_at <= max_age:
        raise ValueError("Claude Desktop quota cache is stale")
    windows = {
        key: _window(
            (value.get(key) or {}).get("used_percent"),
            (value.get(key) or {}).get("resets_at"),
        )
        for key in EMPTY_WINDOWS
    }
    if all(window["used_percent"] is None for window in windows.values()):
        raise ValueError("Claude Desktop quota cache has no usage windows")
    windows["plan"] = (
        value.get("plan") if isinstance(value.get("plan"), str) else None
    )
    windows["banked_resets"] = parse_claude_banked_resets(value.get("cedar_ember"), now)
    return windows


def command_path(name, installed=(), bundle_id=None, bundle_relative=None):
    for path in installed:
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    if bundle_id and bundle_relative:
        try:
            result = subprocess.run(
                [
                    "/usr/bin/mdfind",
                    f"kMDItemCFBundleIdentifier == '{bundle_id}'",
                ],
                text=True,
                capture_output=True,
                timeout=5,
                check=False,
            )
            for value in result.stdout.splitlines():
                path = Path(value.strip()) / bundle_relative
                if path.is_file() and os.access(path, os.X_OK):
                    return str(path)
        except (OSError, subprocess.TimeoutExpired):
            pass
    direct = shutil.which(name)
    if direct:
        return direct
    try:
        result = subprocess.run(
            ["/bin/zsh", "-lic", 'command -v -- "$1"', "--", name],
            text=True,
            capture_output=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    for value in reversed(result.stdout.splitlines()):
        path = Path(value.strip()).expanduser()
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    return None


def read_codex(timeout=20):
    installed = (
        Path.home() / "Applications/Codex.app/Contents/Resources/codex",
        Path("/Applications/Codex.app/Contents/Resources/codex"),
    )
    codex = command_path(
        "codex",
        installed,
        bundle_id="com.openai.codex",
        bundle_relative="Contents/Resources/codex",
    )
    if not codex:
        raise RuntimeError("codex executable not found")

    process = subprocess.Popen(
        [codex, "app-server", "--stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        bufsize=0,
    )
    requests = (
        {
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "quota-display",
                    "title": "Quota Display",
                    "version": APP_VERSION,
                },
                "capabilities": {"experimentalApi": False},
            },
        },
        {"method": "initialized"},
        {"id": 2, "method": "account/rateLimits/read", "params": None},
    )

    selector = selectors.DefaultSelector()
    try:
        for request in requests:
            process.stdin.write((json.dumps(request, separators=(",", ":")) + "\n").encode())
        process.stdin.flush()

        os.set_blocking(process.stdout.fileno(), False)
        selector.register(process.stdout, selectors.EVENT_READ)
        pending = b""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if not selector.select(timeout=min(0.5, deadline - time.monotonic())):
                continue
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                break
            pending += chunk
            if len(pending) > 1024 * 1024:
                raise ValueError("Codex response exceeds size limit")
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                message = json.loads(line)
                if message.get("id") == 2:
                    if "error" in message:
                        raise RuntimeError("Codex rejected rate-limit request")
                    return parse_codex_limits(message["result"])
        raise TimeoutError("Codex rate-limit request timed out")
    finally:
        selector.close()
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
        process.stdin.close()
        process.stdout.close()


def read_claude(timeout=20):
    try:
        # Stay on the Desktop account; never fill its missing windows from another CLI account.
        return read_claude_desktop_cache()
    except (OSError, ValueError, TypeError):
        pass
    oauth = read_claude_oauth()
    token = oauth.get("accessToken")
    expiry = oauth.get("expiresAt")
    if (not isinstance(token, str) or not token.strip()
            or type(expiry) not in (int, float) or not math.isfinite(expiry)
            or expiry <= time.time() * 1000):
        raise ClaudeAuthenticationRequired("Connect Claude Code or authorize Claude Desktop")
    request = Request("https://api.anthropic.com/api/oauth/usage", headers={
        "Authorization": "Bearer " + token,
        "Accept": "application/json", "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "claude-code/2.1.69",
    })
    try:
        with build_opener(NoCredentialRedirect).open(request, timeout=timeout) as response:
            source = json.load(response)
            usage = parse_claude_api_usage(source)
    except HTTPError as error:
        if error.code in (401, 403):
            raise ClaudeAuthenticationRequired("Claude session must be renewed") from None
        raise
    # Login metadata can outlive a plan change; read the current account profile.
    usage["plan"] = read_claude_plan(source)
    if usage["plan"] is None:
        profile_request = Request("https://api.anthropic.com/api/oauth/profile", headers=request.headers)
        profile_request.add_header("User-Agent", "claude-cli (external, cli)")
        try:
            with build_opener(NoCredentialRedirect).open(profile_request, timeout=timeout) as response:
                usage["plan"] = read_claude_plan(json.load(response))
        except (OSError, ValueError, TypeError, AttributeError):
            pass  # Keep usage available without displaying an unverified cached plan.
    return usage


def _weather_label(code):
    code = int(code)
    if code == 0:
        return "ENSOLEILLE"
    if code in (1, 2, 3):
        return "NUAGEUX"
    if code in (45, 48):
        return "BROUILLARD"
    if 51 <= code <= 67 or 80 <= code <= 82:
        return "PLUIE"
    if 71 <= code <= 77 or 85 <= code <= 86:
        return "NEIGE"
    if 95 <= code <= 99:
        return "ORAGE"
    return "VARIABLE"


def _region_short(place):
    regions = {
        "Alberta": "AB",
        "British Columbia": "BC",
        "Manitoba": "MB",
        "New Brunswick": "NB",
        "Newfoundland and Labrador": "NL",
        "Nova Scotia": "NS",
        "Ontario": "ON",
        "Prince Edward Island": "PE",
        "Quebec": "QC",
        "Québec": "QC",
        "Saskatchewan": "SK",
    }
    region = place.get("admin1") or place.get("country") or ""
    return regions.get(region, region)


def _read_json(url, timeout=10):
    request = Request(url, headers={"User-Agent": "quota-display/1.0"})
    with urlopen(request, timeout=timeout) as response:
        return json.load(response)


def rain_summary(forecast):
    unavailable = "Prévision pluie indisponible"
    try:
        now = datetime.fromisoformat(forecast["current"]["time"])
        hourly = forecast["hourly"]
        upcoming = []
        for stamp, rain, showers in zip(hourly["time"], hourly["rain"], hourly["showers"]):
            end = datetime.fromisoformat(stamp)
            if not 0 < (end - now).total_seconds() <= 6 * 3600:
                continue
            if any(type(n) not in (int, float) or not math.isfinite(n) or n < 0 for n in (rain, showers)):
                return unavailable
            upcoming.append((end, rain + showers))
        if len(upcoming) != 6 or any((b[0] - a[0]).total_seconds() != 3600 for a, b in zip(upcoming, upcoming[1:])):
            return unavailable
        for end, amount in upcoming:
            if amount >= 0.1:
                return f"Pluie prévue · {(end - timedelta(hours=1)):%H} h–{end:%H} h"
        return "Pas de pluie prévue · 6 h"
    except (KeyError, ValueError, TypeError):
        return unavailable


def read_weather(city):
    city = city.strip()
    if not 1 <= len(city) <= 80:
        raise ValueError("invalid city")
    geocoding = _read_json(
        "https://geocoding-api.open-meteo.com/v1/search?"
        + urlencode(
            {"name": city, "count": 1, "language": "fr", "format": "json"}
        )
    )
    results = geocoding.get("results") or []
    if not results:
        raise ValueError("city not found")
    place = results[0]
    forecast = _read_json(
        "https://api.open-meteo.com/v1/forecast?"
        + urlencode(
            {
                "latitude": place["latitude"],
                "longitude": place["longitude"],
                "current": "temperature_2m,apparent_temperature,weather_code",
                "hourly": "rain,showers",
                "daily": (
                    "temperature_2m_max,temperature_2m_min,weather_code"
                ),
                "timezone": "auto",
                "forecast_days": 5,
            }
        )
    )
    current = forecast["current"]
    daily = forecast["daily"]
    code = int(current["weather_code"])
    day_names = ("LUN", "MAR", "MER", "JEU", "VEN", "SAM", "DIM")
    days = []
    for index, date in enumerate(daily["time"]):
        day_index = datetime.strptime(date, "%Y-%m-%d").weekday()
        day_code = int(daily["weather_code"][index])
        days.append(
            {
                "date": date,
                "day": "AUJ" if index == 0 else day_names[day_index],
                "minimum_c": round(
                    float(daily["temperature_2m_min"][index]), 1
                ),
                "maximum_c": round(
                    float(daily["temperature_2m_max"][index]), 1
                ),
                "weather_code": day_code,
                "condition": _weather_label(day_code),
            }
        )
    return {
        "status": "ok",
        "city": place["name"],
        "region": _region_short(place),
        "temperature_c": round(float(current["temperature_2m"]), 1),
        "apparent_temperature_c": round(
            float(current["apparent_temperature"]), 1
        ),
        "weather_code": code,
        "condition": _weather_label(code),
        "forecast": days,
        "rain_summary": rain_summary(forecast),
        "updated_at": int(time.time()),
    }


class WeatherCache:
    def __init__(self):
        self.lock = threading.Lock()
        self.entries = {}

    def get(self, city):
        key = city.strip().casefold()
        with self.lock:
            cached = self.entries.get(key)
            if cached and time.time() - cached["updated_at"] < 600:
                return cached.copy()
        try:
            weather = read_weather(city)
        except Exception:
            if cached:
                stale = cached.copy()
                stale["status"] = "stale"
                return stale
            return {"status": "error", "city": city.strip()}
        with self.lock:
            self.entries[key] = weather
        return weather.copy()


def validated_sleep(value):
    if not isinstance(value, dict) or type(value.get("enabled")) is not bool:
        raise ValueError("invalid sleep schedule")
    start, end = value.get("start_minute"), value.get("end_minute")
    if any(type(v) is not int or not 0 <= v < 1440 for v in (start, end)) or start == end:
        raise ValueError("invalid sleep hours")
    timezone = value.get("timezone")
    if not isinstance(timezone, str):
        raise ValueError("invalid timezone")
    try:
        ZoneInfo(timezone)  # Also rejects absolute paths and traversal.
    except (ValueError, ZoneInfoNotFoundError) as error:
        raise ValueError("invalid timezone") from error
    # TZif's POSIX footer lets the screen handle daylight saving time offline.
    for root in TZPATH:
        path = Path(root) / timezone
        if path.is_file():
            data = path.read_bytes()
            if data[:5] in (b"TZif2", b"TZif3", b"TZif4"):
                tz = data.rsplit(b"\n", 2)[-2].decode("ascii")
                if 0 < len(tz) <= 128:
                    return {"enabled": value["enabled"], "start_minute": start,
                            "end_minute": end, "timezone": timezone, "tz": tz}
    raise ValueError("timezone has no supported clock rule")


class QuotaState:
    def __init__(self, api_address="127.0.0.1:8788", display_path=None):
        self.lock = threading.Lock()
        self.api_address = api_address
        self.display_path = Path(display_path).expanduser() if display_path else None
        self.display = {"codex": True, "claude": True, "sleep": None}
        if self.display_path and self.display_path.exists():
            try:
                self.display = self._validated_display(
                    json.loads(self.display_path.read_text())
                )
            except (OSError, ValueError, TypeError, json.JSONDecodeError):
                pass
        self.refreshing = False
        self.refresh_generation = 0
        self.refresh_completed_at = None
        self.refresh_started_at = None
        self.interval = 300
        self.providers = {
            "codex": {
                "status": "loading",
                "updated_at": None,
                **{key: value.copy() for key, value in EMPTY_WINDOWS.items()},
            },
            "claude": {
                "status": "loading",
                "updated_at": None,
                **{key: value.copy() for key, value in EMPTY_WINDOWS.items()},
            },
        }

    @staticmethod
    def _validated_display(value):
        if not isinstance(value, dict):
            raise ValueError("invalid display settings")
        codex = value.get("codex")
        claude = value.get("claude")
        if type(codex) is not bool or type(claude) is not bool or not (codex or claude):
            raise ValueError("at least one provider must be displayed")
        sleep = value.get("sleep")
        return {"codex": codex, "claude": claude,
                "sleep": validated_sleep(sleep) if sleep is not None else None}

    def set_display(self, value):
        if not isinstance(value, dict) or not value or value.keys() - {"codex", "claude", "sleep"}:
            raise ValueError("invalid display settings")
        with self.lock:
            display = self._validated_display({**self.display, **value})
            if self.display_path:
                self.display_path.parent.mkdir(parents=True, exist_ok=True)
                with tempfile.NamedTemporaryFile(mode="w", dir=self.display_path.parent,
                                                 delete=False) as handle:
                    temporary = Path(handle.name)
                try:
                    with temporary.open("w") as handle:
                        json.dump(display, handle)
                        handle.write("\n")
                    os.replace(temporary, self.display_path)
                finally:
                    temporary.unlink(missing_ok=True)
            self.display = display
            return json.loads(json.dumps(display))

    def local_providers_enabled(self):
        if self.display_path is None:
            return True
        try:
            return not self.display_path.with_name("source-host").read_text().strip()
        except FileNotFoundError:
            return True

    def refresh_provider(self, name, reader):
        try:
            windows = reader()
            with self.lock:
                self.providers[name] = {
                    "status": "ok",
                    "updated_at": int(time.time()),
                    **windows,
                }
            print(f"{name}: refreshed", flush=True)
        except Exception as error:
            if not self.local_providers_enabled():
                return
            with self.lock:
                previous = self.providers[name]
                previous["status"] = (
                    "stale" if previous["updated_at"] is not None else "error"
                )
                last_success = previous["updated_at"]
            diagnostics.capture("provider_refresh", error, name, last_success)
            print(f"{name}: {type(error).__name__}: {error}", flush=True)

    def _run_refresh(self):
        threads = []
        try:
            for name, reader in (("codex", read_codex), ("claude", read_claude)):
                thread = threading.Thread(target=self.refresh_provider, args=(name, reader), daemon=True)
                thread.start()
                threads.append(thread)
            for thread in threads:
                thread.join()
            with self.lock:
                self.refresh_generation += 1
                self.refresh_completed_at = int(time.time())
        except Exception as error:
            diagnostics.capture("refresh_cycle", error)
        finally:
            for thread in threads:
                thread.join()
            with self.lock:
                self.refreshing = False

    def refresh(self):
        with self.lock:
            if self.refreshing or not self.local_providers_enabled():
                return False
            self.refreshing = True
            self.refresh_started_at = int(time.time())
        self._run_refresh()
        return True

    def start_refresh(self):
        with self.lock:
            if self.refreshing or not self.local_providers_enabled():
                return False
            self.refreshing = True
            self.refresh_started_at = int(time.time())
        try:
            threading.Thread(target=self._run_refresh, daemon=True).start()
        except Exception:
            with self.lock:
                self.refreshing = False
            raise
        return True

    def refresh_status(self):
        with self.lock:
            return {
                "active": self.refreshing,
                "enabled": self.local_providers_enabled(),
                "generation": self.refresh_generation,
                "completed_at": self.refresh_completed_at,
                "started_at": self.refresh_started_at,
                "interval_seconds": self.interval,
            }

    def payload(self):
        with self.lock:
            providers = json.loads(json.dumps(self.providers))
            display = json.loads(json.dumps(self.display))
            refresh = {
                "active": self.refreshing,
                "enabled": self.local_providers_enabled(),
                "generation": self.refresh_generation,
                "completed_at": self.refresh_completed_at,
                "started_at": self.refresh_started_at,
                "interval_seconds": self.interval,
            }
        return {
            "version": 1,
            "app_version": APP_VERSION,
            "server_time": int(time.time()),
            "api": {"status": "online", "address": self.api_address},
            "display": display,
            "refresh": refresh,
            "providers": providers,
        }


class QuotaHandler(BaseHTTPRequestHandler):
    designer = None
    state = None
    weather = None
    token_path = None

    def _json(self, status, payload):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        try:
            token = token_from(self.token_path, create=False)
        except (OSError, ValueError, TypeError):
            return False
        expected = f"Bearer {token}"
        supplied = self.headers.get("Authorization", "")
        return hmac.compare_digest(supplied.encode(), expected.encode())

    def do_GET(self):
        if self.designer and self.designer.handle(self, "GET"):
            return
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self._json(200, {"ok": True})
            return
        if parsed.path not in ("/v1/quotas", "/v1/weather"):
            self._json(404, {"error": "not_found"})
            return
        if not self._authorized():
            self._json(401, {"error": "unauthorized"})
            return
        if parsed.path == "/v1/quotas":
            self._json(200, self.state.payload())
            return
        city = (parse_qs(parsed.query).get("city") or [""])[0]
        if not city:
            self._json(400, {"error": "city_required"})
            return
        self._json(200, {"version": 1, "weather": self.weather.get(city)})

    def do_POST(self):
        if self.designer and self.designer.handle(self, "POST"):
            return
        parsed = urlparse(self.path)
        if parsed.path not in ("/v1/refresh", "/v1/display"):
            self._json(404, {"error": "not_found"})
            return
        if not self._authorized():
            self._json(401, {"error": "unauthorized"})
            return
        if parsed.path == "/v1/display":
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 1024:
                    raise ValueError
                value = json.loads(self.rfile.read(length))
                display = self.state.set_display(value)
            except (OSError, ValueError, TypeError, json.JSONDecodeError):
                self._json(400, {"error": "invalid_display"})
                return
            self._json(200, {"version": 1, "display": display})
            return
        started = self.state.start_refresh()
        self._json(
            202,
            {
                "version": 1,
                "started": started,
                "refresh": self.state.refresh_status(),
            },
        )

    def log_message(self, message, *args):
        print(f"http: {message % args}", flush=True)


def token_from(path, *, create=True):
    path = Path(path).expanduser()
    try:
        token = path.read_text().strip()
    except FileNotFoundError:
        if not create:
            raise
    else:
        if not 16 <= len(token) <= 256 or not all(33 <= ord(c) <= 126 for c in token):
            raise ValueError(f"invalid token file: {path}")
        return token
    path.parent.mkdir(parents=True, exist_ok=True)
    token = secrets.token_urlsafe(24)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        handle.write(token + "\n")
    return token


def refresh_loop(state, interval):
    while True:
        try:
            state.refresh()
        except Exception as error:
            diagnostics.capture("refresh_loop", error)
        time.sleep(interval)


def lan_ip():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as connection:
            connection.connect(("1.1.1.1", 80))
            return connection.getsockname()[0]
    except OSError:
        return "127.0.0.1"


def main():
    default_token = (
        Path.home()
        / "Library"
        / "Application Support"
        / "Quota Display"
        / "token"
    )
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8788)
    parser.add_argument("--interval", type=int, default=300)
    parser.add_argument("--token-file", default=str(default_token))
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--show-token", action="store_true")
    args = parser.parse_args()

    if args.show_token:
        print(token_from(args.token_file))
        return

    state = QuotaState(
        f"{lan_ip()}:{args.port}",
        Path(args.token_file).expanduser().with_name("display.json"),
    )
    if args.once:
        state.refresh()
        print(json.dumps(state.payload(), indent=2))
        return

    diagnostics.enabled = True
    state.interval = max(60, args.interval)
    token_from(args.token_file)
    QuotaHandler.state = state
    QuotaHandler.weather = WeatherCache()
    QuotaHandler.token_path = Path(args.token_file).expanduser()
    QuotaHandler.designer = Designer(QuotaHandler.token_path.with_name("designer.json"), state, QuotaHandler.weather)
    QuotaHandler.designer.start()
    threading.Thread(
        target=refresh_loop, args=(state, state.interval), daemon=True
    ).start()
    server = ThreadingHTTPServer((args.listen, args.port), QuotaHandler)
    print(f"quota bridge listening on {args.listen}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
