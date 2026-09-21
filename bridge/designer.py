"""Bounded page descriptions, local Designer and nearby-flight data. Stdlib only."""

import copy
import hashlib
import hmac
import json
import math
import os
import re
import secrets
import tempfile
import threading
import time
from datetime import datetime
from http.cookies import SimpleCookie
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlparse, urlencode
from urllib.request import Request, urlopen

from designer_integrations import (
    Connections,
    MODULES,
    BINDINGS as SOURCE_BINDINGS,
    ACTIONS as SOURCE_ACTIONS,
    validate_source,
    templates as source_templates,
)

ASSETS = Path(__file__).with_name("designer")
FONTS = ["pixel", "silkscreen", "pixelify", "terminal", "modern", "mono"]
BINDINGS = {
    "clock",
    "date",
    "codex.5h",
    "codex.week",
    "claude.5h",
    "claude.week",
    "weather.temperature",
    "weather.condition",
    "focus.remaining",
}
KINDS = {"text", "value", "bar", "button"}
DEVICE = re.compile(r"^[a-f0-9]{12}$")


def block(kind, x, y, w, h, text="", binding="", size=1, action=""):
    return dict(
        type=kind,
        x=x,
        y=y,
        w=w,
        h=h,
        text=text,
        binding=binding,
        size=size,
        action=action,
    )


def templates():
    def page(name, blocks=None, kind="custom", font="pixel"):
        return dict(
            id=secrets.token_hex(4),
            name=name,
            kind=kind,
            font=font,
            accent="#38bdf8",
            background="#081322",
            blocks=blocks or [],
        )

    return [
        page(
            "Quotas",
            [
                block("text", 20, 12, 280, 24, "Codex"),
                block("text", 336, 12, 280, 24, "Claude"),
                block("value", 20, 48, 280, 42, "Semaine", "codex.week", 2),
                block("value", 336, 48, 280, 42, "Semaine", "claude.week", 2),
                block("bar", 20, 108, 280, 24, binding="codex.week"),
                block("bar", 336, 108, 280, 24, binding="claude.week"),
                block("value", 20, 144, 280, 24, "5 h : ", "codex.5h"),
                block("value", 336, 144, 280, 24, "5 h : ", "claude.5h"),
            ],
        ),
        page(
            "Météo",
            [
                block("text", 20, 12, 590, 24, "Météo"),
                block("value", 20, 52, 280, 50, binding="weather.temperature", size=3),
                block("value", 320, 62, 296, 32, binding="weather.condition"),
                block("value", 20, 140, 596, 28, binding="date"),
            ],
            font="modern",
        ),
        page(
            "Horloge",
            [
                block("value", 24, 26, 592, 76, binding="clock", size=4),
                block("value", 24, 126, 592, 30, binding="date"),
            ],
            font="terminal",
        ),
        page(
            "Focus",
            [
                block("text", 20, 12, 596, 24, "Un moment pour se concentrer"),
                block("value", 20, 50, 350, 64, binding="focus.remaining", size=3),
                block(
                    "button",
                    410,
                    64,
                    200,
                    60,
                    "Démarrer / pause",
                    action="focus.toggle",
                ),
            ],
            font="mono",
        ),
        page("Dans le ciel", kind="sky", font="mono"),
        page("Page libre"),
    ] + source_templates(page, block)


def number(v, low, high):
    if type(v) not in (int, float) or not math.isfinite(v) or not low <= v <= high:
        raise ValueError("Valeur numérique invalide.")
    return v


def label(v, limit=80):
    if not isinstance(v, str) or len(v) > limit or any(ord(c) < 32 for c in v):
        raise ValueError("Texte invalide ou trop long.")
    return v


def color(v):
    if not isinstance(v, str) or not re.fullmatch("#[0-9a-fA-F]{6}", v):
        raise ValueError("Couleur invalide.")
    return v.lower()


def validate(config):
    if not isinstance(config, dict):
        raise ValueError("Configuration invalide.")
    pages = config.get("pages")
    if not isinstance(pages, list) or not 1 <= len(pages) <= 8:
        raise ValueError("Choisissez de une à huit pages.")
    out = []
    ids = set()
    for p in pages:
        if not isinstance(p, dict):
            raise ValueError("Page invalide.")
        pid = p.get("id", "")
        if (
            not isinstance(pid, str)
            or not re.fullmatch("[a-zA-Z0-9_-]{1,32}", pid)
            or pid in ids
        ):
            raise ValueError("Identifiant de page invalide.")
        ids.add(pid)
        kind = p.get("kind")
        font = p.get("font")
        if (
            kind not in ("custom", "sky", "native-quotas", "native-weather")
            or font not in FONTS
        ):
            raise ValueError("Modèle ou police inconnus.")
        blocks = p.get("blocks", [])
        if not isinstance(blocks, list) or len(blocks) > 16:
            raise ValueError("Maximum de seize éléments par page.")
        clean = []
        for b in blocks:
            if (
                not isinstance(b, dict)
                or b.get("type") not in KINDS
                or b.get("binding", "") not in BINDINGS | SOURCE_BINDINGS | {""}
            ):
                raise ValueError("Élément inconnu.")
            x = int(number(b.get("x"), 0, 639))
            y = int(number(b.get("y"), 0, 179))
            w = int(number(b.get("w"), 8, 640 - x))
            h = int(number(b.get("h"), 8, 180 - y))
            size = int(number(b.get("size", 1), 1, 4))
            action = b.get("action", "")
            if action not in {"", "focus.toggle"} | SOURCE_ACTIONS:
                raise ValueError("Action inconnue.")
            clean.append(
                block(
                    b["type"],
                    x,
                    y,
                    w,
                    h,
                    label(b.get("text", "")),
                    b.get("binding", ""),
                    size,
                    action,
                )
            )
        source = validate_source(p.get("source"))
        if (
            any(
                b["binding"].startswith("source.") or b["action"].startswith("source.")
                for b in clean
            )
            and not source
        ):
            raise ValueError("Connexion requise pour cet élément.")
        out.append(
            dict(
                id=pid,
                name=label(p.get("name", ""), 32),
                kind=kind,
                font=font,
                accent=color(p.get("accent")),
                background=color(p.get("background")),
                blocks=clean,
            )
        )
        if source:
            out[-1]["source"] = source
    sky = config.get("sky", {})
    if not isinstance(sky, dict) or type(sky.get("enabled", False)) is not bool:
        raise ValueError("Zone invalide.")
    lat = sky.get("lat")
    lon = sky.get("lon")
    if lat is not None:
        lat = number(lat, -90, 90)
    if lon is not None:
        lon = number(lon, -180, 180)
    if sky.get("enabled") and (lat is None or lon is None):
        raise ValueError("Indiquez le lieu à surveiller.")
    if type(config.get("auto_sky", False)) is not bool:
        raise ValueError("Bascule invalide.")
    if config.get("auto_sky") and not any(p["kind"] == "sky" for p in out):
        raise ValueError("Ajoutez la page Dans le ciel pour activer la bascule.")
    if sum(len(p["blocks"]) for p in out) > 48 or len(json.dumps(out)) > 16000:
        raise ValueError("Composition trop volumineuse. Réduisez le nombre d’éléments.")
    return dict(
        pages=out,
        rotation=int(number(config.get("rotation", 0), 0, 600)),
        auto_sky=config.get("auto_sky", False),
        city=label(config.get("city", "Sherbrooke"), 80),
        sky=dict(
            enabled=sky.get("enabled", False),
            lat=lat,
            lon=lon,
            radius=number(sky.get("radius", 10), 1, 100),
        ),
    )


def default_config():
    pages = templates()
    p = pages[0]
    p.update(kind="native-quotas", blocks=[], name="Quotas classiques")
    w = pages[1]
    w.update(kind="native-weather", blocks=[], name="Météo classique")
    return validate(
        dict(pages=[p, w], rotation=0, auto_sky=False, sky={}, city="Sherbrooke")
    )


def distance(a, b):
    p, q = map(math.radians, (a[0], b[0]))
    d = math.radians(b[1] - a[1])
    return (
        6371
        * 2
        * math.asin(
            min(
                1,
                math.sqrt(
                    math.sin((q - p) / 2) ** 2
                    + math.cos(p) * math.cos(q) * math.sin(d / 2) ** 2
                ),
            )
        )
    )


def read_json(url):
    # Fixed provider URLs only. No user-supplied URLs or credentials leave the Mac.
    with urlopen(
        Request(
            url,
            headers={
                "User-Agent": "QuotaDisplay/Designer",
                "Accept": "application/json",
            },
        ),
        timeout=6,
    ) as r:
        data = r.read(2_000_001)
    if len(data) > 2_000_000:
        raise ValueError("Response too large")
    return json.loads(data)


class Flights:
    def __init__(self, reader=read_json):
        self.reader = reader
        self.lock = threading.Lock()
        self.entries = {}
        self.metadata = {}

    def poll(self, sky, now=None):
        now = time.time() if now is None else now
        if not sky["enabled"]:
            return {"status": "disabled", "flights": [], "at": now}
        key = (sky["lat"], sky["lon"], sky["radius"])
        with self.lock:
            previous = self.entries.get(key, {})
            if now - previous.get("attempt", 0) < 10:
                return self.snapshot(sky, now)
            self.entries[key] = {**previous, "attempt": now}
        try:
            lat, lon, radius = key
            raw = self.reader(
                f"https://api.adsb.lol/v2/point/{lat}/{lon}/{min(250,math.ceil((radius+2)/1.852))}"
            )
            stamp = float(raw.get("now", now))
            if stamp > 1e12:
                stamp /= 1000
            if abs(stamp - now) > 60:
                raise ValueError("Stale provider")
            flights = []
            for a in raw.get("ac", raw.get("aircraft", [])):
                try:
                    if a.get("alt_baro") == "ground":
                        continue
                    pos = (
                        number(a.get("lat"), -90, 90),
                        number(a.get("lon"), -180, 180),
                    )
                    seen = number(a.get("seen_pos"), 0, 30)
                    hexid = a.get("hex", "")
                    if not re.fullmatch("[a-fA-F0-9]{6}", hexid):
                        continue
                    km = distance((lat, lon), pos)
                    if km > radius + 2:
                        continue
                    altitude = a.get("alt_baro")
                    speed = a.get("gs")
                    flights.append(
                        dict(
                            id=hexid.lower(),
                            callsign=str(a.get("flight", "")).strip()[:12],
                            aircraft=str(a.get("t", ""))[:32],
                            distance=round(km, 1),
                            inside=km <= radius,
                            altitude=(
                                round(altitude * 0.3048)
                                if type(altitude) in (int, float)
                                and math.isfinite(altitude)
                                else None
                            ),
                            speed=(
                                round(speed * 1.852)
                                if type(speed) in (int, float) and math.isfinite(speed)
                                else None
                            ),
                            lat=pos[0],
                            lon=pos[1],
                            at=stamp - seen,
                        )
                    )
                except (ValueError, TypeError):
                    continue
            flights.sort(key=lambda a: a["distance"])
            for f in flights[:2]:
                callsign = f["callsign"]
                meta_key = (f["id"], callsign)
                cached = self.metadata.get(meta_key)
                if not cached or now - cached[0] > 1800:
                    try:
                        query = (
                            f"?callsign={callsign}"
                            if re.fullmatch("[A-Z0-9]{2,10}", callsign)
                            else ""
                        )
                        response = self.reader(
                            f"https://api.adsbdb.com/v0/aircraft/{f['id']}{query}"
                        ).get("response", {})
                        cached = (now, response if isinstance(response, dict) else {})
                    except Exception:
                        cached = (now, {})
                    self.metadata[meta_key] = cached
                meta = cached[1]
                ac = meta.get("aircraft") or {}
                route = meta.get("flightroute") or {}
                f["aircraft"] = str(
                    ac.get("type") or f["aircraft"] or "Appareil inconnu"
                )[:40]
                f["airline"] = str((route.get("airline") or {}).get("name") or "")[:40]
                try:
                    start = route["origin"]
                    end = route["destination"]
                    origin = (
                        number(start["latitude"], -90, 90),
                        number(start["longitude"], -180, 180),
                    )
                    dest = (
                        number(end["latitude"], -90, 90),
                        number(end["longitude"], -180, 180),
                    )
                    total = distance(origin, dest)
                    done = distance(origin, (f["lat"], f["lon"]))
                    remaining = distance((f["lat"], f["lon"]), dest)
                    # A callsign lookup is an estimate; reject loops, unknown legs and implausible routes.
                    if (
                        total < 30
                        or route.get("midpoint")
                        or done + remaining > total * 1.2 + 50
                    ):
                        raise ValueError("Uncertain route")
                    f.update(
                        origin=str(
                            start.get("municipality") or start.get("iata_code") or "?"
                        )[:32],
                        destination=str(
                            end.get("municipality") or end.get("iata_code") or "?"
                        )[:32],
                        origin_code=str(start.get("iata_code") or "")[:4],
                        destination_code=str(end.get("iata_code") or "")[:4],
                        progress=round(100 * done / (done + remaining)),
                        route_estimated=True,
                    )
                except (KeyError, ValueError, TypeError, ZeroDivisionError):
                    pass
            result = {
                "status": "ok",
                "flights": flights[:6],
                "at": stamp,
                "attempt": now,
            }
        except Exception:
            result = {"status": "unavailable", "flights": [], "at": now, "attempt": now}
        with self.lock:
            self.entries[key] = result
            self.metadata = {
                k: v for k, v in self.metadata.items() if now - v[0] < 1800
            }
        return self.snapshot(sky, now)

    def snapshot(self, sky, now=None):
        now = time.time() if now is None else now
        if not sky["enabled"]:
            return {"status": "disabled", "flights": [], "at": now}
        key = (sky["lat"], sky["lon"], sky["radius"])
        value = copy.deepcopy(
            self.entries.get(key, {"status": "loading", "flights": [], "at": 0})
        )
        if now - value.get("at", 0) > 45:
            value.update(status="unavailable", flights=[])
        else:
            value["flights"] = [
                a for a in value.get("flights", []) if now - a["at"] <= 45
            ]
        return value


class Designer:
    def __init__(self, path, state, weather, flights=None):
        self.path = Path(path)
        self.state = state
        self.weather = weather
        self.flights = flights or Flights()
        self.lock = threading.RLock()
        self.connections = Connections(self.path.with_name("designer-connections.json"))
        self.sessions = {}
        self.devices = {}
        self.focus = {}
        self.weather_values = {}
        self.data = {
            "revision": 0,
            "config": default_config(),
            "targets": {},
            "previous": None,
        }
        self.load_error = False
        if self.path.exists():
            try:
                value = json.loads(self.path.read_text())
                validate(value["config"])
                number(value["revision"], 0, 2147483647)
                for target in value.get("targets", {}).values():
                    validate(target["config"])
                self.data = value
            except (OSError, ValueError, TypeError, KeyError):
                self.load_error = (
                    True  # Preserve the file; keep native quotas available.
                )

    def save(self, value):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(dir=self.path.parent)
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(value, f, ensure_ascii=False, allow_nan=False)
            os.replace(name, self.path)
        finally:
            if os.path.exists(name):
                os.unlink(name)
        self.data = value

    def publish(self, body):
        config = validate(body.get("config"))
        targets = body.get("targets")
        if (
            not isinstance(targets, list)
            or not targets
            or len(targets) > 32
            or any(not isinstance(d, str) or not DEVICE.fullmatch(d) for d in targets)
        ):
            raise ValueError(
                "Sélectionnez au moins un écran connecté au nouveau moteur."
            )
        with self.lock:
            if body.get("base_revision") != self.data["revision"]:
                raise ValueError(
                    "Une autre publication a eu lieu. Rechargez le Designer."
                )
            value = copy.deepcopy(self.data)
            value["previous"] = {
                k: copy.deepcopy(self.data[k]) for k in ("config", "targets")
            }
            value["revision"] += 1
            value["config"] = config
            for d in targets:
                value["targets"][d] = {"revision": value["revision"], "config": config}
            self.save(value)
            return self.info()

    def rollback(self, revision):
        with self.lock:
            if revision != self.data["revision"] or not self.data.get("previous"):
                raise ValueError("Aucune version précédente disponible.")
            old = self.data["previous"]
            value = copy.deepcopy(self.data)
            value["revision"] += 1
            value["previous"] = {
                k: copy.deepcopy(self.data[k]) for k in ("config", "targets")
            }
            value["config"] = old["config"]
            value["targets"] = old["targets"]
            # Targets newly assigned by the reverted publication also receive a default layout.
            for d in self.data["targets"]:
                value["targets"].setdefault(d, {"config": default_config()})
                value["targets"][d]["revision"] = value["revision"]
            self.save(value)
            return self.info()

    def info(self):
        with self.lock:
            now = time.time()
            data = copy.deepcopy(self.data)
            return dict(
                revision=data["revision"],
                config=data["config"],
                templates=templates(),
                connections=self.connections.info(),
                load_error=self.load_error,
                rollback=bool(data["previous"]),
                devices=[
                    dict(
                        id=d,
                        **v,
                        online=now - v["seen"] < 30,
                        desired=data["targets"].get(d, {}).get("revision", 0),
                    )
                    for d, v in self.devices.items()
                ],
                flights=self.flights.snapshot(data["config"]["sky"]),
            )

    def tick(self):
        with self.lock:
            configs = [
                copy.deepcopy(t["config"]) for t in self.data["targets"].values()
            ]
        if any(p.get("source") for c in configs for p in c["pages"]):
            self.connections.poll()
        zones = set()
        for c in configs:
            sky = c["sky"]
            key = (sky["lat"], sky["lon"], sky["radius"])
            if sky["enabled"] and key not in zones:
                zones.add(key)
                self.flights.poll(sky)
            if any(
                b.get("binding", "").startswith("weather.")
                for p in c["pages"]
                for b in p["blocks"]
            ):
                self.weather_values[c["city"]] = self.weather.get(c["city"])

    def start(self):
        def loop():
            while True:
                try:
                    self.tick()
                except Exception:
                    pass  # Keep the bridge running; clients expose source freshness.
                time.sleep(2)

        threading.Thread(target=loop, daemon=True).start()

    def action(self, device, action, page_id=""):
        if (
            not DEVICE.fullmatch(device)
            or action not in {"focus.toggle"} | SOURCE_ACTIONS
        ):
            raise ValueError("Action invalide.")
        with self.lock:
            target = self.data["targets"].get(device)
            if not target or not any(
                b.get("action") == action and (not page_id or p["id"] == page_id)
                for p in target["config"]["pages"]
                for b in p["blocks"]
            ):
                raise ValueError("Action non publiée.")
            if action.startswith("source."):
                page = next(
                    (p for p in target["config"]["pages"] if p["id"] == page_id), None
                )
                if not page or not page.get("source"):
                    raise ValueError("Page inconnue.")
                source = copy.deepcopy(page["source"])
            else:
                source = None
        if source:
            return self.connections.action(source, action, device, page_id)
        with self.lock:
            now = time.time()
            focus = self.focus.setdefault(device, {"remaining": 1500, "until": None})
            if focus["until"] is not None:
                focus.update(remaining=max(0, focus["until"] - now), until=None)
            else:
                focus["until"] = now + (focus["remaining"] or 1500)
            return {"ok": True}

    def bindings(self, config, device):
        now = datetime.now()
        payload = self.state.payload()
        weather = self.weather_values.get(config["city"], {})
        values = {
            "clock": now.strftime("%H:%M"),
            "date": now.strftime("%d / %m / %Y"),
            "weather.temperature": (
                str(round(weather["temperature_c"])) + " °C"
                if weather.get("status") == "ok"
                and weather.get("temperature_c") is not None
                else "--"
            ),
            "weather.condition": (
                weather.get("condition", "Météo indisponible")
                if weather.get("status") == "ok"
                else "Météo indisponible"
            ),
        }
        for provider in ("codex", "claude"):
            for name, key in [("5h", "five_hour"), ("week", "weekly")]:
                p = payload["providers"].get(provider, {})
                window = p.get(key, {})
                used = window.get("used_percent") if p.get("status") == "ok" else None
                values[f"{provider}.{name}"] = (
                    round(100 - used) if type(used) in (int, float) else None
                )
        focus = self.focus.get(device, {"remaining": 1500, "until": None})
        remaining = (
            max(0, int(focus["until"] - time.time()))
            if focus["until"]
            else int(focus["remaining"])
        )
        values["focus.remaining"] = f"{remaining//60:02d}:{remaining%60:02d}"
        return values

    def frame(self, device, applied=0, page="", sleeping=False):
        if not DEVICE.fullmatch(device):
            raise ValueError("Écran invalide.")
        with self.lock:
            if device not in self.devices and len(self.devices) >= 32:
                raise ValueError("Trop d’écrans.")
            self.devices[device] = {
                "seen": time.time(),
                "applied": max(0, int(applied)),
                "page": str(page)[:32],
                "sleeping": bool(sleeping),
            }
            target = self.data["targets"].get(device)
            if not target:
                return {
                    "version": 1,
                    "revision": 0,
                    "pages": [],
                    "rotation": 0,
                    "auto_sky": False,
                    "flight": {"status": "disabled", "flights": []},
                }
            c = copy.deepcopy(target["config"])
            values = self.bindings(c, device)
            pages = []
            for p in c["pages"]:
                resolved = copy.deepcopy(p)
                page_values = dict(values)
                if p.get("source"):
                    page_values.update(
                        self.connections.values(p["source"], device, p["id"])
                    )
                resolved.pop("source", None)
                for b in resolved["blocks"]:
                    v = page_values.get(b["binding"])
                    b["value"] = v if type(v) in (int, float) else None
                    if b["binding"]:
                        formatted = ("--" if v is None else str(v)) + (
                            " %"
                            if b["binding"].startswith(("codex.", "claude."))
                            and v is not None
                            else ""
                        )
                        b["text"] = (b["text"] + " " + formatted).strip()[:100]
                pages.append(resolved)
            return dict(
                version=1,
                revision=target["revision"],
                pages=pages,
                rotation=c["rotation"],
                auto_sky=c["auto_sky"],
                flight=self.flights.snapshot(c["sky"]),
                server_time=int(time.time()),
            )

    def handle(self, h, method):
        parsed = urlparse(h.path)
        path = parsed.path
        if not (path.startswith("/designer") or path.startswith("/v1/designer/")):
            return False
        try:
            bearer = h._authorized()
            session = None
            cookie = SimpleCookie()
            cookie.load(h.headers.get("Cookie", ""))
            sid = cookie.get("qd_designer")
            with self.lock:
                self.sessions = {
                    k: v for k, v in self.sessions.items() if v["expires"] > time.time()
                }
                if sid:
                    session = self.sessions.get(sid.value)
            # Revoke web sessions when the source token rotates.
            token_hash = hashlib.sha256(Path(h.token_path).read_bytes()).hexdigest()
            if session and session["token_hash"] != token_hash:
                session = None
            if not bearer and (not session or not path.startswith("/designer/")):
                h._json(401, {"error": "Ouvrez le Designer depuis le Companion."})
                return True
            if method == "GET" and path in ("/designer", "/designer/"):
                sid = secrets.token_urlsafe(32)
                csrf = secrets.token_urlsafe(24)
                with self.lock:
                    if len(self.sessions) >= 32:
                        self.sessions.pop(next(iter(self.sessions)))
                    self.sessions[sid] = {
                        "expires": time.time() + 8 * 3600,
                        "csrf": csrf,
                        "token_hash": token_hash,
                    }
                html = (ASSETS / "index.html").read_text().replace("__CSRF__", csrf)
                self.send(
                    h,
                    html.encode(),
                    "text/html; charset=utf-8",
                    cookie=f"qd_designer={sid}; HttpOnly; SameSite=Strict; Path=/designer/; Max-Age=28800",
                )
            elif method == "GET" and path in (
                "/designer/app.js",
                "/designer/style.css",
                "/designer/connections.js",
                "/designer/fonts.json",
            ):
                self.send(
                    h,
                    (ASSETS / path.rsplit("/", 1)[1]).read_bytes(),
                    {
                        "js": "text/javascript",
                        "css": "text/css",
                        "json": "application/json",
                    }[path.rsplit(".", 1)[1]],
                )
            elif method == "GET" and path == "/designer/api/state":
                h._json(200, self.info())
            elif method == "GET" and path == "/v1/designer/frame":
                q = parse_qs(parsed.query)
                get = lambda k, d="": q.get(k, [d])[0]
                h._json(
                    200,
                    self.frame(
                        get("device"),
                        get("applied", "0"),
                        get("page"),
                        get("sleeping") == "1",
                    ),
                )
            elif method == "POST":
                if path.startswith("/designer/") and not bearer:
                    if not hmac.compare_digest(
                        h.headers.get("X-Designer-CSRF", ""), session["csrf"]
                    ):
                        h._json(403, {"error": "Session expirée. Rouvrez le Designer."})
                        return True
                if (
                    h.headers.get("Content-Type", "").split(";")[0]
                    != "application/json"
                ):
                    raise ValueError("Format invalide.")
                length = int(h.headers.get("Content-Length", "0"))
                if not 0 < length <= 32768:
                    raise ValueError("Document trop volumineux.")
                body = json.loads(h.rfile.read(length))
                if not isinstance(body, dict):
                    raise ValueError("Document invalide.")
                if path == "/designer/api/publish":
                    result = self.publish(body)
                elif path == "/designer/api/rollback":
                    result = self.rollback(body.get("base_revision"))
                elif path == "/designer/api/connect":
                    result = self.connections.connect(body)
                elif path == "/designer/api/connections":
                    self.connections.poll()
                    result = self.connections.info()
                elif path == "/designer/api/places":
                    query = label(body.get("query", ""), 80)
                    if len(query) < 2:
                        raise ValueError("Ville requise.")
                    source = read_json(
                        "https://geocoding-api.open-meteo.com/v1/search?"
                        + urlencode({"name": query, "count": 5, "language": "fr"})
                    )
                    result = {
                        "places": [
                            {
                                "name": ", ".join(
                                    str(p[k])
                                    for k in ("name", "admin1", "country")
                                    if p.get(k)
                                ),
                                "lat": p["latitude"],
                                "lon": p["longitude"],
                            }
                            for p in source.get("results", [])
                        ]
                    }
                elif path == "/v1/designer/action":
                    result = self.action(
                        str(body.get("device", "")),
                        body.get("action"),
                        str(body.get("page", "")),
                    )
                else:
                    h._json(404, {"error": "not_found"})
                    return True
                h._json(200, result)
            else:
                h._json(404, {"error": "not_found"})
        except (ValueError, TypeError, KeyError):
            h._json(
                400,
                {
                    "error": "Configuration invalide. Vérifiez les champs et rechargez si une autre publication a eu lieu."
                },
            )
        except OSError:
            h._json(
                503,
                {
                    "error": "Enregistrement indisponible. La version précédente est conservée."
                },
            )
        return True

    @staticmethod
    def send(h, data, mime, cookie=None):
        h.send_response(200)
        h.send_header("Content-Type", mime)
        h.send_header("Content-Length", str(len(data)))
        h.send_header("Cache-Control", "no-store")
        h.send_header("X-Content-Type-Options", "nosniff")
        h.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
        )
        if cookie:
            h.send_header("Set-Cookie", cookie)
        h.end_headers()
        h.wfile.write(data)
