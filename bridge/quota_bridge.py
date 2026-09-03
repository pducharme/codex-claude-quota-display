#!/usr/bin/env python3
"""Read local Codex/Claude subscription limits and expose a tiny LAN API."""

import argparse
import hmac
import json
import os
import re
import secrets
import selectors
import shutil
import socket
import subprocess
import threading
import time
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlparse
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo

EMPTY_WINDOWS = {
    "five_hour": {"used_percent": None, "resets_at": None},
    "weekly": {"used_percent": None, "resets_at": None},
    "fable_weekly": {"used_percent": None, "resets_at": None},
}
ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
MONTHS = {
    "jan": 1,
    "feb": 2,
    "mar": 3,
    "apr": 4,
    "may": 5,
    "jun": 6,
    "jul": 7,
    "aug": 8,
    "sep": 9,
    "oct": 10,
    "nov": 11,
    "dec": 12,
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


def read_claude_plan():
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
        return None
    if result.returncode != 0:
        return None
    try:
        oauth = json.loads(result.stdout).get("claudeAiOauth") or {}
    except (AttributeError, json.JSONDecodeError):
        return None
    subscription = str(oauth.get("subscriptionType") or "").lower()
    tier = str(oauth.get("rateLimitTier") or "").lower()
    if subscription == "max":
        return "Max 20X" if "20x" in tier else "Max 5X" if "5x" in tier else "Max"
    return "Pro" if subscription == "pro" else None


def _clock(hour, minute, meridiem):
    hour = int(hour) % 12
    if meridiem.lower() == "pm":
        hour += 12
    return hour, int(minute or 0)


def parse_claude_reset(value, now=None):
    """Parse Claude's English reset labels into epoch seconds."""
    if not value:
        return None
    value = value.strip().replace("\u202f", " ").replace("\u00a0", " ")
    zone_match = re.search(r"\(([^()]+)\)\s*$", value)
    if not zone_match:
        return None
    try:
        zone = ZoneInfo(zone_match.group(1))
    except Exception:
        return None

    now = now or datetime.now(zone)
    now = now.astimezone(zone)
    body = value[: zone_match.start()].strip().lower()

    full = re.fullmatch(
        r"([a-z]{3})\s+(\d{1,2})\s+at\s+(\d{1,2})(?::(\d{2}))?(am|pm)",
        body,
    )
    if full and full.group(1) in MONTHS:
        hour, minute = _clock(full.group(3), full.group(4), full.group(5))
        target = datetime(
            now.year,
            MONTHS[full.group(1)],
            int(full.group(2)),
            hour,
            minute,
            tzinfo=zone,
        )
        if target < now - timedelta(days=1):
            target = target.replace(year=target.year + 1)
        return int(target.timestamp())

    relative = re.fullmatch(
        r"(?:(today|tomorrow)\s+at\s+)?(\d{1,2})(?::(\d{2}))?(am|pm)",
        body,
    )
    if relative:
        hour, minute = _clock(relative.group(2), relative.group(3), relative.group(4))
        target = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
        if relative.group(1) == "tomorrow" or (
            relative.group(1) != "today" and target <= now
        ):
            target += timedelta(days=1)
        return int(target.timestamp())
    return None


def parse_claude_usage(text, now=None):
    text = ANSI_RE.sub("", text)
    patterns = {
        "five_hour": r"^Current session:\s*(\d+)% used(?:\s*·\s*resets\s+(.+))?$",
        "weekly": (
            r"^Current week \(all models\):\s*(\d+)% used"
            r"(?:\s*·\s*resets\s+(.+))?$"
        ),
        "fable_weekly": (
            r"^Current week \(Fable\):\s*(\d+)% used"
            r"(?:\s*·\s*resets\s+(.+))?$"
        ),
    }
    windows = {key: value.copy() for key, value in EMPTY_WINDOWS.items()}
    for key, pattern in patterns.items():
        match = re.search(pattern, text, re.MULTILINE | re.IGNORECASE)
        if match:
            windows[key] = _window(
                match.group(1), parse_claude_reset(match.group(2), now)
            )
    if all(window["used_percent"] is None for window in windows.values()):
        raise ValueError("Claude /usage did not contain plan usage windows")
    return windows


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
        text=True,
        bufsize=1,
    )
    requests = (
        {
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "quota-display",
                    "title": "Quota Display",
                    "version": "1.0.10",
                },
                "capabilities": {"experimentalApi": False},
            },
        },
        {"method": "initialized"},
        {"id": 2, "method": "account/rateLimits/read", "params": None},
    )

    try:
        for request in requests:
            process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        process.stdin.flush()

        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if not selector.select(timeout=min(0.5, deadline - time.monotonic())):
                continue
            line = process.stdout.readline()
            if not line:
                break
            message = json.loads(line)
            if message.get("id") == 2:
                if "error" in message:
                    raise RuntimeError("Codex rejected rate-limit request")
                return parse_codex_limits(message["result"])
        raise TimeoutError("Codex rate-limit request timed out")
    finally:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()


def read_claude(timeout=40):
    cached = None
    try:
        cached = read_claude_desktop_cache()
        if cached["fable_weekly"]["used_percent"] is not None:
            return cached
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        pass
    installed = Path.home() / ".local" / "bin" / "claude"
    claude = command_path("claude", (installed,))
    if not claude:
        if cached:
            return cached
        raise RuntimeError("claude executable not found")
    env = os.environ.copy()
    env["LC_ALL"] = "C"
    command = [
        claude,
        "--safe-mode",
        "--no-session-persistence",
        "--tools",
        "",
        "--model",
        "quota-display-invalid-model",
        "-p",
        "/usage",
        "--output-format",
        "text",
    ]
    try:
        result = subprocess.run(
            command,
            cwd=Path.home(),
            env=env,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        if cached:
            return cached
        raise
    if result.returncode != 0:
        if cached:
            return cached
        output = ANSI_RE.sub("", result.stderr or result.stdout).strip().splitlines()
        detail = " | ".join(output[-8:])[:800] if output else "no diagnostic output"
        raise RuntimeError(f"Claude /usage failed ({result.returncode}): {detail}")
    try:
        usage = parse_claude_usage(result.stdout)
    except ValueError:
        if cached:
            return cached
        raise
    usage["plan"] = cached.get("plan") if cached else read_claude_plan()
    if cached:
        for key in EMPTY_WINDOWS:
            if cached[key]["used_percent"] is None:
                cached[key] = usage[key]
        return cached
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


class QuotaState:
    def __init__(self, api_address="127.0.0.1:8788", display_path=None):
        self.lock = threading.Lock()
        self.api_address = api_address
        self.display_path = Path(display_path).expanduser() if display_path else None
        self.display = {"codex": True, "claude": True}
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
        return {"codex": codex, "claude": claude}

    def set_display(self, value):
        display = self._validated_display(value)
        with self.lock:
            if self.display_path:
                self.display_path.parent.mkdir(parents=True, exist_ok=True)
                descriptor = os.open(
                    self.display_path,
                    os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
                    0o600,
                )
                with os.fdopen(descriptor, "w") as handle:
                    json.dump(display, handle)
                    handle.write("\n")
                os.chmod(self.display_path, 0o600)
            self.display = display
            return display.copy()

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
            with self.lock:
                previous = self.providers[name]
                previous["status"] = (
                    "stale" if previous["updated_at"] is not None else "error"
                )
            print(f"{name}: {type(error).__name__}: {error}", flush=True)

    def _run_refresh(self):
        threads = [
            threading.Thread(
                target=self.refresh_provider, args=("codex", read_codex), daemon=True
            ),
            threading.Thread(
                target=self.refresh_provider, args=("claude", read_claude), daemon=True
            ),
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        with self.lock:
            self.refresh_generation += 1
            self.refresh_completed_at = int(time.time())
            self.refreshing = False

    def refresh(self):
        with self.lock:
            if self.refreshing:
                return False
            self.refreshing = True
        self._run_refresh()
        return True

    def start_refresh(self):
        with self.lock:
            if self.refreshing:
                return False
            self.refreshing = True
        threading.Thread(target=self._run_refresh, daemon=True).start()
        return True

    def refresh_status(self):
        with self.lock:
            return {
                "active": self.refreshing,
                "generation": self.refresh_generation,
                "completed_at": self.refresh_completed_at,
            }

    def payload(self):
        with self.lock:
            providers = json.loads(json.dumps(self.providers))
            display = self.display.copy()
            refresh = {
                "active": self.refreshing,
                "generation": self.refresh_generation,
                "completed_at": self.refresh_completed_at,
            }
        return {
            "version": 1,
            "server_time": int(time.time()),
            "api": {"status": "online", "address": self.api_address},
            "display": display,
            "refresh": refresh,
            "providers": providers,
        }


class QuotaHandler(BaseHTTPRequestHandler):
    state = None
    weather = None
    token = ""

    def _json(self, status, payload):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        expected = f"Bearer {self.token}"
        supplied = self.headers.get("Authorization", "")
        return hmac.compare_digest(supplied, expected)

    def do_GET(self):
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


def token_from(path):
    path = Path(path).expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        token = path.read_text().strip()
        if len(token) >= 16:
            return token
        raise RuntimeError(f"invalid token file: {path}")
    token = secrets.token_urlsafe(24)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        handle.write(token + "\n")
    return token


def refresh_loop(state, interval):
    while True:
        state.refresh()
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

    token = token_from(args.token_file)
    QuotaHandler.state = state
    QuotaHandler.weather = WeatherCache()
    QuotaHandler.token = token
    threading.Thread(
        target=refresh_loop, args=(state, max(60, args.interval)), daemon=True
    ).start()
    server = ThreadingHTTPServer((args.listen, args.port), QuotaHandler)
    print(f"quota bridge listening on {args.listen}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
