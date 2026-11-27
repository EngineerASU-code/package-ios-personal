"""Validate all bundled Stage 4 packages without Apple SDKs."""
from collections import Counter
from pathlib import Path
import json
import re
import unicodedata

root = Path(__file__).resolve().parents[1]
directory = root / "Shared" / "Characters"
spec = (root / "Documentation/PRODUCT_SPEC.md").read_text(encoding="utf-8-sig")
roster = dict(re.findall(r"^\| ([a-z_]+) \| ([^|]+?) \| [^|]+ \| [^|]+ \|$", spec.split("## 7. Стартовые")[1].split("### 7.1")[0], re.M))
counts = dict(morning=10, day=10, compliment=20, support=15, tap=20, calendar=20,
              reminder=20, night=15, **{"return": 8}, rare=12)
texts, unlocks = set(), set()
assert set(roster) == {p.name for p in directory.iterdir()}
for hero, name in roster.items():
    folder = directory / hero
    def load(file):
        assert re.fullmatch(r"[a-z_.]+\.json", file)
        return json.loads((folder / file).read_text(encoding="utf-8-sig"))
    manifest = load("manifest.json")
    assert (manifest["id"], manifest["displayName"], manifest["schemaVersion"]) == (hero, name, 1)
    for key, file in manifest.items():
        if key.endswith("File"):
            load(file)
    rights = load("rights.json")
    assert rights["publicRelease"] is False
    art = rights["art"]
    images = {path.name for path in folder.iterdir() if path.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp"}}
    assert {item["file"] for item in art} == images and len(art) == len(images), hero
    assert all(item["source"].strip() and item["publicRelease"] is False for item in art), hero
    assert re.fullmatch("#[0-9A-F]{6}", load("theme.json")["accent"])
    rows = load("dialogue.ru.json")
    by_id = {r["id"]: r for r in rows}
    assert len(by_id) == len(rows) == 150
    assert Counter(r["category"] for r in rows) == counts
    assert [r["id"] for r in rows[:5]] == ["intro","pause","notice","aside","spark"]
    actions = {a["id"]: a["label"] for a in load("behaviors.json")}
    for row in rows:
        normalized = " ".join(unicodedata.normalize("NFC",row["text"]).casefold().split())
        assert normalized not in texts and re.search("[а-яё]", normalized), (hero, normalized)
        assert len(row["text"]) <= 90 and not any(c in normalized for c in "{}")
        assert actions.get(row["behaviorID"]) == row["action"] and row["origin"] == "original" and row["triggers"]
        assert {"app","widget"} <= set(row["channels"]) <= {"app","widget","notification"}
        assert row["weight"] > 0 and row["behaviorID"] in {"intro","pause","notice","aside","spark"}
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
