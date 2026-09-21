import copy
import json
import tempfile
import threading
import time
import unittest
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch
from designer import Designer, Flights, default_config, templates, validate
from quota_bridge import QuotaState, QuotaHandler, WeatherCache


class DesignerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.state = QuotaState()
        self.designer = Designer(
            self.root / "designer.json", self.state, WeatherCache()
        )

    def tearDown(self):
        self.temp.cleanup()

    def config(self):
        c = default_config()
        c["pages"] = templates()[:6]
        c["sky"] = dict(enabled=True, lat=45, lon=-72, radius=10)
        c["auto_sky"] = True
        return c

    def test_roundtrip_targeting_ack_rollback_and_atomic_failure(self):
        a = "a0f262e09880"
        b = "68ee8f4818ec"
        self.designer.frame(a)
        self.designer.frame(b)
        self.designer.publish(dict(config=self.config(), targets=[a], base_revision=0))
        self.assertEqual(self.designer.frame(a)["revision"], 1)
        self.assertEqual(self.designer.frame(b)["revision"], 0)
        self.assertEqual(self.designer.info()["devices"][0]["applied"], 0)
        self.designer.frame(a, 1)
        self.assertEqual(self.designer.info()["devices"][0]["applied"], 1)
        before = self.designer.path.read_bytes()
        with patch("designer.os.replace", side_effect=OSError):
            with self.assertRaises(OSError):
                self.designer.publish(
                    dict(config=self.config(), targets=[b], base_revision=1)
                )
        self.assertEqual(self.designer.path.read_bytes(), before)
        self.assertEqual(self.designer.data["revision"], 1)
        with self.assertRaises(ValueError):
            self.designer.publish(
                dict(config=self.config(), targets=[a], base_revision=0)
            )
        self.designer.rollback(1)
        frame = self.designer.frame(a)
        self.assertEqual(frame["revision"], 2)
        self.assertEqual(frame["pages"][0]["kind"], "native-quotas")
        reloaded = Designer(self.designer.path, self.state, WeatherCache())
        self.assertEqual(reloaded.frame(a)["revision"], 2)

    def test_validation_and_bound_values(self):
        c = self.config()
        for path, bad in [("font", "unknown"), ("background", "#zzzzzz")]:
            d = copy.deepcopy(c)
            d["pages"][0][path] = bad
            with self.assertRaises(ValueError):
                validate(d)
        c["pages"][0]["blocks"][0]["w"] = 641
        with self.assertRaises(ValueError):
            validate(c)
        c = self.config()
        c["sky"]["lat"] = float("nan")
        with self.assertRaises(ValueError):
            validate(c)
        self.state.providers["codex"]["status"] = "ok"
        self.state.providers["codex"]["weekly"] = {
            "used_percent": 30,
            "resets_at": None,
        }
        self.designer.weather_values["Sherbrooke"] = {
            "status": "ok",
            "temperature_c": 21.2,
            "condition": "Soleil",
        }
        values = self.designer.bindings(default_config(), "a0f262e09880")
        self.assertEqual(values["codex.week"], 70)
        self.assertEqual(values["weather.temperature"], "21 °C")
        self.state.providers["codex"]["status"] = "stale"
        self.designer.weather_values["Sherbrooke"]["status"] = "stale"
        values = self.designer.bindings(default_config(), "a0f262e09880")
        self.assertIsNone(values["codex.week"])
        self.assertEqual(values["weather.temperature"], "--")
        with self.assertRaises(ValueError):
            self.designer.action("a0f262e09880", "focus.toggle")
        self.designer.publish(
            dict(config=self.config(), targets=["a0f262e09880"], base_revision=0)
        )
        self.designer.action("a0f262e09880", "focus.toggle")
        self.assertIsNotNone(self.designer.focus["a0f262e09880"]["until"])
        self.designer.action("a0f262e09880", "focus.toggle")
        self.assertIsNone(self.designer.focus["a0f262e09880"]["until"])

    def test_flight_freshness_radius_unknown_route_and_failures(self):
        stamp = time.time()
        sky = dict(enabled=True, lat=45, lon=-72, radius=10)
        ac = {
            "hex": "abcdef",
            "lat": 45.01,
            "lon": -72,
            "alt_baro": 30000,
            "seen_pos": 1,
            "gs": 450,
            "flight": "ACA123 ",
            "t": "A330",
        }

        def reader(url):
            if "adsbdb" in url:
                return {"response": {"aircraft": {"type": "Airbus A330"}}}
            return {
                "now": stamp,
                "ac": [
                    ac,
                    {**ac, "hex": "000001", "alt_baro": "ground"},
                    {**ac, "hex": "000002", "seen_pos": 80},
                    {**ac, "hex": "000003", "lat": 47},
                ],
            }

        flights = Flights(reader)
        result = flights.poll(sky, stamp)
        self.assertEqual(len(result["flights"]), 1)
        f = result["flights"][0]
        self.assertEqual(f["speed"], 833)
        self.assertEqual(f["altitude"], 9144)
        self.assertTrue(f["inside"])
        self.assertNotIn("progress", f)
        self.assertEqual(flights.snapshot(sky, stamp + 60)["status"], "unavailable")
        flights.reader = lambda url: (_ for _ in ()).throw(OSError())
        self.assertEqual(flights.poll(sky, stamp + 65)["status"], "unavailable")

    def test_focus_cycles_pause_long_break_and_reset(self):
        d, device = self.designer, "000000000001"
        config = default_config()
        config["pages"] = [next(p for p in templates() if p["name"] == "Focus")]
        d.publish(dict(config=config, targets=[device], base_revision=0))
        with patch("designer.time.monotonic", return_value=100):
            d.action(device, "focus.toggle")
        with patch("designer.time.monotonic", return_value=150):
            d.action(device, "focus.toggle")
        self.assertEqual(d.focus[device]["remaining"], 1450)
        self.assertIsNone(d.focus[device]["until"])
        with patch("designer.time.monotonic", return_value=200):
            d.action(device, "focus.toggle")
        with patch("designer.time.monotonic", return_value=1650):
            values = d.bindings(config, device)
        self.assertEqual(values["focus.remaining"], "05:00")
        self.assertEqual(d.focus[device]["completed"], 1)
        self.assertIsNone(d.focus[device]["until"])  # Next phase waits for touch.
        with patch("designer.time.monotonic", return_value=1700):
            d.action(device, "focus.toggle")
        self.assertEqual(d.focus_state(device, 2000)["phase"], "Focus")
        d.focus[device].update(completed=3, until=2100)
        focus = d.focus_state(device, 2100)
        self.assertEqual((focus["phase"], focus["remaining"]), ("Pause longue", 900))
        d.action(device, "focus.reset")
        self.assertEqual(d.focus_state(device, 3000)["completed"], 0)

    def test_corrupt_file_does_not_break_quota_bridge(self):
        self.designer.path.write_text("{bad")
        d = Designer(self.designer.path, self.state, WeatherCache())
        self.assertTrue(d.load_error)
        self.assertEqual(d.data["revision"], 0)
        self.assertEqual(d.path.read_text(), "{bad")

    def test_http_auth_csrf_token_rotation_and_limits(self):
        token = "test-token-local-only-12345"
        token_path = self.root / "token"
        token_path.write_text(token)

        class Handler(QuotaHandler):
            pass

        Handler.designer = self.designer
        Handler.token_path = token_path
        Handler.state = self.state
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        connection = HTTPConnection(*server.server_address)

        def request(method, path, body=None, headers=None):
            connection.request(method, path, body, headers or {})
            r = connection.getresponse()
            data = r.read()
            return r.status, dict(r.getheaders()), data

        try:
            self.assertEqual(request("GET", "/designer/api/state")[0], 401)
            status, headers, html = request(
                "GET", "/designer/", headers={"Authorization": "Bearer " + token}
            )
            self.assertEqual(status, 200)
            cookie = headers["Set-Cookie"].split(";")[0]
            self.assertIn("HttpOnly", headers["Set-Cookie"])
            self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
            import re

            csrf = (
                re.search(b'name="designer-csrf" content="([^"]+)', html)
                .group(1)
                .decode()
            )
            self.assertEqual(
                request("GET", "/designer/api/state", headers={"Cookie": cookie})[0],
                200,
            )
            payload = json.dumps(
                dict(config=self.config(), targets=["a0f262e09880"], base_revision=0)
            )
            h = {"Cookie": cookie, "Content-Type": "application/json"}
            for route in ("service-connect", "source-preview", "mac-shortcuts"):
                self.assertEqual(
                    request("POST", "/designer/api/" + route, "{}", h)[0], 403
                )
            self.assertEqual(
                request("POST", "/designer/api/publish", payload, h)[0], 403
            )
            h["X-Designer-CSRF"] = csrf
            self.assertEqual(
                request("POST", "/designer/api/publish", payload, h)[0], 200
            )
            self.assertEqual(
                request(
                    "GET",
                    "/v1/designer/frame?device=a0f262e09880",
                    headers={"Cookie": cookie},
                )[0],
                401,
            )
            self.assertEqual(
                request(
                    "GET",
                    "/v1/designer/frame?device=a0f262e09880",
                    headers={"Authorization": "Bearer " + token},
                )[0],
                200,
            )
            token_path.write_text("replacement-token-local-1234")
            self.assertEqual(
                request("GET", "/designer/api/state", headers={"Cookie": cookie})[0],
                401,
            )
        finally:
            connection.close()
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
