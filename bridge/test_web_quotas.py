import json
import tempfile
import unittest
from pathlib import Path

from quota_bridge import read_web_quotas


class WebQuotaTests(unittest.TestCase):
    def read(self, provider, value, now=1000):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "quotas.json"
            path.write_text(json.dumps(value))
            return read_web_quotas(provider, path, now)

    def test_filters_identity_and_keeps_zero_and_staleness(self):
        value = {"status": "ok", "updated_at": 1000, "identity": "private-secret", "cookie": "private-secret",
                 "plan": "Pro", "five_hour": {"used_percent": 0, "resets_at": 2000},
                 "weekly": {"used_percent": 3, "resets_at": 3000}}
        result = self.read("gemini", value)
        self.assertEqual(result["five_hour"]["used_percent"], 0)
        self.assertNotIn("private-secret", json.dumps(result))
        self.assertEqual(self.read("gemini", value, 2000)["status"], "stale")
        self.assertNotIn("five_hour", self.read("gemini", {**value, "error_reason": "authentication_required"}))

    def test_grok_preserves_actual_period_and_rejects_invalid_counts(self):
        limit = {"label": "RAPIDE", "remaining": 30, "total": 30, "duration_seconds": 86400,
                 "used_percent": 0, "resets_at": None, "secret": "private-secret"}
        value = {"status": "ok", "updated_at": 1000, "plan": "Gratuit", "limits": [limit]}
        result = self.read("grok", value)
        self.assertEqual(result["limits"][0]["duration_seconds"], 86400)
        self.assertIsNone(result["limits"][0]["resets_at"])
        self.assertNotIn("private-secret", json.dumps(result))
        for remaining in (31, -1, True, "30"):
            self.assertEqual(self.read("grok", {**value, "limits": [{**limit, "remaining": remaining}]}), {"status": "unavailable"})
        self.assertEqual(self.read("grok", {**value, "limits": [limit, limit]}), {"status": "unavailable"})
