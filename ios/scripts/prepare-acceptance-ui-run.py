#!/usr/bin/env python3
"""Prepare literal XCTest inputs; never print a pairing URL or credential."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import sqlite3
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("attempt")
parser.add_argument("--base", required=True, type=Path)
parser.add_argument("--lab", required=True, type=Path)
parser.add_argument("--bridge-pid", type=int)
parser.add_argument("--style", choices=["light", "dark"], required=True)
parser.add_argument("--source-citation", action="store_true")
parser.add_argument("--dictionary", action="store_true")
parser.add_argument("--person-dossier", action="store_true")
parser.add_argument("--text-size", choices=["standard", "accessibility3"])
parser.add_argument("--mac-unavailable", action="store_true")
parser.add_argument("--research-marker")
parser.add_argument("--research-body-snippet")
parser.add_argument("--research-title")
parser.add_argument("--research-markdown-sha256")
parser.add_argument("--scriptor-marker")
parser.add_argument("--offline-scriptor-marker")
parser.add_argument("--created-document-marker")
parser.add_argument("--pairing-by-code", action="store_true")
parser.add_argument("--phone-graph", action="store_true")
args = parser.parse_args()
if not re.fullmatch(r"[a-z0-9-]+", args.attempt):
    raise SystemExit("A unique safe attempt name is required")
if not (args.lab / ".nodus-mobile-acceptance-lab").is_file():
    raise SystemExit("An explicitly isolated lab is required")
if args.pairing_by_code and not args.bridge_pid:
    raise SystemExit("Code discovery requires a fresh real Mac offer")
output = args.base.parent / ("Nodus-" + args.attempt + ".xctestrun")
if output.exists():
    raise SystemExit("The private test configuration cannot be overwritten")

values = {"NODUS_ACCEPTANCE_INTERFACE_STYLE": args.style}
if args.research_marker:
    if not re.fullmatch(r"NodusQA-[A-Fa-f0-9-]{36}", args.research_marker):
        raise SystemExit("A native research request marker is required")
    values["NODUS_ACCEPTANCE_RESEARCH_MARKER"] = args.research_marker
if args.research_body_snippet:
    if not args.research_marker or not 40 <= len(args.research_body_snippet) <= 300:
        raise SystemExit("A saved research paragraph snippet and request marker are required")
    values["NODUS_ACCEPTANCE_RESEARCH_BODY_SNIPPET"] = args.research_body_snippet
if args.research_title:
    if not args.research_marker or not args.research_title.startswith(args.research_marker) or not 40 <= len(args.research_title) <= 4096:
        raise SystemExit("The exact saved title must identify the research request")
    values["NODUS_ACCEPTANCE_RESEARCH_TITLE"] = args.research_title
if args.research_markdown_sha256:
    if not args.research_marker or not re.fullmatch(r"[a-f0-9]{64}", args.research_markdown_sha256):
        raise SystemExit("A saved research Markdown digest is required")
    values["NODUS_ACCEPTANCE_RESEARCH_MARKDOWN_SHA256"] = args.research_markdown_sha256
if args.scriptor_marker:
    if not re.fullmatch(r"DesktopQA-[A-Za-z0-9-]{8,80}", args.scriptor_marker):
        raise SystemExit("A Desktop editor request marker is required")
    values["NODUS_ACCEPTANCE_SCRIPTOR_MARKER"] = args.scriptor_marker
if args.offline_scriptor_marker:
    if not re.fullmatch(r"MobileOffline-[A-Fa-f0-9]{8}", args.offline_scriptor_marker):
        raise SystemExit("An exact marker from an executed offline edit is required")
    values["NODUS_ACCEPTANCE_OFFLINE_SCRIPTOR_MARKER"] = args.offline_scriptor_marker
if args.created_document_marker:
    if not re.fullmatch(r"CompanionCreate-[A-Fa-f0-9]{8}", args.created_document_marker):
        raise SystemExit("An exact marker from an executed offline creation is required")
    values["NODUS_ACCEPTANCE_CREATED_DOCUMENT_MARKER"] = args.created_document_marker
if args.text_size:
    values["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] = args.text_size
if args.phone_graph:
    graph = json.loads((args.lab / "phone-graph-acceptance-input.json").read_text())
    if not graph.get("vaultId") or not isinstance(graph.get("themeLabel"), str) or not graph["themeLabel"] or not isinstance(graph.get("ideas"), int) or graph["ideas"] < 3:
        raise SystemExit("A real populated Mac theme and its complete idea count are required")
    values.update(NODUS_ACCEPTANCE_GRAPH_THEME=graph["themeLabel"], NODUS_ACCEPTANCE_GRAPH_IDEAS=str(graph["ideas"]))
if args.mac_unavailable:
    if args.bridge_pid:
        raise SystemExit("Offline acceptance must reuse its existing connection, without a fresh pairing")
    offer = json.loads((args.lab / "mobile-pairing-offer.json").read_text())
    # The test independently probes this address and rejects TLS/auth failures.
    values["NODUS_ACCEPTANCE_OFFLINE_ORIGIN"] = offer["origins"][-1]
if args.bridge_pid:
    expected = "node_modules/electron/dist/Electron.app/Contents/MacOS/Electron node_modules/.cache/nodus-mobile-acceptance"
    command = subprocess.check_output(["ps", "-p", str(args.bridge_pid), "-o", "command="], text=True).strip()
    repository = Path(__file__).resolve().parents[3] / "nodus"
    cwd = subprocess.check_output(["lsof", "-a", "-p", str(args.bridge_pid), "-d", "cwd", "-Fn"], text=True)
    if command != expected or "n" + str(repository) not in cwd.splitlines():
        raise SystemExit("Refusing to signal a process outside this checkout's acceptance Bridge")
    offer_path = args.lab / "mobile-pairing-offer.json"
    previous_id = json.loads(offer_path.read_text())["id"]
    os.kill(args.bridge_pid, signal.SIGUSR1)
    deadline = time.monotonic() + 15
    while True:
        offer = json.loads(offer_path.read_text())
        if offer["id"] != previous_id:
            break
        if time.monotonic() >= deadline:
            raise SystemExit("Desktop did not produce a fresh single-use offer")
        time.sleep(0.1)
    if args.pairing_by_code:
        values["NODUS_ACCEPTANCE_PAIRING_CODE"] = offer["code"]
    else:
        values["NODUS_ACCEPTANCE_LINK"] = offer["pairingURL"]

if args.source_citation:
    fixture = json.loads((args.lab / "source-citation-fixtures.json").read_text())
    pdf = args.lab / "acceptance-backups/nodus-library/acceptance-report/original.pdf"
    info = subprocess.check_output(["/opt/homebrew/bin/pdfinfo", str(pdf)], text=True)
    pages = int(re.search(r"^Pages:\s+(\d+)", info, re.M).group(1))
    values.update(NODUS_ACCEPTANCE_SOURCE_ENTRY=fixture["name"],
                  NODUS_ACCEPTANCE_SOURCE_EVIDENCE=fixture["evidenceLabel"],
                  NODUS_ACCEPTANCE_SOURCE_PAGE_VALUE=f"Página {fixture['page']} de {pages}")

if args.dictionary:
    registry = json.loads((args.lab / "vaults.json").read_text())
    vault = next(v for v in registry["vaults"] if v["id"] == "default")
    database = Path(vault["path"]).resolve()
    if not database.is_relative_to(args.lab.resolve()):
        raise SystemExit("Dictionary expectations must come from the isolated copied vault")
    fixture = json.loads((args.lab / "dictionary-snapshot-fixture.json").read_text())
    with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as connection:
        connection.row_factory = sqlite3.Row
        entry = connection.execute("SELECT * FROM dictionary_entries WHERE id=?", (fixture["entryId"],)).fetchone()
        if entry is None:
            raise SystemExit("The expected saved dictionary entry is missing")
        version = connection.execute("SELECT * FROM dictionary_versions WHERE id=?", (entry["current_version_id"],)).fetchone()
        related = connection.execute("SELECT name FROM dictionary_entries WHERE id IN (SELECT to_entry_id FROM dictionary_relations WHERE from_entry_id=?) ORDER BY name", (entry["id"],)).fetchone()
        if version is None or related is None:
            raise SystemExit("Actual saved dictionary versions and relationships are required")
        authors = json.loads(version["author_summaries_json"])
        evidence = json.loads(version["evidence_snapshot_json"])
        work = next((item["workTitle"] for item in evidence if item.get("workTitle")), None)
        paragraph = next((line for line in entry["content_markdown"].splitlines() if len(line) > 100 and not line.startswith(("#", "|", "-"))), "")
        snippet = re.sub(r"[*_`]+", "", paragraph.split("[")[0]).strip()[:100]
        if len(snippet) < 40 or not authors or not work:
            raise SystemExit("Actual readable definition, author and work evidence are required")
        values.update(NODUS_ACCEPTANCE_DICTIONARY_NAME=entry["name"],
                      NODUS_ACCEPTANCE_DICTIONARY_RELATED_NAME=related["name"],
                      NODUS_ACCEPTANCE_DICTIONARY_BODY_SNIPPET=snippet,
                      NODUS_ACCEPTANCE_DICTIONARY_AUTHOR_NAME=authors[0]["name"],
                      NODUS_ACCEPTANCE_DICTIONARY_WORK_TITLE=work)

if args.person_dossier:
    person = json.loads((args.lab / "person-dossier-acceptance-input.json").read_text())
    if person.get("personId") != "person-acceptance-mobile-010" or person.get("providerCalls") != 0:
        raise SystemExit("An explicitly isolated fictional person fixture is required")
    registry = json.loads((args.lab / "vaults.json").read_text())
    vault = next(vault for vault in registry["vaults"] if vault["id"] == person["vaultId"])
    database = Path(vault["path"]).resolve()
    if not database.is_relative_to(args.lab.resolve()):
        raise SystemExit("Person source expectations must come from the copied vault")
    with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as connection:
        source = connection.execute("SELECT source_id,title,citation FROM prosop_sources WHERE length(citation)>0 ORDER BY source_id LIMIT 1").fetchone()
        if source is None:
            raise SystemExit("An actual saved source with a readable citation is required")
        person.update(sourceId=source[0], sourceTitle=source[1], sourceCitation=source[2])
    values["NODUS_ACCEPTANCE_PERSON_DOSSIER"] = json.dumps(person, ensure_ascii=False)

configuration = plistlib.loads(args.base.read_bytes())
target = configuration["NodusUITests"]
# Xcode normalizes TestingEnvironmentVariables as runtime paths, corrupting
# nodus:// links. Application/test inputs belong in EnvironmentVariables.
target.setdefault("EnvironmentVariables", {}).update(values)
with output.open("xb") as stream:
    os.chmod(output, 0o600)
    plistlib.dump(configuration, stream)
print(json.dumps({"attempt": args.attempt, "configuration": str(output),
                  "freshSingleUseOffer": bool(args.bridge_pid), "style": args.style}))
