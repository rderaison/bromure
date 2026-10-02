#!/usr/bin/env python3
"""Guest shortcut framing/routing. --live-x11 also exercises private Xvfb/Openbox."""
import ctypes
import ctypes.util
import importlib.util
import os
from pathlib import Path
import select
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import Mock, patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
SETUP = ROOT / 'Sources/SandboxEngine/Resources/vm-setup'
spec = importlib.util.spec_from_file_location('shortcut_agent', SETUP / 'scripts/tab-agent.py')
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)
NS = {'o': 'http://openbox.org/3.4/rc'}
LIVE = '--live-x11' in sys.argv
if LIVE: sys.argv.remove('--live-x11')
NEW = {'C-n':'n', 'S-C-n':'private-window', 'C-o':'o', 'C-comma':'app-settings',
       'C-m':'minimize', 'C-A-h':'hide-others', 'C-q':'quit',
       'C-A-b':'bookmarks-manager', 'C-y':'history', 'S-C-h':'history'}


def binding_rows():
    tree = ET.parse(SETUP / 'configs/openbox-rc-nativetabs.xml')
    return [(b.attrib['key'], shlex.split(b.find('o:action/o:command', NS).text))
            for b in tree.findall('o:keyboard/o:keybind', NS)]


class Shortcuts(unittest.TestCase):
    def receiver(self, payload):
        read, write = socket.socketpair()
        self.addCleanup(read.close); self.addCleanup(write.close)
        write.sendall(payload); write.shutdown(socket.SHUT_WR)
        return read

    def test_all_tokens_and_fragmented_named_token(self):
        for key in agent.SHORTCUT_KEYS:
            self.assertEqual(agent.read_shortcut(self.receiver(key.encode())), key)
        r, w = socket.socketpair()
        self.addCleanup(r.close); self.addCleanup(w.close)
        def send():
            with w:
                for piece in (b'book', b'marks-', b'man', b'ager'):
                    w.sendall(piece); time.sleep(.01)
        t = threading.Thread(target=send); t.start()
        self.assertEqual(agent.read_shortcut(r), 'bookmarks-manager')
        t.join(timeout=2); self.assertFalse(t.is_alive())

    def test_reject_unknown_oversize_nonascii_and_valid_prefix(self):
        for payload in (b'', b'nonsense', b'quit-now', b'p\x00', b't\xff', b'n\nquit', b'n'*33):
            self.assertIsNone(agent.read_shortcut(self.receiver(payload)), payload)

    def test_no_dispatch_before_eof_and_absolute_deadline(self):
        r, w = socket.socketpair()
        self.addCleanup(r.close); self.addCleanup(w.close)
        w.sendall(b'n')
        started = time.monotonic()
        with self.assertRaises((TimeoutError, socket.timeout)):
            agent.read_shortcut(r, timeout=.05)
        self.assertLess(time.monotonic()-started, .5)
        conn = Mock(); conn.recv.side_effect = [b'b', b'o', b'o']
        with patch.object(agent.time, 'monotonic', side_effect=[0, .4, .8, 1.2]):
            with self.assertRaises(TimeoutError): agent.read_shortcut(conn)
        self.assertEqual(conn.recv.call_count, 2)
        self.assertAlmostEqual(conn.settimeout.call_args_list[-1].args[0], .2)

    def test_config_native_only_and_editing_passthrough(self):
        rows = binding_rows(); mapped = {key: args[-1] for key,args in rows}
        self.assertEqual(len(rows), len(mapped))
        for key, value in NEW.items(): self.assertEqual(mapped[key], value)
        for key,args in rows:
            self.assertEqual(args[0], '/usr/local/bin/bromure-hostkey')
            self.assertIn(args[-1], agent.SHORTCUT_KEYS)
        for key in ('C-a','C-c','C-v','C-x','C-z','S-C-z','C-f','C-plus','C-minus','C-d','S-C-b'):
            self.assertNotIn(key, mapped)
        legacy = ET.parse(SETUP / 'configs/openbox-rc.xml')
        self.assertFalse(legacy.findall('o:keyboard/o:keybind', NS))

    def test_listener_allowlist_debounce_and_shared_origin(self):
        connections = [self.receiver(x) for x in (b'n', b'n', b'bookmarks-manager', b'quit-invalid')]
        server = Mock(); server.accept.side_effect = [(c, ('127.0.0.1', 1)) for c in connections] + [KeyboardInterrupt()]
        link = Mock()
        with patch.object(agent.socket, 'socket', return_value=server), patch.object(agent, 'log'), \
             patch.object(agent, '_shared', types.SimpleNamespace(focused_window=321)):
            with self.assertRaises(KeyboardInterrupt): agent.shortcut_listener(link)
        self.assertEqual([c.args[0] for c in link.send.call_args_list], [
            {'event':'shortcut','key':'n','windowId':321},
            {'event':'shortcut','key':'bookmarks-manager','windowId':321}])
        server.bind.assert_called_once_with(('127.0.0.1', agent.SHORTCUT_PORT))

    @unittest.skipUnless(LIVE, 'pass --live-x11 on Linux with Xvfb/Openbox/xdotool')
    def test_actual_openbox_grabs_and_shell_helper(self):
        for tool in ('Xvfb','openbox','xdotool'): self.assertIsNotNone(shutil.which(tool), tool)
        with tempfile.TemporaryDirectory() as temp, socket.socket() as listener:
            directory = Path(temp)
            listener.bind(('127.0.0.1', 0)); listener.listen(8); listener.settimeout(3)
            helper = directory / 'hostkey'
            helper.write_text((SETUP/'scripts/bromure-hostkey').read_text().replace('/5917', '/'+str(listener.getsockname()[1])))
            helper.chmod(0o755)
            config = directory/'rc.xml'
            config.write_text((SETUP/'configs/openbox-rc-nativetabs.xml').read_text().replace('/usr/local/bin/bromure-hostkey',str(helper)))
            read_fd, write_fd = os.pipe()
            xvfb = subprocess.Popen(['Xvfb','-displayfd',str(write_fd),'-screen','0','800x600x24','-nolisten','tcp'],pass_fds=(write_fd,),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            os.close(write_fd)
            wm = None; display = None
            try:
                self.assertTrue(select.select([read_fd],[],[],5)[0], 'Xvfb startup deadline')
                number = os.read(read_fd,64).decode().strip(); self.assertTrue(number.isdecimal())
                env = dict(os.environ,DISPLAY=':'+number, XAUTHORITY=str(directory/'no-auth'))
                wm = subprocess.Popen(['openbox','--sm-disable','--config-file',str(config)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                lib=ctypes.CDLL(ctypes.util.find_library('X11'))
                lib.XOpenDisplay.argtypes=[ctypes.c_char_p];lib.XOpenDisplay.restype=ctypes.c_void_p
                lib.XInternAtom.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_int];lib.XInternAtom.restype=ctypes.c_ulong
                lib.XGetSelectionOwner.argtypes=[ctypes.c_void_p,ctypes.c_ulong];lib.XGetSelectionOwner.restype=ctypes.c_ulong
                lib.XCloseDisplay.argtypes=[ctypes.c_void_p]
                display=lib.XOpenDisplay(env['DISPLAY'].encode());self.assertTrue(display)
                atom=lib.XInternAtom(display,b'WM_S0',0);deadline=time.monotonic()+5
                while not lib.XGetSelectionOwner(display,atom):
                    self.assertLess(time.monotonic(),deadline,'Openbox startup deadline');time.sleep(.025)
                observed=[]
                for key,args in binding_rows():
                    mods={'C':'ctrl','S':'shift','A':'alt'}
                    parts=key.split('-');chord='+'.join([mods[p] for p in parts[:-1]]+[parts[-1]])
                    subprocess.run(['xdotool','key','--clearmodifiers',chord],env=env,check=True,timeout=3)
                    conn,_=listener.accept()
                    with conn: token=agent.read_shortcut(conn)
                    self.assertEqual(token,args[-1],key);observed.append(token)
                listener.settimeout(.15)
                for chord in ('ctrl+c','ctrl+v','ctrl+z','ctrl+f','ctrl+d','ctrl+shift+b'):
                    subprocess.run(['xdotool','key','--clearmodifiers',chord],env=env,check=True,timeout=3)
                    with self.assertRaises(socket.timeout): listener.accept()
                print('BROMURE_OPENBOX_SHORTCUTS_PASS bindings='+str(len(observed)),flush=True)
            finally:
                os.close(read_fd)
                if display: lib.XCloseDisplay(display)
                for process in (wm,xvfb):
                    if process is not None:
                        process.terminate()
                        try: process.wait(timeout=3)
                        except subprocess.TimeoutExpired: process.kill();process.wait(timeout=3)


if __name__=='__main__': unittest.main()
