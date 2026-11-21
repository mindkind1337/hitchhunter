"""inject.py --verify: finds every residue, and says NO RESIDUE only when nothing is left.
Uses temporary folders only. Run: python3 -m unittest discover -s test -p 'test_*.py' -v
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


class VerifyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.server = base / 'server'                 # server.cfg, cache/ live here
        self.root = self.server / 'resources'         # resources/<res>/fxmanifest.lua
        self.tool = base / 'tool'                     # stands for the hitchhunter folder (logs/inject.log)
        (self.root / 'sample').mkdir(parents=True)
        self.tool.mkdir()
        self.manifest = self.root / 'sample' / 'fxmanifest.lua'
        self.original = b"fx_version 'cerulean'\r\nclient_script 'c.lua'\r\nserver_script 'main.lua'\r\n"
        self.manifest.write_bytes(self.original)
        (self.server / 'server.cfg').write_text('ensure sample\n')
        self.patch = patch.object(inject, 'SELF_DIR', str(self.tool))
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def tool_run(self, *args):
        with contextlib.redirect_stdout(io.StringIO()):
            inject.main(['--resources', str(self.root), *args])

    def verify(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = inject.verify(str(self.root), str(self.server))
        return code, out.getvalue()

    def test_clean_after_remove(self):
        self.tool_run('--apply')
        self.assertNotEqual(self.manifest.read_bytes(), self.original)
        self.tool_run('--remove', '--apply')
        code, out = self.verify()
        self.assertEqual(code, 0, out)
        self.assertIn('byte-identical to before hitchhunter: 1', out)
        self.assertIn('NO RESIDUE', out)

    def test_line_left(self):
        self.tool_run('--apply')
        code, out = self.verify()
        self.assertEqual(code, 1)
        self.assertIn('still load the wrapper', out)
        self.assertIn('sample', out)

    def test_config_line_left(self):
        self.tool_run('--apply')
        self.tool_run('--remove', '--apply')
        (self.server / 'server.cfg').write_text('ensure sample\nensure %s\n# ensure %s (a comment is fine)\n'
                                                % (inject.NAME, inject.NAME))
        code, out = self.verify()
        self.assertEqual(code, 1)
        self.assertIn('server.cfg:2', out)
        self.assertNotIn('server.cfg:3', out)

    def test_cache_left(self):
        self.tool_run('--apply')
        self.tool_run('--remove', '--apply')
        (self.server / 'cache' / 'files' / inject.NAME).mkdir(parents=True)
        code, out = self.verify()
        self.assertEqual(code, 1)
        self.assertIn("FXServer's cache", out)

    def test_updated_manifest_is_not_a_residue(self):
        self.tool_run('--apply')
        self.tool_run('--remove', '--apply')
        self.manifest.write_bytes(self.original + b"server_script 'new.lua'\r\n")  # a vendor update since
        code, out = self.verify()
        self.assertEqual(code, 0, out)
        self.assertIn('different from before hitchhunter: 1', out)


if __name__ == '__main__':
    unittest.main()
