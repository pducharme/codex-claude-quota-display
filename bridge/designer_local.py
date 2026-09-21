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
