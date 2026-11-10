"""Static packaging regression tests; no credentials or remote services."""
import importlib.util
import json
from pathlib import Path
import tempfile
import sys
import subprocess
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/prepare_deployment.py'
sys.path.insert(0, str(SCRIPT.parent))
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
        self.assertFalse((self.output / 'studio-shell-worker.js').exists())
        self.assertNotIn('studio-shell-register', (self.output / 'index.html').read_text())
        cleanup = self.output / 'studio-shell-cleanup.js'
        self.assertTrue(cleanup.is_file())
        self.assertIn('src="/studio-shell-cleanup.js"', (self.output / 'index.html').read_text())
        result = subprocess.run(['node', str(SCRIPT.parent / 'static_shell_test.cjs'), str(cleanup), 'cleanup'],
                                check=True, text=True, capture_output=True)
        self.assertIn('only own worker/static cache removed', result.stdout)


    def test_auth_csp_is_precise_and_server_secrets_are_rejected(self):
        config = self.root / 'public.json'
        config.write_text(json.dumps({
            'STUDIO_FIREBASE_API_KEY': 'public-client-key',
            'STUDIO_FIREBASE_APP_ID': 'app',
            'STUDIO_FIREBASE_PROJECT_ID': 'project',
            'STUDIO_FIREBASE_AUTH_DOMAIN': 'project.firebaseapp.com',
            'STUDIO_FIREBASE_MESSAGING_SENDER_ID': '123',
            'STUDIO_API_BASE_URL': 'https://private-api.example.com',
        }))
        packaging.prepare(self.source, self.output, self.commit, config)
        headers = (self.output / '_headers').read_text()
        self.assertIn('frame-src https://project.firebaseapp.com;', headers)
        self.assertIn('https://apis.google.com/js/gen_204 ', headers)
        self.assertIn('https://private-api.example.com', headers)
        self.assertNotIn('https://*.googleapis.com', headers)
        script_policy = headers.split('script-src ', 1)[1].split(';', 1)[0]
        self.assertNotIn("'unsafe-inline'", script_policy)
        self.assertEqual(script_policy.count("'sha256-"), 4)
        # CSP hashes are reviewed for the locked FlutterFire import wrappers.
        lock = (SCRIPT.parents[1] / 'pubspec.lock').read_text()
        core_web = lock.split('  firebase_core_web:', 1)[1].split('  flutter:', 1)[0]
        self.assertIn('version: "4.1.0"', core_web)
        data = json.loads(config.read_text())
        data['private_key'] = 'must-never-be-compiled'
        config.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            packaging.prepare(self.source, self.root / 'bad-pages', self.commit, config)
        self.assertFalse((self.root / 'bad-pages').exists())

    def test_offline_shell_opt_in_has_exact_public_allowlist_and_never_caches_private_traffic(self):
        config = self.root / 'public.json'
        config.write_text(json.dumps({
            'STUDIO_FIREBASE_API_KEY': 'public-client-key',
            'STUDIO_FIREBASE_APP_ID': 'app',
            'STUDIO_FIREBASE_PROJECT_ID': 'project',
            'STUDIO_FIREBASE_AUTH_DOMAIN': 'project.firebaseapp.com',
            'STUDIO_FIREBASE_MESSAGING_SENDER_ID': '123',
            'STUDIO_API_BASE_URL': 'https://private-api.example.com',
        }))
        packaging.prepare(self.source, self.output, self.commit, config)
        worker = self.output / 'studio-shell-worker.js'
        self.assertTrue(worker.is_file())
        self.assertIn('src="/studio-shell-register.js"', (self.output / 'index.html').read_text())
        source = worker.read_text()
        self.assertIn('biguess-studio-shell-' + self.commit, source)
        manifest = json.loads(source.split('const STATIC = new Set(', 1)[1].split(');', 1)[0])
        self.assertEqual(set(manifest), {'/index.html', '/studio-shell-register.js',
            f'/releases/{self.commit}/main.dart.js', f'/releases/{self.commit}/flutter_bootstrap.js',
            f'/releases/{self.commit}/assets/test.svg'})
        self.assertNotIn('private-api.example.com', source)
        result = subprocess.run(['node', str(SCRIPT.parent / 'static_shell_test.cjs'), str(worker)],
                                check=True, text=True, capture_output=True)
        self.assertIn('private/auth/API/query traffic never intercepted or cached', result.stdout)

    def test_auth_only_release_keeps_service_workers_disabled(self):
        config = self.root / 'public.json'
        config.write_text(json.dumps({
            'STUDIO_FIREBASE_API_KEY': 'public-client-key',
            'STUDIO_FIREBASE_APP_ID': 'app',
            'STUDIO_FIREBASE_PROJECT_ID': 'project',
            'STUDIO_FIREBASE_AUTH_DOMAIN': 'project.firebaseapp.com',
            'STUDIO_FIREBASE_MESSAGING_SENDER_ID': '123',
            'STUDIO_API_BASE_URL': '',
        }))
        packaging.prepare(self.source, self.output, self.commit, config)
        self.assertFalse((self.output / 'studio-shell-worker.js').exists())

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
