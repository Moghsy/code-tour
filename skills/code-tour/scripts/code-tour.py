#!/usr/bin/env python3
"""Locate the installed Neovim tour CLI without embedding another copy."""
import os
from pathlib import Path
import runpy

config = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config'))
cli = Path(os.environ.get('CODE_TOUR_CLI') or os.environ.get('CODE_WALKTHROUGH_CLI')
           or config / os.environ.get('NVIM_APPNAME', 'nvim') / 'local-plugins/code-tour.nvim/bin/code-tour')
if not cli.is_file():
    raise SystemExit(f'Code tour CLI not found: {cli}. Set CODE_TOUR_CLI to its installed path.')
runpy.run_path(str(cli), run_name='__main__')
