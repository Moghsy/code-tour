#!/usr/bin/env python3
"""Install the tour skill in existing Claude, Codex and shared discovery directories."""
import argparse
from datetime import datetime
from pathlib import Path
import shutil

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--home', type=Path, default=Path.home())
args = parser.parse_args()
source = Path(__file__).resolve().parents[1] / 'skills/code-tour'
stamp = datetime.now().strftime('%Y%m%d-%H%M%S-%f')
resources = sorted((source / 'references').rglob('*.md'))
resources.extend([source / 'scripts/code-tour.py', source / 'SKILL.md'])

def install(destination, origin):
    if destination.exists() and destination.read_bytes() == origin.read_bytes():
        return
    if destination.exists():
        shutil.copy2(destination, destination.with_name(destination.name + '.backup-' + stamp))
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(origin, destination)


for discovery in ('.agents', '.codex', '.claude'):
    target = args.home / discovery / 'skills/code-tour'
    legacy = args.home / discovery / 'skills/code-walkthrough'
    if (legacy / 'SKILL.md').exists():
        if not target.exists():
            legacy.rename(target)
            old_script = target / 'scripts/walkthrough.py'
            new_script = target / 'scripts/code-tour.py'
            if old_script.exists() and not new_script.exists():
                old_script.rename(new_script)
        else:
            # Preserve an existing installation without leaving two active skills.
            old_skill = legacy / 'SKILL.md'
            old_skill.rename(old_skill.with_name('SKILL.md.backup-' + stamp))
    for resource in resources:
        install(target / resource.relative_to(source), resource)
    # Commands already delivered to an agent may still name this exact script.
    install(legacy / 'scripts/walkthrough.py', source / 'scripts/code-tour.py')
    print(target)
