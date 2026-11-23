import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

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

    def test_scenario_reads_source_and_uses_live_tour_token(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'CodeTourScenario.java'
            source.write_text('class Example { void run() {} }\n')
            target = dict(address='/scenario', instance_id='scenario', cwd=str(self.root))
            with patch.object(cli, 'choose', return_value=target), patch.object(cli, 'deliver', return_value={'started': True}) as send:
                with patch('sys.stdout') as stdout:
                    code = cli.scenario_main(['n1.r2', str(source), '--tour', 'tour-1', '--project', str(self.root)])
                self.assertEqual(code, 0)
                self.assertEqual(send.call_args.args[1:4], ('ast_scenario', [dict(box='n1.r2', source=source.read_text())], 'tour-1'))
                stdout.write.assert_called()

    def test_knowledge_budget_keeps_gists_before_optional_bodies(self):
        full = {'boxes': [{'gist': 'first', 'body': 'A' * 30}, {'gist': 'second', 'body': 'B' * 30}]}
        unbounded = cli.budget_knowledge(full, 100)
        self.assertEqual([box['body'] for box in unbounded['boxes']], ['A' * 30, 'B' * 30])
        self.assertNotIn('truncated', unbounded)
        bounded = cli.budget_knowledge(full, 26)
        self.assertTrue(bounded['truncated'])
        self.assertEqual([box['gist'] for box in bounded['boxes']], ['first', 'second'])
        self.assertIn('body', bounded['boxes'][0])
        self.assertNotIn('body', bounded['boxes'][1])

    def test_agent_integration_is_idempotent_and_reversible(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            claude = root / 'CLAUDE.md'
            claude.write_text('# Project\n\nKeep this instruction.\n')
            command = [sys.executable, str(CLI), 'agent', 'install', '--project', str(root)]
            subprocess.run(command, check=True, capture_output=True, text=True)
            installed = claude.read_text()
            self.assertIn('Keep this instruction.', installed)
            self.assertIn('code-tour impact SYMBOL', installed)
            subprocess.run(command, check=True, capture_output=True, text=True)
            self.assertEqual(claude.read_text().count('code-tour:section:start'), 1)
            subprocess.run([sys.executable, str(CLI), 'agent', 'uninstall', '--project', str(root)],
                           check=True, capture_output=True, text=True)
            self.assertEqual(claude.read_text(), '# Project\n\nKeep this instruction.\n')
            self.assertFalse((root / 'AGENTS.md').read_text().strip())

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
            source = PLUGIN / 'skills/code-tour'
            links = re.findall(r'\]\((references/[^)#]+)(?:#[^)]*)?\)', (source / 'SKILL.md').read_text())
            self.assertTrue(links)
            for discovery in ('.agents', '.codex', '.claude'):
                installed = home / discovery / 'skills/code-tour'
                for relative in set(links):
                    with self.subTest(discovery=discovery, reference=relative):
                        self.assertEqual((installed / relative).read_bytes(), (source / relative).read_bytes())
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

    def test_renamed_commands_and_module_alias(self):
        address = self.addresses[0]
        self.assertEqual(cli.rpc(address, 'return vim.fn.exists(":CodeTourExpand")'), 2)
        self.assertTrue(cli.rpc(address, 'return require("code-walkthrough") == require("code-tour") and require("tour") == require("code-tour")'))

    def test_saved_tour_uses_only_the_current_filename(self):
        address = self.addresses[0]
        directory = self.root / '.nvim'
        directory.mkdir(exist_ok=True)
        legacy = directory / 'walkthrough.json'
        current = directory / 'code-tour.json'
        legacy.write_text(json.dumps([dict(file='source.lua', start=1, end=3, note='Legacy saved tour')]))
        try:
            self.assertFalse(cli.rpc(address, 'return require("code-tour").load()'))
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

    def test_badge_fills_text_and_padding_in_rendered_cells_over_blue_focus(self):
        file = self.root / 'badge.lua'
        file.write_text('handlerStack.bubbleEvent(event)\n')
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
            stream.settimeout(5)
            stream.connect(self.addresses[0])
            buffer = b''
            sequence = 0

            def request(method, args):
                nonlocal sequence, buffer
                sequence += 1
                stream.sendall(cli.pack([0, sequence, method, args]))
                while True:
                    while buffer:
                        try:
                            response, used = cli.unpack(buffer)
                        except cli.Incomplete:
                            break
                        buffer = buffer[used:]
                        if response[0] == 1 and response[1] == sequence:
                            self.assertIsNone(response[2], response[2])
                            return response[3]
                    buffer += stream.recv(65536)

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
            colours = request('nvim_exec_lua', ['''local function hl(name) return vim.api.nvim_get_hl(0,{name=name,link=false}) end
              return {hl("CodeTourCall").bg, hl("CodeTourCall").fg, hl("CodeTourFocus").bg}''', []])
            badge_bg, badge_fg, line_bg = colours
            row = position['row'] - 1
            cells = [request('nvim__inspect_cell', [1, row, column]) for column in range(position['col'] - 2, position['col'] + 40)]
            glyphs = [cell[0] for cell in cells]
            left = glyphs.index('\ue0b6')
            # Left cap, the call text, right cap, in a row (no padding by default).
            symbol = 'handlerStack.bubbleEvent'
            self.assertEqual(''.join(glyphs[left:left + 1 + len(symbol)]), '\ue0b6' + symbol)
            right = left + 1 + len(symbol)
            self.assertEqual(glyphs[right], '\ue0b4')
            for index in range(left + 1, right):  # padding and every text cell carry the badge colour
                self.assertEqual(cells[index][1]['background'], badge_bg, glyphs[index])
            for index in range(left + 1, right):
                self.assertEqual(cells[index][1]['foreground'], badge_fg, glyphs[index])
            for index in (left, right):  # caps: badge colour over the line background
                self.assertEqual(cells[index][1]['foreground'], badge_bg)
                self.assertEqual(cells[index][1]['background'], line_bg)
            self.assertEqual(''.join(glyphs[right + 1:right + 7]), '(event')
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



def graphify_python():
    """The interpreter graphify is installed under, or None."""
    if os.environ.get('GRAPHIFY_PYTHON'):
        return os.environ['GRAPHIFY_PYTHON']
    import shutil
    launcher = shutil.which('graphify')
    if not launcher:
        return None
    first = Path(launcher).read_text(errors='replace').splitlines()[:1]
    return first[0][2:].strip() if first and first[0].startswith('#!') else None


GRAPHIFY_CHECK = r"""
import json, sys
from pathlib import Path
from graphify.build import build_from_json, build
from graphify.extract import extract
ours = json.load(open(sys.argv[1])); root = Path(sys.argv[2])
loaded = build_from_json(ours, directed=True)
theirs = extract(sorted(root.rglob('*.java')), root=root)
merged = build([theirs, ours], directed=True)
print(json.dumps(dict(
    loaded=loaded.number_of_nodes(),
    missing=[n['id'] for n in ours['nodes'] if n['id'] not in merged],
    dangling=[[e['source'], e['target']] for e in ours['links'] if e['source'] not in merged or e['target'] not in merged],
    files=sorted({n['source_file'] for n in ours['nodes']} - {n['source_file'] for n in theirs['nodes']}),
)))
"""


class CodeGraphTests(unittest.TestCase):
    """SPEC-ast-graph §15: `code-tour codegraph` over the Java fixture, headless."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name) / 'shop'
        subprocess.run(['cp', '-r', str(PLUGIN / 'tests/fixtures/java'), str(cls.root)], check=True)
        for args in (['init', '-q'], ['add', '-A']):
            subprocess.run(['git', '-C', str(cls.root), *args], check=True)
        cls.out = Path(cls.tmp.name) / 'graph.json'
        env = dict(os.environ, XDG_CACHE_HOME=str(Path(cls.tmp.name) / 'cache'))
        cls.proc = subprocess.run([sys.executable, str(CLI), 'codegraph', '--project', str(cls.root), '--out', str(cls.out)],
                                  capture_output=True, text=True, env=env, timeout=300)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_writes_node_link_json(self):
        if 'no parser' in self.proc.stderr or 'MISSING PARSER' in self.proc.stderr:
            self.skipTest('Java parser missing (verification gap)')
        self.assertEqual(self.proc.returncode, 0, self.proc.stderr)
        result = json.loads(self.proc.stdout)
        self.assertEqual(Path(result['path']), self.out)
        graph = json.loads(self.out.read_text())
        self.assertEqual(result['nodes'], len(graph['nodes']))
        ids = {n['id'] for n in graph['nodes']}
        for node in graph['nodes']:
            self.assertEqual(node['file_type'], 'code')
            self.assertRegex(node['source_location'], r'^L\d+(-\d+)?$')
        self.assertIn('java:shop.order.OrderService#checkout(Order)', ids)
        checkout = next(n for n in graph['nodes'] if n['id'] == 'java:shop.order.OrderService#checkout(Order)')
        self.assertEqual(checkout['source_location'], 'L21-39')
        for link in graph['links']:
            self.assertIn(link['source'], ids)
            self.assertIn(link['target'], ids)
            self.assertIn(link['confidence'], ('EXTRACTED', 'INFERRED', 'AMBIGUOUS'))
        calls = [l for l in graph['links'] if l['relation'] == 'calls'
                 and l['source'] == 'java:shop.order.OrderService#checkout(Order)']
        charge = next(l for l in calls if l['callsite'] == 'gateway.charge')
        self.assertEqual((charge['key'], charge['via'], charge['target']),
                         ('s7', 'dispatch', 'java:shop.payment.CardGateway#charge(Money)'))
        send = [l for l in calls if l['key'] == 's13']
        self.assertEqual(sorted(l['via'] for l in send), ['declared', 'dispatch', 'dispatch'])

    def test_loads_and_merges_with_graphify(self):
        python = graphify_python()
        if not python or subprocess.run([python, '-c', 'import graphify'], capture_output=True).returncode:
            self.skipTest('graphify not installed (verification gap)')
        self.assertEqual(self.proc.returncode, 0, self.proc.stderr)
        check = subprocess.run([python, '-I', '-c', GRAPHIFY_CHECK, str(self.out), str(self.root)],
                               capture_output=True, text=True, cwd=self.root, timeout=300)
        self.assertEqual(check.returncode, 0, check.stderr)
        report = json.loads(check.stdout.strip().splitlines()[-1])
        graph = json.loads(self.out.read_text())
        self.assertEqual(report['loaded'], len(graph['nodes']))
        self.assertEqual(report['missing'], [])
        self.assertEqual(report['dangling'], [])
        self.assertEqual(report['files'], [])


class AstDryRunTests(unittest.TestCase):
    """SPEC-ast-graph §9.1–9.2, phase 2: `code-tour ast --dry-run` prints the outline, headless."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name) / 'shop'
        subprocess.run(['cp', '-r', str(PLUGIN / 'tests/fixtures/java'), str(cls.root)], check=True)
        for args in (['init', '-q'], ['add', '-A']):
            subprocess.run(['git', '-C', str(cls.root), *args], check=True)
        # no live editor may be found: without --dry-run `ast` would drive the user's own Neovim
        cls.env = {k: v for k, v in os.environ.items() if not k.startswith(('HERDR_', 'CODEX_', 'CLAUDE_'))}
        cls.env.update(XDG_CACHE_HOME=str(Path(cls.tmp.name) / 'cache'), XDG_STATE_HOME=str(Path(cls.tmp.name) / 'state'))

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def ast(self, *args, route=None):
        if route:
            args = (*args, '--route', str(PLUGIN / 'tests/fixtures/routes' / (route + '.json')))
        return subprocess.run([sys.executable, str(CLI), 'ast', *args, '--project', str(self.root)],
                              capture_output=True, text=True, env=self.env, timeout=300)

    def skip_without_parser(self, proc):
        if 'no parser' in proc.stderr or 'MISSING PARSER' in proc.stderr:
            self.skipTest('Java parser missing (verification gap)')

    def test_outline_text(self):
        proc = self.ast('OrderService#checkout', '--dry-run', route='checkout')
        self.skip_without_parser(proc)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = proc.stdout.splitlines()
        self.assertRegex(lines[0], r'^tour \(dry run\) · normal · 6 snippets · 6 to write · 0 gaps$')
        self.assertRegex(proc.stdout, r'(?m)^n1 OrderService\.checkout\(Order\) +OrderService\.java:21-39 +deep +write: overview r1-r6$')
        self.assertIn('walk: s5 order.total → n2 [0★]', proc.stdout)
        self.assertIn('sink: s9 http.send (HttpClient)', proc.stdout)
        self.assertIn('s11 order.markPaid [9 not in the route]', proc.stdout)

    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(CLI), *args, '--project', str(self.root)],
                              capture_output=True, text=True, env=self.env, timeout=300)

    def test_analyze_and_concepts(self):
        proc = self.run_cli('analyze', 'communities', '--limit', '3')
        self.skip_without_parser(proc)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertGreaterEqual(len(json.loads(proc.stdout)['communities']), 1)
        self.assertTrue((self.root / '.code-tour/graph.json').is_file(), 'the graph is persisted')
        proc = self.run_cli('analyze', 'gods', '--limit', '2')
        self.assertEqual(len(json.loads(proc.stdout)['hubs']), 2)
        proc = self.run_cli('analyze', 'neighbors', 'OrderService#checkout')
        self.assertTrue(json.loads(proc.stdout)['callees'])
        proc = self.run_cli('concept', 'add', 'Order totalling', '--members', 'Order#total', '--summary', 'Sums the lines.')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)['id'], 'order-totalling')
        listed = json.loads(self.run_cli('concept', 'list').stdout)['concepts']
        self.assertEqual([c['name'] for c in listed], ['Order totalling'])
        self.assertTrue(json.loads(self.run_cli('concept', 'remove', 'order-totalling').stdout)['removed'])

    def test_route_flags_are_validated(self):
        proc = self.ast('OrderService#checkout', '--dry-run', '--walk', 'no arrow')
        self.assertEqual(proc.returncode, 2)
        self.assertIn("expects 'CALLER -> CALLEE'", proc.stderr)
        proc = self.ast('OrderService#checkout', '--dry-run', '--walk', 'OrderService#checkout -> Order#total',
                        '--branch', 'OrderService#checkout -> Money#format@3')
        self.skip_without_parser(proc)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('route OrderService#checkout -> Money#format: no resolved call', proc.stdout)

    def test_json_and_detail(self):
        proc = self.ast('Pipeline', '--dry-run', '--json', '--detail', 'overview', route='pipeline')
        self.skip_without_parser(proc)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        tour = json.loads(proc.stdout)
        self.assertEqual(tour['detail'], 'overview')
        self.assertEqual(tour['snippets'][0]['symbol'], 'java:shop.route.Pipeline#run(String)')
        self.assertTrue(all(not s['regions'] for s in tour['snippets']), 'overview: no child boxes')
        self.assertEqual(len(tour['gaps']), 2)
        self.assertTrue(all(r['main'] for r in tour['route'] if r['mode'] == 'walk'))

    def test_through(self):
        edges = [e for e in json.loads((PLUGIN / 'tests/fixtures/routes/pipeline.json').read_text())
                 if not e['to'].endswith('Pipeline#audit(String)')]
        route = Path(self.tmp.name) / 'no-audit.json'
        route.write_text(json.dumps(edges))
        proc = self.ast('Pipeline#run', '--dry-run', '--through', 'Pipeline#audit', '--route', str(route))
        self.skip_without_parser(proc)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('s5 audit → n4 [0★] (--through)', proc.stdout)

    def test_errors(self):
        # phase 3: without --dry-run the tour opens in an editor, and none is running here
        proc = self.ast('OrderService#checkout')
        self.assertEqual(proc.returncode, 1)
        self.assertIn('No Neovim instance', proc.stderr)
        proc = self.ast('Nowhere#run', '--dry-run')
        self.skip_without_parser(proc)
        self.assertEqual(proc.returncode, 1)
        self.assertIn('no type Nowhere', proc.stderr)

    def test_auto_lists_candidates_without_opening_a_tour(self):
        proc = self.ast('--auto', '--json')
        self.skip_without_parser(proc)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertTrue(data['auto'])
        self.assertGreater(len(data['candidates']), 0)
        self.assertTrue(all(item['symbol'] and item['score'] for item in data['candidates']))

    def test_add_can_be_the_only_entry(self):
        spec = dict(file='src/main/java/shop/catalog/Catalog.java', start=1, end=4, label='AgentCatalog')
        proc = self.ast('--add', json.dumps(spec), '--dry-run', '--json')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertEqual(data['snippets'][0]['label'], 'AgentCatalog')
        self.assertTrue(data['snippets'][0]['symbol'].startswith('agent:'))

    def test_knowledge_commands_run_headless(self):
        explain = subprocess.run([sys.executable, str(CLI), 'explain', 'OrderService#checkout', '--json',
                                  '--project', str(self.root)], capture_output=True, text=True, env=self.env, timeout=300)
        self.skip_without_parser(explain)
        self.assertEqual(explain.returncode, 0, explain.stderr)
        data = json.loads(explain.stdout)
        self.assertEqual(data['symbols'][0]['label'], 'OrderService.checkout(Order)')
        flow = subprocess.run([sys.executable, str(CLI), 'flow', 'OrderService#checkout', '--json',
                               '--project', str(self.root)], capture_output=True, text=True, env=self.env, timeout=300)
        self.assertEqual(flow.returncode, 0, flow.stderr)
        self.assertTrue(json.loads(flow.stdout)['snippets'])
        search = subprocess.run([sys.executable, str(CLI), 'search', 'OrderService', '--json',
                                 '--project', str(self.root)], capture_output=True, text=True, env=self.env, timeout=300)
        self.assertEqual(search.returncode, 0, search.stderr)
        self.assertTrue(json.loads(search.stdout)['results'])
        callers = subprocess.run([sys.executable, str(CLI), 'callers', 'DiscountPolicy#apply', '--json',
                                  '--project', str(self.root)], capture_output=True, text=True, env=self.env, timeout=300)
        self.assertEqual(callers.returncode, 0, callers.stderr)
        self.assertTrue(json.loads(callers.stdout)['callers'])
        path = subprocess.run([sys.executable, str(CLI), 'path', 'OrderService#checkout', 'Order#total', '--json',
                               '--project', str(self.root)], capture_output=True, text=True, env=self.env, timeout=300)
        self.assertEqual(path.returncode, 0, path.stderr)
        self.assertTrue(json.loads(path.stdout)['paths'])
        impact = subprocess.run([sys.executable, str(CLI), 'impact', 'DiscountPolicy#apply', '--json',
                                 '--project', str(self.root)], capture_output=True, text=True, env=self.env, timeout=300)
        self.assertEqual(impact.returncode, 0, impact.stderr)
        self.assertTrue(json.loads(impact.stdout)['callers'])

    def test_note_writeback_is_visible_to_explain(self):
        with tempfile.TemporaryDirectory() as temporary:
            markdown = Path(temporary) / 'note.md'
            markdown.write_text('## overview\nCharges the order.\n\nValidates, totals, and charges.\n')
            note = subprocess.run([sys.executable, str(CLI), 'note', 'OrderService#checkout', str(markdown),
                                   '--detail', 'normal', '--model', 'test-model', '--project', str(self.root)],
                                  capture_output=True, text=True, env=self.env, timeout=300)
            self.skip_without_parser(note)
            self.assertEqual(note.returncode, 0, note.stderr)
            self.assertEqual(json.loads(note.stdout)['count'], 1)
            explain = subprocess.run([sys.executable, str(CLI), 'explain', 'OrderService#checkout', '--json',
                                      '--project', str(self.root)], capture_output=True, text=True, env=self.env, timeout=300)
            self.assertEqual(explain.returncode, 0, explain.stderr)
            self.assertEqual(json.loads(explain.stdout)['symbols'][0]['boxes'][0]['gist'], 'Charges the order.')

    def test_store_prune_runs_headless(self):
        proc = subprocess.run([sys.executable, str(CLI), 'store', '--prune', '--project', str(self.root)],
                              capture_output=True, text=True, env=self.env, timeout=300)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('removed', json.loads(proc.stdout))


class PythonAstCliTests(unittest.TestCase):
    def test_opt_in_backend_resolves_project_calls_and_entries_headlessly(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / 'checkout'
            shutil.copytree(PLUGIN / 'tests/fixtures/python', root)
            for args in (['init', '-q'], ['add', '-A']):
                subprocess.run(['git', '-C', str(root), *args], check=True)
            env = dict(os.environ, CODE_TOUR_AST_LANGUAGES='java,python',
                       XDG_CACHE_HOME=str(base / 'cache'), XDG_STATE_HOME=str(base / 'state'))

            def run(*args):
                proc = subprocess.run([sys.executable, str(CLI), *args, '--project', str(root), '--json'],
                                      capture_output=True, text=True, env=env, timeout=300)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                return json.loads(proc.stdout)

            tour = run('ast', 'python:checkout.pipeline.handle', '--dry-run')
            if tour.get('fallback') and 'no parser for python' in tour.get('reason', ''):
                self.skipTest('Python parser missing (verification gap)')
            self.assertFalse(tour.get('fallback'), tour)
            entry = tour['snippets'][0]
            self.assertEqual(entry['symbol'], 'python:checkout.pipeline.handle')
            self.assertEqual(entry['file'], 'src/checkout/pipeline.py')
            sites = {site['text']: site for site in entry['sites']}
            self.assertEqual((sites['normalize']['target'], sites['normalize']['via']),
                             ('python:checkout.words.clean', 'import'))
            self.assertEqual(sites['output.format_payload']['target'],
                             'python:checkout.pipeline.Output.format_payload')

            callers = run('callers', 'checkout.words.clean')['callers']
            self.assertEqual([(edge['source'], edge['callsite'], edge['confidence']) for edge in callers],
                             [('python:checkout.pipeline.handle', 'normalize', 'EXTRACTED')])
            entries = run('ast', '--auto')['candidates']
            self.assertEqual([entry['symbol'] for entry in entries[:2]],
                             ['python:checkout.pipeline.$main', 'python:checkout.pipeline.view'])


class AstTourTests(unittest.TestCase):
    """SPEC-ast-graph §9.1–9.4, §10, §16, phase 3: `code-tour ast` against a live editor socket,
    Markdown and JSON `--fill`, and `code-tour adjust --detail`."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='code-tour-ast-')
        base = Path(cls.tmp.name)
        cls.root = base / 'shop'
        subprocess.run(['cp', '-r', str(PLUGIN / 'tests/fixtures/java'), str(cls.root)], check=True)
        for args in (['init', '-q'], ['add', '-A']):
            subprocess.run(['git', '-C', str(cls.root), *args], check=True)
        cls.env = {k: v for k, v in os.environ.items() if not k.startswith(('HERDR_', 'CODEX_', 'CLAUDE_'))}
        cls.env.update(XDG_STATE_HOME=str(base / 'state'), XDG_CACHE_HOME=str(base / 'cache'),
                       XDG_DATA_HOME=str(base / 'data'))
        parsers = os.environ.get('CODE_TOUR_PARSER_RUNTIME') or str(Path.home() / '.local/share/nvim/site')
        cls.address = str(base / 'editor.sock')
        # the conversation is stubbed: requests the editor sends (e.g. after a detail change) go nowhere
        setup = ('lua vim.opt.rtp:prepend(' + json.dumps(str(PLUGIN)) + '); vim.opt.rtp:append(' + json.dumps(parsers)
                 + '); require("code-tour.conversation").deliver = function(_, _, _, _, cb) cb(true) end'
                 + '; require("tour").setup({ keys = false, smooth_scroll = false })')
        cls.process = subprocess.Popen(['nvim', '--clean', '--headless', '-n', '-i', 'NONE', '--listen', cls.address,
                                        '-c', setup], cwd=cls.root, env=cls.env, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.PIPE)
        deadline = time.monotonic() + 10
        while True:
            try:
                cli.inspect(cls.address)
                break
            except (OSError, RuntimeError):
                if cls.process.poll() is not None:
                    raise RuntimeError(cls.process.stderr.read().decode())
                if time.monotonic() > deadline:
                    raise RuntimeError('Test editor did not start')
                time.sleep(0.05)
        cls.parser = cli.rpc(cls.address, 'return require("code-tour.ast.index").parser_available("java")')

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        cls.process.wait(timeout=5)
        cls.process.stderr.close()
        cls.tmp.cleanup()

    def setUp(self):
        if not self.parser:
            self.skipTest('Java parser missing (verification gap)')

    def run_cli(self, *args, data='', expected=0):
        proc = subprocess.run([sys.executable, str(CLI), *args], input=data, capture_output=True, text=True,
                              cwd=self.root, env=self.env, timeout=300)
        self.assertEqual(proc.returncode, expected, proc.stdout + proc.stderr)
        return proc

    def start(self):
        """Open the checkout tour; returns the outline text and its tour token."""
        proc = self.run_cli('ast', 'OrderService#checkout', '--pane', self.address, '--force',
                            '--route', str(PLUGIN / 'tests/fixtures/routes/checkout.json'))
        match = re.match(r'tour (\S+) · ', proc.stdout)
        self.assertTrue(match, proc.stdout)
        return proc.stdout, match.group(1)

    @staticmethod
    def fill_argv(outline, n):
        """The outline header's fill command for snippet n, as argv."""
        return shlex.split(outline.splitlines()[0].split(' · fill: ', 1)[1].replace('<n>', n))

    def note(self, anchor):
        return cli.rpc(self.address, """local anchor = ...
            for _, stop in ipairs(require("tour").state().stops) do
              for _, box in ipairs(require("code-tour.stops").boxes(stop)) do
                if box.anchor == anchor then return box.note end
              end
            end""", [anchor])

    def test_ast_prints_outline_with_token_and_fill_command(self):
        outline, token = self.start()
        header = outline.splitlines()[0]
        self.assertRegex(header, r'^tour \S+ · normal · 6 snippets · 6 to write · 0 gaps · fill: ')
        argv = self.fill_argv(outline, '<n>')
        self.assertEqual(Path(argv[0]).resolve(), CLI.resolve())
        self.assertEqual(argv[1:], ['--fill', '<n>', '--pane', self.address, '--tour', token, '--detail', 'normal'])
        self.assertRegex(outline, r'(?m)^n1 OrderService\.checkout\(Order\) +OrderService\.java:21-39 +deep +write: overview r1-r6$')
        self.assertIn('walk: s5 order.total → n2 [0★]', outline)
        self.assertEqual(cli.rpc(self.address, 'return require("tour").state().id'), token)
        self.assertEqual(self.note('n1.r2'), 'Being written…')

    def test_brief_reads_the_live_snippet(self):
        _, token = self.start()
        proc = self.run_cli('brief', 'n1', '--tour', token, '--pane', self.address, '--json')
        data = json.loads(proc.stdout)
        self.assertIn('brief', data)
        self.assertIn('OrderService.checkout(Order)', data['brief'])

    def test_second_ast_is_refused_without_force(self):
        _, token = self.start()
        proc = self.run_cli('ast', 'OrderService#checkout', '--pane', self.address, expected=1)
        self.assertIn('--force', proc.stderr)
        self.assertEqual(cli.rpc(self.address, 'return require("tour").state().id'), token)
        self.run_cli('ast', 'OrderService#checkout', '--pane', self.address, '--force')
        self.assertNotEqual(cli.rpc(self.address, 'return require("tour").state().id'), token)

    def test_bad_fill_id_is_named_before_the_editor_is_asked(self):
        _, token = self.start()
        proc = self.run_cli('--fill', '13', '--tour', token, '--pane', self.address, data='## overview\nx\n', expected=2)
        self.assertIn('fill ids look like n13', proc.stderr)

    def test_markdown_flag_never_parses_json(self):
        outline, token = self.start()
        text = '[a link-first](x) paragraph.\n'
        proc = self.run_cli('--fill', 'n1', '--tour', token, '--pane', self.address, '--markdown', data='## overview\n' + text)
        self.assertEqual(json.loads(proc.stdout)['boxes'], ['n1 overview'])
        proc = self.run_cli('--fill', 'n1', '--tour', token, '--pane', self.address, data='{broken', expected=1)
        self.assertIn('--markdown', proc.stderr)

    def test_partial_fill_warns(self):
        _, token = self.start()
        proc = self.run_cli('--fill', 'n1', '--tour', token, '--pane', self.address, '--markdown', data='## overview\nOnly this.\n')
        self.assertTrue(json.loads(proc.stdout)['partial'])
        self.assertIn('warning: Partial fill', proc.stderr)

    def test_outline_names_the_wrapper_it_was_started_through(self):
        wrapper = PLUGIN / 'skills/code-tour/scripts/code-tour.py'
        env = dict(self.env, CODE_TOUR_CLI=str(CLI))
        proc = subprocess.run([sys.executable, str(wrapper), 'ast', 'OrderService#checkout', '--pane', self.address, '--force'],
                              capture_output=True, text=True, cwd=self.root, env=env, timeout=300)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn(str(wrapper), proc.stdout)
        self.assertNotIn(str(CLI), proc.stdout)

    def test_markdown_and_json_fills(self):
        outline, token = self.start()
        markdown = ('## overview\nCharge the order.\n\nValidate, total, charge, receipt.\n\n'
                    '## r2\nCompute the total.\n\nRecomputed from the lines.\n\n## n2\nSum the lines.\n')
        position = 'local s = require("tour").state(); return {s.stop, s.box}'
        before = cli.rpc(self.address, position)
        # the fill command exactly as the outline prints it, Markdown on stdin
        proc = self.run_cli(*self.fill_argv(outline, 'n1')[1:], data=markdown)
        result = json.loads(proc.stdout)
        self.assertEqual(result['boxes'], ['n1 overview', 'n1 r2', 'n2 overview'])
        self.assertEqual(result['count'], 3)
        self.assertFalse(result['navigate'])
        self.assertEqual(result['ready'], {'n1': False, 'n2': False})
        self.assertIn('n1 r3', result['remaining'])
        self.assertEqual(self.note('n1.r2'), 'Compute the total.\n\nRecomputed from the lines.')
        self.assertEqual(self.note('n1.r3'), 'Being written…')
        self.assertEqual(cli.rpc(self.address, position), before, 'a fill never moves the reader')
        # JSON on stdin, with the bare --fill form
        proc = self.run_cli('--fill', 'n1', '--tour', token, '--pane', self.address,
                            data=json.dumps({'r3': {'gist': 'Apply discounts.', 'body': 'The policy decides.'}}))
        self.assertEqual(json.loads(proc.stdout)['boxes'], ['n1 r3'])
        self.assertEqual(self.note('n1.r3'), 'Apply discounts.\n\nThe policy decides.')
        # a fill at another level is stored without changing what normal shows
        self.run_cli('--fill', 'n1', '--tour', token, '--pane', self.address, '--detail', 'detailed',
                     data='## r3\nApply discounts.\n\nEvery rule in turn.\n')
        self.assertEqual(self.note('n1.r3'), 'Apply discounts.\n\nThe policy decides.')
        # errors: an unknown box, text before the first heading, a replaced tour
        proc = self.run_cli('--fill', 'n1', '--tour', token, '--pane', self.address, data='## r99\nNo such box.\n',
                            expected=1)
        self.assertIn('Unknown box n1 r99 at normal detail (n1 has overview r1 r2 r3 r4 r5 r6)', proc.stderr)
        proc = self.run_cli('--fill', 'n1', '--tour', token, '--pane', self.address, data='Hello.\n\n## r1\nG.\n',
                            expected=1)
        self.assertIn('Text before the first section', proc.stderr)
        _, newer = self.start()
        self.assertNotEqual(newer, token)
        proc = self.run_cli('--fill', 'n1', '--tour', token, '--pane', self.address, data='## r1\nG.\n', expected=1)
        self.assertIn('replaced tour', proc.stderr)

    def test_adjust_detail_returns_outline_at_detailed(self):
        _, token = self.start()
        proc = self.run_cli('adjust', '--tour', token, '--detail', 'detailed', '--pane', self.address)
        header = proc.stdout.splitlines()[0]
        self.assertRegex(header, r'^tour ' + re.escape(token) + r' · detailed · \d+ snippets · ')
        self.assertIn('--detail detailed', header)
        self.assertEqual(cli.rpc(self.address, 'return require("tour").state().ast.detail'), 'detailed')
        proc = self.run_cli('adjust', '--tour', token, '--detail', 'normal', '--pane', self.address, '--json')
        result = json.loads(proc.stdout)
        self.assertEqual((result['detail'], result['tour']), ('normal', token))
        self.assertIn(' · normal · ', result['outline'].splitlines()[0])

    def test_live_structural_adjustment_is_atomic_and_reopens_from_recipe(self):
        _, token = self.start()
        adjust = ('adjust', '--tour', token, '--pane', self.address, '--json')
        state = """local s = require("tour").state()
            local sn = s.ast.snippets.n1
            local sites, regions = {}, {}
            for _, site in ipairs(sn.sites) do
              if site.site == "s5" or site.site == "s6" then
                sites[site.site] = {site.rating, site.region, site.main == true, site.to or false}
              end
            end
            for _, region in ipairs(sn.regions) do regions[region.id] = region.lines end
            return {tour = s.id, recipe = s.ast.recipe.id, sites = sites, regions = regions}"""
        before = cli.rpc(self.address, state)
        failure = self.run_cli(*adjust, '--rate', 'n1.s5=2', '--merge', 'n1.r2,n1.r99', expected=1)
        self.assertIn('invalid --merge', failure.stderr)
        self.assertEqual(cli.rpc(self.address, state), before)

        result = json.loads(self.run_cli(*adjust, '--rate', 'n1.s5=2', '--split', 'n1.r1@stmt2').stdout)
        after = cli.rpc(self.address, state)
        self.assertEqual(after['tour'], result['tour'])
        self.assertNotEqual(after['tour'], token)
        self.assertEqual(after['recipe'], before['recipe'])
        self.assertEqual(after['sites']['s5'][:3], [2, 'r2', False])
        self.assertEqual(after['sites']['s6'], [0, 'r2', True, before['sites']['s6'][3]])
        self.assertEqual(after['regions']['r2'], [29, 30])
        self.assertIn([21, 24], after['regions'].values())
        self.assertIn([25, 28], after['regions'].values())
        stale = self.run_cli('--fill', 'n1', '--tour', token, '--pane', self.address,
                             data='## r2\nWritten against the former region.\n', expected=1)
        self.assertIn('replaced tour', stale.stderr)

        cli.rpc(self.address, 'require("tour").ast_history(...)', [after['recipe']])
        reopened = cli.rpc(self.address, state)
        self.assertEqual(reopened['regions'], after['regions'])
        self.assertEqual({key: site[:3] for key, site in reopened['sites'].items()},
                         {key: site[:3] for key, site in after['sites'].items()})

    def test_codegraph_uses_unsaved_buffers_only_when_given_a_pane(self):
        source = 'src/main/java/shop/order/OrderService.java'
        edit = """local path, replacement, modified = ...
            local buf = vim.fn.bufadd(path)
            vim.fn.bufload(buf)
            vim.api.nvim_buf_set_lines(buf, 28, 29, false, {replacement})
            vim.bo[buf].modified = modified"""
        original = (self.root / source).read_text().splitlines()[28]
        changed = original.replace('order.total()', 'discounts.apply(order, order.total())')
        self.assertNotEqual(original, changed)
        cli.rpc(self.address, edit, [str(self.root / source), changed, True])
        try:
            with tempfile.TemporaryDirectory() as output:
                def apply_sites(*args):
                    path = Path(output) / 'codegraph.json'
                    self.run_cli('codegraph', '--out', str(path), *args)
                    graph = json.loads(path.read_text())
                    return [edge['source_location'] for edge in graph['links']
                            if edge['relation'] == 'calls'
                            and edge['source'] == 'java:shop.order.OrderService#checkout(Order)'
                            and edge.get('callsite') == 'discounts.apply']

                self.assertCountEqual(apply_sites('--pane', self.address), ['L29', 'L30'])
                self.assertEqual(apply_sites(), ['L30'])
        finally:
            cli.rpc(self.address, edit, [str(self.root / source), original, False])

    def test_dispatch_edge_fill_is_target_specific_and_survives_reopening(self):
        _, token = self.start()
        fill = ('--fill', 'n1', '--tour', token, '--pane', self.address)
        ambiguous = self.run_cli(*fill, data='## edge s13\nExplain the notifier.\n', expected=1)
        self.assertIn('Ambiguous edge n1.s13', ambiguous.stderr)

        email = 'java:shop.notify.EmailNotifier#send(String,String)'
        sms = 'java:shop.notify.SmsNotifier#send(String,String)'
        explanation = 'Sends the receipt over email.'
        key = f'edge s13>{email}'
        result = json.loads(self.run_cli(*fill, data=json.dumps({key: {'gist': explanation}})).stdout)
        self.assertEqual(result['edges'], [f'n1 {key}'])
        self.assertEqual(result['count'], 0)
        notes = """local notes = {}
            for _, site in ipairs(require("tour").state().ast.snippets.n1.sites) do
              if site.site == "s13" then notes[site.target] = site.why end
            end
            return notes"""
        self.assertEqual(cli.rpc(self.address, notes), {email: explanation, sms: 'detail'})

        _, reopened = self.start()
        self.assertNotEqual(reopened, token)
        self.assertEqual(cli.rpc(self.address, notes), {email: explanation, sms: 'detail'})


if __name__ == '__main__':
    unittest.main()
