#!/usr/bin/env python3
"""Install isolated damaged/repaired snapshots through the app's marked Debug lab."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--device', required=True)
args = parser.parse_args()
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '--json'], text=True))
assert any(d['udid'] == args.device and d['state'] == 'Booted' for values in devices['devices'].values() for d in values), 'A booted simulator is required'
container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', args.device, 'com.drakonis96.nodus.ios', 'data'], text=True).strip())
folder = container / 'Library/Application Support/AcceptanceLab'
marker = folder / '.nodus-mobile-acceptance-lab'
marker_text = 'Nodus Mobile isolated acceptance fixture\n'
if folder.exists():
    assert marker.is_file() and marker.read_text() == marker_text, 'Never write into an unmarked data folder'
else:
    folder.mkdir(parents=True)
    marker.write_text(marker_text)
title = 'Informe reparado de aceptación'
brief = {'kind': 'deep_research', 'objective': title, 'language': 'es'}
draft = {'title': title, 'brief': brief, 'selection': {}, 'generatedAt': '2026-10-09T00:00:00Z',
         'abstract': 'Texto conservado para comprobar la recuperación.', 'outline': [],
         'draftMarkdown': '## Resultado\n\nTexto recuperado: la consulta vuelve a mostrar el informe completo tras reparar el registro.',
         'bibliography': [], 'matrix': [], 'nextSteps': [], 'limitations': [], 'stats': {'selectedIdeas': 0, 'selectedWorks': 0}}
receipts = []
for state in ['damaged', 'repaired']:
    row = {'id': 'acceptance-format-report', 'title': title,
           'brief_json': '{broken' if state == 'damaged' else json.dumps(brief),
           'draft_json': json.dumps(draft), 'selection_json': '{}', 'model_json': None,
           'created_at': '2026-10-09T00:00:00Z', 'updated_at': '2026-10-09T00:00:00Z'}
    snapshot = {'format': 'nodus.server-snapshot', 'formatVersion': 2, 'schemaVersion': 1,
                'revision': 'acceptance-research-format-' + state,
                'vault': {'name': 'Aceptación de consulta', 'type': 'academic'},
                'tables': {'writing_saved_drafts': [row], 'writing_draft_reads': [],
                           'writing_draft_annotations': [], 'content_translations': [], 'works': [], 'ideas': [], 'themes': []}}
    data = (json.dumps(snapshot, ensure_ascii=False) + '\n').encode()
    path = folder / f'research-{state}-snapshot.json'
    path.write_bytes(data); os.chmod(path, 0o600)
    receipts.append({'state': state, 'filename': path.name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
print(json.dumps({'device': args.device, 'isolatedDebugLab': str(folder), 'fixtures': receipts}))
