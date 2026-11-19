"""Validate public Flutter defines and derive narrowly scoped browser origins."""
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit

FIREBASE_KEYS = {
    'STUDIO_FIREBASE_API_KEY', 'STUDIO_FIREBASE_APP_ID',
    'STUDIO_FIREBASE_PROJECT_ID', 'STUDIO_FIREBASE_AUTH_DOMAIN',
    'STUDIO_FIREBASE_MESSAGING_SENDER_ID',
}
ALLOWED_KEYS = FIREBASE_KEYS | {'STUDIO_API_BASE_URL'}


def read_config(path: Path | None) -> dict[str, str]:
    if path is None:
        return {}
    config = json.loads(path.read_text())
    if not isinstance(config, dict) or set(config) - ALLOWED_KEYS:
        raise ValueError('Only approved public Firebase client defines and API URL are accepted')
    if not all(isinstance(value, str) for value in config.values()):
        raise ValueError('Public configuration values must be strings')
    if not config:
        return config
    if not all(config.get(key) for key in FIREBASE_KEYS):
        raise ValueError('All five Firebase client configuration fields are required')
    domain = config['STUDIO_FIREBASE_AUTH_DOMAIN']
    if not re.fullmatch(r'[a-z0-9][a-z0-9.-]*\.[a-z]{2,}', domain):
        raise ValueError('Firebase auth domain must be a hostname without scheme or path')
    if config.get('STUDIO_API_BASE_URL'):
        api_origin(config['STUDIO_API_BASE_URL'])
    return config


def api_origin(value: str) -> str:
    parsed = urlsplit(value)
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError('API URL must not contain credentials, query or fragment')
    if parsed.scheme != 'https' and not (
        parsed.scheme == 'http' and parsed.hostname in {'localhost', '127.0.0.1'}
    ):
        raise ValueError('API requires HTTPS, except loopback development')
    if not parsed.hostname or not re.fullmatch(r'[a-zA-Z0-9.-]+', parsed.hostname) or re.search(r'[\s;\'"<>]', value):
        raise ValueError('Invalid API origin')
    return f'{parsed.scheme}://{parsed.netloc}'


if __name__ == '__main__':
    read_config(Path(sys.argv[1]))
    print('Public Studio build configuration validated; no server credentials accepted.')
