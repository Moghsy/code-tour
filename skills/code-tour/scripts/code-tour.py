#!/usr/bin/env python3
"""Locate the installed Neovim tour CLI without embedding another copy."""
import os
from pathlib import Path
import runpy

home = Path.home()
app = os.environ.get('NVIM_APPNAME', 'nvim')
data = Path(os.environ.get('XDG_DATA_HOME', home / '.local/share'))
config = Path(os.environ.get('XDG_CONFIG_HOME', home / '.config'))
explicit = os.environ.get('CODE_TOUR_CLI') or os.environ.get('CODE_WALKTHROUGH_CLI')
candidates = [Path(explicit)] if explicit else [
    data / app / 'lazy/code-tour.nvim/bin/code-tour',
    config / app / 'local-plugins/code-tour.nvim/bin/code-tour',
]
cli = next((path for path in candidates if path.is_file()), candidates[0])
if not cli.is_file():
    raise SystemExit(f'Code tour CLI not found: {cli}. Set CODE_TOUR_CLI to its installed path.')
runpy.run_path(str(cli), run_name='__main__')
