"""T26's deliberately narrow public scaffold policy; not a general secret scanner."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
allowed = {'package:flutter/', 'package:flutter_web_plugins/',
           'app/', '../app/', '../presentation/', 'studio_', 'presentation/'}
for path in (root / 'lib').rglob('*.dart'):
    source = path.read_text()
    for imported in re.findall(r"(?:import|export) ['\"]([^'\"]+)", source):
        assert any(imported.startswith(prefix) for prefix in allowed), (path, imported)
    assert not re.search(r'Firebase|https?://|localStorage|indexedDB', source), path
for platform in ('android', 'ios', 'linux', 'macos', 'windows'):
    assert not (root / platform).exists(), platform
# These are the complete direct runtime dependencies for the inert scaffold.
pubspec = (root / 'pubspec.yaml').read_text()
section = pubspec.split('dependencies:\n', 1)[1].split('dev_dependencies:', 1)[0]
assert re.findall(r'^  ([a-z_]+):', section, re.M) == ['flutter', 'flutter_web_plugins']
build = root / 'build/web'
assert (build / 'main.dart.js').is_file(), 'Build Studio first'
worker = build / 'flutter_service_worker.js'
# Flutter 3.47 emits a zero-byte placeholder with --pwa-strategy=none.
assert not worker.exists() or worker.stat().st_size == 0, 'No active service worker allowed'
assert 'serviceWorkerSettings' not in (root / 'web/flutter_bootstrap.js').read_text()
# Reject Mobile content accidentally registered as browser assets.
assert not (build / 'assets/assets').exists(), 'Unexpected bundled content'
print('Studio boundary checks passed: SDK-only, no native platforms, no content assets or service worker.')
