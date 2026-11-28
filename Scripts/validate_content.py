"""Validate all bundled Stage 4 packages without Apple SDKs."""
from collections import Counter
from pathlib import Path
import json
import re
import struct
import unicodedata

root = Path(__file__).resolve().parents[1]
directory = root / "Shared" / "Characters"
spec = (root / "Documentation/PRODUCT_SPEC.md").read_text(encoding="utf-8-sig")
roster = dict(re.findall(r"^\| ([a-z_]+) \| ([^|]+?) \| [^|]+ \| [^|]+ \|$", spec.split("## 7. Стартовые")[1].split("### 7.1")[0], re.M))
counts = dict(morning=10, day=10, compliment=20, support=15, tap=20, calendar=20,
              reminder=20, night=15, **{"return": 8}, rare=12)
texts, unlocks = set(), set()


def load_json(path):
    assert not path.is_symlink() and 0 < path.stat().st_size <= 1_000_000, path
    raw = path.read_text(encoding="utf-8-sig")
    depth = 0
    quoted = escaped = False
    for char in raw:
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
        elif char in "[{":
            depth += 1
            assert depth <= 24, path
        elif char in "]}":
            depth -= 1
            assert depth >= 0, path
    return json.loads(raw)


def image_dimensions(path):
    assert not path.is_symlink() and 0 < path.stat().st_size <= 4_194_304, path
    data = path.read_bytes()
    if path.suffix == ".png":
        assert data[:16] == b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR" and len(data) >= 33, path
        return struct.unpack_from(">II", data, 16)
    assert path.suffix == ".jpg" and data.startswith(b"\xff\xd8"), path
    offset = 2
    # JPEG dimensions live in the start-of-frame segment, after optional metadata.
    while offset + 4 < len(data):
        assert data[offset] == 0xFF, path
        while offset < len(data) and data[offset] == 0xFF:
            offset += 1
        assert offset + 3 <= len(data), path
        marker = data[offset]
        offset += 1
        length = struct.unpack_from(">H", data, offset)[0]
        assert length >= 2 and offset + length <= len(data), path
        if marker in (0xC0, 0xC1, 0xC2):
            assert length >= 8, path
            height, width = struct.unpack_from(">HH", data, offset + 3)
            return width, height
        assert marker not in (0xDA, 0xD9), path
        offset += length
    raise ValueError(f"Missing JPEG frame: {path}")


assert set(roster) == {p.name for p in directory.iterdir()}
for hero, name in roster.items():
    folder = directory / hero
    assert not folder.is_symlink(), folder
    def load(file):
        assert re.fullmatch(r"[a-z_.]+\.json", file)
        return load_json(folder / file)
    manifest = load("manifest.json")
    assert (manifest["id"], manifest["displayName"], manifest["schemaVersion"]) == (hero, name, 1)
    declared_json = {"manifest.json"}
    for key, file in manifest.items():
        if key.endswith("File"):
            load(file)
            declared_json.add(file)
    rights = load("rights.json")
    assert isinstance(rights["publicRelease"], bool), hero
    art = rights["art"]
    images = {path.name for path in folder.iterdir() if path.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp"}}
    assert {path.name for path in folder.iterdir()} == declared_json | images, hero
    assert {item["file"] for item in art} == images and len(art) == len(images), hero
    assert {"chibi.png", "portrait.png", "scene.jpg"} <= images, hero
    for file in images:
        assert re.fullmatch(r"[a-z0-9_-]+\.(png|jpg)", file), file
        width, height = image_dimensions(folder / file)
        assert 0 < width <= 4096 and 0 < height <= 4096 and width * height <= 8_388_608, (hero, file)
    effects = {"satoru_gojo": {"gaze"}, "toji_fushiguro": {"spirit"}, "jinshi": {"fan"},
               "sung_jinwoo": {"portal", "summon"}, "ryomen_sukuna": {"expression"}, "maomao": {"portal"}}
    used_surfaces = set()
    for scene in load("animations.json")["transitions"]:
        assert scene["id"] in effects[hero] and 0 < scene["duration"] <= 2, hero
        assert scene["from"] and scene["to"] and scene["from"] != scene["to"], hero
        assert scene["fallback"] == "staticPose" and scene["motion"] == "full", hero
        assert scene["assets"] and set(scene["assets"]) <= images, hero
        surfaces = set(scene["surfaces"])
        assert surfaces and len(surfaces) == len(scene["surfaces"]) and used_surfaces.isdisjoint(surfaces), hero
        used_surfaces |= surfaces
    assert used_surfaces == {"app", "widgetMedium", "widgetLarge"}, hero
    for item in art:
        assert item["source"].strip() and isinstance(item["publicRelease"], bool), (hero, item["file"])
        if item["publicRelease"]:
            assert isinstance(item.get("evidence"), str) and item["evidence"].strip(), (hero, item["file"])
    if rights["publicRelease"] or any(item["publicRelease"] for item in art):
        assert rights.get("characterIP") == "cleared", hero
        assert isinstance(rights.get("evidence"), str) and rights["evidence"].strip(), hero
    if rights["publicRelease"]:
        assert all(item["publicRelease"] for item in art), hero
    assert re.fullmatch("#[0-9A-F]{6}", load("theme.json")["accent"])
    rows = load("dialogue.ru.json")
    by_id = {r["id"]: r for r in rows}
    assert len(by_id) == len(rows) == 150
    assert Counter(r["category"] for r in rows) == counts
    assert [r["id"] for r in rows[:5]] == ["intro","pause","notice","aside","spark"]
    behaviors = load("behaviors.json")
    actions = {a["id"]: a["label"] for a in behaviors}
    states = {"idle", "greeting", "talking", "resting", "sleeping", "working",
              "training", "exploring", "celebrating", "annoyed", "specialAction"}
    assert len(actions) == len(behaviors), hero
    assert all(a["from"] in states and a["to"] in states for a in behaviors), hero
    reachable = {"idle"}
    while added := {a["to"] for a in behaviors if a["from"] in reachable} - reachable:
        reachable.update(added)
    assert all(a["from"] in reachable for a in behaviors), hero
    assert len({a["to"] for a in behaviors}) > 1, hero
    for row in rows:
        normalized = " ".join(unicodedata.normalize("NFC",row["text"]).casefold().split())
        assert normalized not in texts and re.search("[а-яё]", normalized), (hero, normalized)
        assert len(row["text"]) <= 90 and not any(c in normalized for c in "{}")
        assert actions.get(row["behaviorID"]) == row["action"] and row["origin"] == "original" and row["triggers"]
        if "sarcasm" in row:
            assert hero == "ryomen_sukuna" and row["sarcasm"] in {"mild", "regular", "sharp"}, row["id"]
        assert {"app","widget"} <= set(row["channels"]) <= {"app","widget","notification"}
        assert 1 <= row["weight"] <= 1_000_000
        if "notification" in row["channels"]:
            short = row["shortText"]
            assert short.strip() and len(short) <= 60 and not any(c in short for c in "{}"), row["id"]
        texts.add(normalized)
    eggs = load("easter_eggs.json")
    assert len(eggs) == len({egg["title"] for egg in eggs}) == 5
    for egg in eggs:
        assert egg["id"] not in unlocks and by_id[egg["lineID"]]["category"] == "rare"
        unlocks.add(egg["id"])
    print(f"{hero}: {len(rows)} lines, {len(eggs)} finds")
assert len(texts) == 900 and len(unlocks) == 30
print("PASS: roster, distributions, IDs, links, rights, length and unique normalized texts")
