"""Check character rights in the resources copied into an iOS product."""
import json
from pathlib import Path
import sys

ROSTER = {"satoru_gojo", "toji_fushiguro", "jinshi", "sung_jinwoo", "ryomen_sukuna", "maomao"}
METADATA = {"manifest.json", "rights.json", "theme.json", "animations.json", "behaviors.json",
            "personality.json", "emotions.json", "easter_eggs.json", "dialogue.ru.json"}


def documented(entry):
    evidence = entry.get("evidence")
    return entry.get("publicRelease") is True and isinstance(evidence, str) and bool(evidence.strip())


def declared_scope(scope):
    fields = ("rightsHolder", "license", "territory", "channel")
    return isinstance(scope, dict) and scope.get("status") == "cleared" and all(
        isinstance(scope.get(field), str) and scope[field].strip() for field in fields
    )


def check(directory):
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError(f"Отсутствуют упакованные персонажи: {directory}")
    packs = sorted(directory.iterdir())
    if {p.name for p in packs} != ROSTER:
        raise ValueError("В поставке должны присутствовать все шесть утверждённых персонажей")
    for pack in packs:
        if pack.is_symlink() or not pack.is_dir():
            raise ValueError(f"Неизвестный ресурс: {pack.name}")
        files = list(pack.iterdir())
        if any(p.is_symlink() or not p.is_file() for p in files):
            raise ValueError(f"{pack.name}: в пакете есть непроверенный вложенный ресурс")
        names = {p.name for p in files}
        if not METADATA.issubset(names) or not {"chibi.png", "portrait.png"}.issubset(names):
            raise ValueError(f"{pack.name}: отсутствуют метаданные или базовые иллюстрации")
        manifest = json.loads((pack / "manifest.json").read_text(encoding="utf-8-sig"))
        if manifest.get("id") != pack.name:
            raise ValueError(f"{pack.name}: идентификатор пакета расходится с реестром")
        rights = json.loads((pack / "rights.json").read_text(encoding="utf-8-sig"))
        scope = rights.get("distribution")
        if rights.get("characterIP") != "cleared" or not documented(rights) or not declared_scope(scope):
            raise ValueError(f"{pack.name}: требуется подтверждение прав на персонажа и пакет")
        art = rights["art"]
        licensed = {row["file"] for row in art if documented(row) and declared_scope(row.get("distribution", scope))}
        if len(licensed) != len(art) or licensed != names - METADATA:
            raise ValueError(f"{pack.name}: состав ресурсов расходится с подтверждёнными правами")


if __name__ == "__main__":
    try:
        check(Path(sys.argv[1]))
    except (ValueError, TypeError, KeyError, OSError) as error:
        sys.exit(f"error: {error}")
