#!/usr/bin/env python3
"""Run all Flutter tests and enforce lib/ line coverage, including unused libraries."""
import argparse
from collections import defaultdict
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--minimum', type=float, default=70.0)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    entry = root / 'test' / 'coverage_all_libraries_test.dart'
    report = root / 'coverage' / 'lcov.info'
    if entry.exists():
        parser.error(f'Refusing to overwrite {entry}')
    libraries = sorted((root / 'lib').rglob('*.dart'))
    imports = [p for p in libraries if not any(
        line.lstrip().startswith('part of ') for line in p.read_text().splitlines())]
    entry.write_text(
        '// Generated only for coverage; removed after the run.\n'
        '// ignore_for_file: unused_import\n'
        "import 'package:flutter_test/flutter_test.dart';\n" + ''.join(
            f"import 'package:ticketdiary/{p.relative_to(root / 'lib').as_posix()}';\n"
            for p in imports) +
        "void main() { test('load all libraries for coverage', () {}); }\n")
    report.parent.mkdir(exist_ok=True)
    report.unlink(missing_ok=True)
    try:
        result = subprocess.run(['flutter', 'test', '--no-pub', '--coverage'], cwd=root)
    finally:
        entry.unlink()
    if not report.exists():
        print('No coverage report produced.', file=sys.stderr)
        return 1
    covered_files = set()
    totals = defaultdict(lambda: [0, 0])
    for block in report.read_text().split('end_of_record'):
        lines = block.splitlines()
        source = next((line[3:] for line in lines if line.startswith('SF:')), None)
        if not source:
            continue
        path = Path(source)
        if path.is_absolute():
            path = path.relative_to(root)
        if path.parts[0] != 'lib':
            continue
        covered_files.add(path)
        hits = [int(line.split(',')[1]) for line in lines if line.startswith('DA:')]
        group = path.parts[1] if len(path.parts) > 2 else 'lib root'
        totals[group][0] += sum(hit > 0 for hit in hits)
        totals[group][1] += len(hits)
    missing = {p.relative_to(root) for p in libraries} - covered_files
    hit = sum(pair[0] for pair in totals.values())
    count = sum(pair[1] for pair in totals.values())
    percentage = 100 * hit / count if count else 0
    print(f'\nlib/: {hit}/{count} lines = {percentage:.2f}% ({len(covered_files)} files)')
    for group, (hits, lines) in sorted(totals.items()):
        print(f'  {group}: {hits}/{lines} = {100 * hits / lines if lines else 0:.2f}%')
    if missing:
        print('Missing files:', ', '.join(map(str, sorted(missing))))
    if result.returncode:
        print('Tests failed; coverage includes execution from failed tests.')
    if percentage < args.minimum:
        print(f'Coverage is below {args.minimum:.2f}%.')
    return int(bool(result.returncode or missing or percentage < args.minimum))


if __name__ == '__main__':
    sys.exit(main())
