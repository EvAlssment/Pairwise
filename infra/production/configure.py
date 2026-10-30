#!/usr/bin/env python3
"""Render a single-host deployment without printing or rotating existing secrets."""
import argparse
import ipaddress
import os
from pathlib import Path
import re
import secrets

ROOT = Path(__file__).resolve().parent

def render(api, media, turn, public_ip, contact, output):
    domains = [api, media, turn]
    pattern = r"(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}"
    if any(not re.fullmatch(pattern, domain) for domain in domains) or len(set(domains)) != 3:
        raise ValueError('Use three distinct lowercase public DNS names')
    address = ipaddress.IPv4Address(public_ip)
    if not address.is_global:
        raise ValueError('A routable static public IPv4 address is required')
    if not re.fullmatch(r"[A-Za-z0-9._+%-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}", contact):
        raise ValueError('Provide the certificate contact email')
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(output, 0o700)
    env_file = output / '.env'
    existing = {}
    if env_file.exists():
        existing = dict(line.split('=', 1) for line in env_file.read_text().splitlines() if '=' in line)
        for key, value in [('API_DOMAIN', api), ('MEDIA_DOMAIN', media), ('TURN_DOMAIN', turn), ('PUBLIC_IP', public_ip)]:
            if existing.get(key) != value:
                raise ValueError('Existing deployment differs; use a separate directory rather than overwrite it')
    key = existing.get('LIVEKIT_API_KEY', 'AP' + secrets.token_hex(12))
    secret = existing.get('LIVEKIT_API_SECRET', secrets.token_hex(32))
    if not re.fullmatch(r'AP[0-9a-f]{24}', key) or not re.fullmatch(r'[0-9a-f]{64}', secret):
        raise ValueError('Existing generated secrets have an unexpected format')
    push_values = {name: existing.get(name, '') for name in [
        'PAIRDESK_APNS_TEAM_ID', 'PAIRDESK_APNS_KEY_ID', 'PAIRDESK_APNS_TOPIC',
        'PAIRDESK_APNS_PRIVATE_KEY_HOST_FILE', 'PAIRDESK_APNS_HOST',
        'PAIRDESK_FCM_PROJECT_ID', 'PAIRDESK_FCM_SERVICE_ACCOUNT_HOST_FILE',
        'PAIRDESK_SIGNUP_ENABLED', 'PAIRDESK_SIGNUP_ALLOWED_DOMAINS',
        'PAIRDESK_ACCESS_ALLOWED_DOMAINS', 'PAIRDESK_ACCESS_ALLOWED_EMAILS',
        'PAIRDESK_SIGNUP_VERIFY_EMAIL', 'PAIRDESK_RESEND_FROM',
        'PAIRDESK_RESEND_API_KEY_HOST_FILE']}
    safe_patterns = {
        'PAIRDESK_APNS_TEAM_ID': r'[A-Za-z0-9]{0,20}',
        'PAIRDESK_APNS_KEY_ID': r'[A-Za-z0-9]{0,20}',
        'PAIRDESK_APNS_TOPIC': r'[A-Za-z0-9.-]{0,255}',
        'PAIRDESK_APNS_PRIVATE_KEY_HOST_FILE': r'(/[A-Za-z0-9._-]+)*',
        'PAIRDESK_APNS_HOST': r'(https://[A-Za-z0-9.-]+(:[0-9]{1,5})?)?',
        'PAIRDESK_FCM_PROJECT_ID': r'([a-z][a-z0-9-]{0,62})?',
        'PAIRDESK_FCM_SERVICE_ACCOUNT_HOST_FILE': r'(/[A-Za-z0-9._-]+)*',
        'PAIRDESK_SIGNUP_ENABLED': r'(true|false|1|0)?',
        'PAIRDESK_SIGNUP_VERIFY_EMAIL': r'(true|false|1|0)?',
        'PAIRDESK_SIGNUP_ALLOWED_DOMAINS': r'[A-Za-z0-9.,-]*',
        'PAIRDESK_ACCESS_ALLOWED_DOMAINS': r'[A-Za-z0-9.,-]*',
        'PAIRDESK_ACCESS_ALLOWED_EMAILS': r'[A-Za-z0-9@._+,-]*',
        'PAIRDESK_RESEND_FROM': r'[A-Za-z0-9@._+%-]*',
        'PAIRDESK_RESEND_API_KEY_HOST_FILE': r'(/[A-Za-z0-9._-]+)*',
    }
    for name, value in push_values.items():
        if not re.fullmatch(safe_patterns[name], value):
            raise ValueError(f'{name} contains unsupported characters')
    values = dict(API_DOMAIN=api, MEDIA_DOMAIN=media, TURN_DOMAIN=turn, PUBLIC_IP=public_ip,
                  CERT_CONTACT=contact, LIVEKIT_API_KEY=key, LIVEKIT_API_SECRET=secret, **push_values)
    env_file.write_text(''.join(f'{k}={v}\n' for k, v in values.items()))
    os.chmod(env_file, 0o600)
    for filename in ['nginx.conf', 'livekit.yaml']:
        content = (ROOT / (filename + '.template')).read_text()
        for name, value in values.items():
            content = content.replace('@@' + name + '@@', value)
        if '@@' in content:
            raise ValueError('Unresolved template variable')
        destination = output / filename
        destination.write_text(content)
        os.chmod(destination, 0o600)
    for name in ['certificates', 'challenges']:
        (output / name).mkdir(exist_ok=True, mode=0o700)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['api-domain', 'media-domain', 'turn-domain', 'public-ip', 'contact']:
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    try:
        render(args.api_domain, args.media_domain, args.turn_domain, args.public_ip, args.contact, ROOT / 'generated')
    except ValueError as error:
        parser.error(str(error))
    print('Rendered private configuration; existing secrets preserved. No services started.')
