"""Local Mac statistics and small built-in pixel drawings; no external service."""

import os
import re
import subprocess
import time


def parse_stats(top, interfaces, previous=None, now=None):
    now = time.monotonic() if now is None else now
    cpu = re.search(r"CPU usage:.*?([\d.]+)% idle", top)
    memory = re.search(
        r"PhysMem: ([\d.]+)([KMGT]) used .*?, ([\d.]+)([KMGT]) unused", top
    )
    if not cpu or not memory:
        raise ValueError("Statistiques macOS indisponibles.")

    def amount(value, unit):
        return float(value) * 1024 ** ("KMGT".index(unit) + 1)

    used, free = amount(*memory.group(1, 2)), amount(*memory.group(3, 4))
    totals = [0, 0]
    for line in interfaces.splitlines()[1:]:
        fields = line.split()
        if (
            len(fields) >= 10
            and re.fullmatch(r"en\d+", fields[0])
            and fields[2].startswith("<Link#")
        ):
            totals[0] += int(fields[-5])
            totals[1] += int(fields[-2])
    network = "--"
    if previous and now > previous[0]:
        down, up = [
            max(0, (value - old) / (now - previous[0]) / 1024)
            for value, old in zip(totals, previous[1])
        ]
        network = f"{round(down)} / {round(up)} Ko/s"
    return {
        "source.cpu": f"{round(100-float(cpu.group(1)))} %",
        "source.memory": f"{used/1024**3:.1f} Go",
        "source.network": network,
        "source.progress": round(100 * used / (used + free)),
        "source.status": "Mac source · réception / envoi",
    }, (now, totals)


class MacStats:
    def __init__(self):
        self.at = 0
        self.attempt = 0
        self.previous = None
        self.data = {}

    def poll(self):
        if time.time() - self.attempt < 10:
            return
        self.attempt = time.time()
        try:
            env = dict(os.environ, LC_ALL="C")
            top = subprocess.run(
                ["/usr/bin/top", "-l", "1", "-n", "0"],
                env=env,
                capture_output=True,
                text=True,
                timeout=4,
                check=True,
            ).stdout
            interfaces = subprocess.run(
                ["/usr/sbin/netstat", "-ibn"],
                env=env,
                capture_output=True,
                text=True,
                timeout=4,
                check=True,
            ).stdout
            self.data, self.previous = parse_stats(top, interfaces, self.previous)
            self.at = time.time()
        except (OSError, ValueError, subprocess.SubprocessError):
            self.data = {"source.status": "Statistiques du Mac indisponibles"}

    def values(self):
        return (
            dict(self.data)
            if time.time() - self.at < 35
            else {"source.status": "Statistiques du Mac indisponibles"}
        )


# A two-colour 16×16 cat, editable in the Designer.
CAT = "".join(
    [
        "0000000000000000",
        "0011000000001100",
        "0011100000011100",
        "0011111111111100",
        "0011111111111100",
        "0110011111100110",
        "0110011111100110",
        "0111111111111110",
        "0111111001111110",
        "0111111001111110",
        "0011111111111100",
        "0001111111111000",
        "0000111111110000",
        "0000111111110000",
        "0001100000011000",
        "0000000000000000",
    ]
)


class AudioOutput:
    """CoreAudio scalar volume; unsupported outputs remain explicitly read-only."""

    def __init__(self):
        import ctypes as c

        self.c = c

        class Address(c.Structure):
            _fields_ = [
                ("selector", c.c_uint32),
                ("scope", c.c_uint32),
                ("element", c.c_uint32),
            ]

        self.Address = Address
        self.core = c.CDLL("/System/Library/Frameworks/CoreAudio.framework/CoreAudio")
        self.core.AudioObjectGetPropertyData.argtypes = [
            c.c_uint32,
            c.POINTER(Address),
            c.c_uint32,
            c.c_void_p,
            c.POINTER(c.c_uint32),
            c.c_void_p,
        ]
        self.core.AudioObjectGetPropertyData.restype = c.c_int32
        self.core.AudioObjectSetPropertyData.argtypes = [
            c.c_uint32,
            c.POINTER(Address),
            c.c_uint32,
            c.c_void_p,
            c.c_uint32,
            c.c_void_p,
        ]
        self.core.AudioObjectSetPropertyData.restype = c.c_int32
        self.core.AudioObjectHasProperty.argtypes = [c.c_uint32, c.POINTER(Address)]
        self.core.AudioObjectHasProperty.restype = c.c_ubyte
        self.core.AudioObjectIsPropertySettable.argtypes = [
            c.c_uint32,
            c.POINTER(Address),
            c.POINTER(c.c_ubyte),
        ]
        self.core.AudioObjectIsPropertySettable.restype = c.c_int32

    @staticmethod
    def fourcc(text):
        return int.from_bytes(text.encode("ascii"), "big")

    def address(self, selector, element=0, scope="outp"):
        return self.Address(self.fourcc(selector), self.fourcc(scope), element)

    def get(self, device, address, kind):
        value = kind()
        size = self.c.c_uint32(self.c.sizeof(value))
        if (
            self.core.AudioObjectGetPropertyData(
                device,
                self.c.byref(address),
                0,
                None,
                self.c.byref(size),
                self.c.byref(value),
            )
            != 0
        ):
            raise OSError("Audio indisponible.")
        return value.value

    def output(self):
        return self.get(1, self.address("dOut", scope="glob"), self.c.c_uint32)

    def properties(self, device, selector):
        main = self.address(selector)
        if self.core.AudioObjectHasProperty(device, self.c.byref(main)):
            return [main]
        return [
            a
            for a in (self.address(selector, 1), self.address(selector, 2))
            if self.core.AudioObjectHasProperty(device, self.c.byref(a))
        ]

    def read(self):
        device = self.output()
        volumes = [
            self.get(device, a, self.c.c_float) for a in self.properties(device, "volm")
        ]
        mute = [
            self.get(device, a, self.c.c_uint32)
            for a in self.properties(device, "mute")
        ]
        return dict(
            volume=sum(volumes) / len(volumes) if volumes else None,
            muted=all(mute) if mute else None,
        )

    def change(self, action):
        if action not in ("mute", "volume_up", "volume_down"):
            raise ValueError("Commande audio inconnue.")
        device = self.output()
        selector = "mute" if action == "mute" else "volm"
        addresses = self.properties(device, selector)
        if not addresses:
            raise ValueError("Cette sortie audio ne permet pas cette commande.")
        kind = self.c.c_uint32 if selector == "mute" else self.c.c_float
        current = [self.get(device, a, kind) for a in addresses]
        for address in addresses:
            writable = self.c.c_ubyte()
            if (
                self.core.AudioObjectIsPropertySettable(
                    device, self.c.byref(address), self.c.byref(writable)
                )
                != 0
                or not writable.value
            ):
                raise ValueError("Sortie audio à volume fixe.")
        for address, old in zip(addresses, current):
            value = kind(
                not all(current)
                if selector == "mute"
                else min(1, max(0, old + (0.05 if action == "volume_up" else -0.05)))
            )
            if (
                self.core.AudioObjectSetPropertyData(
                    device,
                    self.c.byref(address),
                    0,
                    None,
                    self.c.sizeof(value),
                    self.c.byref(value),
                )
                != 0
            ):
                raise OSError("Commande audio non confirmée.")


class MacControls:
    def __init__(self, audio=None, runner=None):
        self.audio = audio
        self.runner = runner or subprocess.run

    def output(self):
        if self.audio is None:
            self.audio = AudioOutput()
        return self.audio

    def shortcuts(self):
        try:
            result = self.runner(
                ["/usr/bin/shortcuts", "list"],
                capture_output=True,
                text=True,
                timeout=8,
                check=True,
            )
            return sorted(
                {
                    name.strip()
                    for name in result.stdout.splitlines()
                    if 0 < len(name.strip()) <= 120 and not name.strip().startswith("-")
                }
            )
        except (OSError, subprocess.SubprocessError):
            return []

    def values(self, options):
        try:
            state = self.output().read()
            return {
                "source.volume": (
                    f'{round(state["volume"]*100)} %'
                    if state["volume"] is not None
                    else "Fixe"
                ),
                "source.muted": (
                    "Oui"
                    if state["muted"]
                    else "Non" if state["muted"] is not None else "--"
                ),
                "source.shortcut": options.get("shortcut") or "À choisir",
                "source.status": "Commandes du Mac source",
            }
        except (OSError, ValueError):
            return {"source.status": "Sortie audio du Mac indisponible"}

    def action(self, action, options):
        if action in ("volume_up", "volume_down", "mute"):
            self.output().change(action)
        elif action in ("shortcut", "play_pause"):
            name = options.get(
                "shortcut" if action == "shortcut" else "playback_shortcut", ""
            )
            if not name or name not in self.shortcuts():
                raise ValueError("Choisissez un raccourci existant sur le Mac source.")
            try:
                self.runner(
                    ["/usr/bin/shortcuts", "run", name],
                    capture_output=True,
                    text=True,
                    timeout=15,
                    check=True,
                )
            except (OSError, subprocess.SubprocessError):
                raise ValueError(
                    "Raccourci non confirmé. Vérifiez ses autorisations sur le Mac source."
                ) from None
        else:
            raise ValueError("Commande Mac inconnue.")
        return {"ok": True}
