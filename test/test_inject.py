"""Injector regressions; uses temporary resources, never the server's resources.
Run: python3 -m unittest discover -s test -p 'test_*.py' -v
"""
import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('inject', Path(__file__).parents[1] / 'tools/inject.py')
inject = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(inject)


class InjectorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.resource = self.root / 'sample'
        self.resource.mkdir()
        self.manifest = self.resource / 'fxmanifest.lua'

    def run_tool(self, *args):
        with contextlib.redirect_stdout(io.StringIO()), patch.object(inject, 'log_change'):
            inject.main(['--resources', str(self.root), *args])

    def roundtrip(self, original, directive, entry):
        self.manifest.write_bytes(original)
        self.run_tool()
        self.assertEqual(self.manifest.read_bytes(), original)
        self.run_tool('--apply')
        added = self.manifest.read_bytes()
        self.assertIn(directive.encode(), added)
        self.assertLess(added.index(directive.encode()), added.index(entry.encode()))
        self.run_tool('--apply')
        self.assertEqual(self.manifest.read_bytes(), added)
        self.run_tool('--remove', '--apply')
        self.assertEqual(self.manifest.read_bytes(), original)
        return added

    def test_normal_and_line_endings(self):
        for newline in (b'\n', b'\r\n'):
            for final in (b'', newline):
                with self.subTest(newline=newline, final=final):
                    self.roundtrip(newline.join([b"fx_version 'cerulean'", b"server_script 'main.lua'"])+final,
                                   inject.LINES['lua_server'], "server_script 'main.lua'")

    def test_compact(self):
        self.roundtrip(b"fx_version 'cerulean'; game 'gta5'; server_script 'main.lua'",
                       inject.LINES['lua_server'], "server_script 'main.lua'")

    def test_bom(self):
        added = self.roundtrip(b"\xef\xbb\xbfserver_script 'main.lua'\r\n", inject.LINES['lua_server'], "server_script 'main.lua'")
        self.assertTrue(added.startswith(b'\xef\xbb\xbf'))

    def test_keep_first(self):
        guard = b"shared_script '@guard/init.lua' -- keep first\n"
        added = self.roundtrip(guard+b"server_script 'main.lua'\n", inject.LINES['lua_shared'], "server_script 'main.lua'")
        self.assertTrue(added.startswith(guard))

    def test_multiline_keep_first(self):
        guard = b"shared_scripts {\n '@guard/init.lua'\n} -- keep first\n"
        added = self.roundtrip(guard+b"server_script 'main.lua'\n", inject.LINES['lua_shared'], "server_script 'main.lua'")
        self.assertTrue(added.startswith(guard))

    def test_shared_js(self):
        self.roundtrip(b"shared_script 'main.js'\n", inject.LINES['js_shared'], "shared_script 'main.js'")

    def test_server_js(self):
        self.roundtrip(b"server_script 'main.js'\n", inject.LINES['js'], "server_script 'main.js'")

    def test_migrate_existing_shared_js(self):
        self.manifest.write_text(inject.LINES['js']+"\nshared_script 'main.js'\n")
        self.run_tool('--apply')
        self.assertEqual(self.manifest.read_text(), inject.LINES['js_shared']+"\nshared_script 'main.js'\n")
        self.run_tool('--apply')
        self.run_tool('--remove', '--apply')
        self.assertEqual(self.manifest.read_text(), "shared_script 'main.js'\n")

    def test_migrate_late_wrapper(self):
        original = "fx_version 'cerulean'; server_script 'main.lua'\n\n"
        self.manifest.write_text(original+inject.LINES['lua_server']+'\n')
        self.run_tool('--apply')
        self.assertTrue(self.manifest.read_text().startswith(inject.LINES['lua_server']+'\n'))
        self.run_tool('--remove', '--apply')
        self.assertEqual(self.manifest.read_text(), original)

    def test_marker_in_comment_is_preserved(self):
        original = ('-- Example: '+inject.MARK+"lua\nserver_script 'main.lua'\n").encode()
        self.roundtrip(original, inject.LINES['lua_server'], "server_script 'main.lua'")

    def test_wrapper_inside_block_comment_is_preserved(self):
        original = ('--[[\n'+inject.LINES['lua_server']+"\n]]\nserver_script 'main.lua'\n").encode()
        self.roundtrip(original, inject.LINES['lua_server'], "server_script 'main.lua'")

    def test_only_keep_first_is_unchanged(self):
        original = b"server_script '@guard/init.lua' -- keep first"
        self.manifest.write_bytes(original)
        self.run_tool('--apply')
        self.assertEqual(self.manifest.read_bytes(), original)

    def test_client_only_is_unchanged(self):
        original = b"client_script 'main.lua'\n"
        self.manifest.write_bytes(original)
        self.run_tool('--apply')
        self.assertEqual(self.manifest.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
