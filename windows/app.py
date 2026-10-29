"""Source-run Windows tray MVP. GUI/state confined to Tk thread; HTTP off-thread."""
import io
import json
import os
import queue
import threading
import time
import wave
from datetime import datetime, timezone


def main():
    if os.name != 'nt':
        raise SystemExit('This tray app requires Windows 10/11 x64. Portable tests can run on any OS.')
    import tkinter as tk
    from tkinter import messagebox, simpledialog
    import winsound
    import msvcrt
    import pystray
    import sounddevice as sd
    from PIL import Image, ImageDraw
    from core import DATA, Backend, load_settings
    import native
    import siwc
    import keyring
    from keyring.backends.Windows import WinVaultKeyring

    # Never permit a plaintext/fallback keyring backend for credentials.
    keyring.set_keyring(WinVaultKeyring())
    DATA.mkdir(parents=True, exist_ok=True)
    lock = open(DATA / 'instance.lock', 'a+b')
    lock.seek(0)
    if not lock.read(1):
        lock.write(b'0')
        lock.flush()
    lock.seek(0)
    try:
        msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
    except OSError:
        lock.close()
        raise SystemExit('Typeless Alt is already running. Check the system tray.')
    root = tk.Tk()
    root.withdraw()
    jobs = queue.Queue()

    class App:
        def __init__(self):
            self.closing = False
            self.settings = load_settings()
            self.state = 'Idle'
            self.stream = None
            self.last = ''
            self.timer = None
            self.chunks = []
            self.audio_error = False
            self.hotkey = native.Hotkey(self.settings['hotkey'], lambda: jobs.put(self.toggle))
            def action(fn):
                return lambda icon, item: jobs.put(fn)
            menu = pystray.Menu(
                pystray.MenuItem(lambda _: f'{self.state} | {self.settings["hotkey"]}', None, enabled=False),
                pystray.MenuItem('Cancel recording', action(self.cancel)),
                pystray.MenuItem('Copy last result', action(self.copy_last)),
                pystray.MenuItem('Open settings.json', action(lambda: os.startfile(DATA / 'settings.json'))),
                pystray.MenuItem('Reload settings', action(self.reload)),
                pystray.MenuItem('Set credentials...', action(self.credentials)),
                pystray.MenuItem('Continue with ChatGPT', action(lambda: self.work(siwc.sign_in, 'Signed in with ChatGPT'))),
                pystray.MenuItem('Sign out of ChatGPT', action(lambda: self.work(siwc.sign_out, 'Signed out'))),
                pystray.MenuItem('ChatGPT usage / manage access', action(lambda: __import__('webbrowser').open('https://chatgpt.com/#settings'))),
                pystray.MenuItem('Quit', action(self.quit)))
            self.icon = pystray.Icon('typeless-alt', self.image('steelblue'), 'Typeless Alt', menu)
            self.icon.run_detached()

        def image(self, color):
            image = Image.new('RGB', (64, 64), '#202020')
            draw = ImageDraw.Draw(image)
            draw.ellipse((16, 6, 48, 44), fill=color)
            draw.line((32, 42, 32, 57), fill='white', width=5)
            draw.line((21, 57, 43, 57), fill='white', width=4)
            return image

        def status(self, value):
            self.state = value
            self.icon.title = 'Typeless Alt: ' + value
            self.icon.icon = self.image('red' if value == 'Recording' else 'orange' if value == 'Working' else 'steelblue')
            self.icon.update_menu()

        def notify(self, message):
            self.icon.notify(message, 'Typeless Alt')

        def idle(self):
            if self.state != 'Idle':
                raise ValueError('Finish or cancel the current operation first')

        def beep(self):
            if self.settings['sounds']:
                winsound.MessageBeep()

        def toggle(self):
            if self.state == 'Recording':
                self.finish()
                return
            self.idle()
            self.backend = Backend(self.settings)  # Check credentials before recording.
            self.target = native.focus()
            device = self.settings['inputDevice']
            self.rate = int(sd.query_devices(device, 'input')['default_samplerate'])
            if self.rate * 2 * 180 >= 24_000_000:
                raise ValueError('Input sample rate too high; select a 48 kHz input device')
            self.chunks = []
            self.audio_error = False
            self.bytes = 0
            def record(data, frames, timing, status):
                if status:
                    self.audio_error = True
                block = bytes(data)
                self.bytes += len(block)
                if self.bytes <= self.rate * 2 * 180:
                    self.chunks.append(block)
                else:
                    raise sd.CallbackStop
            self.beep()
            self.stream = sd.RawInputStream(samplerate=self.rate, channels=1, dtype='int16', device=device, callback=record)
            try:
                self.stream.start()
            except Exception:
                self.stream.close()
                self.stream = None
                raise
            self.status('Recording')
            self.timer = root.after(180000, lambda: guard(self.finish))

        def stop(self):
            if self.timer:
                root.after_cancel(self.timer)
                self.timer = None
            if self.stream:
                try:
                    self.stream.stop()
                finally:
                    self.stream.close()
                    self.stream = None

        def cancel(self):
            if self.state == 'Recording':
                self.stop()
                self.chunks.clear()
                self.status('Idle')
                self.notify('Recording cancelled; no API request sent')

        def finish(self):
            if self.state != 'Recording':
                return
            self.stop()
            self.status('Idle')
            self.beep()
            chunks, self.chunks = self.chunks, []
            if self.audio_error or sum(map(len, chunks)) < self.rate:
                raise ValueError('Audio input overflow / recording too short; retry')
            audio = io.BytesIO()
            with wave.open(audio, 'wb') as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(self.rate)
                wav.writeframes(b''.join(chunks))
            backend, target = self.backend, self.target
            self.last = ''
            def process():
                transcript = backend.transcribe(audio.getvalue())
                jobs.put(lambda value=transcript: setattr(self, 'last', value))
                result = backend.polish(transcript)
                return result
            def done(result):
                self.last = result
                limit = self.settings['historyLimit']
                history_error = False
                if limit:
                    try:
                        path = DATA / 'history.json'
                        history = json.loads(path.read_text('utf-8')) if path.exists() else []
                        history.insert(0, dict(date=datetime.now(timezone.utc).isoformat(), text=result))
                        temp = path.with_suffix('.tmp')
                        temp.write_text(json.dumps(history[:limit], ensure_ascii=False), 'utf-8')
                        temp.replace(path)
                    except Exception:
                        history_error = True
                native.paste(result, target)
                self.notify('Paste sent; check text before sending.' + (' History could not be saved.' if history_error else ''))
            self.work(process, done=done)

        def work(self, function, success=None, done=None):
            self.idle()
            self.status('Working')
            def worker():
                try:
                    result = function()
                    error = None
                except Exception as exc:
                    result, error = None, exc
                def complete():
                    self.status('Idle')
                    if error:
                        # Do not expose response bodies, tokens, transcripts, or library URLs.
                        from requests import RequestException
                        if isinstance(error, ValueError) and not isinstance(error, (RequestException, json.JSONDecodeError)):
                            message = str(error)
                        else:
                            message = 'Operation failed (' + type(error).__name__ + '); check settings, connectivity or sign in again'
                        self.notify(message + ('; Copy last result is available' if self.last else ''))
                    elif done:
                        done(result)
                    elif success:
                        self.notify(success)
                jobs.put(complete)
            threading.Thread(target=worker, daemon=True).start()

        def copy_last(self):
            if self.last:
                native.copy(self.last)
                self.notify('Copied last result (may be raw transcript if polish failed)')
            else:
                self.notify('No result yet')

        def reload(self):
            self.idle()
            settings = load_settings()
            if settings['hotkey'] != self.settings['hotkey']:
                old = self.settings['hotkey']
                self.hotkey.stop()
                try:
                    self.hotkey = native.Hotkey(settings['hotkey'], lambda: jobs.put(self.toggle))
                except Exception:
                    self.hotkey = native.Hotkey(old, lambda: jobs.put(self.toggle))
                    raise
            self.settings = settings
            self.icon.update_menu()
            self.notify('Settings reloaded')

        def credentials(self):
            self.idle()
            name = simpledialog.askstring('Credential', 'Name: OPENAI_API_KEY / GROQ_API_KEY / CF_API_TOKEN / CF_WORKER_TOKEN', parent=root)
            if name is None:
                return
            if name not in ('OPENAI_API_KEY', 'GROQ_API_KEY', 'CF_API_TOKEN', 'CF_WORKER_TOKEN'):
                raise ValueError('Use one of the listed credential names')
            value = simpledialog.askstring('Credential', 'Secret (stored in Windows Credential Manager):', show='*', parent=root)
            if value:
                keyring.set_password('typeless-alt.windows', name, value.strip())
                self.notify('Credential saved; environment variables take precedence')

        def quit(self):
            if self.state == 'Working':
                self.notify('Wait for processing / sign-in timeout before quitting')
                return
            self.cancel()
            self.hotkey.stop()
            self.icon.stop()
            self.closing = True
            root.destroy()

    def guard(fn):
        try:
            fn()
        except Exception as exc:
            # GUI/native exceptions can contain device/window info, never HTTP bodies.
            messagebox.showerror('Typeless Alt', str(exc) if isinstance(exc, ValueError) else type(exc).__name__, parent=root)

    app = None
    try:
        app = App()
        def poll():
            for _ in range(30):
                try:
                    job = jobs.get_nowait()
                except queue.Empty:
                    break
                guard(job)
                if app.closing:
                    return
            if not app.closing:
                root.after(50, poll)
        root.after(50, poll)
        app.notify('Ready: ' + app.settings['hotkey'] + '. Set credentials from tray before first dictation.')
        root.mainloop()
    finally:
        if app:
            app.stop()
            app.hotkey.stop()
            app.icon.stop()
        lock.close()


if __name__ == '__main__':
    main()
