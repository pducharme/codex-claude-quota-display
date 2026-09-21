"""Bounded, cached public service adapters. Provider secrets stay in Keychain."""

import copy
import hashlib
import json
import math
import os
import re
import tempfile
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, HTTPRedirectHandler, build_opener

MODULES = {
    "github": dict(
        name="Build / déploiement",
        category="Bureau",
        description="Le dernier workflow GitHub Actions de votre projet.",
        requires="Dépôt GitHub public, ou jeton avec accès Actions en lecture pour un dépôt privé.",
        provider="github",
        fields=[("build", "Workflow"), ("result", "État"), ("branch", "Branche")],
        options=[
            dict(
                key="repository",
                label="Dépôt GitHub",
                placeholder="propriétaire/projet",
                default="",
            ),
            dict(
                key="branch",
                label="Branche (facultatif)",
                placeholder="Toutes les branches",
                default="",
            ),
        ],
        interval=60,
    ),
    "youtube": dict(
        name="Créateur YouTube",
        category="Créateur",
        description="Abonnés publics, vues, objectif et dernière vidéo.",
        requires="Clé YouTube Data API v3. Le nombre public d’abonnés est arrondi.",
        provider="youtube",
        fields=[
            ("subscribers", "Abonnés"),
            ("views", "Vues"),
            ("latest", "Dernière vidéo"),
            ("goal", "Objectif"),
        ],
        options=[
            dict(
                key="channel",
                label="Chaîne YouTube",
                placeholder="@maChaine ou identifiant UC…",
                default="",
            ),
            dict(
                key="goal",
                label="Objectif d’abonnés",
                type="number",
                min=1,
                max=1000000000,
                default=1000,
            ),
        ],
        interval=300,
        progress=True,
    ),
    "twitch": dict(
        name="Live / Twitch",
        category="Créateur",
        description="En direct ou hors ligne, spectateurs et durée du stream.",
        requires="Client ID et secret d’une application Twitch. Aucun mot de passe du compte.",
        provider="twitch",
        fields=[
            ("title", "Diffusion"),
            ("viewers", "Spectateurs"),
            ("duration", "Durée"),
        ],
        options=[
            dict(
                key="channel",
                label="Nom de la chaîne Twitch",
                placeholder="ma_chaine",
                default="",
            )
        ],
        interval=30,
    ),
    "currency": dict(
        name="Cours et devises",
        category="Bureau",
        description="Devises quotidiennes ou Bitcoin, Ether et Solana avec variation.",
        requires="Frankfurter pour les devises; CoinGecko pour les cryptoactifs. Accès CoinGecko Demo configurable dans Connexions.",
        provider="public",
        fields=[("rate", "Valeur"), ("change", "Variation"), ("date", "Publication")],
        options=[
            dict(
                key="asset",
                label="À suivre",
                default="Devises",
                choices=["Devises", "Bitcoin", "Ether", "Solana"],
            ),
            dict(
                key="base",
                label="Devise de départ",
                default="CAD",
                choices=[
                    "CAD",
                    "USD",
                    "EUR",
                    "GBP",
                    "CHF",
                    "JPY",
                    "AUD",
                    "NZD",
                    "CNY",
                    "MXN",
                ],
            ),
            dict(
                key="quote",
                label="Devise d’arrivée",
                default="USD",
                choices=[
                    "CAD",
                    "USD",
                    "EUR",
                    "GBP",
                    "CHF",
                    "JPY",
                    "AUD",
                    "NZD",
                    "CNY",
                    "MXN",
                ],
            ),
        ],
        interval=3600,
    ),
}
for spec in MODULES.values():
    spec.update(slots=[], actions=[])

CREDENTIALS = {
    "currency": dict(
        name="CoinGecko",
        note="Clé Demo pour Bitcoin, Ether et Solana. Les devises n’en ont pas besoin. Sans clé, la lecture utilise l’accès public lorsqu’il est disponible.",
        fields=[dict(key="key", label="Clé CoinGecko Demo", secret=True)],
    ),
    "github": dict(
        name="GitHub",
        note="Facultatif pour un dépôt public. Pour un dépôt privé, choisissez un jeton limité au dépôt avec la permission Actions en lecture.",
        fields=[dict(key="token", label="Jeton GitHub", secret=True)],
    ),
    "youtube": dict(
        name="YouTube",
        note="Activez YouTube Data API v3 dans votre projet Google Cloud, puis créez une clé limitée à cette API.",
        fields=[dict(key="key", label="Clé YouTube Data API", secret=True)],
    ),
    "twitch": dict(
        name="Twitch",
        note="Créez une application sur dev.twitch.tv et recopiez son Client ID et son secret. Le Companion lit les diffusions publiques.",
        fields=[
            dict(key="client_id", label="Client ID"),
            dict(key="client_secret", label="Client secret", secret=True),
        ],
    ),
}


def validate_options(module, value, definitions=None):
    if not isinstance(value, dict):
        raise ValueError("Réglages invalides.")
    definitions = MODULES[module]["options"] if definitions is None else definitions
    if set(value) - {d["key"] for d in definitions}:
        raise ValueError("Réglage inconnu.")
    out = {}
    for d in definitions:
        v = value.get(d["key"], d["default"])
        if d.get("type") == "number":
            if (
                type(v) not in (int, float)
                or not math.isfinite(v)
                or not d["min"] <= v <= d["max"]
                or int(v) != v
            ):
                raise ValueError("Objectif invalide.")
            v = int(v)
        else:
            if not isinstance(v, str) or len(v) > 120 or any(ord(c) < 32 for c in v):
                raise ValueError("Texte invalide.")
            v = v.strip()
            if d.get("choices") and v not in d["choices"]:
                raise ValueError("Devise inconnue.")
        out[d["key"]] = v
    if module == "github" and out["repository"]:
        if not re.fullmatch(
            r"[A-Za-z0-9-]{1,39}/[A-Za-z0-9_.-]{1,100}", out["repository"]
        ) or out["repository"].split("/")[1] in (".", ".."):
            raise ValueError("Utilisez propriétaire/projet.")
    if (
        module == "youtube"
        and out["channel"]
        and not re.fullmatch(
            r"(?:UC[A-Za-z0-9_-]{22}|@[^\s/?#]{1,100})", out["channel"]
        )
    ):
        raise ValueError("Utilisez @nom ou un identifiant de chaîne UC.")
    if (
        module == "twitch"
        and out["channel"]
        and not re.fullmatch(r"[A-Za-z0-9_]{1,25}", out["channel"])
    ):
        raise ValueError("Chaîne Twitch invalide.")
    if (
        module == "currency"
        and out["asset"] == "Devises"
        and out["base"] == out["quote"]
    ):
        raise ValueError("Choisissez deux devises différentes.")
    return out


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError("Redirection du fournisseur refusée.")


def fetch_json(url, headers=None, form=None):
    headers = {
        "User-Agent": "QuotaDisplay-Designer",
        "Accept": "application/json",
        **(headers or {}),
    }
    body = None
    if form is not None:
        body = urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    with build_opener(NoRedirect).open(
        Request(url, data=body, headers=headers), timeout=6
    ) as response:
        raw = response.read(2_000_001)
    if len(raw) > 2_000_000:
        raise ValueError("Réponse trop volumineuse.")
    return json.loads(raw)


def count(value):
    if isinstance(value, str) and re.fullmatch(r"\d{1,18}", value):
        value = int(value)
    if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
        return None
    return int(value)


def compact(value):
    v = count(value)
    if v is None:
        return "--"
    return (
        f"{v/1000000:.2f} M"
        if v >= 1000000
        else f"{v/1000:.1f} k" if v >= 10000 else str(v)
    )


class WebServices:
    def __init__(self, path, vault, reader=None):
        self.path = Path(path)
        self.vault = vault
        self.reader = reader or fetch_json
        self.lock = threading.RLock()
        self.accounts = {}
        self.secrets = {}
        self.cache = {}
        self.twitch_token = None
        try:
            stored = json.loads(self.path.read_text())
            if not isinstance(stored, dict):
                raise ValueError()
            for provider, entry in stored.items():
                if (
                    provider in CREDENTIALS
                    and isinstance(entry, dict)
                    and re.fullmatch(
                        r"service-[a-z]+-[a-f0-9]{20}", str(entry.get("account", ""))
                    )
                ):
                    self.accounts[provider] = entry
                    try:
                        raw = self.vault.read(entry["account"])
                        self.secrets[provider] = (
                            self.validate_credentials(provider, json.loads(raw))
                            if raw
                            else {}
                        )
                    except (OSError, ValueError, TypeError):
                        self.secrets[provider] = {}
        except (OSError, ValueError, TypeError):
            pass

    @staticmethod
    def validate_credentials(provider, body):
        if provider not in CREDENTIALS or not isinstance(body, dict):
            raise ValueError("Service inconnu.")
        out = {}
        fields = CREDENTIALS[provider]["fields"]
        if set(body) - {d["key"] for d in fields}:
            raise ValueError("Champ inconnu.")
        for d in fields:
            value = body.get(d["key"], "")
            if (
                not isinstance(value, str)
                or not 8 <= len(value) <= 4096
                or any(ord(c) < 33 for c in value)
            ):
                raise ValueError("Accès invalide.")
            out[d["key"]] = value
        return out

    def configure(self, provider, body):
        credentials = self.validate_credentials(provider, body)
        encoded = json.dumps(credentials, sort_keys=True)
        account = (
            "service-"
            + provider
            + "-"
            + hashlib.sha256(encoded.encode()).hexdigest()[:20]
        )
        with self.lock:
            updated = copy.deepcopy(self.accounts)
            updated[provider] = {"account": account}
            self.path.parent.mkdir(parents=True, exist_ok=True)
            fd, name = tempfile.mkstemp(dir=self.path.parent)
            try:
                with os.fdopen(fd, "w") as file:
                    json.dump(updated, file)
                self.vault.write(account, encoded)
                os.replace(name, self.path)
            finally:
                if os.path.exists(name):
                    os.unlink(name)
            self.accounts = updated
            self.secrets[provider] = credentials
            self.cache = {
                k: v for k, v in self.cache.items() if v["module"] != provider
            }
            if provider == "twitch":
                self.twitch_token = None
        return self.info()

    def info(self):
        with self.lock:
            return {
                name: dict(spec, configured=bool(self.secrets.get(name)))
                for name, spec in CREDENTIALS.items()
            }

    @staticmethod
    def key(source):
        return json.dumps(
            [
                source["module"],
                validate_options(source["module"], source.get("options", {})),
            ],
            sort_keys=True,
        )

    @staticmethod
    def interval(source):
        return (
            60
            if source["module"] == "currency"
            and source.get("options", {}).get("asset", "Devises") != "Devises"
            else MODULES[source["module"]]["interval"]
        )

    def poll(self, sources, now=None):
        now = time.time() if now is None else now
        active = {self.key(s): s for s in sources if s["module"] in MODULES}
        with self.lock:
            # Keep recent previews too, so switching pages cannot bypass provider quotas.
            self.cache = {
                k: v
                for k, v in self.cache.items()
                if k in active or now < v.get("retry", 0) + 60
            }
            # ponytail: at most 512 cache entries; move to per-provider budgets if concurrent clients grow.
            while len(self.cache) > 512:
                self.cache.pop(next(iter(self.cache)))
        for key, source in active.items():
            module = source["module"]
            options = validate_options(module, source.get("options", {}))
            interval = self.interval(source)
            with self.lock:
                old = self.cache.get(key, {})
                if now < old.get("retry", 0):
                    continue
                credentials = copy.deepcopy(self.secrets.get(module, {}))
                # Reserve this attempt before I/O. Repeated refreshes must respect quotas.
                self.cache[key] = {
                    "module": module,
                    "retry": now + interval,
                    "at": old.get("at", now),
                    "values": old.get(
                        "values", {"source.status": "Actualisation en cours"}
                    ),
                }
            retry = now + interval
            try:
                if module == "github":
                    values = self.github(options, credentials)
                elif module == "youtube":
                    values = self.youtube(options, credentials)
                elif module == "twitch":
                    values = self.twitch(options, credentials, now)
                else:
                    values = (
                        self.crypto(options, credentials, now)
                        if options["asset"] != "Devises"
                        else self.currency(options, now)
                    )
            except HTTPError as e:
                if e.code in (401, 403):
                    message = "Accès refusé ou quota atteint : vérifiez Connexions"
                elif e.code == 429:
                    message = "Limite du fournisseur atteinte, nouvel essai plus tard"
                elif e.code == 404:
                    message = "Chaîne ou projet introuvable"
                else:
                    message = "Service momentanément indisponible"
                if e.code in (403, 429):
                    try:
                        delay = float(e.headers.get("Retry-After", "300"))
                    except (TypeError, ValueError):
                        delay = 300
                    retry = now + min(
                        3600, max(interval, delay if math.isfinite(delay) else 300)
                    )
                if module == "twitch" and e.code == 401:
                    self.twitch_token = None
                values = {"source.status": message}
            except Exception:
                values = {"source.status": "Service momentanément indisponible"}
            with self.lock:
                if credentials == self.secrets.get(module, {}):
                    self.cache[key] = {
                        "module": module,
                        "at": now,
                        "retry": retry,
                        "values": values,
                    }

    def values(self, source, now=None):
        now = time.time() if now is None else now
        with self.lock:
            entry = self.cache.get(self.key(source))
            if not entry:
                return {"source.status": "Première lecture après publication"}
            if now - entry["at"] > self.interval(source) * 2 + 30:
                return {"source.status": "Données périmées : service indisponible"}
            return copy.deepcopy(entry["values"])

    def github(self, options, credentials):
        if not options["repository"]:
            return {"source.status": "Indiquez le dépôt GitHub dans le Designer"}
        headers = {
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2026-03-10",
        }
        if credentials.get("token"):
            headers["Authorization"] = "Bearer " + credentials["token"]
        params = {"per_page": 1}
        if options["branch"]:
            params["branch"] = options["branch"]
        result = self.reader(
            "https://api.github.com/repos/"
            + options["repository"]
            + "/actions/runs?"
            + urlencode(params),
            headers,
        )
        runs = result["workflow_runs"]
        if not runs:
            return {"source.status": "Aucun workflow pour ce dépôt et cette branche"}
        run = runs[0]
        status = run.get("conclusion") or run["status"]
        labels = {
            "success": "Réussi",
            "failure": "Échec",
            "in_progress": "En cours",
            "queued": "En attente",
            "cancelled": "Annulé",
            "timed_out": "Délai dépassé",
            "action_required": "Action requise",
            "waiting": "En attente",
            "skipped": "Ignoré",
            "neutral": "Neutre",
            "completed": "Terminé",
        }
        stamp = str(run.get("updated_at") or "").replace("T", " ").replace("Z", " UTC")
        return {
            "source.build": str(run.get("name") or options["repository"])[:80],
            "source.result": labels.get(status, str(status)),
            "source.branch": str(run.get("head_branch") or "--")[:80],
            "source.status": (options["repository"] + " · " + stamp)[:100],
        }

    def youtube(self, options, credentials):
        if not credentials.get("key"):
            return {"source.status": "Ajoutez votre clé YouTube dans Connexions"}
        if not options["channel"]:
            return {"source.status": "Choisissez la chaîne YouTube dans le Designer"}
        query = {"part": "statistics,contentDetails", "key": credentials["key"]}
        query["forHandle" if options["channel"].startswith("@") else "id"] = options[
            "channel"
        ]
        result = self.reader(
            "https://www.googleapis.com/youtube/v3/channels?" + urlencode(query)
        )
        if not result["items"]:
            return {"source.status": "Chaîne YouTube introuvable"}
        channel = result["items"][0]
        stats = channel.get("statistics", {})
        subs = (
            None
            if stats.get("hiddenSubscriberCount")
            else count(stats.get("subscriberCount"))
        )
        values = {
            "source.subscribers": compact(subs),
            "source.views": compact(stats.get("viewCount")),
            "source.goal": compact(options["goal"]),
            "source.progress": (
                min(100, 100 * subs / options["goal"]) if subs is not None else None
            ),
            "source.latest": "Aucune vidéo publique",
            "source.status": "YouTube · abonnés publics arrondis",
        }
        playlist = (
            channel.get("contentDetails", {}).get("relatedPlaylists", {}).get("uploads")
        )
        if playlist:
            videos = self.reader(
                "https://www.googleapis.com/youtube/v3/playlistItems?"
                + urlencode(
                    {
                        "part": "snippet",
                        "playlistId": playlist,
                        "maxResults": 1,
                        "key": credentials["key"],
                    }
                )
            )
            if videos.get("items"):
                values["source.latest"] = str(videos["items"][0]["snippet"]["title"])[
                    :80
                ]
        return values

    def twitch(self, options, credentials, now):
        if not credentials:
            return {"source.status": "Ajoutez les accès Twitch dans Connexions"}
        if not options["channel"]:
            return {"source.status": "Choisissez la chaîne Twitch dans le Designer"}
        if (
            not self.twitch_token
            or self.twitch_token[0] < now
            or self.twitch_token[2] != credentials["client_id"]
        ):
            result = self.reader(
                "https://id.twitch.tv/oauth2/token",
                form={**credentials, "grant_type": "client_credentials"},
            )
            token = result["access_token"]
            expires = float(result["expires_in"])
            if (
                not isinstance(token, str)
                or not math.isfinite(expires)
                or expires <= 60
            ):
                raise ValueError("Jeton invalide.")
            validated = self.reader(
                "https://id.twitch.tv/oauth2/validate",
                {"Authorization": "OAuth " + token},
            )
            if validated.get("client_id") != credentials["client_id"]:
                raise ValueError("Application Twitch incompatible.")
            self.twitch_token = (
                now + min(3500, expires - 60),
                token,
                credentials["client_id"],
            )
        headers = {
            "Client-Id": credentials["client_id"],
            "Authorization": "Bearer " + self.twitch_token[1],
        }
        users = self.reader(
            "https://api.twitch.tv/helix/users?"
            + urlencode({"login": options["channel"]}),
            headers,
        )
        if not users["data"]:
            return {"source.status": "Chaîne Twitch introuvable"}
        streams = self.reader(
            "https://api.twitch.tv/helix/streams?"
            + urlencode({"user_login": options["channel"]}),
            headers,
        )["data"]
        if not streams:
            return {
                "source.title": "Hors ligne",
                "source.viewers": "--",
                "source.duration": "--",
                "source.status": "Twitch · " + options["channel"],
            }
        stream = streams[0]
        start = datetime.fromisoformat(
            stream["started_at"].replace("Z", "+00:00")
        ).timestamp()
        minutes = max(0, int((now - start) / 60))
        return {
            "source.title": str(stream.get("title") or "En direct")[:80],
            "source.viewers": compact(stream.get("viewer_count")),
            "source.duration": f"{minutes//60} h {minutes%60:02d}",
            "source.status": "En direct · " + options["channel"],
        }

    def crypto(self, options, credentials, now):
        coin = {"Bitcoin": "bitcoin", "Ether": "ethereum", "Solana": "solana"}[
            options["asset"]
        ]
        quote = options["quote"].lower()
        headers = (
            {"x-cg-demo-api-key": credentials["key"]} if credentials.get("key") else {}
        )
        data = self.reader(
            "https://api.coingecko.com/api/v3/simple/price?"
            + urlencode(
                dict(
                    ids=coin,
                    vs_currencies=quote,
                    include_24hr_change="true",
                    include_last_updated_at="true",
                )
            ),
            headers,
        )[coin]
        price, stamp, change = (
            data.get(quote),
            data.get("last_updated_at"),
            data.get(quote + "_24h_change"),
        )
        if (
            type(stamp) not in (int, float)
            or not math.isfinite(stamp)
            or not -60 <= now - stamp <= 600
        ):
            return {"source.status": "Cotation périmée ou sans horodatage"}
        if type(price) not in (int, float) or not math.isfinite(price) or price <= 0:
            return {"source.status": "Cotation indisponible"}
        return {
            "source.rate": f"{price:,.2f}".replace(",", " ") + " " + options["quote"],
            "source.change": (
                f"{change:+.2f} %"
                if type(change) in (int, float) and math.isfinite(change)
                else "--"
            ),
            "source.date": datetime.fromtimestamp(stamp, timezone.utc).strftime(
                "%H:%M UTC"
            ),
            "source.status": options["asset"] + " · variation 24 h · CoinGecko",
        }

    def currency(self, options, now):
        start = (
            (datetime.fromtimestamp(now, timezone.utc) - timedelta(days=14))
            .date()
            .isoformat()
        )
        data = self.reader(
            "https://api.frankfurter.dev/v2/rates?"
            + urlencode(
                {"base": options["base"], "quotes": options["quote"], "from": start}
            )
        )
        rates = []
        for row in data:
            if (
                row.get("base") == options["base"]
                and row.get("quote") == options["quote"]
                and type(row.get("rate")) in (int, float)
                and math.isfinite(row["rate"])
                and row["rate"] > 0
            ):
                day = datetime.strptime(row["date"], "%Y-%m-%d").date()
                if (
                    0
                    <= (datetime.fromtimestamp(now, timezone.utc).date() - day).days
                    <= 14
                ):
                    rates.append((row["date"], row["rate"]))
        rates.sort()
        if not rates:
            return {"source.status": "Aucun taux récent disponible"}
        date, rate = rates[-1]
        change = f"{(rate/rates[-2][1]-1)*100:+.2f} %" if len(rates) > 1 else "--"
        return {
            "source.rate": f"{rate:.4f}",
            "source.change": change,
            "source.date": date,
            "source.status": f'1 {options["base"]} en {options["quote"]} · taux quotidien Frankfurter',
        }
