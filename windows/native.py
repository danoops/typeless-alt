"""Windows-only desktop integration; explicit x64-safe SendInput layout."""
import ctypes
from ctypes import wintypes as W
import threading
import time
import win32clipboard
import win32con
import win32gui
import win32process

user32 = ctypes.WinDLL('user32', use_last_error=True)


class GUIINFO(ctypes.Structure):
    _fields_ = [('cbSize', W.DWORD), ('flags', W.DWORD), ('hwndActive', W.HWND),
                ('hwndFocus', W.HWND), ('hwndCapture', W.HWND), ('hwndMenuOwner', W.HWND),
                ('hwndMoveSize', W.HWND), ('hwndCaret', W.HWND), ('rcCaret', W.RECT)]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [('wVk', W.WORD), ('wScan', W.WORD), ('dwFlags', W.DWORD),
                ('time', W.DWORD), ('dwExtraInfo', ctypes.c_size_t)]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [('dx', W.LONG), ('dy', W.LONG), ('mouseData', W.DWORD),
                ('dwFlags', W.DWORD), ('time', W.DWORD), ('dwExtraInfo', ctypes.c_size_t)]


class INPUTUNION(ctypes.Union):
    _fields_ = [('ki', KEYBDINPUT), ('mi', MOUSEINPUT)]


class INPUT(ctypes.Structure):
    _anonymous_ = ('data',)
    _fields_ = [('type', W.DWORD), ('data', INPUTUNION)]


user32.GetGUIThreadInfo.argtypes = [W.DWORD, ctypes.POINTER(GUIINFO)]
user32.GetGUIThreadInfo.restype = W.BOOL
user32.SendInput.argtypes = [W.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
user32.SendInput.restype = W.UINT
user32.RegisterHotKey.argtypes = [W.HWND, ctypes.c_int, W.UINT, W.UINT]
user32.RegisterHotKey.restype = W.BOOL
user32.GetAsyncKeyState.argtypes = [ctypes.c_int]
user32.GetAsyncKeyState.restype = W.SHORT
user32.GetClipboardSequenceNumber.restype = W.DWORD


def focus():
    hwnd = win32gui.GetForegroundWindow()
    if not hwnd:
        raise ValueError('No focused window')
    tid, _ = win32process.GetWindowThreadProcessId(hwnd)
    info = GUIINFO(cbSize=ctypes.sizeof(GUIINFO))
    if not user32.GetGUIThreadInfo(tid, ctypes.byref(info)) or not info.hwndFocus:
        raise ValueError('Cannot identify focused control; use a normal text field')
    # ES_PASSWORD is used by standard Win32 password edits. Custom/browser fields
    # cannot be reliably classified; users must avoid dictating into password fields.
    if win32gui.GetClassName(info.hwndFocus).lower() == 'edit' and win32gui.GetWindowLong(info.hwndFocus, -16) & 0x20:
        raise ValueError('Password control; dictation refused')
    return hwnd, info.hwndFocus


def copy(text):
    for attempt in range(10):
        try:
            win32clipboard.OpenClipboard()
            break
        except Exception:
            if attempt == 9:
                raise ValueError('Clipboard is busy; retry Copy last result') from None
            time.sleep(0.03)
    try:
        win32clipboard.EmptyClipboard()
        win32clipboard.SetClipboardText(text, win32con.CF_UNICODETEXT)
    finally:
        win32clipboard.CloseClipboard()


def paste(text, target):
    # Wait for the dictation hotkey to be released, rather than sending Ctrl+Alt+V.
    deadline = time.monotonic() + 2
    while any(user32.GetAsyncKeyState(k) & 0x8000 for k in (0x10, 0x11, 0x12, 0x5B, 0x5C)):
        if time.monotonic() > deadline:
            raise ValueError('Release modifier keys, then Copy last result')
        time.sleep(0.02)
    if focus() != target:
        raise ValueError('Focus changed; use tray > Copy last result and paste manually')
    copy(text)
    sequence = user32.GetClipboardSequenceNumber()
    if focus() != target:
        raise ValueError('Focus changed; result is on clipboard')
    events = (INPUT * 4)()
    for event, (key, flags) in zip(events, [(0x11, 0), (0x56, 0), (0x56, 2), (0x11, 2)]):
        event.type = 1
        event.ki = KEYBDINPUT(wVk=key, dwFlags=flags)
    if user32.SendInput(4, events, ctypes.sizeof(INPUT)) != 4:
        # Release injected modifiers even if Windows accepted only part of the batch.
        release = INPUT(type=1, data=INPUTUNION(ki=KEYBDINPUT(wVk=0x11, dwFlags=2)))
        user32.SendInput(1, ctypes.byref(release), ctypes.sizeof(INPUT))
        raise ValueError('Windows rejected paste (e.g. elevated target); result is on clipboard')
    return sequence


def parse_hotkey(value):
    parts = value.lower().split('+')
    modifiers = {'ctrl': 2, 'alt': 1, 'shift': 4, 'win': 8}
    if len(parts) < 2 or len(set(parts)) != len(parts) or any(p not in modifiers for p in parts[:-1]) or len(parts[-1]) != 1 or not parts[-1].isascii() or not parts[-1].isalnum():
        raise ValueError('hotkey format: ctrl+alt+d (modifiers ctrl/alt/shift/win + A-Z/0-9)')
    return sum(modifiers[p] for p in parts[:-1]) | 0x4000, ord(parts[-1].upper())


class Hotkey:
    def __init__(self, value, callback):
        self.error = None
        self.ready = threading.Event()
        self.args = parse_hotkey(value)
        self.callback = callback
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()
        self.ready.wait(5)
        if not self.ready.is_set() or self.error:
            raise ValueError(self.error or 'Hotkey registration timed out')

    def run(self):
        self.tid = win32api_thread_id()
        # Create a message queue before any stop message can be posted.
        msg = W.MSG()
        user32.PeekMessageW(ctypes.byref(msg), None, 0, 0, 0)
        if not user32.RegisterHotKey(None, 1, *self.args):
            self.error = 'Hotkey unavailable; change hotkey in settings.json and restart'
            self.ready.set()
            return
        self.ready.set()
        try:
            while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
                if msg.message == 0x0312:
                    self.callback()
        finally:
            user32.UnregisterHotKey(None, 1)

    def stop(self):
        if self.thread.is_alive():
            user32.PostThreadMessageW(self.tid, 0x0012, 0, 0)
            self.thread.join(3)


def win32api_thread_id():
    import win32api
    return win32api.GetCurrentThreadId()
