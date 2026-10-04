"""Normalize inode ownership and creation times without mounting an ext4 image."""
from pathlib import Path
import subprocess
import sys

root, image = map(Path, sys.argv[1:])
paths = [root, *sorted(root.rglob('*'))]
commands = []
for path in paths:
    relative = '/' + path.relative_to(root).as_posix()
    if relative == '/.':
        relative = '/'
    # debugfs has a quoted pathname syntax; reject ambiguous command input.
    if any(c in relative for c in ('"', '\\', '\n', '\r')):
        raise ValueError(f'unsupported image pathname: {relative!r}')
    for field, value in [('uid', 0), ('gid', 0), ('ctime', 315532800),
                         ('crtime', 315532800), ('atime', 315532800), ('mtime', 315532800)]:
        commands.append(f'set_inode_field "{relative}" {field} {value}\n')
command_file = Path('normalize.debugfs')
command_file.write_text(''.join(commands))
result = subprocess.run(['debugfs', '-w', '-f', str(command_file), str(image)],
                        capture_output=True, text=True, check=True)
# debugfs reports command failures without setting a failing exit status.
if any(line and not line.startswith(('debugfs ', 'debugfs: '))
       for line in result.stderr.splitlines()):
    raise RuntimeError(result.stderr)
