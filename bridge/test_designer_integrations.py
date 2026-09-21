import copy
import json
import tempfile
import time
import unittest
from pathlib import Path
from designer import Designer, default_config, templates, validate
from designer_integrations import (
    Connections,
    MODULES,
    base_url,
    validate_source,
    request_json,
    request_artwork,
)
from quota_bridge import QuotaState, WeatherCache


class Vault:
    def __init__(self):
        self.values = {}

    def read(self, account):
        return self.values.get(account, "")

    def write(self, account, value):
        self.values[account] = value


class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name)
        self.calls = []
        self.entities = [
            dict(
                entity_id="media_player.bureau",
                state="playing",
                attributes=dict(
                    friendly_name="Bureau",
                    media_title="Été à Montréal",
                    media_artist="Artiste",
                    volume_level=0.4,
                ),
            ),
            dict(
                entity_id="sensor.progress",
                state="72",
                attributes=dict(friendly_name="Imprimante", unit_of_measurement="%"),
            ),
            dict(
                entity_id="scene.soir",
                state="2026-09-21",
                attributes=dict(friendly_name="Soirée"),
            ),
        ]

        def reader(url, token, data=None):
            self.calls.append((url, data))
            return copy.deepcopy(self.entities) if data is None else []

        self.vault = Vault()
        self.connections = Connections(
            self.path / "connections.json", self.vault, reader
        )
        self.connections.connect(
            dict(url="http://homeassistant.local:8123", token="private-test-token")
        )

    def tearDown(self):
        self.temp.cleanup()

    def test_catalogue_roundtrip_boundaries_and_no_secrets(self):
        self.assertEqual(
            len(templates()), 28
        )  # 26 requested uses, plus clock and blank.
        pages = [p for p in templates() if p.get("source")]
        self.assertEqual({p["source"]["module"] for p in pages}, set(MODULES))
        for page in pages:
            c = default_config()
            c["pages"] = [page]
            self.assertEqual(
                validate(c)["pages"][0]["source"]["module"], page["source"]["module"]
            )
        bad = default_config()
        bad["pages"] = [next(p for p in pages if p["source"]["module"] == "sonos")]
        bad["pages"][0]["blocks"][-1]["action"] = "source.scene_primary"
        with self.assertRaises(ValueError):
            validate(bad)
        for bad in [
            "file:///etc/passwd",
            "http://user:secret@host",
            "http://host/path",
            "http://169.254.169.254",
            "https://host/?a=b",
        ]:
            with self.assertRaises(ValueError):
                base_url(bad)
        with self.assertRaises(ValueError):
            validate_source(dict(module="sonos", entities=dict(player="scene.soir")))
        with self.assertRaises(ValueError):
            validate_source(
                dict(
                    module="sonos", entities=dict(player="media_player.x/../../config")
                )
            )
        self.assertNotIn("private-test-token", self.connections.path.read_text())
        self.assertNotIn("private-test-token", json.dumps(self.connections.info()))
        self.assertNotIn("media_title", json.dumps(self.connections.info()))

    def test_page_routing_actions_staleness_and_restart(self):
        d = Designer(self.path / "designer.json", QuotaState(), WeatherCache())
        d.connections = self.connections
        page = next(
            p for p in templates() if p.get("source", {}).get("module") == "sonos"
        )
        page["source"]["entities"]["player"] = "media_player.bureau"
        c = default_config()
        c["pages"] = [page]
        d.publish(dict(config=c, targets=["000000000001"], base_revision=0))
        frame = d.frame("000000000001")
        self.assertIn("Été à Montréal", json.dumps(frame, ensure_ascii=False))
        self.assertNotIn("media_player.bureau", json.dumps(frame))
        self.assertNotIn("private-test-token", json.dumps(frame))
        d.action("000000000001", "source.play_pause", page["id"])
        self.assertEqual(
            self.calls[-1],
            (
                "http://homeassistant.local:8123/api/services/media_player/media_play_pause",
                {"entity_id": "media_player.bureau"},
            ),
        )
        before = len(self.calls)
        for device, action, pid in [
            ("000000000002", "source.play_pause", page["id"]),
            ("000000000001", "source.scene_primary", page["id"]),
            ("000000000001", "source.play_pause", "wrong"),
        ]:
            with self.assertRaises(ValueError):
                d.action(device, action, pid)
        self.assertEqual(len(self.calls), before)
        self.connections.at = time.time() - 40
        frame = d.frame("000000000001")
        self.assertNotIn("Été à Montréal", json.dumps(frame, ensure_ascii=False))
        with self.assertRaises(ValueError):
            d.action("000000000001", "source.play_pause", page["id"])
        reloaded = Connections(
            self.connections.path, self.vault, self.connections.reader
        )
        self.assertEqual(reloaded.token, "private-test-token")
        self.assertEqual(reloaded.info()["home_assistant"]["status"], "unavailable")
        reloaded.poll()
        self.assertEqual(reloaded.info()["home_assistant"]["status"], "ok")

    def test_music_choices_are_current_and_actions_stay_bound_to_player(self):
        c = self.connections
        c.entities["media_player.bureau"]["attributes"]["source_list"] = [
            "Bureau",
            "Salon",
        ]
        spotify = dict(
            module="spotify",
            entities=dict(player="media_player.bureau"),
            options=dict(output="Salon"),
        )
        self.assertEqual(
            c.choices(spotify)["output"][1], dict(value="Salon", label="Salon")
        )
        c.action(spotify, "source.select_output", "device", "page")
        self.assertEqual(
            self.calls[-1][1], dict(entity_id="media_player.bureau", source="Salon")
        )
        self.assertTrue(self.calls[-1][0].endswith("/media_player/select_source"))
        c.entities["sensor.favorites"] = dict(
            state="2",
            attributes=dict(items={"FV:2/31": "Jazz", "http://untrusted/": "Invalid"}),
        )
        sonos = dict(
            module="sonos",
            entities=dict(player="media_player.bureau", favorites="sensor.favorites"),
            options=dict(favorite="FV:2/31"),
        )
        self.assertEqual(
            c.choices(sonos)["favorite"], [dict(value="FV:2/31", label="Jazz")]
        )
        c.action(sonos, "source.favorite", "device", "page")
        self.assertEqual(
            self.calls[-1][1],
            dict(
                entity_id="media_player.bureau",
                media_content_type="favorite_item_id",
                media_content_id="FV:2/31",
            ),
        )
        count = len(self.calls)
        c.entities["sensor.favorites"]["attributes"]["items"] = {}
        with self.assertRaises(ValueError):
            c.action(sonos, "source.favorite", "device", "page")
        c.at -= 40
        self.assertEqual(c.choices(spotify), {})
        with self.assertRaises(ValueError):
            c.action(spotify, "source.select_output", "device", "page")
        self.assertEqual(len(self.calls), count)

    def test_artwork_is_cached_bound_to_current_track_and_never_exposes_urls(self):
        from unittest.mock import patch

        c = self.connections
        source = dict(module="spotify", entities=dict(player="media_player.bureau"))
        attrs = c.entities["media_player.bureau"]["attributes"]
        attrs.update(
            entity_picture="https://example.test/cover?token=private-image-token",
            media_content_id="track1",
        )
        pixels = "f800" * 1024

        def run_thread(**kwargs):
            class Thread:
                def start(self):
                    kwargs["target"]()

            return Thread()

        with patch(
            "designer_integrations.threading.Thread", side_effect=run_thread
        ), patch(
            "designer_integrations.request_artwork", return_value=pixels
        ) as reader:
            c.poll_artwork([source])
            self.assertEqual(
                reader.call_args.args[0],
                "http://homeassistant.local:8123/api/media_player_proxy/media_player.bureau",
            )
            self.assertEqual(c.artwork_value(source), pixels)
            c.poll_artwork([source])
            self.assertEqual(reader.call_count, 1)
            attrs["media_content_id"] = "track2"
            self.assertEqual(c.artwork_value(source), "")
            c.poll_artwork([source])
            self.assertEqual(reader.call_count, 2)
            d = Designer(self.path / "art-pages.json", QuotaState(), WeatherCache())
            d.connections = c
            config = default_config()
            config["pages"] = [
                next(
                    p
                    for p in templates()
                    if p.get("source", {}).get("module") == "spotify"
                )
            ]
            config["pages"][0]["source"] = source
            d.publish(dict(config=config, targets=["000000000001"], base_revision=0))
            frame = d.frame("000000000001")
            self.assertEqual(frame["pages"][0]["blocks"][0]["pixels"], pixels)
            self.assertNotIn("private-image-token", json.dumps(frame))
            self.assertNotIn("example.test", json.dumps(frame))
            self.assertNotIn("media_player.bureau", json.dumps(frame))
            compact = copy.deepcopy(config["pages"][0])
            compact["blocks"] = compact["blocks"][:5] + compact["blocks"][-1:]
            many = default_config()
            many["pages"] = [
                dict(copy.deepcopy(compact), id=f"music-{i}") for i in range(8)
            ]
            d.publish(dict(config=many, targets=["000000000001"], base_revision=1))
            size = len(json.dumps(d.frame("000000000001")).encode())
            self.assertGreater(size, 32768)
            self.assertLess(size, 65536)
            config["pages"][0]["blocks"].append(
                copy.deepcopy(config["pages"][0]["blocks"][0])
            )
            with self.assertRaises(ValueError):
                validate(config)
            c.at -= 40
            self.assertEqual(c.artwork_value(source), "")
            c.at = time.time()
            attrs["media_content_id"] = "track3"
            reader.side_effect = OSError()
            c.poll_artwork([source])
            self.assertEqual(c.artwork_value(source), "")
            c.poll_artwork([source])
            self.assertEqual(
                reader.call_count, 3
            )  # Missing image retries later, not every tick.

    def test_sports_freshness_ev_reminder_and_acknowledgement_reset(self):
        from datetime import datetime, timezone

        c = self.connections
        stamp = datetime.now(timezone.utc).isoformat()
        game = dict(
            state="IN",
            attributes=dict(
                team_abbr="MTL",
                opponent_abbr="TOR",
                team_score=2,
                opponent_score=1,
                quarter=3,
                clock="5:10",
                last_update=stamp,
            ),
        )
        c.entities["sensor.game"] = game
        source = dict(module="sports", entities=dict(game="sensor.game"))
        self.assertEqual(c.values(source, "a", "p")["source.score"], "2 - 1")
        game["attributes"]["last_update"] = "2020-01-01T00:00:00Z"
        self.assertNotIn("source.score", c.values(source, "a", "p"))
        game["state"] = "POST"
        self.assertEqual(c.values(source, "a", "p")["source.status"], "Terminé")
        game["state"] = "PRE"
        self.assertEqual(c.values(source, "a", "p")["source.score"], "--")
        c.entities["binary_sensor.plug"] = dict(state="off", attributes={})
        c.entities["sensor.progress"]["state"] = "20"
        ev = dict(
            module="ev",
            entities=dict(primary="sensor.progress", third="binary_sensor.plug"),
        )
        self.assertEqual(
            c.values(ev, "a", "p")["source.status"], "Pensez à brancher le véhicule"
        )
        ev["options"] = dict(reminder_below=20)
        self.assertEqual(c.values(ev, "a", "p")["source.status"], "À jour")
        monitor = dict(
            module="monitor",
            entities=dict(primary="binary_sensor.plug", secondary="sensor.progress"),
        )
        c.action(monitor, "source.acknowledge", "a", "p")
        self.assertEqual(
            c.values(monitor, "a", "p")["source.status"], "Rappel acquitté"
        )
        self.assertNotEqual(
            c.values(monitor, "b", "p")["source.status"], "Rappel acquitté"
        )
        c.entities["sensor.progress"]["state"] = "21"
        self.assertNotEqual(
            c.values(monitor, "a", "p")["source.status"], "Rappel acquitté"
        )
        c.entities["sensor.progress"]["state"] = "unavailable"
        with self.assertRaises(ValueError):
            c.action(monitor, "source.acknowledge", "a", "p")

    def test_http_transport_and_redirect_does_not_forward_token(self):
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        import threading
        from urllib.error import HTTPError

        seen = []
        entities = self.entities

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                seen.append((self.path, self.headers.get("Authorization")))
                if self.path == "/redirect":
                    self.send_response(302)
                    self.send_header("Location", "/leak")
                    self.end_headers()
                    return
                body = json.dumps(entities).encode()
                if self.path == "/image":
                    body = b"synthetic-image"
                self.send_response(200)
                self.send_header(
                    "Content-Type",
                    "image/png" if self.path == "/image" else "application/json",
                )
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        root = "http://127.0.0.1:" + str(server.server_port)
        try:
            result = request_json(root + "/api/states", "isolated-transport-test")
            self.assertEqual(result, entities)
            with self.assertRaises(ValueError):
                request_json(root + "/redirect", "isolated-transport-test")
            self.assertEqual([path for path, _ in seen], ["/api/states", "/redirect"])
            self.assertEqual(seen[0][1], "Bearer isolated-transport-test")
            from unittest.mock import patch

            with patch(
                "designer_integrations.artwork_pixels", return_value="f800" * 1024
            ) as decode:
                self.assertEqual(
                    request_artwork(root + "/image", "isolated-transport-test"),
                    "f800" * 1024,
                )
                decode.assert_called_once_with(b"synthetic-image")
                with self.assertRaises(ValueError):
                    request_artwork(root + "/api/states", "isolated-transport-test")
                with self.assertRaises(ValueError):
                    request_artwork(root + "/redirect", "isolated-transport-test")
                self.assertNotIn("/leak", [p for p, _ in seen])
        finally:
            server.shutdown()
            server.server_close()

    def test_failed_connection_preserves_previous_and_unavailable_states(self):
        previous = self.connections.path.read_bytes()

        def fail(*args):
            raise OSError("network down")

        reader = self.connections.reader
        self.connections.reader = fail
        with self.assertRaises(OSError):
            self.connections.connect(
                dict(url="http://another.local", token="another-private-token")
            )
        self.assertEqual(self.connections.path.read_bytes(), previous)
        self.assertEqual(self.connections.url, "http://homeassistant.local:8123")
        self.connections.attempt = 0
        self.connections.poll()
        self.assertEqual(
            self.connections.info()["home_assistant"]["status"], "unavailable"
        )
        self.connections.reader = reader
        self.connections.attempt = 0
        self.entities[0]["state"] = "unavailable"
        self.connections.poll()
        values = self.connections.values(
            dict(module="sonos", entities=dict(player="media_player.bureau")),
            "000000000001",
            "page",
        )
        self.assertEqual(values["source.title"], "Indisponible")
        with self.assertRaises(ValueError):
            self.connections.action(
                dict(module="sonos", entities=dict(player="media_player.bureau")),
                "source.play_pause",
                "000000000001",
                "page",
            )


if __name__ == "__main__":
    unittest.main()
