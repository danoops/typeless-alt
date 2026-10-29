import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch, MagicMock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import core
import siwc


class ProtocolTests(unittest.TestCase):
    def test_settings_migration_and_validation(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'settings.json'
            self.assertEqual(core.load_settings(path)['hotkey'], 'ctrl+alt+d')
            path.write_text('{"backend":"chatgpt-plan"}')
            self.assertEqual(core.load_settings(path)['chatgptSTT'], 'groq')
            for bad in [{'backend': 'unknown'}, {'chatgptSTT': 'siwc'}, {'historyLimit': True}, {'historyLimit': 501}]:
                path.write_text(json.dumps(bad))
                with self.assertRaises(ValueError):
                    core.load_settings(path)

    def test_cf_responses_reject_truncation_and_reasoning(self):
        self.assertEqual(core.decode_polish({'result': {'response': '<think>hidden</think>你好'}}), '你好')
        self.assertEqual(core.decode_polish({'choices': [{'message': {'content': 'hello'}, 'finish_reason': 'stop'}]}), 'hello')
        for data in [{'success': False}, {'response': '<think>unfinished'},
                     {'choices': [{'message': {'content': 'partial'}, 'finish_reason': 'length'}]}]:
            with self.assertRaises(ValueError):
                core.decode_polish(data)

    def test_pkce_and_callback_binding(self):
        self.assertEqual(siwc.challenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'), 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM')
        self.assertEqual(siwc.callback('/auth/callback?state=s&code=c&client_id=issued', 's'), ('issued', 'c'))
        for query in ['state=bad&code=c&client_id=issued', 'state=s&state=s&code=c&client_id=issued',
                      'state=s&code=c&client_id=dynamic_agent_client', 'state=s&code=c', 'state=s&error=access_denied']:
            with self.assertRaises(ValueError):
                siwc.callback('/auth/callback?' + query, 's')
        with self.assertRaises(ValueError):
            siwc.callback('/auth/callback?state=s&code=c&client_id=other', 's', 'issued')

    def test_sse_accepts_only_completed_assistant_text(self):
        self.assertIsNone(siwc.completed({'type': 'response.output_text.delta', 'delta': 'partial'}))
        event = {'type': 'response.completed', 'response': {'status': 'completed', 'output': [
            {'type': 'reasoning', 'content': [{'type': 'output_text', 'text': 'hidden'}]},
            {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': '你好'}]}]}}
        self.assertEqual(siwc.completed(event), '你好')
        for t in ['error', 'response.failed', 'response.incomplete', 'response.completed']:
            with self.assertRaises(ValueError):
                siwc.completed({'type': t})

    @patch.dict('os.environ', {'GROQ_API_KEY': 'fixture-only'}, clear=True)
    def test_plan_stt_uses_groq_never_siwc(self):
        backend = core.Backend(core.DEFAULTS | {'backend': 'chatgpt-plan'})
        response = MagicMock()
        response.__enter__.return_value.json.return_value = {'text': ' raw '}
        with patch.object(core, 'request', return_value=response) as send:
            self.assertEqual(backend.transcribe(b'audio'), 'raw')
            args, kwargs = send.call_args
            self.assertEqual(args[0], 'https://api.groq.com/openai/v1/audio/transcriptions')
            self.assertEqual(args[1], 'fixture-only')
            self.assertEqual(kwargs['data']['model'], 'whisper-large-v3')

    @patch.dict('os.environ', {'GROQ_API_KEY': 'fixture-only'}, clear=True)
    def test_worker_validation_before_credentials_sent(self):
        for url in ['http://example.com', 'https://user:password@example.com', 'https://example.com/?secret=x']:
            with self.assertRaises(ValueError):
                core.Backend(core.DEFAULTS | {'backend': 'groq-cf', 'cloudflareWorkerURL': url})

    def test_http_does_not_follow_redirect_or_echo_body(self):
        import requests
        response = MagicMock(status_code=401, text='SECRET TRANSCRIPT')
        with patch.object(requests, 'request', return_value=response) as send:
            with self.assertRaisesRegex(ValueError, 'HTTP 401') as caught:
                core.request('https://example.invalid', 'fixture-only', json={})
            self.assertNotIn('SECRET', str(caught.exception))
            self.assertFalse(send.call_args.kwargs['allow_redirects'])


@unittest.skipUnless(sys.platform == 'win32', 'Windows desktop API only')
class WindowsTests(unittest.TestCase):
    def test_x64_layout_hotkey_and_native_registration(self):
        import ctypes
        import native
        self.assertEqual(ctypes.sizeof(native.INPUT), 40)
        self.assertEqual(native.parse_hotkey('ctrl+alt+d'), (0x4003, 68))
        with self.assertRaises(ValueError):
            native.parse_hotkey('ctrl+ctrl+d')
        h = native.Hotkey('ctrl+alt+shift+9', lambda: None)
        h.stop()
        self.assertFalse(h.thread.is_alive())

    def test_tray_import_audio_and_keyring(self):
        import pystray
        import sounddevice
        from keyring.backends.Windows import WinVaultKeyring
        self.assertIsNotNone(pystray.Icon)
        self.assertIsInstance(sounddevice.query_devices(), sounddevice.DeviceList)
        self.assertGreater(WinVaultKeyring.priority, 0)


if __name__ == '__main__':
    unittest.main()

class SessionTests(unittest.TestCase):
    def test_refresh_rotation_saved_before_responses_without_paid_fallback(self):
        import time
        scopes = 'resource.invoke chatgpt.tokens.use.direct'
        old = dict(client='issued', access_token='expired-fixture', refresh_token='old-fixture', scope=scopes, expires=0)
        catalog = MagicMock()
        catalog.__enter__.return_value.json.return_value = {'models': [{'slug': 'fixture-model', 'visibility': 'list'}]}
        stream = MagicMock()
        stream.__enter__.return_value.iter_lines.return_value = [
            'data: ' + json.dumps({'type': 'response.completed', 'response': {'status': 'completed', 'output': [
                {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'done'}]}]}})]
        with patch.object(siwc, 'read', return_value=old), patch.object(siwc, 'save') as saved, patch.object(
                siwc, 'token', return_value=dict(access_token='new-fixture', refresh_token='rotated-fixture', expires_in=3600)), patch.object(
                siwc, 'request', side_effect=[catalog, stream]) as send:
            self.assertEqual(siwc.polish('raw', ''), 'done')
            self.assertEqual(saved.call_args.args[0]['refresh_token'], 'rotated-fixture')
            payload = send.call_args.kwargs['json']
            self.assertFalse(payload['store'])
            self.assertTrue(payload['stream'])
            self.assertNotIn('temperature', payload)
            self.assertEqual(send.call_args.args[1], 'new-fixture')

    def test_signout_clears_local_even_if_revocation_fails(self):
        with patch.object(siwc, 'read', return_value=dict(host='host', client='issued', refresh_token='fixture')), patch.object(
                siwc, 'request', side_effect=ValueError('HTTP 503')), patch.object(siwc, 'save') as save:
            with self.assertRaisesRegex(ValueError, 'revocation unconfirmed'):
                siwc.sign_out()
            self.assertEqual(save.call_args.args[0], dict(host='host', client='issued'))

    @unittest.skipUnless(sys.platform == 'win32', 'Windows DPAPI only')
    def test_dpapi_roundtrip_long_session(self):
        with tempfile.TemporaryDirectory() as d, patch.object(siwc, 'DATA', Path(d)):
            fixture = {'access_token': 'fixture-only-' * 1000}
            siwc.save(fixture)
            self.assertEqual(siwc.read(), fixture)
            self.assertNotIn(b'fixture-only', (Path(d) / 'siwc.dpapi').read_bytes())
