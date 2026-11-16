import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import msgpack

PLUGIN = Path(__file__).resolve().parents[1]
CLI = PLUGIN / 'bin/code-tour'
loader = importlib.machinery.SourceFileLoader('code_tour_cli', str(CLI))
spec = importlib.util.spec_from_loader(loader.name, loader)
cli = importlib.util.module_from_spec(spec)
loader.exec_module(cli)


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.root = Path('/tmp/workspace')
        self.one = dict(address='/one', instance_id='one', cwd=str(self.root), pane_id='w1:p1')
        self.two = dict(address='/two', instance_id='two', cwd=str(self.root / 'sub'), pane_id='w1:p2')

    def test_ambiguity_is_not_resolved_by_focus_or_closer_cwd(self):
        with self.assertRaises(cli.Ambiguous):
            cli.choose([self.one, self.two], None, None, self.root, [self.root / 'sub/source'])
        self.assertEqual(cli.choose([self.one, self.two], 'w1:p2', None, self.root, []), self.two)

    def test_remembered_instance_precedes_workspace_ambiguity(self):
        key = 'code-tour-test-' + str(os.getpid())
        cli.remember(key, self.one)
        self.assertEqual(cli.choose([self.one, self.two], None, key, self.root, []), self.one)
        changed = dict(self.one, instance_id='new-process')
        with self.assertRaises(cli.Ambiguous):
            cli.choose([changed, self.two], None, key, self.root, [])

    def test_containing_cwd_and_no_match(self):
        self.assertEqual(cli.choose([self.one], None, None, Path('/other'), [self.root / 'source']), self.one)
        self.assertIsNone(cli.choose([], None, None, self.root, []))

    def test_exact_pane_focus_uses_neighbor_result(self):
        calls = []
        def herdr(*args, **kwargs):
            calls.append(args)
            if args[:2] == ('pane', 'list'):
                return dict(panes=[dict(pane_id='a', tab_id='tab'), dict(pane_id='b', tab_id='tab')])
            if args[:2] == ('pane', 'neighbor'):
                return dict(neighbor=dict(neighbor_pane_id='b'))
            return {}
        with patch.object(cli, 'herdr', herdr):
            cli.focus(dict(session='session', tab_id='tab', pane_id='b'))
        self.assertIn(('pane', 'focus', '--pane', 'a', '--direction', 'left'), calls)

    def test_nested_call_paths_resolve_from_caller_cwd(self):
        items = [dict(file='main.lua', parts=[dict(calls=[dict(file='helper.lua', calls=[
            dict(file='../util.lua', lazy=True)])])])]
        paths = cli.resolve_stops(items, self.root / 'sub')
        self.assertEqual(paths, [self.root / 'sub/main.lua', self.root / 'sub/helper.lua', self.root / 'util.lua'])
        self.assertEqual(items[0]['parts'][0]['calls'][0]['calls'][0]['file'], str(self.root / 'util.lua'))


class SkillMigrationTests(unittest.TestCase):
    def test_existing_skill_is_migrated_with_backups_and_legacy_reply_wrapper(self):
        with tempfile.TemporaryDirectory(prefix='code-tour-skills-') as temporary:
            home = Path(temporary)
            legacy = home / '.agents/skills/code-walkthrough'
            (legacy / 'scripts').mkdir(parents=True)
            (legacy / 'SKILL.md').write_text('original user skill\n')
            (legacy / 'scripts/walkthrough.py').write_text('original user script\n')
            command = [sys.executable, str(PLUGIN / 'scripts/install_skills.py'), '--home', str(home)]
            subprocess.run(command, check=True, capture_output=True, text=True)
            target = home / '.agents/skills/code-tour'
            self.assertIn('name: code-tour\n', (target / 'SKILL.md').read_text())
            self.assertEqual(next(target.glob('SKILL.md.backup-*')).read_text(), 'original user skill\n')
            self.assertEqual(next((target / 'scripts').glob('code-tour.py.backup-*')).read_text(), 'original user script\n')
            self.assertFalse((legacy / 'SKILL.md').exists())
            self.assertTrue((legacy / 'scripts/walkthrough.py').is_file())
            env = dict(os.environ, CODE_TOUR_CLI=str(CLI))
            help_result = subprocess.run([sys.executable, str(legacy / 'scripts/walkthrough.py'), '--help'],
                                         env=env, check=True, capture_output=True, text=True)
            self.assertIn('--fill', help_result.stdout)
            backups = sorted(str(p) for p in home.rglob('*.backup-*'))
            subprocess.run(command, check=True, capture_output=True, text=True)
            self.assertEqual(sorted(str(p) for p in home.rglob('*.backup-*')), backups)


class RPCIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='code-tour-cli-')
        cls.root = Path(cls.temporary.name)
        cls.env = {k: v for k, v in os.environ.items() if not k.startswith(('HERDR_', 'CODEX_', 'CLAUDE_'))}
        cls.env['XDG_STATE_HOME'] = str(cls.root / 'state')
        cls.env['XDG_DATA_HOME'] = str(cls.root / 'data')
        cls.env['XDG_CACHE_HOME'] = str(cls.root / 'cache')
        cls.source = cls.root / 'source.lua'
        cls.source.write_text('local x = 1\nlocal y = 2\nreturn x + y\n')
        cls.processes = []
        cls.addresses = []
        for i in range(2):
            address = str(cls.root / f'editor-{i}.sock')
            setup = 'lua vim.opt.rtp:prepend(' + json.dumps(str(PLUGIN)) + '); require("tour").setup({smooth_scroll=false})'
            process = subprocess.Popen(['nvim', '--clean', '--headless', '-n', '-i', 'NONE', '--listen', address, '-c', setup],
                                       cwd=cls.root, env=cls.env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            cls.processes.append(process)
            cls.addresses.append(address)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                try:
                    cli.inspect(address)
                    break
                except (OSError, RuntimeError):
                    if process.poll() is not None:
                        raise RuntimeError(process.stderr.read().decode())
                    time.sleep(0.05)
            else:
                raise RuntimeError('Test editor did not start')

    @classmethod
    def tearDownClass(cls):
        for process in cls.processes:
            process.terminate()
            process.wait(timeout=5)
            process.stderr.close()
        cls.temporary.cleanup()

    def run_cli(self, *args, data='', expected=0):
        result = subprocess.run([str(CLI), *args], input=data, capture_output=True, text=True,
                                cwd=self.root, env=self.env, timeout=15)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def test_saved_library_save_open_overwrite_and_remapping(self):
        address = self.addresses[0]
        self.run_cli('--pane', address, data=json.dumps([dict(file='source.lua', start=1, end=3, note='Saved current code')]))
        first = json.loads(self.run_cli('saved', 'save', '--pane', address, '--title', 'RPC saved tour').stdout)
        second = json.loads(self.run_cli('saved', 'save', '--pane', address).stdout)
        self.assertNotEqual(first['id'], second['id'])
        listed = json.loads(self.run_cli('saved', 'list', '--limit', '100').stdout)
        self.assertIn(first['id'], [item['id'] for item in listed['tours']])
        cli.rpc(address, 'require("code-tour.conversation").deliver=function(_,_,_,_,cb) cb(true) end')
        # Unchanged unchecked prose is reused by default; nothing is requested.
        reused = json.loads(self.run_cli('saved', 'open', first['id'], '--pane', address).stdout)
        self.assertEqual(reused['reused_unverified'], 1)
        self.assertNotIn('generating', reused['counts'])
        cli.rpc(address, 'require("tour").state().opts.saved_reuse_unverified=false')
        opened = json.loads(self.run_cli('saved', 'open', first['id'], '--pane', address).stdout)
        cli.rpc(address, 'require("tour").state().opts.saved_reuse_unverified=true')
        self.assertEqual(opened['counts']['generating'], 1)
        self.assertEqual(opened['revision'], first['revision'])
        pending = cli.rpc(address, 'local s=require("tour").state(); local r=s.saved.active; '
                          'return {id=r.id,token=s.id,path=r.entry.path}')
        filled = json.loads(self.run_cli('--fill', pending['id'], '--pane', address, '--tour', pending['token'],
                                        data=json.dumps([dict(file=pending['path'], start=1, end=3, note='Checked RPC replacement')])).stdout)
        self.assertFalse(filled['navigate'])
        self.assertEqual(cli.rpc(address, 'return require("tour").state().stops[1].note'), 'Checked RPC replacement')
        mismatch_process = subprocess.run([str(CLI), 'saved', 'save', '--pane', address],
                                          cwd=self.root, env=dict(self.env, NVIM_APPNAME='other-profile'),
                                          capture_output=True, text=True, timeout=15)
        self.assertEqual(mismatch_process.returncode, 1)
        self.assertIn('profile/path mismatch', mismatch_process.stderr)
        # A second editor's explicit overwrite makes this editor's retained revision stale.
        self.run_cli('--pane', self.addresses[1], 'source.lua:1-3')
        self.run_cli('saved', 'save', '--pane', self.addresses[1], '--overwrite', first['id'],
                     '--revision', first['revision'], '--title', 'Concurrent update')
        conflict = self.run_cli('saved', 'save', '--pane', address, '--overwrite', first['id'], expected=1)
        self.assertIn('revision conflict', conflict.stderr)
        self.run_cli('saved', 'save', '--pane', self.addresses[1], '--overwrite', second['id'], expected=1)
        record = json.loads((Path(first['library']) / (first['id'] + '.json')).read_text())
        repo = record['repositories'][0]
        mapped = self.root / 'mapped'
        mapped.mkdir(exist_ok=True)
        (mapped / 'renamed.lua').write_text(self.source.read_text())
        old_file = record['stops'][0]['file']
        self.run_cli('saved', 'open', first['id'], '--pane', address, '--repo', repo['id'], str(mapped),
                     '--map-file', repo['id'], old_file, 'renamed.lua')
        self.assertEqual(cli.rpc(address, 'return require("tour").state().stops[1].path'), str(mapped / 'renamed.lua'))
        mismatch = cli.rpc(address, 'local ok,err=pcall(require("tour").save_saved,{library="/wrong/profile"}); return {ok,tostring(err)}')
        self.assertFalse(mismatch[0])
        self.assertIn('profile/path mismatch', mismatch[1])
        cli.rpc(address, 'require("tour").cancel()')
        cli.rpc(self.addresses[1], 'local t=require("tour"); t.stop(); t.state().stops={}')

    def test_renamed_commands_and_legacy_cli_alias(self):
        address = self.addresses[0]
        self.assertEqual(cli.rpc(address, 'return vim.fn.exists(":CodeTourExpand")'), 2)
        self.assertTrue(cli.rpc(address, 'return require("code-walkthrough") == require("code-tour") and require("tour") == require("code-tour")'))
        legacy_cli = PLUGIN.parent / 'code-walkthrough.nvim/bin/walkthrough'
        payload = [dict(file='source.lua', start=1, end=3, note='Use the renamed plugin')]
        result = subprocess.run([str(legacy_cli), '--pane', address], input=json.dumps(payload),
                                cwd=self.root, env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(cli.rpc(address, 'return require("code-tour").state().stops[1].note'), 'Use the renamed plugin')

    def test_saved_tour_uses_new_filename_with_legacy_fallback(self):
        address = self.addresses[0]
        directory = self.root / '.nvim'
        directory.mkdir(exist_ok=True)
        legacy = directory / 'walkthrough.json'
        current = directory / 'code-tour.json'
        legacy.write_text(json.dumps([dict(file='source.lua', start=1, end=3, note='Legacy saved tour')]))
        try:
            self.assertTrue(cli.rpc(address, 'return require("code-tour").load()'))
            self.assertEqual(cli.rpc(address, 'return require("code-tour").state().stops[1].note'), 'Legacy saved tour')
            current.write_text(json.dumps([dict(file='source.lua', start=1, end=3, note='New saved tour')]))
            self.assertTrue(cli.rpc(address, 'return require("code-tour").load()'))
            self.assertEqual(cli.rpc(address, 'return require("code-tour").state().stops[1].note'), 'New saved tour')
        finally:
            legacy.unlink(missing_ok=True)
            current.unlink(missing_ok=True)

    def test_ambiguous_workspace_returns_choices_and_exit_two(self):
        result = self.run_cli(data=json.dumps([dict(file='source.lua', start=1, end=3, note='Source')]), expected=2)
        self.assertEqual(len(json.loads(result.stderr)['instances']), 2)

    def test_show_append_answer_and_fill_over_real_rpc(self):
        address = self.addresses[0]
        result = self.run_cli('--pane', address, 'source.lua:1-3')
        self.assertEqual(json.loads(result.stdout)['shown'], 1)
        self.assertEqual(cli.rpc(self.addresses[1], 'return #require("tour").state().stops'), 0)
        self.run_cli('--pane', address, '--append', data=json.dumps([dict(file='source.lua', start=1, end=2, note='More')]))
        self.assertEqual(cli.rpc(address, 'return #require("tour").state().stops'), 2)
        prompt = cli.rpc(address, '''require("code-tour.conversation").deliver=function(_,_,_,_,cb) cb(true) end
            require("tour").next_snippet(-1)
            return require("tour").ask("Why addition?", "stay")''')
        self.assertIn('--answer 1.1', prompt)
        self.run_cli('--answer', '1.1', '--pane', address, data='It adds x and y.')
        self.assertEqual(cli.rpc(address, 'return require("tour").state().stops[1].thread[1].answer'), 'It adds x and y.')
        self.run_cli('--answer', '1.1', '--pane', address, data='Late duplicate', expected=1)
        request_id = cli.rpc(address, '''local id=require("tour").explain_location({uri=vim.uri_from_fname(...),
          range={start={line=0,character=0},["end"]={line=0,character=4}}}); return id''', [str(self.source)])
        payload = [dict(file='source.lua', start=1, end=3, note='Refine', parts=[
            dict(start=1, end=2, note='Inputs'), dict(start=3, end=3, note='Addition')])]
        self.run_cli('--fill', request_id, '--pane', address, data=json.dumps(payload))
        self.assertEqual(cli.rpc(address, 'return #require("tour").state().stops[1].parts'), 2)
        self.assertEqual(self.source.read_text(), 'local x = 1\nlocal y = 2\nreturn x + y\n')

    def test_review_old_and_validation_errors_are_atomic(self):
        address = self.addresses[0]
        data = [dict(file='source.lua', start=1, end=2, note='Review', old='old input\n')]
        self.run_cli('--pane', address, '--review', data=json.dumps(data))
        self.assertEqual(cli.rpc(address, 'return #require("tour").state().stops[1].removed[1].lines'), 1)
        invalid = [dict(file='source.lua', start=1, end=3, note='Invalid', parts=[dict(start=2, end=3, note='Gap')])]
        self.run_cli('--pane', address, data=json.dumps(invalid), expected=1)
        self.assertEqual(cli.rpc(address, 'return require("tour").state().stops[1].note'), 'Review')

    def test_late_answer_cannot_enter_a_replaced_tour(self):
        address = self.addresses[0]
        self.run_cli('--pane', address, 'source.lua:1-3')
        old = cli.rpc(address, 'return require("tour").state().id')
        self.run_cli('--pane', address, 'source.lua:1-3')
        cli.rpc(address, '''require("code-tour.conversation").deliver=function(_,_,_,_,cb) cb(true) end
          require("tour").ask("New tour question", "stay")''')
        self.run_cli('--answer', '1.1', '--pane', address, '--tour', old, data='Old reply', expected=1)
        self.assertIsNone(cli.rpc(address, 'return require("tour").state().stops[1].thread[1].answer'))

    def test_nested_lazy_call_fill_returns_to_caller_over_rpc(self):
        address = self.addresses[0]
        data = [dict(file='source.lua', start=1, end=3, note='Caller', parts=[
            dict(start=1, end=1, note='Call', calls=[
                dict(file='source.lua', start=2, end=3, title='Lazy helper', lazy=True)]),
            dict(start=2, end=3, note='Continue')])]
        self.run_cli('--pane', address, data=json.dumps(data))
        request_id = cli.rpc(address, '''require("code-tour.conversation").deliver=function(_,_,_,_,cb) cb(true) end
          local tour=require("tour")
          tour.next_explanation(1)
          local id=tour.expand_call()
          return id''')
        payload = [dict(file='source.lua', start=2, end=3, note='Generated helper')]
        result = self.run_cli('--fill', request_id, '--pane', address, data=json.dumps(payload))
        self.assertTrue(json.loads(result.stdout)['navigate'])
        position = cli.rpc(address, '''local tour=require("tour"); tour.next_explanation(1)
          return {tour.state().stop, tour.state().box}''')
# An optional branch still returns to the box it was opened from.
        self.assertEqual(position, [1, 2])

    def test_badge_background_is_red_in_rendered_cells_over_blue_focus(self):
        file = self.root / 'badge.lua'
        file.write_text('handlerStack.bubbleEvent(event)\n')
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
            stream.settimeout(5)
            stream.connect(self.addresses[0])
            unpacker = msgpack.Unpacker(raw=False, strict_map_key=False)
            sequence = 0

            def request(method, args):
                nonlocal sequence
                sequence += 1
                stream.sendall(msgpack.packb([0, sequence, method, args], use_bin_type=True))
                while True:
                    for response in unpacker:
                        if response[0] == 1 and response[1] == sequence:
                            self.assertIsNone(response[2], response[2])
                            return response[3]
                    unpacker.feed(stream.recv(65536))

            request('nvim_ui_attach', [100, 40, dict(rgb=True, ext_linegrid=True)])
            position = request('nvim_exec_lua', ['''local file,root=...
              local tour=require("tour")
              tour.show({{file=file,start=1,["end"]=1,note="Caller",calls={
                {file="source.lua",start=1,["end"]=3,title="bubbleEvent",note="Definition",
                  callsite={start=1,["end"]=1,symbol="handlerStack.bubbleEvent"}}
              }}},{root=root})
              vim.cmd("redraw")
              local s=tour.state()
              return vim.fn.screenpos(s.win,1,1)''', [str(file), str(self.root)]])
            cell = request('nvim__inspect_cell', [1, position['row'] - 1, position['col']])
            self.assertEqual(cell[0], 'a')
            self.assertEqual(cell[1]['background'], 0x5c3038)
            self.assertEqual(cell[1]['foreground'], 0xf0dfe2)
            request('nvim_ui_detach', [])

    def test_failed_definition_lookup_round_trip_over_rpc(self):
        address = self.addresses[0]
        file = self.root / 'lookup.lua'
        file.write_text('handlerStack.bubbleEvent(event)\nreturn true\n')
        payload = [dict(file='lookup.lua', start=1, end=2, note='Caller', parts=[
            dict(start=1, end=1, note='Dispatch event'), dict(start=2, end=2, note='Return')])]
        self.run_cli('--pane', address, data=json.dumps(payload))
        request_id = cli.rpc(address, '''local tour=require("tour")
          require("code-tour.conversation").deliver=function(_,_,prompt,_,cb)
            _G.tour_lookup_prompt=prompt; cb(true)
          end
          _G.tour_original_clients=vim.lsp.get_clients
          vim.lsp.get_clients=function() return {{offset_encoding="utf-16",
            request=function(_,_,_,cb) cb(nil,{}); return true end}} end
          tour.next_explanation(1)
          tour.expand_call()
          assert(vim.wait(1000,function() return next(tour.state().pending)~=nil end,1))
          return next(tour.state().pending)''')
        prompt = cli.rpc(address, 'return _G.tour_lookup_prompt')
        self.assertIn('Call: handlerStack.bubbleEvent', prompt)
        self.assertIn('tour: ', prompt)
        result = self.run_cli('--fill', request_id, '--pane', address,
                              data=json.dumps(dict(unresolved='Implementation is supplied by the runtime')))
        self.assertTrue(json.loads(result.stdout)['unresolved'])
        self.assertEqual(cli.rpc(address, 'return #require("tour").state().stops[1].parts'), 2)
        retry = cli.rpc(address, 'local id=require("tour").expand_call(); return id')
        result = self.run_cli('--fill', retry, '--pane', address,
                              data=json.dumps([dict(file='source.lua', start=1, end=3, note='Resolved method')]))
        self.assertTrue(json.loads(result.stdout)['navigate'])
        position = cli.rpc(address, '''vim.lsp.get_clients=_G.tour_original_clients
          local tour=require("tour"); tour.return_to_caller()
          return {tour.state().stop,tour.state().box}''')
        self.assertEqual(position, [1, 2])

    def test_selected_code_example_survives_rpc_fill(self):
        address = self.addresses[0]
        self.run_cli('--pane', address, 'source.lua:1-3')
        request_id = cli.rpc(address, '''require("code-tour.conversation").deliver=function(_,_,_,_,cb) cb(true) end
          local tour=require("tour")
          local selection=require("code-tour.selection").capture(tour.state(), {start=2,["end"]=3})
          local id=tour.explain_range(selection, "Show an example with input x = 1")
          return id''')
        payload = [dict(file='source.lua', start=1, end=1, note='Assign x'),
                   dict(file='source.lua', start=2, end=3, note='Assign y and return the sum',
                        example=dict(input='x = 1', output='y = 2', values={'2': 'y = 2'}))]
        self.run_cli('--fill', request_id, '--pane', address, data=json.dumps(payload))
        self.assertEqual(cli.rpc(address, 'return require("tour").state().stops[1].parts[2].example.values["2"]'), 'y = 2')
        self.assertEqual(cli.rpc(address, 'return require("tour").state().box'), 3)
        explanation = cli.rpc(address, 'return require("code-tour.tour-view").state().text')
        self.assertEqual(explanation, 'Assign y and return the sum')

    def test_selected_diff_survives_review_fill_with_git_base(self):
        address = self.addresses[0]
        file = self.root / 'diff.lua'
        file.write_text('local a = 1\nreturn a\n')
        for args in (['git', 'init', '--quiet'], ['git', 'add', 'diff.lua'],
                     ['git', '-c', 'user.name=Tour test', '-c', 'user.email=tour@test.invalid',
                      'commit', '--quiet', '-m', 'diff base']):
            subprocess.run(args, cwd=self.root, env=self.env, check=True, capture_output=True)
        file.write_text('local a = 2\nreturn a\n')
        self.run_cli('--pane', address, 'diff.lua:1-2')
        request_id = cli.rpc(address, '''require("code-tour.conversation").deliver=function(_,_,_,_,cb) cb(true) end
          local tour=require("tour")
          local selection=require("code-tour.selection").capture(tour.state(), {start=1,["end"]=1})
          local id=tour.explain_range(selection, "Show the diff against HEAD")
          return id''')
        data = [dict(file='diff.lua', start=1, end=2, note='Update and return a', parts=[
            dict(start=1, end=1, note='Change a to 2'), dict(start=2, end=2, note='Return a')])]
        self.run_cli('--fill', request_id, '--pane', address, '--review', '--base', 'HEAD', data=json.dumps(data))
        self.assertTrue(cli.rpc(address, 'return require("tour").state().stops[1].added[1]'))
        self.assertEqual(cli.rpc(address, 'return require("tour").state().stops[1].removed[1].lines[1]'), 'local a = 1')
        self.assertEqual(file.read_text(), 'local a = 2\nreturn a\n')


if __name__ == '__main__':
    unittest.main()
