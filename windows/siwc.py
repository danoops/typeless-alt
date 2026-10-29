"""SIWC browser + localhost PKCE flow, matching ChatGPTPlan.swift (single account MVP)."""
import base64
import hashlib
import json
import secrets
import time
import uuid
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qsl, urlencode, urlsplit
from core import DATA, request, messages

ISSUER = 'https://auth.openai.com'
RESOURCE = 'https://api.openai.com/v1'
SCOPES = 'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct'


def read():
    import win32crypt
    path = DATA / 'siwc.dpapi'
    if not path.exists():
        return {}
    return json.loads(win32crypt.CryptUnprotectData(path.read_bytes(), None, None, None, 0)[1])


def save(store):
    import win32crypt
    # Credential Manager blobs have a small size limit; SIWC token sets can exceed
    # it. Use user-scoped DPAPI for the whole atomic session instead.
    DATA.mkdir(parents=True, exist_ok=True)
    protected = win32crypt.CryptProtectData(json.dumps(store).encode(), 'Typeless Alt SIWC', None, None, None, 0)
    temp = DATA / 'siwc.dpapi.tmp'
    temp.write_bytes(protected)
    temp.replace(DATA / 'siwc.dpapi')


def challenge(verifier):
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip('=')


def callback(path, state, previous=None):
    parsed = urlsplit(path)
    pairs = parse_qsl(parsed.query, keep_blank_values=True)
    values = dict(pairs)
    if parsed.path != '/auth/callback' or len(pairs) != len(values) or values.get('state') != state:
        raise ValueError('Invalid OAuth callback / state')
    client = values.get('client_id', previous)
    if values.get('error') or not values.get('code') or not client or client == 'dynamic_agent_client' or (previous and client != previous):
        raise ValueError('Authorization declined or mismatched client; credentials unchanged')
    return client, values['code']


def token(**fields):
    with request(ISSUER + '/api/accounts/oauth/token', data=fields | {'resource': RESOURCE}) as r:
        result = r.json()
    if not result.get('access_token') or result.get('token_type', '').lower() != 'bearer':
        raise ValueError('Invalid OAuth token response')
    return result


def sign_in():
    import jwt
    store = read()
    store.setdefault('host', 'urn:uuid:' + str(uuid.uuid4()))
    save(store)
    state, nonce, verifier = (secrets.token_urlsafe(32) for _ in range(3))
    previous = store.get('client')
    result = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # Never log authorization codes or query strings.

        def do_GET(self):
            try:
                value = callback(self.path, state, previous)
            except ValueError:
                self.send_error(400, 'Invalid callback')
                return
            result.append(value)
            self.send_response(200)
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(b'Return to Typeless Alt to check sign-in. You may close this tab.')

    with HTTPServer(('127.0.0.1', 0), Handler) as server:
        server.timeout = 1
        # Bound individual connections as well as the overall authorization wait.
        original_get = server.get_request
        def get_request():
            connection, address = original_get()
            connection.settimeout(2)
            return connection, address
        server.get_request = get_request
        redirect = f'http://127.0.0.1:{server.server_port}/auth/callback'
        fields = dict(client_id=previous or 'dynamic_agent_client', ext_agent_host_id=store['host'],
                      response_type='code', redirect_uri=redirect, scope=SCOPES, resource=RESOURCE,
                      state=state, nonce=nonce, code_challenge_method='S256', code_challenge=challenge(verifier))
        if previous:
            fields.update(prompt='consent')
            if store.get('id_token'):
                fields['id_token_hint'] = store['id_token']
        else:
            fields['agent_name_hint'] = 'Typeless Alt'
        if not webbrowser.open(ISSUER + '/api/accounts/authorize?' + urlencode(fields)):
            raise ValueError('Cannot open browser; set a default Windows browser')
        deadline = time.monotonic() + 300
        while not result and time.monotonic() < deadline:
            server.handle_request()
    if not result:
        raise ValueError('Sign-in timed out / declined; try again')
    client, code = result[0]
    t = token(grant_type='authorization_code', client_id=client, code=code,
              code_verifier=verifier, redirect_uri=redirect)
    raw = t.get('id_token', '')
    with request(ISSUER + '/.well-known/jwks.json', method='GET') as r:
        jwks = jwt.PyJWKSet.from_dict(r.json())
    header = jwt.get_unverified_header(raw)
    key = next((k.key for k in jwks.keys if k.key_id == header.get('kid') and k.algorithm_name == 'RS256' and k.public_key_use in (None, 'sig')), None)
    if key is None:
        raise ValueError('Invalid ID token signing key')
    claims = jwt.decode(raw, key, algorithms=['RS256'], audience=client, issuer=ISSUER,
                        options={'require': ['exp', 'iss', 'aud', 'sub', 'nonce']})
    aud = claims['aud']
    if claims['nonce'] != nonce or not claims['sub'] or (isinstance(aud, list) and len(aud) > 1 and claims.get('azp') != client):
        raise ValueError('Invalid ID token identity / nonce')
    if store.get('subject') and store['subject'] != claims['sub']:
        raise ValueError('Different account; sign out first')
    store.update(t, client=client, subject=claims['sub'], expires=time.time() + float(t['expires_in']))
    save(store)
    authorized(store)


def authorized(store):
    scopes = store.get('scope', '').split()
    if not all(s in scopes for s in ('chatgpt.tokens.use.direct', 'resource.invoke')):
        raise ValueError('Signed in but plan usage is disabled. Continue with ChatGPT again and authorize plan usage.')


def sign_out():
    store = read()
    failed = False
    if store.get('refresh_token'):
        try:
            with request(ISSUER + '/api/accounts/oauth/revoke', data=dict(
                    token=store['refresh_token'], token_type_hint='refresh_token', client_id=store['client'])):
                pass
        except Exception:
            failed = True
    save({k: v for k, v in store.items() if k in ('host', 'client')})
    if failed:
        raise ValueError('Signed out locally; remote revocation unconfirmed. Disconnect in ChatGPT Settings.')


def completed(event):
    if event.get('type') in ('error', 'response.failed', 'response.incomplete'):
        raise ValueError('ChatGPT response failed / incomplete; nothing inserted')
    if event.get('type') != 'response.completed':
        return None
    response = event.get('response', {})
    if response.get('status') != 'completed':
        raise ValueError('ChatGPT response not completed')
    text = ''.join(c.get('text', '') for m in response.get('output', [])
                   if m.get('type') == 'message' and m.get('role') == 'assistant'
                   for c in m.get('content', []) if c.get('type') == 'output_text').strip()
    if not text:
        raise ValueError('No usable ChatGPT text')
    return text


def polish(text, model):
    store = read()
    if not store.get('access_token'):
        raise ValueError('Use tray > Continue with ChatGPT first (STT still needs Groq)')
    if store.get('expires', 0) < time.time() + 60:
        if not store.get('refresh_token'):
            raise ValueError('Session expired; sign in again')
        t = token(grant_type='refresh_token', client_id=store['client'], refresh_token=store['refresh_token'])
        store.update({k: v for k, v in t.items() if v is not None}, expires=time.time() + float(t['expires_in']))
        save(store)  # Persist rotated refresh token before inference.
    authorized(store)
    access = store['access_token']
    with request(RESOURCE + '/models', access, method='GET') as r:
        models = [m['slug'] for m in r.json()['models'] if m.get('visibility') == 'list']
    if not models or (model and model not in models):
        raise ValueError('Plan model unavailable; clear chatgptModel or check account access')
    payload = dict(model=model or models[0], instructions=messages(text)[0]['content'],
                   input=[{'role': 'user', 'content': text}], store=False, stream=True)
    with request(RESOURCE + '/responses', access, json=payload, stream=True) as r:
        r.encoding = 'utf-8'
        for line in r.iter_lines(decode_unicode=True):
            if line.startswith('data:') and line[5:].strip() != '[DONE]':
                value = completed(json.loads(line[5:]))
                if value is not None:
                    return value
    raise ValueError('Stream ended without response.completed; nothing inserted')
