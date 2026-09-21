import copy
import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError
from designer_services import WebServices, validate_options
from designer_integrations import validate_source
from test_designer_integrations import Vault


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "services.json"
        self.vault = Vault()
        self.calls = []
        self.now = datetime(2026, 9, 21, 12, tzinfo=timezone.utc).timestamp()
        self.hidden = False
        self.live = True
        self.failure = None

        def reader(url, headers=None, form=None):
            self.calls.append((url, headers, form))
            if self.failure:
                raise self.failure
            if "/actions/runs?" in url:
                return {
                    "workflow_runs": [
                        dict(
                            name="Deploy",
                            conclusion="success",
                            status="completed",
                            head_branch="main",
                            updated_at="2026-09-21T11:00:00Z",
                        )
                    ]
                }
            if "/channels?" in url:
                return {
                    "items": [
                        dict(
                            statistics=dict(
                                subscriberCount="12300",
                                viewCount="456000",
                                hiddenSubscriberCount=self.hidden,
                            ),
                            contentDetails=dict(
                                relatedPlaylists=dict(uploads="uploads-fixture")
                            ),
                        )
                    ]
                }
            if "/playlistItems?" in url:
                return {"items": [dict(snippet=dict(title="Vidéo récente"))]}
            if "/oauth2/token" in url:
                return dict(access_token="private-twitch-access", expires_in=7200)
            if "/oauth2/validate" in url:
                return dict(client_id="public-client-id", expires_in=7200)
            if "/helix/users?" in url:
                return {"data": [{"id": "123"}]}
            if "/helix/streams?" in url:
                return {
                    "data": (
                        [
                            dict(
                                title="En direct",
                                viewer_count=42,
                                started_at="2026-09-21T10:30:00Z",
                            )
                        ]
                        if self.live
                        else []
                    )
                }
            if "/v2/rates?" in url:
                return [
                    dict(base="CAD", quote="USD", date="2026-09-18", rate=0.72),
                    dict(base="CAD", quote="USD", date="2026-09-21", rate=0.73),
                    dict(base="CAD", quote="USD", date="2026-09-22", rate=0.99),
                ]
            raise AssertionError(url)

        self.services = WebServices(self.path, self.vault, reader)

    def tearDown(self):
        self.temp.cleanup()

    def source(self, module, **options):
        return validate_source(dict(module=module, options=options))

    def test_validation_keychain_atomicity_and_restart(self):
        for module, options in [
            ("github", {"repository": "../secret"}),
            ("youtube", {"channel": "https://evil.example"}),
            ("twitch", {"channel": "a?x=y"}),
            ("currency", {"base": "CAD", "quote": "CAD"}),
            ("youtube", {"goal": float("nan")}),
            ("github", {"repository": "owner/repo", "token": "secret"}),
        ]:
            with self.assertRaises(ValueError):
                validate_options(module, options)
        self.services.configure("youtube", dict(key="private-google-key"))
        before = self.path.read_bytes()
        self.assertNotIn(b"private-google-key", before)
        self.assertNotIn("private-google-key", json.dumps(self.services.info()))
        with patch("designer_services.os.replace", side_effect=OSError):
            with self.assertRaises(OSError):
                self.services.configure("youtube", dict(key="replacement-private-key"))
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(
            WebServices(self.path, self.vault).secrets["youtube"]["key"],
            "private-google-key",
        )

    def test_github_caching_preview_quota_and_freshness(self):
        s = self.source("github", repository="owner/project", branch="feature/a")
        self.services.poll([s], self.now)
        self.assertEqual(self.services.values(s, self.now)["source.result"], "Réussi")
        self.assertIn("branch=feature%2Fa", self.calls[-1][0])
        self.assertNotIn("Authorization", self.calls[-1][1])
        self.services.poll([], self.now + 2)
        self.services.poll([s], self.now + 10)
        self.assertEqual(len(self.calls), 1)
        self.assertNotIn("source.result", self.services.values(s, self.now + 200))
        self.failure = HTTPError("fixed", 429, "quota", {"Retry-After": "600"}, None)
        self.services.poll([s], self.now + 61)
        self.assertIn("Limite", self.services.values(s, self.now + 61)["source.status"])
        self.services.poll([s], self.now + 300)
        self.assertEqual(len(self.calls), 2)
        self.assertNotIn("source.result", self.services.values(s, self.now + 300))

    def test_youtube_hidden_subscribers_goal_latest_and_no_secret_values(self):
        self.services.configure("youtube", dict(key="private-google-key"))
        s = self.source("youtube", channel="@chaine", goal=20000)
        self.services.poll([s], self.now)
        v = self.services.values(s, self.now)
        self.assertEqual(v["source.progress"], 61.5)
        self.assertEqual(v["source.latest"], "Vidéo récente")
        self.assertNotIn("private-google-key", json.dumps(v))
        self.assertIn("forHandle=%40chaine", self.calls[0][0])
        self.hidden = True
        self.services.poll([s], self.now + 301)
        v = self.services.values(s, self.now + 301)
        self.assertEqual(v["source.subscribers"], "--")
        self.assertIsNone(v["source.progress"])

    def test_twitch_token_validation_live_offline_expired_and_unavailable(self):
        self.services.configure(
            "twitch",
            dict(client_id="public-client-id", client_secret="private-client-secret"),
        )
        s = self.source("twitch", channel="test_channel")
        self.services.poll([s], self.now)
        v = self.services.values(s, self.now)
        self.assertEqual(v["source.duration"], "1 h 30")
        self.assertEqual(v["source.viewers"], "42")
        self.assertTrue(any("/oauth2/validate" in url for url, _, _ in self.calls))
        self.assertNotIn("private-client-secret", json.dumps(v))
        self.live = False
        self.services.poll([s], self.now + 31)
        self.assertEqual(
            self.services.values(s, self.now + 31)["source.title"], "Hors ligne"
        )
        self.assertEqual(sum("/oauth2/token" in url for url, _, _ in self.calls), 1)
        self.services.poll([s], self.now + 3600)
        self.assertEqual(sum("/oauth2/token" in url for url, _, _ in self.calls), 2)
        self.failure = OSError("network down")
        self.services.poll([s], self.now + 3631)
        self.assertNotIn("source.title", self.services.values(s, self.now + 3631))

    def test_currency_dates_variation_and_missing_credentials(self):
        s = self.source("currency", base="CAD", quote="USD")
        self.services.poll([s], self.now)
        v = self.services.values(s, self.now)
        self.assertEqual(v["source.rate"], "0.7300")
        self.assertEqual(v["source.change"], "+1.39 %")
        self.assertEqual(v["source.date"], "2026-09-21")
        yt = self.source("youtube", channel="@chaine")
        self.services.poll([yt], self.now)
        self.assertIn(
            "clé YouTube", self.services.values(yt, self.now)["source.status"]
        )

    def test_crypto_selection_secret_header_freshness_and_cache_interval(self):
        s = self.source("currency", asset="Bitcoin", base="CAD", quote="CAD")
        data = dict(
            bitcoin=dict(cad=120000, cad_24h_change=-2.3, last_updated_at=self.now - 20)
        )
        calls = []

        def reader(url, headers=None):
            calls.append((url, headers))
            return copy.deepcopy(data)

        self.services.reader = reader
        self.services.configure("currency", dict(key="private-demo-key"))
        self.services.poll([s], self.now)
        self.assertEqual(
            self.services.values(s, self.now)["source.rate"], "120 000.00 CAD"
        )
        self.assertEqual(self.services.values(s, self.now)["source.change"], "-2.30 %")
        self.assertEqual(calls[0][1], {"x-cg-demo-api-key": "private-demo-key"})
        self.assertNotIn("private-demo-key", calls[0][0])
        self.services.poll([s], self.now + 30)
        self.assertEqual(len(calls), 1)
        data["bitcoin"]["last_updated_at"] = self.now - 1000
        self.services.poll([s], self.now + 61)
        self.assertNotIn("source.rate", self.services.values(s, self.now + 61))
        data["bitcoin"].update(last_updated_at=self.now + 122, cad=float("nan"))
        self.services.poll([s], self.now + 122)
        self.assertNotIn("source.rate", self.services.values(s, self.now + 122))
        legacy = dict(module="currency", options=dict(base="CAD", quote="USD"))
        self.assertEqual(
            self.services.key(legacy),
            self.services.key(self.source("currency", base="CAD", quote="USD")),
        )


if __name__ == "__main__":
    unittest.main()
