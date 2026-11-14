import contextlib
import copy
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

PLUGIN = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader('saved_cli', str(PLUGIN / 'bin/code-tour'))
spec = importlib.util.spec_from_loader(loader.name, loader)
cli = importlib.util.module_from_spec(spec)
loader.exec_module(cli)
FIXTURE = json.loads((PLUGIN / 'tests/fixtures/saved-v1.json').read_text())


class LibraryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='saved-metadata-')
        self.addCleanup(self.temporary.cleanup)
        self.env = patch.dict(os.environ, XDG_DATA_HOME=self.temporary.name, NVIM_APPNAME='test-profile')
        self.env.start()
        self.addCleanup(self.env.stop)
        self.directory = cli.library_directory()

    def write(self, record=None, name=None):
        record = copy.deepcopy(record or FIXTURE)
        self.directory.mkdir(parents=True, exist_ok=True)
        path = self.directory / ((name or record['id']) + '.json')
        path.write_text(json.dumps(record) + '\n')
        return path

    def test_missing_library_is_empty_and_never_created(self):
        with patch.object(cli, 'instances', side_effect=AssertionError('editor discovery')), \
                patch.object(cli, 'rpc', side_effect=AssertionError('RPC')), \
                patch.object(cli, 'herdr', side_effect=AssertionError('Herdr')):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(cli.main(['saved', 'list', '--limit', '5']), 0)
            self.assertEqual(json.loads(output.getvalue()), dict(tours=[], issues=[]))
        self.assertFalse(self.directory.exists())

    def test_profile_path_and_fallback(self):
        self.assertEqual(self.directory, Path(self.temporary.name) / 'test-profile/code-tour/tours')
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(cli.library_directory(), Path.home() / '.local/share/nvim/code-tour/tours')
        with patch.dict(os.environ, NVIM_APPNAME='nested/profile'):
            self.assertEqual(cli.library_directory(), Path(self.temporary.name) / 'nested/profile/code-tour/tours')

    def test_metadata_revisions_and_shared_lua_fixture(self):
        path = self.write()
        metadata = cli.saved_metadata(path)
        self.assertEqual(metadata['revision'], hashlib.sha256(path.read_bytes()).hexdigest())
        self.assertEqual(len(metadata['repositories']), 2)
        code = ('vim.opt.rtp:prepend(' + json.dumps(str(PLUGIN)) + '); '
                'require("code-tour.library").validate(vim.json.decode(table.concat(vim.fn.readfile(' +
                json.dumps(str(path)) + '),"\\n")))')
        result = subprocess.run(['nvim', '--clean', '--headless', '-i', 'NONE', '+lua ' + code, '+qa'],
                                env=dict(os.environ, XDG_STATE_HOME=self.temporary.name + '/state'),
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('Error', result.stderr)

    def test_sort_by_save_time_then_id_and_allow_duplicate_titles(self):
        for identity, stamp in [('a' * 32, '2026-11-01T12:00:00Z'),
                                ('c' * 32, '2026-11-01T13:00:00Z'),
                                ('b' * 32, '2026-11-01T13:00:00Z')]:
            record = copy.deepcopy(FIXTURE)
            record.update(id=identity, saved_at=stamp)
            self.write(record)
        result = cli.saved_list(2)
        self.assertEqual([r['id'] for r in result['tours']], ['b' * 32, 'c' * 32])
        self.assertFalse(result['issues'])

    def test_bad_entries_are_diagnostics_without_hiding_good_entries(self):
        self.write()
        (self.directory / 'broken.json').write_text('{bad JSON')
        for index, change in enumerate([dict(version=2), dict(title=''), dict(saved_at='2026-02-30T12:00:00Z'),
                                         dict(repositories=[]), dict(saved_at='2020-01-01T00:00:00Z')]):
            record = copy.deepcopy(FIXTURE)
            record.update(id=f'{index:032x}', **change)
            self.write(record)
        self.write(name='d' * 32)  # filename/ID disagreement
        result = cli.saved_list(50)
        self.assertEqual(len(result['tours']), 1)
        self.assertEqual(len(result['issues']), 7)

    def test_limit_requires_positive_integer(self):
        for limit in [0, -1, 1.5, True]:
            with self.assertRaises(ValueError):
                cli.saved_list(limit)
        with contextlib.redirect_stderr(io.StringIO()):
            for value in ['0', '-1', 'bad']:
                with self.assertRaises(SystemExit):
                    cli.main(['saved', 'list', '--limit', value])

    def test_listing_without_neovim_msgpack_or_editor(self):
        self.write()
        env = dict(os.environ, PATH='/nonexistent')
        command = ('import builtins,runpy,sys; original=builtins.__import__; '
                   'exec("def restricted(name,*args,**kwargs):\\n'
                   ' if name==\\\"msgpack\\\": raise AssertionError(\\\"msgpack imported\\\")\\n'
                   ' return original(name,*args,**kwargs)"); '
                   'builtins.__import__=restricted; sys.argv=' + repr([str(PLUGIN / 'bin/code-tour'), 'saved', 'list', '--limit', '1']) +
                   '; runpy.run_path(sys.argv[0],run_name="__main__")')
        result = subprocess.run([sys.executable, '-c', command], env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(json.loads(result.stdout)['tours']), 1)

    def test_save_and_open_argument_transport(self):
        self.write()
        target = dict(address='/editor', instance_id='test', cwd='/tmp', pane_id='pane')
        with patch.object(cli, 'instances', return_value=[target]), patch.object(cli, 'choose', return_value=target), \
                patch.object(cli, 'deliver', return_value={}) as deliver, \
                patch.object(cli, 'origin', return_value={'agent': 'current'}), \
                patch.object(cli, 'focus'), patch.object(cli, 'remember'), contextlib.redirect_stdout(io.StringIO()):
            cli.main(['saved', 'save', '--pane', 'pane', '--overwrite', FIXTURE['id'], '--revision', 'e' * 64])
            self.assertEqual(deliver.call_args.args[1], 'save_saved')
            opts = deliver.call_args.args[2][0]
            self.assertEqual(opts['revision'], 'e' * 64)
            self.assertEqual(opts['library'], str(self.directory))
            cli.main(['saved', 'open', FIXTURE['id'], '--repo', 'app', '/tmp', '--map-file', 'app', 'auth.lua', 'renamed.lua'])
            self.assertEqual(deliver.call_args.args[1], 'open_saved')
            opts = deliver.call_args.args[2][1]
            self.assertEqual(opts['repositories'], {'app': '/tmp'})
            self.assertEqual(opts['files'], [['app', 'auth.lua', 'renamed.lua']])
            self.assertEqual(opts['origin'], {'agent': 'current'})


if __name__ == '__main__':
    unittest.main()
