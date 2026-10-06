#!/usr/bin/env python3
"""open/opend behavior, against a private daemon and isolated tables and
applications, then under a foreground launchd that activates it on demand.
Nothing here touches the host's applications or LaunchServices."""
import os
import plistlib
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

OPEN = os.environ['MD_OPEN']
OPEND = os.environ['MD_OPEND']
PLIST = os.environ['MD_OPEN_PLIST']
LAUNCHD = os.environ['MD_LAUNCHD']


def eventually(function, timeout=8):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        result = function()
        if result:
            return result
        time.sleep(0.04)
    raise AssertionError('condition did not become true before deadline')


RECORD = '''#!/bin/sh
# record TAG ARGS...: argv, cwd and selected environment, one line each.
tag=$1; shift
out="{root}/out/$tag.$$"
{{ for a in "$@"; do printf 'arg:%s\\n' "$a"; done
  printf 'cwd:%s\\n' "$PWD"; printf 'foo:%s\\n' "${{FOO-unset}}"; }} > "$out.tmp"
mv "$out.tmp" "$out"
'''


class Base(unittest.TestCase):
    def setUp(self):
        # sockaddr_un is short on Darwin, even when TMPDIR is a long Nix path.
        self.temp = tempfile.TemporaryDirectory(prefix='mdop-', dir='/tmp')
        self.root = Path(self.temp.name).resolve()
        self.addCleanup(self.temp.cleanup)
        (self.root / 'out').mkdir()
        self.home = self.root / 'home'
        self.home.mkdir()
        record = self.root / 'record'
        record.write_text(RECORD.format(root=self.root))
        record.chmod(0o755)
        self.handlers = self.root / 'handlers'
        self.write_handlers(f'''
# comment
app:TextEdit,role:editor ; {record} editor %s
app:Viewer ; {record} viewer
ext:txt,MD ; {record} text %s
ext:cat ; /bin/cat ; needsterminal
ext:copy ; /bin/sh -c "cat" ; needsterminal
ext:broken ; /definitely/missing
type:directory ; {record} dir %s
type:executable ; %s ; single ; needsterminal
type:text ; {record} plain
scheme:http,https ; {record} web
''')
        self.apps = self.root / 'Applications'
        self.make_bundle('Fake', 'org.example.Fake', extensions=['fake'], schemes=['fakeurl'])
        self.sock = self.root / 'open.sock'

    def write_handlers(self, text, path=None):
        path = path or self.handlers
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o644)

    def make_bundle(self, name, identifier, extensions=(), schemes=()):
        bundle = self.apps / f'{name}.app' / 'Contents'
        (bundle / 'MacOS').mkdir(parents=True)
        info = {'CFBundleIdentifier': identifier, 'CFBundleName': name, 'CFBundleExecutable': name.lower(),
                'CFBundleVersion': '1.0', 'LSMinimumSystemVersion': '10.9', 'NSHighResolutionCapable': True,
                'CFBundleDocumentTypes': [{'CFBundleTypeExtensions': list(extensions), 'CFBundleTypeRole': 'Viewer'}],
                'CFBundleURLTypes': [{'CFBundleURLSchemes': list(schemes)}]}
        data = plistlib.dumps(info).replace(b'<string>1.0</string>', b'<real>1.0</real>', 1)
        (bundle / 'Info.plist').write_bytes(data)
        exe = bundle / 'MacOS' / name.lower()
        exe.write_text(f'#!/bin/sh\nexec {self.root}/record bundle-{name} "$@"\n')
        exe.chmod(0o755)

    def env(self, **extra):
        env = {'PATH': '/usr/bin:/bin', 'HOME': str(self.home), 'MINIDARWIN_OPEN_SOCKET': str(self.sock), 'TMPDIR': str(self.root)}
        env.update(extra)
        return env

    def open(self, *args, rc=0, cwd=None, input=None, env=None, timeout=15):
        result = subprocess.run([OPEN, *map(str, args)], capture_output=True, text=True, cwd=cwd or self.root,
                                input=input, env=env or self.env(), timeout=timeout)
        self.assertEqual(result.returncode, rc, result.stdout + result.stderr)
        return result

    def records(self, tag, count=1):
        def found():
            files = sorted((self.root / 'out').glob(tag + '.*'))
            files = [f for f in files if not f.name.endswith('.tmp')]
            return files if len(files) >= count else None
        files = eventually(found)
        time.sleep(0.1)
        self.assertEqual(len([f for f in (self.root / 'out').glob(tag + '.*') if not f.name.endswith('.tmp')]), count)
        return [f.read_text().splitlines() for f in files]

    def record(self, tag):
        return self.records(tag)[0]

    def args(self, tag):
        return [line[4:] for line in self.record(tag) if line.startswith('arg:')]


class DaemonTests(Base):
    def setUp(self):
        super().setUp()
        self.log = (self.root / 'opend.log').open('wb')
        self.daemon = subprocess.Popen([OPEND, '--socket', self.sock, '--system-handlers', self.handlers,
                                        '--applications', self.apps, '--idle-timeout', '0'],
                                       stdout=self.log, stderr=self.log)
        self.addCleanup(self.stop)
        eventually(lambda: self.sock.exists() or self.daemon.poll() is not None)
        self.assertIsNone(self.daemon.poll())

    def stop(self):
        self.daemon.terminate()
        self.daemon.wait(timeout=5)
        self.log.close()

    def test_extension_routing_and_grouping(self):
        (self.root / 'a.txt').write_text('a')
        (self.root / 'B.Md').write_text('b')
        self.open('a.txt', 'B.Md')
        # One process for both: as one app receives every document.
        self.assertEqual(self.args('text'), [str(self.root / 'a.txt'), str(self.root / 'B.Md')])

    def test_relative_paths_are_canonicalized(self):
        sub = self.root / 'sub'
        sub.mkdir()
        (sub / 'n.txt').write_text('x')
        (self.root / 'link.txt').symlink_to(sub / 'n.txt')
        self.open('./sub/../link.txt')
        self.assertEqual(self.args('text'), [str(sub / 'n.txt')])

    def test_directory_text_sniff_and_cwd(self):
        (self.root / 'README').write_text('plain text\n')
        self.open('..', cwd=self.root / 'out')
        record = self.record('dir')
        self.assertIn('arg:' + str(self.root), record)
        self.assertIn('cwd:' + str(self.root / 'out'), record)
        self.open('README')
        self.assertEqual(self.args('plain'), [str(self.root / 'README')])

    def test_binary_without_handler(self):
        (self.root / 'blob').write_bytes(b'\0\1\2')
        result = self.open('blob', rc=1)
        self.assertEqual(result.stderr.strip(), f'No application knows how to open {self.root / "blob"}.')

    def test_missing_file_message(self):
        result = self.open('missing.txt', rc=1)
        self.assertEqual(result.stderr, f'The file {self.root / "missing.txt"} does not exist.\n')

    def test_urls(self):
        self.open('https://example.org/x?y=1')
        self.assertEqual(self.args('web'), ['https://example.org/x?y=1'])
        result = self.open('nosuch://thing', rc=1)
        self.assertEqual(result.stderr.strip(), 'No application knows how to open URL nosuch://thing.')
        (self.root / 'file name.txt').write_text('x')
        self.open('file://' + str(self.root) + '/file%20name.txt')
        self.assertEqual(self.args('text'), [str(self.root / 'file name.txt')])

    def test_url_flag_beats_existing_path(self):
        (self.root / 'http:x').write_text('x')
        self.open('-u', 'http:x')
        self.assertEqual(self.args('web'), ['http:x'])

    def test_executables_run_once_each_on_the_terminal(self):
        for name in ['one', 'two']:
            script = self.root / name
            script.write_text(f'#!/bin/sh\necho {name}:"$*":$FOO\n')
            script.chmod(0o755)
        result = self.open('one', 'two', '--args', 'x', 'y', env=self.env(FOO='inherited'))
        self.assertEqual(sorted(result.stdout.splitlines()), ['one:x y:inherited', 'two:x y:inherited'])

    def test_handlers_are_never_session_leaders(self):
        # A session leader could acquire the caller's terminal as its own.
        probe = self.root / 'probe'
        probe.write_text(f'#!{sys.executable}\nimport os\nprint(os.getsid(0) != os.getpid(), os.getpgid(0) == os.getsid(0))\n')
        probe.chmod(0o755)
        self.assertEqual(self.open('probe').stdout, 'True True\n')

    def test_terminal_handlers_get_caller_stdio_and_wait(self):
        (self.root / 'in.cat').write_text('cat me\n')
        result = self.open('in.cat', input='')
        self.assertEqual(result.stdout, 'cat me\n')
        (self.root / 'x.copy').write_text('')
        result = self.open('x.copy', input='from stdin\n')
        self.assertEqual(result.stdout, 'from stdin\n')

    def test_explicit_streams(self):
        (self.root / 'x.copy').write_text('')
        (self.root / 'input').write_text('redirected\n')
        self.open('-i', 'input', '-o', 'output', 'x.copy')
        self.assertEqual((self.root / 'output').read_text(), 'redirected\n')

    def test_args_env_and_application_by_name(self):
        (self.root / 'a.txt').write_text('a')
        self.open('-a', 'textedit', '--env', 'FOO=bar', 'a.txt', '--args', '-x', 'two words')
        record = self.record('editor')
        self.assertEqual([l[4:] for l in record if l.startswith('arg:')], [str(self.root / 'a.txt'), '-x', 'two words'])
        self.assertIn('foo:bar', record)
        # Without %s the items follow the --args arguments.
        self.open('-a', 'Viewer', 'a.txt', '--args', '-q')
        self.assertEqual(self.args('viewer'), ['-q', str(self.root / 'a.txt')])
        result = self.open('-a', 'Nonexistent', rc=1)
        self.assertEqual(result.stderr.strip(), "Unable to find application named 'Nonexistent'")

    def test_editor_roles(self):
        self.open('-e')
        self.assertEqual(self.args('editor'), [])
        (self.root / 'x.bin').write_bytes(b'\0')
        self.open('-t', 'x.bin')
        self.assertEqual(self.records('editor', 2)[1][0], 'arg:' + str(self.root / 'x.bin'))

    def test_stdin_to_temporary_file(self):
        self.open('-f', input='piped text\n')
        path = Path(self.args('editor')[0])
        self.assertEqual(path.parent, self.root)
        self.assertTrue(path.name.startswith('open_') and path.name.endswith('.txt'))
        self.assertEqual(path.read_text(), 'piped text\n')

    def test_bundles(self):
        (self.root / 'doc.fake').write_text('x')
        self.open('doc.fake')
        self.assertEqual(self.args('bundle-Fake'), [str(self.root / 'doc.fake')])
        self.open('-b', 'ORG.EXAMPLE.FAKE', '--args', 'z')
        self.open('fakeurl:abc')
        self.open('-a', 'Fake')
        self.open(self.apps / 'Fake.app')
        self.open('-a', self.apps / 'Fake.app', 'doc.fake')
        runs = sorted(tuple(r) for r in self.records('bundle-Fake', 6))
        args = sorted(tuple(l for l in r if l.startswith('arg:')) for r in runs)
        self.assertEqual(args, sorted([('arg:' + str(self.root / 'doc.fake'),), ('arg:z',), ('arg:fakeurl:abc',),
                                       (), (), ('arg:' + str(self.root / 'doc.fake'),)]))
        result = self.open('-b', 'org.example.missing', rc=1)
        self.assertEqual(result.stderr.strip(), 'Unable to find application with bundle identifier org.example.missing')

    def test_reveal_and_ignored_flags(self):
        (self.root / 'a.txt').write_text('a')
        result = self.open('-R', '-g', '-j', 'a.txt')
        self.assertIn('-R cannot select items', result.stderr)
        self.assertIn('-g has no effect', result.stderr)
        self.assertIn('-j has no effect', result.stderr)
        self.assertIn('arg:' + str(self.root), self.record('dir'))

    def test_wait(self):
        slow = self.root / 'slow.txt'
        slow.write_text('x')
        waiter = self.root / 'waiter'
        waiter.write_text(f'#!/bin/sh\nsleep 1\ntouch {self.root}/done\n')
        waiter.chmod(0o755)
        self.write_handlers(f'ext:txt ; {waiter}\n')
        started = time.monotonic()
        self.open('-W', 'slow.txt')
        self.assertGreater(time.monotonic() - started, 0.9)
        self.assertTrue((self.root / 'done').exists())

    def test_disconnect_hangs_up_terminal_handlers(self):
        pidfile = self.root / 'pid'
        script = self.root / 'waiter'
        script.write_text(f'#!/bin/sh\ntrap "touch {self.root}/hup; exit 0" HUP\necho $$ > {pidfile}\nwhile :; do sleep 0.1; done\n')
        script.chmod(0o755)
        client = subprocess.Popen([OPEN, str(script)], env=self.env(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
        eventually(lambda: pidfile.exists() and pidfile.read_text().strip())
        # The client goes away with the terminal: opend hangs up its handlers.
        client.send_signal(signal.SIGKILL)
        client.wait(timeout=5)
        eventually(lambda: (self.root / 'hup').exists())

    def test_signals_are_forwarded_to_terminal_handlers(self):
        pidfile = self.root / 'pid'
        script = self.root / 'interruptible'
        script.write_text(f'#!/bin/sh\ntrap "touch {self.root}/int; exit 0" INT\necho $$ > {pidfile}\nwhile :; do sleep 0.1; done\n')
        script.chmod(0o755)
        client = subprocess.Popen([OPEN, str(script)], env=self.env(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
        eventually(lambda: pidfile.exists() and pidfile.read_text().strip())
        client.send_signal(signal.SIGINT)
        self.assertEqual(client.wait(timeout=5), 0)
        self.assertTrue((self.root / 'int').exists())

    def test_launch_failure(self):
        (self.root / 'x.broken').write_text('')
        result = self.open('x.broken', rc=1)
        self.assertEqual(result.stderr.strip(), 'Unable to launch /definitely/missing: No such file or directory')

    def test_user_table_wins_and_unsafe_tables_are_ignored(self):
        (self.root / 'a.txt').write_text('a')
        user = self.home / '.config' / 'open' / 'handlers'
        self.write_handlers(f'ext:txt ; {self.root}/record user\nnot a valid line\n', user)
        result = self.open('a.txt')
        self.assertIn('expected', result.stderr)
        self.record('user')
        user.chmod(0o666)
        result = self.open('a.txt')
        self.assertIn('ignoring ' + str(user), result.stderr)
        self.record('text')

    def test_unavailable_service(self):
        result = self.open('-a', 'Viewer', env=self.env(MINIDARWIN_OPEN_SOCKET=str(self.root / 'none.sock')), rc=1)
        self.assertTrue(result.stderr.startswith('open: the open service is unavailable'), result.stderr)

    def test_usage(self):
        for args in [[], ['-z'], ['-a'], ['-a', 'x', '-b', 'y'], ['-f', 'file']]:
            self.assertIn('Usage: open', self.open(*args, rc=1).stderr)
        self.assertIn('not supported', self.open('-h', 'stdio.h', rc=1).stderr)

    def raw(self, request, fds=()):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(10)
            connection.connect(str(self.sock))
            data = plistlib.dumps(request)
            framed = struct.pack('!I', len(data)) + data
            connection.sendmsg([framed], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, struct.pack(f'{len(fds)}i', *fds))] if fds else [])
            header = b''
            while len(header) < 4:
                chunk = connection.recv(4 - len(header))
                if not chunk:
                    return None
                header += chunk
            length, = struct.unpack('!I', header)
            body = b''
            while len(body) < length:
                body += connection.recv(length - len(body))
            return plistlib.loads(body)

    def test_protocol_validation(self):
        bad = [{'Version': 2, 'Items': []},
               {'Version': 1, 'Items': [{'Type': 'file', 'Value': 'relative'}]},
               {'Version': 1, 'Items': [{'Type': 'other', 'Value': '/'}]},
               {'Version': 1, 'Items': []},
               {'Version': 1, 'Items': [], 'Descriptors': ['stdin']},
               {'Version': 1, 'Application': {'Name': 'Viewer', 'Path': '/x'}}]
        for request in bad:
            reply = self.raw(request)
            self.assertFalse(reply['OK'], request)
            self.assertTrue(reply['Message'].startswith('open: invalid request'), reply)
        with open(os.devnull) as null:
            reply = self.raw({'Version': 1, 'Items': [], 'Descriptors': ['bogus']}, [null.fileno()])
        self.assertFalse(reply['OK'])
        # A minimal well-formed request: no Environment, no descriptors.
        reply = self.raw({'Version': 1, 'Items': [{'Type': 'url', 'Value': 'http://x'}]})
        self.assertTrue(reply['OK'], reply)
        self.assertEqual(len(reply['Launched']), 1)
        self.assertFalse(reply['Waiting'])


class LaunchdActivationTests(Base):
    """The shipped launchd plist, retargeted at private paths."""

    def test_on_demand_launch_idle_exit_and_relaunch(self):
        jobs = self.root / 'jobs'
        jobs.mkdir()
        job = plistlib.loads(Path(PLIST).read_bytes())
        self.assertEqual(job['Program'], '/usr/libexec/opend')
        self.assertEqual(job['Sockets']['Listener']['SockPathMode'], 0o666)
        job['Program'] = OPEND
        job['ProgramArguments'] = [OPEND, '--system-handlers', str(self.handlers), '--applications', str(self.apps),
                                   '--idle-timeout', '1']
        job['Sockets']['Listener']['SockPathName'] = str(self.sock)
        job['StandardErrorPath'] = str(self.root / 'opend.log')
        job['ThrottleInterval'] = 1
        (jobs / 'opend.plist').write_bytes(plistlib.dumps(job))
        control = self.root / 'ctl.sock'
        log = (self.root / 'launchd.log').open('wb')
        launchd = subprocess.Popen([LAUNCHD, '--foreground', '--socket', control, '--jobs-dir', jobs], stdout=log, stderr=log)
        try:
            eventually(lambda: self.sock.exists())
            self.assertEqual(stat.S_IMODE(self.sock.stat().st_mode), 0o666)
            time.sleep(0.3)
            self.assertFalse(list((self.root / 'out').iterdir()))
            (self.root / 'a.txt').write_text('a')
            self.open('a.txt')
            self.record('text')
            # opend idles out; launchd keeps the socket and relaunches.
            time.sleep(2.5)
            self.open('-a', 'Viewer')
            self.record('viewer')
            self.assertTrue(self.sock.exists())
        finally:
            launchd.terminate()
            launchd.wait(timeout=10)
            log.close()
        self.assertFalse(self.sock.exists(), 'launchd removes the sockets it created')


if __name__ == '__main__':
    unittest.main()
