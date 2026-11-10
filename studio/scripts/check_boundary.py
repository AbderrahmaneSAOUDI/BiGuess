"""Studio Web dependency and bundled-content policy; not a general secret scanner."""
from pathlib import Path
import re
from xml.etree import ElementTree

root = Path(__file__).resolve().parents[1]
allowed = {'package:flutter/', 'package:flutter_web_plugins/', 'package:flutter_svg/',
           'package:firebase_core/', 'package:firebase_auth/', 'package:http/',
           'dart:async', 'dart:convert', 'app/', '../app/', '../presentation/',
           '../auth/', 'auth/', 'studio_', 'presentation/', '../data/', 'data/',
           'dataset_', 'indexed_db_', 'network_', 'offline_access_',
           'dart:js_interop', 'package:idb_shim/', 'package:web/'}
for path in (root / 'lib').rglob('*.dart'):
    source = path.read_text()
    for imported in re.findall(r"(?:import|export) ['\"]([^'\"]+)", source):
        assert any(imported.startswith(prefix) for prefix in allowed), (path, imported)
    assert not re.search(r'localStorage|indexedDB|BEGIN PRIVATE KEY|service_account', source), path
for platform in ('android', 'ios', 'linux', 'macos', 'windows'):
    assert not (root / platform).exists(), platform
# Reviewed Web adapters only; no Mobile/native content dependencies.
pubspec = (root / 'pubspec.yaml').read_text()
section = pubspec.split('dependencies:\n', 1)[1].split('dev_dependencies:', 1)[0]
assert set(re.findall(r'^  ([a-z_]+):', section, re.M)) == {
    'flutter', 'flutter_web_plugins', 'flutter_svg', 'firebase_core', 'firebase_auth', 'http',
    'idb_shim', 'web'}
build = root / 'build/web'
assert (build / 'main.dart.js').is_file(), 'Build Studio first'
worker = build / 'flutter_service_worker.js'
# Flutter 3.47 emits a zero-byte placeholder with --pwa-strategy=none.
assert not worker.exists() or worker.stat().st_size == 0, 'No active service worker allowed'
assert 'serviceWorkerSettings' not in (root / 'web/flutter_bootstrap.js').read_text()
# Only the approved brand logo and nine current UI icons may be bundled.
media = build / 'assets/assets'
media_files = {p.relative_to(media).as_posix() for p in media.rglob('*') if p.is_file()}
expected_icons = {'dashboard', 'topic', 'pack', 'card', 'profile', 'signin', 'menu', 'error', 'offline'}
expected_media = {'brand/biguess_logo.webp'} | {f'icons/{name}.svg' for name in expected_icons}
assert media_files == expected_media, ('Unexpected bundled content', media_files)
# SVG media must remain self-contained and cannot embed browser code or requests.
for name in expected_icons:
    svg = ElementTree.parse(media / f'icons/{name}.svg')
    for element in svg.iter():
        assert element.tag.split('}')[-1] not in {'script', 'foreignObject', 'image', 'use'}, name
        assert not any('href' in key for key in element.attrib), name
assert 'SvgPicture.network' not in '\n'.join(p.read_text() for p in (root / 'lib').rglob('*.dart'))
print('Studio boundary checks passed: approved SVG renderer, no native platforms, logo and nine icons only, no content assets or active service worker.')
