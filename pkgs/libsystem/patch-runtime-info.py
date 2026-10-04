"""Select Libinfo's existing stat-based file validation and local backends."""
from pathlib import Path

def edit(file, before, after):
    path = Path(file)
    text = path.read_text()
    assert text.count(before) == 1, (file, before)
    path.write_text(text.replace(before, after))

edit('lookup.subproj/si_module.c', '\t\t{ "mdns", si_module_static_mdns, NULL },\n', '')
edit('lookup.subproj/search_module.c', '\t\t\t"mdns",\n', '')
# Feature headers are irrelevant when DarwinDirectory is not configured.
edit('Libinfo/darwin_directory_enabled.h', '#include <os/feature_private.h>\n#include <os/variant_private.h>', '')
p = Path('lookup.subproj/file_module.c')
s = p.read_text()
# Keep the upstream stat path, removing only the notify-server alternatives.
def select_else(text, condition):
    start = text.index(condition)
    opening = text.index('{', start)
    def close(pos):
        depth = 1
        while depth:
            pos += 1
            depth += (text[pos] == '{') - (text[pos] == '}')
        return pos
    first_end = close(opening)
    tail = text.index('else', first_end) + 4
    second_open = text.index('{', tail)
    second_end = close(second_open)
    return text[:start] + text[second_open:second_end+1] + text[second_end+1:]
s = select_else(s, 'if (bit & pp->validation_notify_mask)')
# The first arm of this condition is the stat validation path.
start = s.index('if (pp->notify_token[vtype] < 0)')
opening = s.index('{', start)
depth = 1; pos = opening
while depth:
    pos += 1; depth += (s[pos] == '{') - (s[pos] == '}')
first_end = pos
second_open = s.index('{', s.index('else', first_end))
depth = 1; pos = second_open
while depth:
    pos += 1; depth += (s[pos] == '{') - (s[pos] == '}')
s = s[:start] + s[opening:first_end+1] + s[pos+1:]
p.write_text(s)

edit('lookup.subproj/libinfo.c', '#include <asl.h>', '')
edit('lookup.subproj/ils.c', '#include <servers/bootstrap.h>', '')
# Only its DS_AVAILABLE (opendirectory) code talks to bootstrap.
edit('membership.subproj/membership.c', '#include <servers/bootstrap.h>\n', '')
