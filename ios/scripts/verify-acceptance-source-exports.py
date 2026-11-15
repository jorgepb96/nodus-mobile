#!/usr/bin/env python3
"""Verify actual Files exports against the owning isolated Mac's source bytes."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("--result", required=True, type=Path)
parser.add_argument("--attachments", required=True, type=Path)
parser.add_argument("--lab", required=True, type=Path)
parser.add_argument("--simulator", required=True)
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
assert (args.lab / ".nodus-mobile-acceptance-lab").is_file()
assert "artifacts/acceptance-0.1.0" in str(args.output.resolve())
assert not args.output.exists(), "An executed byte-verification receipt cannot be overwritten"
assert str(uuid.UUID(args.simulator)).upper() == args.simulator.upper()
summary = json.loads(subprocess.check_output([
    "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(args.result), "--compact"
], text=True))
assert summary["result"] == "Passed" and summary["failedTests"] == 0 and summary["skippedTests"] == 0
assert summary["passedTests"] == 1
assert any(item["device"]["deviceId"] == args.simulator for item in summary["devicesAndConfigurations"])
storage = Path.home() / "Library/Developer/CoreSimulator/Devices" / args.simulator / "data/Containers/Shared/AppGroup"
source = args.lab / "acceptance-backups/nodus-library/acceptance-report"
expected = {"original": "original.pdf", "clean": "reader.md", "attachment": "acceptance-supplement.txt"}
fixture = json.loads((args.lab / "source-citation-fixtures.json").read_text())
digest = lambda data: hashlib.sha256(data).hexdigest()
assert digest((source / "original.pdf").read_bytes()) == fixture["originalSha256"]
results = []
for test in json.loads((args.attachments / "manifest.json").read_text()):
    for attachment in test.get("attachments", []):
        label = attachment.get("suggestedHumanReadableName", "")
        for kind, original in expected.items():
            if not label.startswith("source-" + kind + "-export-expected-filename_"):
                continue
            exported = attachment["exportedFileName"]
            assert Path(exported).name == exported
            filename = (args.attachments / exported).read_text().strip()
            assert re.fullmatch(r"Nodus-acceptance-" + kind + r"-[A-Fa-f0-9-]{36}\.(pdf|md|txt)", filename)
            matches = list(storage.glob("*/File Provider Storage/" + filename))
            assert len(matches) == 1, "The exact native Files export must exist once"
            actual_path, original_path = matches[0].resolve(), (source / original).resolve()
            assert actual_path.is_relative_to(storage.resolve()) and original_path.is_relative_to(args.lab.resolve())
            actual, original_bytes = actual_path.read_bytes(), original_path.read_bytes()
            assert actual and actual == original_bytes, "An export must preserve the complete Mac source bytes"
            results.append({"kind": kind, "byteCount": len(actual), "sha256": digest(actual), "matchesMacSource": True})
assert sorted(item["kind"] for item in results) == sorted(expected)
args.output.write_text(json.dumps({"result": "passed", "skipped": 0,
    "sourceResult": str(args.result), "simulator": args.simulator, "files": results}, indent=2) + "\n")
print(json.dumps({"result": "passed", "files": len(results), "byteCount": sum(item["byteCount"] for item in results)}))
