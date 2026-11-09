"""Package a verified Flutter release for static Cloudflare Pages hosting."""
import argparse
import json
from pathlib import Path
import re
import shutil

from public_config import api_origin, read_config

STUDIO = Path(__file__).resolve().parents[1]

SECURITY_HEADERS = """/*
  X-Content-Type-Options: nosniff
  X-Frame-Options: DENY
  Referrer-Policy: no-referrer
  Permissions-Policy: camera=(), microphone=(), geolocation=()
  Strict-Transport-Security: max-age=31536000
  Content-Security-Policy: default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; worker-src 'self' blob:; object-src 'none'; base-uri 'self'; frame-ancestors 'none'

/releases/*
  Cache-Control: public, max-age=31536000, immutable
"""


# Exact FlutterFire 4.1.0 / Firebase JS 13.1.0 import wrappers (Trusted Types
# and fallback variants). Review these when upgrading firebase_core_web; the
# browser smoke test exercises the actual SDK under this CSP. No unsafe-inline.
FIREBASE_SCRIPT_HASHES = " ".join("'sha256-" + value + "'" for value in (
    'YYaa/Ai2XuluQa6sbDZmBFePjXaJErauT33uzHZRB1Y=',
    'lxY7MwgY05//x5PJru5QZIF5G3LSEYRi/NpG8F32UmE=',
    'YE4XeMtzbmXoK0iniV4w5yeEvANP61G11Z0qhaAcoHU=',
    'E5pQKGuCE4yyzi3hBHqfnUZ9xuaXZ4NGzdrGhm0zDsk=',
))


def prepare(source: Path, destination: Path, commit: str, public_config: Path | None = None) -> None:
    config = read_config(public_config)
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('A full lowercase Git commit SHA is required')
    if destination.exists():
        raise ValueError('Use a new output directory; existing releases are never overwritten')
    if source.resolve() in destination.resolve().parents or destination.resolve() in source.resolve().parents:
        raise ValueError('Input and output directories must be separate')
    for forbidden in ('_worker.js', 'functions', '404.html'):
        if (source / forbidden).exists():
            raise ValueError(f'Unexpected non-SPA/static input: {forbidden}')
    worker = source / 'flutter_service_worker.js'
    if worker.exists() and worker.stat().st_size:
        raise ValueError('Service workers are disabled for the public preview')
    html = (source / 'index.html').read_text()
    bootstrap = (source / 'flutter_bootstrap.js').read_text()
    if '<base href="/">' not in html or html.count('src="flutter_bootstrap.js"') != 1:
        raise ValueError('Expected root-hosted Flutter index.html')
    marker = "const studioConfig = {fontFallbackBaseUrl: '/font-fallbacks/'};"
    if bootstrap.count(marker) != 1 or bootstrap.count('initializeEngine(studioConfig)') != 1:
        raise ValueError('Unexpected Flutter bootstrap; review SDK/configuration changes')
    if not (source / 'main.dart.js').is_file():
        raise ValueError('Build Flutter web in release mode first')
    prefix = f'/releases/{commit}/'
    renderer_config = json.dumps({'entrypointBaseUrl': prefix, 'assetBase': prefix,
                         'canvasKitBaseUrl': prefix + 'canvaskit/',
                         'fontFallbackBaseUrl': prefix + 'font-fallbacks/'})
    bootstrap = bootstrap.replace(marker, f'const studioConfig = {renderer_config};', 1)
    html = html.replace('src="flutter_bootstrap.js"', f'src="{prefix}flutter_bootstrap.js"')
    html = html.replace('href="favicon.webp"', f'href="{prefix}favicon.webp"')
    html = html.replace('</head>', f'<meta name="studio-commit" content="{commit}">\n</head>')
    release = destination / 'releases' / commit
    shutil.copytree(source, release, ignore=shutil.ignore_patterns('*.map', 'flutter_service_worker.js', '_headers', '_redirects'))
    (release / 'flutter_bootstrap.js').write_text(bootstrap)
    (release / 'index.html').unlink()
    (destination / 'index.html').write_text(html)
    (destination / 'release.json').write_text(json.dumps({'commit': commit, 'project': 'biguess-studio'}, indent=2) + '\n')
    headers = SECURITY_HEADERS
    if config:
        auth_origin = 'https://' + config['STUDIO_FIREBASE_AUTH_DOMAIN']
        # Firebase SDK loader, Auth REST token endpoints, and the sign-in helper.
        headers = headers.replace("script-src 'self' 'wasm-unsafe-eval'",
                                  "script-src 'self' 'wasm-unsafe-eval' https://www.gstatic.com https://apis.google.com " + FIREBASE_SCRIPT_HASHES)
        connections = "connect-src 'self' https://apis.google.com/js/gen_204 https://identitytoolkit.googleapis.com https://securetoken.googleapis.com " + auth_origin
        if config.get('STUDIO_API_BASE_URL'):
            connections += ' ' + api_origin(config['STUDIO_API_BASE_URL'])
        headers = headers.replace("connect-src 'self'", connections)
        headers = headers.replace("object-src 'none'", "frame-src " + auth_origin + "; object-src 'none'")
    for route in ('/', '/index.html', '/release.json', '/dashboard', '/topics', '/my-packs', '/cards', '/profile', '/login', '/not-found'):
        headers += f'\n{route}\n  Cache-Control: public, max-age=0, must-revalidate\n'
    (destination / '_headers').write_text(headers)
    # No 404.html: Pages' documented SPA fallback serves index.html for routes.
    print(f'Static release ready: {destination} (commit {commit})')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--public-config', type=Path)
    parser.add_argument('--source', type=Path, default=STUDIO / 'build/web')
    parser.add_argument('--output', type=Path, default=STUDIO / 'build/pages')
    args = parser.parse_args()
    prepare(args.source, args.output, args.commit, args.public_config)


if __name__ == '__main__':
    main()
