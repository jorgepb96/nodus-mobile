#!/usr/bin/env python3
"""Give the bundled example vault a Dictionary.

The example vault is a published snapshot built by `make-demo-snapshot.mjs` from a corpus that
has no authored Dictionary, so the Dictionary section of the example vault opened on an error
("the published copy does not include dictionary_entries"). That is the vault App Review uses.

This adds the four consultation tables the shared Dictionary reader requires, one entry per
theme, written only from the ideas, works and authors already in the snapshot (all public
domain). Nothing is invented beyond joining what is there. It is idempotent: the tables are
replaced on every run, and the revision is derived from the previous revision and the added
rows, so a device that already imported the example vault imports it again.

Run after `make-demo-snapshot.mjs` regenerates the files:

    python3 ios/scripts/add-demo-dictionary.py
"""
import gzip
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "Nodus" / "Resources"
STAMP = "2026-01-15T09:00:00.000Z"
TEXT = {
    "es": {
        "intro": "Concepto del vault de ejemplo que reúne {n} ideas de {works}.",
        "and": " y ",
    },
    "en": {
        "intro": "A concept from the example vault that brings together {n} ideas from {works}.",
        "and": " and ",
    },
}


def joined(items, conjunction):
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + conjunction + items[-1]


def build(document, language):
    t = document["tables"]
    ideas = {row["global_id"]: row for row in t["ideas"]}
    works = {row["nodus_id"]: row for row in t["works"]}
    authors = {row["author_id"]: row for row in t["authors"]}
    authors_of = {}
    for link in t["work_authors"]:
        authors_of.setdefault(link["nodus_id"], []).append(authors[link["author_id"]])
    words = TEXT[language]
    entries, evidence, versions, relations = [], [], [], []
    ideas_by_theme = {}
    for theme in t["themes"]:
        links = [link for link in t["idea_theme_links"] if link["theme_id"] == theme["theme_id"] and link["global_id"] in ideas]
        if not links:
            continue
        entry_id = "demo-d-" + theme["theme_id"].removeprefix("demo-t-")
        version_id = entry_id + "-v1"
        ideas_by_theme[entry_id] = {link["global_id"] for link in links}
        titles = []
        paragraphs = []
        refs = []
        for link in sorted(links, key=lambda row: -float(row["confidence"] or 0)):
            idea, work = ideas[link["global_id"]], works.get(link["nodus_id"])
            people = authors_of.get(link["nodus_id"], [])
            byline = joined([person["name"] for person in people], words["and"]) if people else ""
            title = work["title"] if work else ""
            if title and f"*{title}*" not in titles:
                titles.append(f"*{title}*")
            source = f" ({byline}, *{title}*)" if byline and title else ""
            paragraphs.append(f"**{idea['label']}.** {idea['statement']}{source}")
            refs.append({"kind": "idea", "id": idea["global_id"]})
            evidence.append({
                "entry_id": entry_id, "kind": "idea", "ref_id": idea["global_id"], "decision": "included",
                "score": float(link["confidence"] or 0.8), "reason": "", "label": idea["label"],
                "evidence_text": idea["statement"], "work_id": link["nodus_id"], "work_title": title,
                "zotero_key": None, "works_json": json.dumps([{"id": link["nodus_id"], "title": title}], ensure_ascii=False),
                "page_label": None,
                "authors_json": json.dumps([{"id": person["author_id"], "name": person["name"]} for person in people], ensure_ascii=False),
                "tags_json": "[]", "source_revision": None, "is_new": 0, "first_seen_at": STAMP, "updated_at": STAMP,
            })
        content = words["intro"].format(n=len(links), works=joined(titles, words["and"])) + "\n\n" + "\n\n".join(paragraphs)
        entries.append({
            "id": entry_id, "name": theme["label"], "normalized_name": theme["label"].casefold(), "aliases_json": "[]",
            "focus_prompt": "", "scope_kind": "vault", "scope_json": '{"kind":"vault"}', "output_language": language,
            "detail_level": "standard", "tags_json": "[]", "content_markdown": content, "notes": "", "status": "active",
            "current_version_id": version_id, "proposed_version_id": None, "insufficient_evidence": 0,
            "new_evidence_count": 0, "last_evidence_scan_at": STAMP, "last_change_seq": 1,
            "created_at": STAMP, "updated_at": STAMP,
        })
        versions.append({
            "id": version_id, "entry_id": entry_id, "content_markdown": content, "evidence_json": json.dumps(refs),
            "evidence_snapshot_json": "[]", "citations_json": json.dumps(refs), "author_summaries_json": "[]",
            "focus_prompt": "", "scope_json": '{"kind":"vault"}', "output_language": language, "detail_level": "standard",
            "model_json": None, "generated_at": STAMP, "trigger": "creation", "state": "applied", "outcome": "synthesis",
            "degradation_reason": None, "generation_attempts": 1, "generation_problems_json": "[]",
            "insufficient_evidence": 0, "created_at": STAMP, "updated_at": STAMP,
        })
    ids = sorted(ideas_by_theme)
    for index, left in enumerate(ids):
        for right in ids[index + 1:]:
            if ideas_by_theme[left] & ideas_by_theme[right]:
                relations.append({
                    "id": f"{left}--{right}", "from_entry_id": left, "to_entry_id": right, "type": "related",
                    "origin": "manual", "status": "confirmed", "created_at": STAMP, "updated_at": STAMP,
                })
    return {"dictionary_entries": entries, "dictionary_evidence": evidence,
            "dictionary_versions": versions, "dictionary_relations": relations}


def main():
    for language in ("es", "en"):
        path = ROOT / f"demo-space.{language}.json.gz"
        document = json.loads(gzip.decompress(path.read_bytes()))
        base = document.get("baseRevision") or document["revision"]
        added = build(document, language)
        document["tables"].update(added)
        digest = hashlib.sha256((base + json.dumps(added, sort_keys=True, ensure_ascii=False)).encode()).hexdigest()[:16]
        document["baseRevision"] = base
        document["revision"] = f"{base}-dict-{digest}"
        payload = json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode()
        path.write_bytes(gzip.compress(payload, compresslevel=9, mtime=0))
        print(f"{path.name}: {len(added['dictionary_entries'])} entries, {len(added['dictionary_evidence'])} evidence, "
              f"{len(added['dictionary_relations'])} relations, revision {document['revision'][:24]}…")


if __name__ == "__main__":
    main()
