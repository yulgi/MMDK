"""Verify a completed Windows/local MMDK export against tables.lua and a run time."""
import argparse
import hashlib
import json
import re
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root', required=True, type=Path, help='MMDK/PlayerData directory')
parser.add_argument('--tables', required=True, type=Path)
parser.add_argument('--since', required=True, help='Local start time: YYYY-MM-DDTHH:MM:SS')
parser.add_argument('--report', required=True, type=Path)
parser.add_argument('--ids', help='Optional subset of game resource IDs, e.g. 26 or 1-22,25-34')
parser.add_argument('--require-common', action='store_true', help='Require the six shared files exported by batch version 2026-10-14.1')
args = parser.parse_args()
start = datetime.fromisoformat(args.since).timestamp()
text = args.tables.read_text(encoding='utf-8')
block = re.search(r'local characters\s*=\s*\{(.*?)\}', text, re.S).group(1)
roster = sorted((int(i), name) for i, name in re.findall(r'\[(\d+)\]\s*=\s*"([^"]+)"', block))
if args.ids:
    selected = set()
    for token in re.split(r'[,\s]+', args.ids.strip()):
        match = re.fullmatch(r'(\d+)(?:-(\d+))?', token)
        if not match:
            parser.error(f'Invalid ID range: {token}')
        first, last = int(match[1]), int(match[2] or match[1])
        if first > last:
            parser.error(f'Invalid ID range: {token}')
        selected.update(range(first, last + 1))
    unknown = selected - {fid for fid, _ in roster}
    if unknown:
        parser.error(f'IDs are not in tables.lua: {sorted(unknown)}')
    roster = [(fid, name) for fid, name in roster if fid in selected]
suffixes = ['HIT_DT', 'triggers', 'atemi', 'tgroups', 'rects', 'commands', 'charge', 'char_info', 'assist_combo', 'moves_dict', 'Names']
errors, fighters, hashes = [], [], {}
for fid, name in roster:
    info = {'id': fid, 'name': name, 'files': [], 'move_count': 0}
    moves, names = {}, {}
    for suffix in suffixes:
        path = args.root / name / f'{name} {suffix}.json'
        if not path.is_file():
            errors.append(f'Missing {path}')
            continue
        raw = path.read_bytes()
        info['files'].append({'name': path.name, 'bytes': len(raw), 'modified': datetime.fromtimestamp(path.stat().st_mtime).isoformat(timespec='seconds'), 'sha256': hashlib.sha256(raw).hexdigest()})
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
            moves = value
            info['move_count'] = len(value)
            digest = hashlib.sha256(raw).hexdigest()
            if digest in hashes:
                errors.append(f'Identical move dictionaries: {hashes[digest]} and {name}')
            hashes[digest] = name
        if suffix == 'Names' and isinstance(value, dict):
            names = value
        if value is None:
            info.setdefault('null_resources', []).append(suffix)
    by_id = defaultdict(set)
    motion_ids = Counter()
    for move in moves.values():
        if not isinstance(move, dict):
            errors.append(f'{name}: invalid move entry')
            continue
        by_id[move.get('id')].add(move.get('name'))
        motion = re.match(r'esf(\d{3})_', move.get('mot_name', ''))
        if motion:
            motion_ids[int(motion[1])] += 1
    info['motion_resource_id_counts'] = dict(motion_ids)
    if motion_ids and motion_ids.most_common(1)[0][0] != fid:
        errors.append(f'{name}: predominant motion resource ID {motion_ids.most_common(1)[0][0]} differs from requested ID {fid}')
    for action_id, candidates in by_id.items():
        if not isinstance(action_id, int) or names.get(f'{action_id:04d}') not in candidates:
            errors.append(f'{name}: Names/moves_dict disagree for action {action_id}')
    fighters.append(info)
common, common_values = [], {}
if args.require_common:
    for suffix in ['moves', 'rects', 'atemi', 'names', 'act_id', 'manifest']:
        path = args.root / f'common_{suffix}.json'
        if not path.is_file():
            errors.append(f'Missing {path}')
            continue
        raw = path.read_bytes()
        common.append({'name': path.name, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(), 'modified': datetime.fromtimestamp(path.stat().st_mtime).isoformat(timespec='seconds')})
        if path.stat().st_mtime < start:
            errors.append(f'Stale {path}')
        try:
            value = json.loads(raw)
            if not isinstance(value, dict) or not value:
                errors.append(f'Empty or invalid dictionary {path}')
            else:
                common_values[suffix] = value
        except (UnicodeError, ValueError) as exc:
            errors.append(f'Invalid JSON {path}: {exc}')
    cmoves, cnames = common_values.get('moves') or {}, common_values.get('names') or {}
    if len(cmoves) != common_values.get('manifest', {}).get('action_entries'):
        errors.append('Common move count differs from common_manifest.action_entries')
    for move in cmoves.values():
        if not isinstance(move, dict):
            errors.append('Invalid common move entry')
            continue
        action_id = move.get('id')
        if not isinstance(action_id, int) or cnames.get(f'{action_id:04d}') != move.get('name'):
            errors.append(f'Common Names/moves disagree for action {action_id}')
fighter_file_count = sum(len(f['files']) for f in fighters)
report = {'ok': not errors, 'since': args.since, 'fighter_count': len(fighters), 'fighter_file_count': fighter_file_count, 'common_file_count': len(common), 'file_count': fighter_file_count + len(common), 'fighters': fighters, 'common_files': common, 'common_action_count': len(common_values.get('moves') or {}), 'errors': errors}
report['root'] = str(args.root.resolve())
report['tables_source'] = {'path': str(args.tables.resolve()), 'sha256': hashlib.sha256(args.tables.read_bytes()).hexdigest()}
report['require_common'] = args.require_common
args.report.parent.mkdir(parents=True, exist_ok=True)
args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
console = {k: report[k] for k in ['ok', 'since', 'fighter_count', 'file_count']}
console.update(error_count=len(errors), errors=errors[:10], report=str(args.report))
print(json.dumps(console, ensure_ascii=False))
raise SystemExit(0 if report['ok'] else 1)
