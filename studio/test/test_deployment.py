"""Static packaging regression tests; no credentials or remote services."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/prepare_deployment.py'
spec = importlib.util.spec_from_file_location('studio_packaging', SCRIPT)
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'web'
        self.source.mkdir()
        self.output = self.root / 'pages'
        self.commit = 'a' * 40
        (self.source / 'index.html').write_text('<head><base href="/"></head><script src="flutter_bootstrap.js"></script>')
        (self.source / 'flutter_bootstrap.js').write_text("const studioConfig = {fontFallbackBaseUrl: '/font-fallbacks/'}; _flutter.loader.load({ callback: () => initializeEngine(studioConfig) });")
        (self.source / 'main.dart.js').write_text('compiled app fixture')
        (self.source / 'main.dart.js.map').write_text('excluded source map')
        (self.source / 'flutter_service_worker.js').write_text('')
        (self.source / 'assets').mkdir()
        (self.source / 'assets/test.svg').write_text('<svg/>')

    def test_versioned_assets_and_revalidating_shell(self):
        packaging.prepare(self.source, self.output, self.commit)
        release = self.output / 'releases' / self.commit
        self.assertEqual((release / 'assets/test.svg').read_text(), '<svg/>')
        bootstrap = (release / 'flutter_bootstrap.js').read_text()
        self.assertIn('initializeEngine(studioConfig)', bootstrap)
        self.assertIn(f'"assetBase": "/releases/{self.commit}/"', bootstrap)
        self.assertIn(f'/releases/{self.commit}/flutter_bootstrap.js', (self.output / 'index.html').read_text())
        self.assertEqual(json.loads((self.output / 'release.json').read_text())['commit'], self.commit)
        self.assertFalse((self.output / '404.html').exists())
        self.assertFalse((release / 'flutter_service_worker.js').exists())
        self.assertFalse((release / 'main.dart.js.map').exists())
        headers = (self.output / '_headers').read_text()
        self.assertIn('/releases/*\n  Cache-Control: public, max-age=31536000, immutable', headers)
        self.assertIn('/release.json\n  Cache-Control: public, max-age=0, must-revalidate', headers)
        self.assertIn("connect-src 'self'", headers)

    def test_invalid_commit_does_not_create_output(self):
        for sha in ('main', '../escape', 'a' * 7, 'x' * 40):
            with self.subTest(sha=sha), self.assertRaises(ValueError):
                packaging.prepare(self.source, self.output, sha)
            self.assertFalse(self.output.exists())

    def test_existing_release_is_preserved(self):
        self.output.mkdir()
        marker = self.output / 'keep'
        marker.write_text('existing release')
        with self.assertRaises(ValueError):
            packaging.prepare(self.source, self.output, self.commit)
        self.assertEqual(marker.read_text(), 'existing release')

    def test_active_worker_and_backend_files_are_rejected(self):
        for name in ('_worker.js', 'functions', '404.html', 'flutter_service_worker.js'):
            with self.subTest(name=name):
                path = self.source / name
                path.write_text('not static preview')
                with self.assertRaises(ValueError):
                    packaging.prepare(self.source, self.output, self.commit)
                path.unlink()
                self.assertFalse(self.output.exists())

    def test_changed_bootstrap_fails_before_packaging(self):
        (self.source / 'flutter_bootstrap.js').write_text('changed loader')
        with self.assertRaises(ValueError):
            packaging.prepare(self.source, self.output, self.commit)
        self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main()
