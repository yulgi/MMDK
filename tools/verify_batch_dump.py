"""Verify a completed Windows/local MMDK export against tables.lua and a run time."""
import argparse
import hashlib
import json
import re
from datetime import datetime
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root', required=True, type=Path, help='MMDK/PlayerData directory')
parser.add_argument('--tables', required=True, type=Path)
parser.add_argument('--since', required=True, help='Local start time: YYYY-MM-DDTHH:MM:SS')
parser.add_argument('--report', required=True, type=Path)
args = parser.parse_args()
start = datetime.fromisoformat(args.since).timestamp()
text = args.tables.read_text(encoding='utf-8')
block = re.search(r'local characters\s*=\s*\{(.*?)\}', text, re.S).group(1)
roster = sorted((int(i), name) for i, name in re.findall(r'\[(\d+)\]\s*=\s*"([^"]+)"', block))
suffixes = ['HIT_DT', 'triggers', 'Atemi', 'tgroups', 'rects', 'commands', 'charge', 'char_info', 'assist_combo', 'moves_dict', 'Names']
errors, fighters, hashes = [], [], {}
for fid, name in roster:
    info = {'id': fid, 'name': name, 'files': [], 'move_count': 0}
    for suffix in suffixes:
        path = args.root / name / f'{name} {suffix}.json'
        if not path.is_file():
            errors.append(f'Missing {path}')
            continue
        raw = path.read_bytes()
        info['files'].append({'name': path.name, 'bytes': len(raw), 'modified': datetime.fromtimestamp(path.stat().st_mtime).isoformat(timespec='seconds')})
        if path.stat().st_mtime < start:
            errors.append(f'Stale {path}')
        try:
            value = json.loads(raw)
        except (UnicodeError, ValueError) as exc:
            errors.append(f'Invalid JSON {path}: {exc}')
            continue
        if suffix in ['HIT_DT', 'triggers', 'rects', 'moves_dict', 'Names'] and (not isinstance(value, dict) or not value):
            errors.append(f'Empty or invalid dictionary {path}')
        if suffix == 'moves_dict' and isinstance(value, dict):
            info['move_count'] = len(value)
            digest = hashlib.sha256(raw).hexdigest()
            if digest in hashes:
                errors.append(f'Identical move dictionaries: {hashes[digest]} and {name}')
            hashes[digest] = name
    fighters.append(info)
report = {'ok': not errors, 'since': args.since, 'fighter_count': len(fighters), 'file_count': sum(len(f['files']) for f in fighters), 'fighters': fighters, 'errors': errors}
args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps({k: report[k] for k in ['ok', 'since', 'fighter_count', 'file_count', 'errors']}, ensure_ascii=False))
raise SystemExit(0 if report['ok'] else 1)
