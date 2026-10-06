#!/usr/bin/env python3
"""Behavioral tests use a private daemon and explicit paths, never host launchd."""
import os
import plistlib
import signal
import socket
import stat
import sys
import struct
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

DAEMON = os.environ['MD_LAUNCHD']
CLIENT = os.environ['MD_LAUNCHCTL']


def eventually(function, timeout=6):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        result = function()
        if result:
            return result
        time.sleep(0.04)
    raise AssertionError('condition did not become true before deadline')


class LaunchdTests(unittest.TestCase):
    def setUp(self):
        # sockaddr_un is short on Darwin, even when TMPDIR is a long Nix path.
        self.temp = tempfile.TemporaryDirectory(prefix='mdld-', dir='/tmp')
        self.root = Path(self.temp.name).resolve()
        self.jobs = self.root / 'jobs'
        self.jobs.mkdir()
        self.sock = self.root / 'ctl.sock'
        self.log = (self.root / 'daemon.log').open('wb')
        self.daemon = subprocess.Popen(self.daemon_args(), stdout=self.log, stderr=self.log)
        self.addCleanup(self.cleanup)
        eventually(lambda: self.sock.exists() or self.daemon.poll() is not None)
        self.assertIsNone(self.daemon.poll(), self.logs())
        eventually(lambda: self.request('list')['OK'])

    extra_args = []

    def daemon_args(self):
        return [DAEMON, '--foreground', '--socket', str(self.sock), '--jobs-dir', str(self.jobs), *self.extra_args]

    def logs(self):
        return (self.root / 'daemon.log').read_text(errors='replace')

    def cleanup(self):
        if self.daemon.poll() is None:
            self.daemon.terminate()
            try:
                self.daemon.wait(timeout=6)
            except subprocess.TimeoutExpired:
                self.daemon.kill()
                self.daemon.wait(timeout=3)
                self.fail('daemon failed to shut down: ' + self.logs())
        self.log.close()
        self.temp.cleanup()

    def request(self, command, argument='', raw=None):
        value = {'Version': 1, 'Command': command, 'Argument': argument}
        data = raw if raw is not None else plistlib.dumps(value)
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(6)
            connection.connect(str(self.sock))
            connection.sendall(struct.pack('!I', len(data)) + data)
            header = self.receive(connection, 4)
            length, = struct.unpack('!I', header)
            self.assertLessEqual(length, 1024 * 1024)
            return plistlib.loads(self.receive(connection, length))

    @staticmethod
    def receive(connection, size):
        result = b''
        while len(result) < size:
            chunk = connection.recv(size - len(result))
            if not chunk:
                raise AssertionError('unexpected socket EOF')
            result += chunk
        return result

    def ctl(self, *args, success=True):
        result = subprocess.run([CLIENT, '--socket', str(self.sock), *args], capture_output=True, text=True, timeout=7)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def load(self, label, args=None, **keys):
        config = {'Label': label, 'ProgramArguments': args or ['/bin/sh', '-c', 'exit 0']}
        config.update(keys)
        path = self.root / (label + '.plist')
        path.write_bytes(plistlib.dumps(config))
        result = self.request('load', str(path))
        self.assertTrue(result['OK'], result)
        return path

    def status(self, label):
        response = self.request('list', label)
        self.assertTrue(response['OK'], response)
        return response['Jobs'][0]

    def idle(self, label):
        return eventually(lambda: (s if (s := self.status(label))['State'] == 'idle' else None))

    def test_manual_lifecycle_and_client(self):
        path = self.load('manual', ['/bin/sh', '-c', 'sleep 30'], ExitTimeOut=1)
        self.assertEqual(self.status('manual')['PID'], 0)
        self.ctl('start', 'manual')
        running = eventually(lambda: (s if (s := self.status('manual'))['State'] == 'running' else None))
        self.assertGreater(running['PID'], 0)
        self.assertIn('manual', self.ctl('list').stdout)
        self.ctl('stop', 'manual')
        stopped = self.idle('manual')
        self.assertFalse(stopped['Enabled'])
        self.ctl('load', str(path), success=False)
        self.ctl('unload', 'manual')
        eventually(lambda: not self.request('list', 'manual')['OK'])
        self.ctl('start', 'missing', success=False)
        self.ctl('nonsense', success=False)

    def test_one_shot_environment_cwd_and_stdio(self):
        result = self.root / 'out'
        error = self.root / 'err'
        stdin = self.root / 'input'
        stdin.write_text('hello\n')
        self.load('once', ['/bin/sh', '-c', 'read line; printf "%s|%s|%s|%s" "$VALUE" "$line" "$PWD" "$PATH"; echo stderr >&2; exit 7'],
                  RunAtLoad=True, EnvironmentVariables={'VALUE': 'safe & <value>'}, WorkingDirectory=str(self.root),
                  StandardInPath=str(stdin), StandardOutPath=str(result), StandardErrorPath=str(error))
        status = self.idle('once')
        self.assertEqual(status['ExitStatus'], 7)
        self.assertEqual(result.read_text(), f'safe & <value>|hello|{self.root}|/usr/bin:/bin:/usr/sbin:/sbin')
        self.assertEqual(error.read_text(), 'stderr\n')
        before = result.read_text()
        time.sleep(0.2)
        self.assertEqual(result.read_text(), before)

    def test_keepalive_throttle_stop_and_restart(self):
        out = self.root / 'restarts'
        self.load('repeat', ['/bin/sh', '-c', 'echo x'], KeepAlive=True, ThrottleInterval=1, StandardOutPath=str(out))
        eventually(lambda: out.exists() and len(out.read_text().splitlines()) == 1)
        time.sleep(0.3)
        self.assertEqual(len(out.read_text().splitlines()), 1)
        eventually(lambda: len(out.read_text().splitlines()) >= 2)
        self.ctl('stop', 'repeat')
        self.idle('repeat')
        count = len(out.read_text().splitlines())
        time.sleep(1.2)
        self.assertEqual(len(out.read_text().splitlines()), count)
        self.ctl('start', 'repeat')
        eventually(lambda: len(out.read_text().splitlines()) > count)

    def test_setup_failures(self):
        self.load('execfail', ['/definitely/missing'], RunAtLoad=True)
        result = self.idle('execfail')
        self.assertEqual(result['ExitStatus'], 127)
        self.assertTrue(result['LaunchError'])
        self.load('cwdfail', RunAtLoad=True, WorkingDirectory='/definitely/missing')
        self.assertTrue(self.idle('cwdfail')['LaunchError'])
        self.load('stdiofail', RunAtLoad=True, StandardOutPath=str(self.root))
        self.assertTrue(self.idle('stdiofail')['LaunchError'])
        self.load('retryfail', ['/definitely/missing'], KeepAlive=True, ThrottleInterval=1)
        eventually(lambda: self.status('retryfail')['LaunchError'])
        self.assertIn(self.status('retryfail')['State'], ['waiting', 'launching'])

    def test_group_cleanup_and_timeout_escalation(self):
        pidfile = self.root / 'child.pid'
        self.load('stubborn', ['/bin/sh', '-c', f'trap "" TERM; sleep 30 & echo $! > "{pidfile}"; wait'], RunAtLoad=True, ExitTimeOut=1)
        eventually(lambda: pidfile.exists() and pidfile.read_text().strip())
        leader = self.status('stubborn')['PID']
        self.ctl('stop', 'stubborn')
        stopped = self.idle('stubborn')
        self.assertEqual(stopped['ExitSignal'], signal.SIGKILL)
        with self.assertRaises(ProcessLookupError):
            os.kill(leader, 0)
        # macOS may retain an orphan zombie until host PID 1 reaps it.
        child = int(pidfile.read_text())
        def gone_or_zombie():
            result = subprocess.run(['/bin/ps', '-o', 'stat=', '-p', str(child)], capture_output=True, text=True)
            return result.returncode != 0 or result.stdout.strip().startswith('Z')
        eventually(gone_or_zombie)

    def test_leader_exit_kills_descendants(self):
        pidfile = self.root / 'orphan.pid'
        self.load('leader', ['/bin/sh', '-c', f'sleep 30 & echo $! > "{pidfile}"; exit 0'], RunAtLoad=True)
        self.assertEqual(self.idle('leader')['ExitStatus'], 0)
        child = int(pidfile.read_text())
        def gone_or_zombie():
            result = subprocess.run(['/bin/ps', '-o', 'stat=', '-p', str(child)], capture_output=True, text=True)
            return result.returncode != 0 or result.stdout.strip().startswith('Z')
        eventually(gone_or_zombie)

    def test_manual_start_is_throttled(self):
        out = self.root / 'manual-output'
        self.load('throttled', ['/bin/sh', '-c', 'echo x'], RunAtLoad=True, ThrottleInterval=1, StandardOutPath=str(out))
        self.idle('throttled')
        self.ctl('start', 'throttled')
        self.assertEqual(len(out.read_text().splitlines()), 1)
        eventually(lambda: len(out.read_text().splitlines()) == 2)
        self.idle('throttled')

    def test_fast_exit_and_concurrent_jobs(self):
        for n in range(12):
            self.load(f'fast{n}', RunAtLoad=True)
        for n in range(12):
            self.assertEqual(self.idle(f'fast{n}')['ExitStatus'], 0)
        self.assertEqual(len(self.request('list')['Jobs']), 12)

    def test_validation_and_malformed_requests(self):
        for keys in [{'KeepAlive': {}}, {'UserName': 'root'}, {'UserID': 0, 'GroupID': 0}, {'Sockets': {}}, {'ThrottleInterval': -1}, {'Disabled': True}]:
            path = self.root / 'invalid.plist'
            path.write_bytes(plistlib.dumps({'Label': 'bad', 'Program': '/bin/echo', **keys}))
            self.assertFalse(self.request('load', str(path))['OK'])
        for raw in [b'not xml', b'<plist><dict/></plist>', plistlib.dumps({'Version': 2, 'Command': 'list', 'Argument': ''})]:
            self.assertFalse(self.request('list', raw=raw)['OK'])
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(2)
            connection.connect(str(self.sock))
            connection.sendall(struct.pack('!I', 1024 * 1024 + 1))
            self.assertEqual(connection.recv(1), b'')
        self.assertTrue(self.request('list')['OK'])

    def test_slow_client_does_not_block_jobs(self):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(7)
            connection.connect(str(self.sock))
            connection.sendall(b'\0')
            self.load('progress', RunAtLoad=True)
            self.assertEqual(self.idle('progress')['ExitStatus'], 0)
            self.assertEqual(connection.recv(1), b'')
        self.assertTrue(self.request('list')['OK'])

    def test_fragmented_and_abandoned_requests(self):
        data = plistlib.dumps({'Version': 1, 'Command': 'list', 'Argument': ''})
        framed = struct.pack('!I', len(data)) + data
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(3)
            connection.connect(str(self.sock))
            for offset in range(0, len(framed), 13):
                connection.sendall(framed[offset:offset + 13])
            length, = struct.unpack('!I', self.receive(connection, 4))
            self.assertTrue(plistlib.loads(self.receive(connection, length))['OK'])
        # Repeated disconnects encourage FD reuse and exercise stale events.
        for _ in range(60):
            with socket.socket(socket.AF_UNIX) as connection:
                try:
                    connection.connect(str(self.sock))
                    connection.sendall(framed)
                except (ConnectionError, OSError):
                    pass  # Listen backlog/client capacity can reject the burst.
        # The bounded server may reject connections while the abandoned burst
        # still occupies all 32 slots. Verify it recovers after draining them.
        def recovered():
            try:
                return self.request('list')['OK']
            except (AssertionError, ConnectionError, OSError):
                return False
        eventually(recovered)

    def test_singleton_and_shutdown(self):
        second = subprocess.run(self.daemon_args(), capture_output=True, text=True, timeout=3)
        self.assertNotEqual(second.returncode, 0)
        self.assertTrue(self.request('list')['OK'])
        self.assertEqual(self.sock.stat().st_mode & 0o777, 0o600)
        self.load('shutdown', ['/bin/sh', '-c', 'trap "" TERM; sleep 30'], RunAtLoad=True, KeepAlive=True, ExitTimeOut=1)
        eventually(lambda: self.status('shutdown')['State'] == 'running')
        self.daemon.terminate()
        self.daemon.wait(timeout=4)
        self.assertEqual(self.daemon.returncode, 0, self.logs())
        self.assertFalse(self.sock.exists())
        self.assertTrue(Path(str(self.sock) + '.lock').exists())

    def test_sorted_startup_load_and_rejection(self):
        self.daemon.terminate()
        self.daemon.wait(timeout=3)
        for filename, label in [('a.plist', 'startup'), ('b.plist', 'startup'), ('c.plist', 'other')]:
            (self.jobs / filename).write_bytes(plistlib.dumps({'Label': label, 'Program': '/bin/echo', 'RunAtLoad': True}))
        (self.jobs / 'bad.plist').write_text('invalid')
        self.daemon = subprocess.Popen(self.daemon_args(), stdout=self.log, stderr=self.log)
        eventually(lambda: self.sock.exists())
        eventually(lambda: len(self.request('list')['Jobs']) == 2)
        self.assertEqual(self.idle('startup')['ExitStatus'], 0)
        self.assertIn('duplicate job label', self.logs())

    def test_socket_activation(self):
        listener = self.root / 'svc.sock'
        out = self.root / 'activated'
        # The job answers one connection on the descriptor launchd names, then exits.
        server = self.root / 'server.py'
        server.write_text(f"""import os, socket, sys
names = dict(e.split('=') for e in os.environ['MINIDARWIN_LAUNCHD_SOCKETS'].split())
with open({str(out)!r}, 'a') as f: f.write(os.environ['MINIDARWIN_LAUNCHD_SOCKETS'] + chr(10))
s = socket.socket(fileno=int(names['Listener']))
c, _ = s.accept()
c.sendall(c.recv(100).upper())
""")
        self.load('activated', [sys.executable, str(server)], ThrottleInterval=1,
                  Sockets={'Listener': {'SockPathName': str(listener), 'SockPathMode': 0o640,
                                        'SockType': 'stream', 'SockFamily': 'Unix', 'SockPassive': True}})
        self.assertTrue(stat.S_ISSOCK(listener.lstat().st_mode))
        self.assertEqual(listener.stat().st_mode & 0o777, 0o640)
        time.sleep(0.3)
        self.assertEqual(self.status('activated')['PID'], 0)
        self.assertFalse(out.exists())
        for word in [b'one', b'two']:
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(6)
                client.connect(str(listener))
                client.sendall(word)
                self.assertEqual(client.recv(100), word.upper())
            self.idle('activated')
        self.assertEqual(out.read_text().splitlines(), ['Listener=3', 'Listener=3'])
        # Stopped jobs are not activated; start re-enables them.
        self.ctl('stop', 'activated')
        with socket.socket(socket.AF_UNIX) as client:
            client.connect(str(listener))
            client.sendall(b'three')
            time.sleep(0.5)
            self.assertEqual(self.status('activated')['PID'], 0)
            self.ctl('start', 'activated')
            client.settimeout(6)
            self.assertEqual(client.recv(100), b'THREE')
        # Another job cannot claim the same path; unload removes the socket.
        path = self.root / 'thief.plist'
        path.write_bytes(plistlib.dumps({'Label': 'thief', 'Program': '/bin/echo',
                                         'Sockets': {'S': {'SockPathName': str(listener)}}}))
        response = self.request('load', str(path))
        self.assertFalse(response['OK'])
        self.assertIn('already owned by activated', response['Message'])
        self.ctl('unload', 'activated')
        eventually(lambda: not listener.exists())

    def test_socket_validation(self):
        for sockets in [{'bad name': {'SockPathName': '/tmp/x'}}, {'S': {}}, {'S': {'SockPathName': 'relative'}},
                        {'S': {'SockPathName': str(self.root / 's'), 'SockType': 'dgram'}},
                        {'S': {'SockPathName': str(self.root / 's'), 'SockPassive': False}},
                        {'S': {'SockPathName': str(self.root / 's'), 'SockNodeName': 'x'}},
                        {'S': {'SockPathName': str(self.root / 'jobs')}}]:
            path = self.root / 'invalid.plist'
            path.write_bytes(plistlib.dumps({'Label': 'bad', 'Program': '/bin/echo', 'Sockets': sockets}))
            self.assertFalse(self.request('load', str(path))['OK'], sockets)
        self.assertTrue((self.root / 'jobs').is_dir())

    def test_overrides_require_a_database(self):
        result = self.ctl('disable', 'anything', success=False)
        self.assertIn('no overrides database', result.stderr)

    def test_explicit_foreground_required(self):
        result = subprocess.run([DAEMON], capture_output=True, text=True, timeout=3)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('requires PID 1', result.stderr)


    def test_disable_enable_and_restart(self):
        # A private overrides database; `launchctl disable` beats the plist.
        self.extra_args = ['--overrides', str(self.root / 'disabled.plist')]
        self.daemon.terminate()
        self.daemon.wait(timeout=5)
        out = self.root / 'ran'
        for label, disabled in [('quiet', False), ('dormant', True)]:
            (self.jobs / f'{label}.plist').write_bytes(plistlib.dumps({
                'Label': label, 'Disabled': disabled, 'RunAtLoad': True,
                'ProgramArguments': ['/bin/sh', '-c', f'echo {label} >> {out}']}))
        self.daemon = subprocess.Popen(self.daemon_args(), stdout=self.log, stderr=self.log)
        eventually(lambda: self.sock.exists())
        eventually(lambda: self.request('list')['OK'])
        self.assertEqual([j['Label'] for j in self.request('list')['Jobs']], ['quiet'])
        self.ctl('disable', 'system/quiet')
        self.ctl('enable', 'dormant')
        database = plistlib.loads((self.root / 'disabled.plist').read_bytes())
        self.assertEqual(database, {'quiet': True, 'dormant': False})
        self.assertEqual((self.root / 'disabled.plist').stat().st_mode & 0o777, 0o644)
        # Recorded for the next load; the loaded job is untouched.
        self.assertEqual(len(self.request('list')['Jobs']), 1)
        self.daemon.terminate()
        self.daemon.wait(timeout=5)
        out.unlink()
        self.daemon = subprocess.Popen(self.daemon_args(), stdout=self.log, stderr=self.log)
        eventually(lambda: self.sock.exists())
        eventually(lambda: self.request('list')['OK'])
        self.assertEqual([j['Label'] for j in self.request('list')['Jobs']], ['dormant'])
        eventually(lambda: out.exists() and out.read_text() == 'dormant\n')
        self.assertIn('disabled by override', self.logs())
        self.ctl('disable', 'not a label', success=False)


if __name__ == '__main__':
    unittest.main()
