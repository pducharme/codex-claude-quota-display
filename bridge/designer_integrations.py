"""Home Assistant connections and page data. Credentials never enter page documents."""

import copy
import json
import math
import os
import re
import shlex
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from designer_local import MacStats
from urllib.parse import urlsplit
from urllib.request import Request, HTTPRedirectHandler, build_opener

# Slots carry human labels and compatible domains, so users select names, not JSON paths.
MODULES = {
    "sonos": dict(
        name="Télécommande Sonos",
        category="Musique",
        description="Titre, pièce, lecture et volume via Home Assistant.",
        slots=[("player", "Pièce Sonos", ["media_player"])],
        fields=[("title", "Morceau"), ("artist", "Artiste"), ("volume", "Volume")],
        actions=[
            ("previous", "Préc."),
            ("play_pause", "Lire/II"),
            ("next", "Suivant"),
            ("volume_down", "Vol -"),
            ("volume_up", "Vol +"),
            ("mute", "Muet"),
        ],
    ),
    "meeting": dict(
        name="Prochaine réunion",
        category="Bureau",
        description="Le prochain événement d’un calendrier Home Assistant.",
        slots=[("calendar", "Calendrier", ["calendar"])],
        fields=[("title", "Événement"), ("start", "Début"), ("remaining", "Dans")],
    ),
    "homelab": dict(
        name="Homelab",
        category="Bureau",
        description="Disponibilité, stockage et onduleur de votre serveur.",
        slots=[
            ("primary", "Serveur", ["sensor", "binary_sensor"]),
            ("secondary", "Stockage", ["sensor"]),
            ("third", "Onduleur", ["sensor", "binary_sensor"]),
        ],
    ),
    "printer": dict(
        name="Impression 3D",
        category="Atelier",
        description="Progression, temps restant et température de l’imprimante.",
        slots=[
            ("primary", "Progression (%)", ["sensor"]),
            ("secondary", "Temps restant", ["sensor"]),
            ("third", "Température", ["sensor"]),
        ],
        progress=True,
    ),
    "scenes": dict(
        name="Scènes de la maison",
        category="Maison",
        description="Trois scènes choisies, à lancer au toucher.",
        slots=[
            ("primary", "Première scène", ["scene"]),
            ("secondary", "Deuxième scène", ["scene"]),
            ("third", "Troisième scène", ["scene"]),
        ],
        actions=[
            ("scene_primary", "Scène 1"),
            ("scene_secondary", "Scène 2"),
            ("scene_third", "Scène 3"),
        ],
    ),
    "air": dict(
        name="Air intérieur",
        category="Maison",
        description="CO₂, humidité et température de vos capteurs.",
        slots=[
            ("primary", "CO₂", ["sensor"]),
            ("secondary", "Humidité", ["sensor"]),
            ("third", "Température", ["sensor"]),
        ],
    ),
    "energy": dict(
        name="Énergie",
        category="Maison",
        description="Production solaire, importation et exportation.",
        slots=[
            ("primary", "Production", ["sensor"]),
            ("secondary", "Importation", ["sensor"]),
            ("third", "Exportation", ["sensor"]),
        ],
    ),
    "ev": dict(
        name="Véhicule électrique",
        category="Maison",
        description="Batterie, autonomie et état du branchement.",
        slots=[
            ("primary", "Batterie (%)", ["sensor"]),
            ("secondary", "Autonomie", ["sensor"]),
            ("third", "Branchement", ["sensor", "binary_sensor"]),
        ],
        progress=True,
    ),
    "departures": dict(
        name="Prochains départs",
        category="Déplacements",
        description="Les horaires de bus ou de train de votre intégration locale.",
        slots=[
            ("primary", "Premier départ", ["sensor"]),
            ("secondary", "Deuxième départ", ["sensor"]),
            ("third", "Troisième départ", ["sensor"]),
        ],
    ),
    "monitor": dict(
        name="Maison à surveiller",
        category="Maison",
        description="Porte, garage et congélateur : trois états à surveiller.",
        slots=[
            ("primary", "Porte", ["binary_sensor", "sensor"]),
            ("secondary", "Garage", ["binary_sensor", "sensor"]),
            ("third", "Congélateur", ["binary_sensor", "sensor"]),
        ],
    ),
    "laundry": dict(
        name="Lessive terminée",
        category="Maison",
        description="État de la lessive et rappel à acquitter au toucher.",
        slots=[
            (
                "primary",
                "État de la lessive",
                ["sensor", "binary_sensor", "input_boolean"],
            ),
            ("secondary", "Temps restant", ["sensor"]),
        ],
        actions=[("acknowledge", "Vu, merci")],
    ),
    "packages": dict(
        name="Colis",
        category="Maison",
        description="Trois suivis de colis déjà connectés à Home Assistant.",
        slots=[
            ("primary", "Premier colis", ["sensor"]),
            ("secondary", "Deuxième colis", ["sensor"]),
            ("third", "Troisième colis", ["sensor"]),
        ],
    ),
}
for spec in MODULES.values():
    spec.setdefault("fields", [(key, label) for key, label, _ in spec["slots"]])
    spec.setdefault("actions", [])
    spec["provider"] = "home_assistant"
    spec["requires"] = (
        "Home Assistant et les appareils ou services correspondants déjà connectés."
    )

MODULES["mac_stats"] = dict(
    name="Stats ordinateur",
    category="Bureau",
    description="CPU, mémoire et débit réseau du Mac source.",
    slots=[],
    fields=[("cpu", "CPU"), ("memory", "Mémoire"), ("network", "Réseau")],
    actions=[],
    provider="local",
    requires="Le Companion mesure le Mac source; aucun compte nécessaire.",
    progress=True,
)

BINDINGS = {"source." + key for m in MODULES.values() for key, _ in m["fields"]} | {
    "source.status",
    "source.progress",
}
ACTIONS = {"source." + key for m in MODULES.values() for key, _ in m["actions"]}
ENTITY = re.compile(r"[a-z_]+\.[a-z0-9_]+")


def validate_source(value):
    if value is None:
        return None
    if not isinstance(value, dict) or value.get("module") not in MODULES:
        raise ValueError("Module inconnu.")
    spec = MODULES[value["module"]]
    entities = value.get("entities", {})
    if not isinstance(entities, dict) or set(entities) - {s[0] for s in spec["slots"]}:
        raise ValueError("Sélection invalide.")
    clean = {}
    for slot, _, domains in spec["slots"]:
        entity = entities.get(slot, "")
        if not isinstance(entity, str) or (
            entity
            and (not ENTITY.fullmatch(entity) or entity.split(".")[0] not in domains)
        ):
            raise ValueError("Appareil incompatible.")
        clean[slot] = entity
    return dict(module=value["module"], entities=clean)


def templates(page, block):
    result = []
    for key, m in MODULES.items():
        blocks = [
            block("text", 16, 10, 440, 20, m["name"]),
            block("value", 16, 156, 608, 20, binding="source.status"),
        ]
        fields = m["fields"]
        for i, (field, title) in enumerate(fields):
            width = 608 // len(fields)
            x = 16 + i * width
            blocks += [
                block("text", x, 40, width - 8, 20, title),
                block(
                    "value",
                    x,
                    64,
                    width - 8,
                    40,
                    binding="source." + field,
                    size=1 if key in ("sonos", "meeting", "mac_stats") else 2,
                ),
            ]
        actions = m["actions"]
        if actions:
            width = 608 // len(actions)
            for i, (action, title) in enumerate(actions):
                blocks.append(
                    block(
                        "button",
                        16 + i * width,
                        108,
                        width - 6,
                        40,
                        title,
                        action="source." + action,
                    )
                )
        elif m.get("progress"):
            blocks.append(block("bar", 16, 114, 608, 22, binding="source.progress"))
        p = page(m["name"], blocks, font="modern")
        p.update(
            source=dict(module=key, entities={}),
            category=m["category"],
            description=m["description"],
            requires=m["requires"],
        )
        result.append(p)
    return result


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError(
            "Redirection refusée. Utilisez l’adresse directe de Home Assistant."
        )


def request_json(url, token, data=None):
    req = Request(
        url,
        data=json.dumps(data).encode() if data is not None else None,
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
            "User-Agent": "QuotaDisplay-Designer",
        },
    )
    with build_opener(NoRedirect).open(req, timeout=6) as response:
        raw = response.read(2_000_001)
    if len(raw) > 2_000_000:
        raise ValueError("Réponse trop volumineuse.")
    return json.loads(raw)


class Keychain:
    def read(self, account):
        try:
            p = subprocess.run(
                [
                    "/usr/bin/security",
                    "find-generic-password",
                    "-s",
                    "Quota Display Designer",
                    "-a",
                    account,
                    "-w",
                ],
                capture_output=True,
                text=True,
                timeout=5,
            )
            return p.stdout.strip() if p.returncode == 0 else ""
        except (OSError, subprocess.TimeoutExpired):
            return ""

    def write(self, account, token):
        # Feed the secret through stdin; keep it out of the process argument list.
        args = [
            "add-generic-password",
            "-U",
            "-s",
            "Quota Display Designer",
            "-a",
            account,
            "-w",
            token,
        ]
        try:
            p = subprocess.run(
                ["/usr/bin/security", "-i"],
                input=shlex.join(args) + "\n",
                capture_output=True,
                text=True,
                timeout=10,
            )
            if p.returncode != 0 or self.read(account) != token:
                raise OSError("Trousseau indisponible.")
        except subprocess.TimeoutExpired:
            raise OSError("Trousseau indisponible.") from None


def base_url(value):
    if (
        not isinstance(value, str)
        or len(value) > 512
        or any(ord(c) < 33 for c in value)
    ):
        raise ValueError("Adresse invalide.")
    p = urlsplit(value)
    if (
        p.scheme not in ("http", "https")
        or not p.hostname
        or p.username
        or p.password
        or p.query
        or p.fragment
        or p.path not in ("", "/")
    ):
        raise ValueError("Indiquez l’adresse de base de Home Assistant.")
    if p.hostname in (
        "169.254.169.254",
        "metadata.google.internal",
    ) or p.hostname.startswith("169.254."):
        raise ValueError("Adresse invalide.")
    _ = p.port
    return value.rstrip("/")


def display_value(entity):
    if not entity or entity.get("state") in ("unknown", "unavailable", None):
        return "Indisponible"
    value = str(entity["state"])
    unit = entity.get("attributes", {}).get("unit_of_measurement", "")
    device_class = entity.get("attributes", {}).get("device_class")
    if value in ("on", "off"):
        pair = (
            ("Ouvert", "Fermé")
            if device_class in ("door", "garage_door", "window", "opening")
            else (
                ("Branché", "Débranché")
                if device_class == "plug"
                else ("Actif", "Inactif")
            )
        )
        value = pair[value == "off"]
    return (value + (" " + str(unit) if unit else ""))[:80]


class Connections:
    def __init__(self, path, vault=None, reader=None):
        self.path = Path(path)
        self.vault = vault or Keychain()
        self.reader = reader or request_json
        self.lock = threading.RLock()
        self.url = ""
        self.token = ""
        self.entities = {}
        self.at = 0
        self.attempt = 0
        self.status = "not_connected"
        self.acknowledged = {}
        self.mac = MacStats()
        try:
            self.url = base_url(json.loads(self.path.read_text())["home_assistant"])
        except (OSError, ValueError, KeyError, TypeError):
            pass
        if self.url:
            self.token = self.vault.read(self.url)

    @staticmethod
    def decode_entities(data):
        if not isinstance(data, list):
            raise ValueError("Réponse Home Assistant invalide.")
        result = {}
        for e in data:
            if (
                isinstance(e, dict)
                and ENTITY.fullmatch(str(e.get("entity_id", "")))
                and isinstance(e.get("attributes"), dict)
            ):
                result[e["entity_id"]] = e
        return result

    def connect(self, body):
        url = base_url(body.get("url"))
        token = body.get("token")
        if (
            not isinstance(token, str)
            or not 10 <= len(token) <= 4096
            or any(ord(c) < 33 for c in token)
        ):
            raise ValueError("Jeton invalide.")
        entities = self.decode_entities(self.reader(url + "/api/states", token))
        with self.lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            fd, temp = tempfile.mkstemp(dir=self.path.parent)
            try:
                with os.fdopen(fd, "w") as f:
                    json.dump({"home_assistant": url}, f)
                self.vault.write(url, token)
                os.replace(temp, self.path)
            finally:
                if os.path.exists(temp):
                    os.unlink(temp)
            self.url, self.token, self.entities = url, token, entities
            self.status, self.at, self.attempt = "ok", time.time(), time.time()
        return self.info()

    def info(self):
        with self.lock:
            return dict(
                home_assistant=dict(
                    url=self.url,
                    connected=bool(self.url and self.token),
                    status=(
                        self.status
                        if time.time() - self.at < 35
                        else "unavailable" if self.url else "not_connected"
                    ),
                    at=self.at,
                ),
                modules=MODULES,
                entities=[
                    dict(
                        id=k,
                        name=str(e["attributes"].get("friendly_name") or k)[:100],
                        domain=k.split(".")[0],
                    )
                    for k, e in sorted(self.entities.items())
                ],
            )

    def poll(self):
        with self.lock:
            if not self.url or not self.token or time.time() - self.attempt < 10:
                return
            url, token = self.url, self.token
            self.attempt = time.time()
        try:
            entities = self.decode_entities(self.reader(url + "/api/states", token))
            status = "ok"
        except Exception:
            entities, status = {}, "unavailable"
        with self.lock:
            if (url, token) == (self.url, self.token):
                self.entities, self.status, self.at = entities, status, time.time()

    def values(self, source, device, page):
        with self.lock:
            source = validate_source(source)
            spec = MODULES[source["module"]]
            if source["module"] == "mac_stats":
                return self.mac.values()
            if not self.url or not self.token:
                return {"source.status": "Connectez Home Assistant dans le Designer"}
            if self.status != "ok" or time.time() - self.at > 35:
                return {"source.status": "Home Assistant indisponible"}
            selected = {
                slot: self.entities.get(entity)
                for slot, entity in source["entities"].items()
            }
            missing = any(
                not selected.get(slot)
                for slot, _, _ in spec["slots"]
                if source["entities"].get(slot)
            )
            values = {"source." + k: display_value(v) for k, v in selected.items()}
            values["source.status"] = (
                "Appareil introuvable"
                if missing
                else (
                    "À configurer dans le Designer"
                    if not any(selected.values())
                    else "À jour"
                )
            )
            primary = selected.get("primary") or {}
            raw = primary.get("state")
            try:
                progress = float(raw)
                if math.isfinite(progress) and 0 <= progress <= 100:
                    values["source.progress"] = progress
            except (ValueError, TypeError):
                pass
            if source["module"] == "sonos":
                e = selected.get("player") or {}
                a = e.get("attributes", {})
                volume = a.get("volume_level")
                values.update(
                    {
                        "source.title": str(a.get("media_title") or "Aucun morceau")[
                            :80
                        ],
                        "source.artist": str(
                            a.get("media_artist") or a.get("friendly_name") or ""
                        )[:80],
                        "source.volume": (
                            f"{round(volume * 100)} %"
                            if type(volume) in (int, float) and math.isfinite(volume)
                            else "--"
                        ),
                    }
                )
                if e.get("state") in ("unknown", "unavailable"):
                    values.update(
                        {
                            "source.title": "Indisponible",
                            "source.artist": "",
                            "source.volume": "--",
                            "source.status": "Enceinte indisponible",
                        }
                    )
            elif source["module"] == "meeting":
                from datetime import datetime

                a = (selected.get("calendar") or {}).get("attributes", {})
                values.update(
                    {
                        "source.title": str(a.get("message") or "Aucun événement")[:80],
                        "source.start": str(a.get("start_time") or "--")[:32],
                        "source.remaining": "--",
                    }
                )
                try:
                    start = datetime.fromisoformat(a["start_time"])
                    remaining = start.timestamp() - time.time()
                    values["source.remaining"] = (
                        f"{math.ceil(remaining / 60)} min"
                        if remaining > 0
                        else "En cours"
                    )
                except (KeyError, ValueError, TypeError):
                    pass
            elif source["module"] == "scenes":
                for slot, entity in selected.items():
                    values["source." + slot] = str(
                        (entity or {}).get("attributes", {}).get("friendly_name")
                        or "Choisir une scène"
                    )[:80]
            elif source["module"] == "laundry":
                signature = (primary.get("state"), primary.get("last_changed"))
                if self.acknowledged.get((device, page)) == signature:
                    values["source.status"] = "Rappel acquitté"
            return values

    def action(self, source, action, device, page):
        source = validate_source(source)
        name = action.removeprefix("source.")
        if name not in {a[0] for a in MODULES[source["module"]]["actions"]}:
            raise ValueError("Action incompatible.")
        with self.lock:
            if self.status != "ok" or time.time() - self.at > 35:
                raise ValueError("Appareil indisponible.")
            url, token = self.url, self.token
            if name == "acknowledge":
                e = self.entities.get(source["entities"].get("primary"), {})
                self.acknowledged[device, page] = (
                    e.get("state"),
                    e.get("last_changed"),
                )
                return {"ok": True}
            if name.startswith("scene_"):
                entity = source["entities"].get(name[6:])
                route, data = "scene/turn_on", {"entity_id": entity}
            else:
                entity = source["entities"].get("player")
                services = dict(
                    previous="media_previous_track",
                    play_pause="media_play_pause",
                    next="media_next_track",
                    volume_up="volume_up",
                    volume_down="volume_down",
                    mute="volume_mute",
                )
                route, data = "media_player/" + services[name], {"entity_id": entity}
                if name == "mute":
                    data["is_volume_muted"] = (
                        not self.entities.get(entity, {})
                        .get("attributes", {})
                        .get("is_volume_muted", False)
                    )
            if (
                not entity
                or entity not in self.entities
                or self.entities[entity].get("state") in ("unknown", "unavailable")
            ):
                raise ValueError("Choisissez un appareil disponible.")
        self.reader(url + "/api/services/" + route, token, data)
        with self.lock:
            self.attempt = 0
        return {"ok": True}
