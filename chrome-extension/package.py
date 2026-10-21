"""Build the Chrome Web Store ZIP with manifest.json at its root."""
import hashlib
import json
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

root = Path(__file__).resolve().parent
manifest = json.loads((root / "manifest.json").read_text())
files = [
    "manifest.json", "api.js", "background.js", "dashboard.js", "dashboard.css",
    "popup.html", "popup.js", "popup.css", "NOTICE.txt", "PRIVACY.md",
    *sorted(set(manifest["icons"].values())),
]
for name in files:
    if not (root / name).is_file():
        raise FileNotFoundError(root / name)
destination = root.parent / "dist" / f"Quota-Display-Chrome-{manifest['version']}.zip"
destination.parent.mkdir(exist_ok=True)
with ZipFile(destination, "w", ZIP_DEFLATED) as archive:
    for name in files:
        archive.write(root / name, name)
with ZipFile(destination) as archive:
    assert archive.testzip() is None
    assert set(archive.namelist()) == set(files)
    assert json.loads(archive.read("manifest.json")) == manifest
destination.with_suffix(".zip.sha256").write_text(
    f"{hashlib.sha256(destination.read_bytes()).hexdigest()}  {destination.name}\n"
)
print(destination)
