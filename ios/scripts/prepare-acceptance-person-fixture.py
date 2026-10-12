#!/usr/bin/env python3
"""Add an explicitly fictional, complete identity to an isolated copied vault."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import sqlite3

parser = argparse.ArgumentParser()
parser.add_argument("--lab", required=True, type=Path)
args = parser.parse_args()
lab = args.lab.resolve()
assert (lab / ".nodus-mobile-acceptance-lab").is_file()
registry = json.loads((lab / "vaults.json").read_text())
for vault in registry["vaults"]:
    assert Path(vault["path"]).resolve().is_relative_to(lab)
vault = next(vault for vault in registry["vaults"] if vault["type"] == "prosopography")
fixture = {
    "fixtureKind": "explicitly fictional person; no real individual or identity document",
    "vaultId": vault["id"], "personId": "person-acceptance-mobile-010",
    "name": "Persona ficticia de aceptación móvil",
    "biography": "Esta biografía describe una persona ficticia preparada para comprobar la lectura completa del dossier en el móvil.\n\n**Su contenido no corresponde a una persona real.** Debe conservar la segunda parte del texto al volver a abrir el dossier.",
    "biographySnippet": "Esta biografía describe una persona ficticia preparada para comprobar",
    "notes": "Esta nota ficticia comprueba que las notas privadas de la persona también se pueden consultar desde el móvil.",
    "birthDate": "1700", "deathDate": "1750", "nationalId": "NODUS-QA-010",
    "authorityScheme": "Nodus QA (ficticio)", "authorityId": "NODUS-QA-AUTHORITY-010",
    "providerCalls": 0, "extractionOrIndexingStarted": False,
}
now = datetime.now(timezone.utc).isoformat()
with sqlite3.connect(Path(vault["path"]).resolve()) as connection:
    connection.execute("PRAGMA foreign_keys=ON")
    connection.execute("BEGIN IMMEDIATE")
    row = connection.execute("SELECT display_name,biography,notes,birth_date,death_date,national_id FROM persons WHERE person_id=?", (fixture["personId"],)).fetchone()
    values = tuple(fixture[key] for key in ["name", "biography", "notes", "birthDate", "deathDate", "nationalId"])
    if row is None:
        connection.execute("INSERT INTO persons(person_id,display_name,biography,notes,birth_date,death_date,national_id,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)", (fixture["personId"], *values, now, now))
        connection.execute("INSERT INTO prosop_person_profiles(person_id,created_at,updated_at) VALUES(?,?,?)", (fixture["personId"], now, now))
    else:
        assert row == values, "An existing fixture must not overwrite later edits"
    assert connection.execute("SELECT count(*) FROM prosop_person_profiles WHERE person_id=?", (fixture["personId"],)).fetchone()[0] == 1
    authority = connection.execute("SELECT scheme,external_id FROM prosop_authority_ids WHERE authority_id=?", ("authority-acceptance-mobile-010",)).fetchone()
    if authority is None:
        connection.execute("INSERT INTO prosop_authority_ids(authority_id,entity_kind,entity_id,scheme,external_id,created_at) VALUES(?,?,?,?,?,?)",
            ("authority-acceptance-mobile-010", "person", fixture["personId"], fixture["authorityScheme"], fixture["authorityId"], now))
    else:
        assert authority == (fixture["authorityScheme"], fixture["authorityId"])
output = lab / "person-dossier-acceptance-input.json"
if output.exists():
    existing = json.loads(output.read_text())
    assert all(fixture.get(key) == value for key, value in existing.items()), "Only new fixture fields may be added"
    if existing != fixture:
        output.write_text(json.dumps(fixture, ensure_ascii=False, indent=2) + "\n")
else:
    output.write_text(json.dumps(fixture, ensure_ascii=False, indent=2) + "\n")
    output.chmod(0o600)
print(json.dumps({"prepared": True, "fictional": True, "providerCalls": 0}))
