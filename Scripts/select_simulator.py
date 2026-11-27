"""Select an available iPhone from simctl JSON and record the actual destination."""
import json
from pathlib import Path
import re
import sys


def select(devices):
    candidates = []
    for runtime, entries in devices.items():
        match = re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-([0-9]+(?:-[0-9]+)*)", runtime)
        if not match:
            continue
        version = tuple(map(int, match[1].split("-")))
        if version < (17,):
            continue
        for device in entries:
            if not device.get("isAvailable") or not device.get("deviceTypeIdentifier", "").startswith(
                "com.apple.CoreSimulator.SimDeviceType.iPhone-"
            ):
                continue
            baseline = device["name"] == "iPhone 16" and version[:2] == (18, 5)
            candidates.append(((baseline, version, device["name"] == "iPhone 16", device["name"], device["udid"]),
                               {"runtime": runtime, "name": device["name"], "udid": device["udid"],
                                "state": device["state"]}))
    if not candidates:
        sys.exit("Нет доступного симулятора iPhone с iOS 17 или новее. Проверьте список destinations и runtimes.")
    return max(candidates, key=lambda candidate: candidate[0])[1]


if __name__ == "__main__":
    destination = select(json.loads(Path(sys.argv[1]).read_text())["devices"])
    Path(sys.argv[2]).write_text(json.dumps(destination, indent=2) + "\n")
    print(destination["udid"])
