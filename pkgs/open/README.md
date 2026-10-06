# MiniDarwin open

`/usr/bin/open` and its default service, `/usr/libexec/opend`. As on macOS,
`open` is a thin client: it parses Apple's options and marshals a request; the
daemon decides what handles each item. The protocol between them,
`docs/open-protocol.md` (installed beside this file), is the stable boundary:
another environment replaces `opend` without touching `open`.

Both are C++23 over launchd's plist and framing code (`../launchd/common.cpp`),
linking only libSystem, libc++ and libxml2.

## open

Options are Apple's: `-a`, `-b`, `-e`, `-t`, `-f`, `-F`, `-R`, `-W`, `-n`,
`-j`, `-g`, `-u`, `-i`/`--stdin`, `-o`/`--stdout`, `--stderr`, `--env`,
`--arch`, `--args`. As with BSD `getopt`, the first file ends option parsing;
`--args` is recognized anywhere. An argument that names an existing path is a
file even if it looks like a URL; `-u` forces a URL. Paths are made absolute
and symlink-resolved before sending. `-h`/`-s` (header search) are refused.

## opend

launchd starts `opend` when a client connects to its socket
(`org.minidarwin.opend.plist`, a `Sockets` job), and `opend` exits after 30
idle seconds. Each connection is served by a forked worker that first takes
the caller's identity (`LOCAL_PEERCRED`: effective UID and groups), so table
lookups, file inspection and launches all happen with the caller's
permissions. A non-root `opend` serves only its own UID.

Resolution, for each item, first match wins:

1. `-a`/`-b`/`-e`: the named application gets every item. `-a NAME` looks up
   `app:NAME` in the tables, then bundles by file or `CFBundleName`; `-b ID`
   looks up `bundle:ID`, then `CFBundleIdentifier` (case-insensitively).
   `-a /path` is a bundle, or an executable run on the caller's terminal.
2. `-t`/`-f`: `role:editor`.
3. A `.app` launches itself. A URL uses `scheme:`. A directory uses
   `type:directory`. A regular file tries `ext:` (last extension,
   case-insensitive), a bundle claiming that extension, `type:executable`
   (executable files), `type:text` (first 4 KiB has no NUL and is UTF-8),
   then `type:file`.

Tables: `~/.config/open/handlers` (`$HOME` from the caller's environment),
then `/etc/open/handlers`; for any selector the user's table wins. Bundle
claims come after both. A table that is not a regular file owned by its user
(root for the system table) or that is group/world writable is ignored with a
warning. The format is documented at the top of `/etc/open/handlers`:

```
selector[,selector...] ; command words ; flag ; ...
```

with selectors `ext:` `type:` `scheme:` `app:` `bundle:` `role:` (a bare value
repeats the previous kind), and flags `needsterminal` (the caller's terminal
streams, and an implicit wait) and `single` (one process per item; otherwise
items for the same handler share one process, as one application receives
every document). A word that is exactly `%s` becomes the items; otherwise
argv is the command, then `--args` arguments, then the items. Words split on
blanks, without quoting; a bare program name is searched in the caller's
`PATH`.

The defaults suit a console system: text and source files and `-e`/`-t` open
in `nano`, directories list with `ls -la`, executables and `.command` scripts
run on the terminal, and `open -a Terminal` starts a shell.

Launched processes start in a new session (`setsid`), so they outlive the
worker, `opend` and launchd's job cleanup. The session's leader is a small
holder process that waits for the handler and exits the same way; it is the
`PID` reported, and its process group contains the handler. The handler itself
is never a session leader, so it can never acquire the caller's terminal as
its controlling terminal (whose revocation, when it exited, would hang up the
caller's shell). Their environment is the caller's plus
`--env`; their working directory is the caller's (or `/`); their streams are
`-i`/`-o`/`--stderr` when given, the caller's terminal for `needsterminal`,
and `/dev/null` otherwise.

### Bundles without CoreServices

`.app` bundles are read from `/Applications`, `/Applications/Utilities`,
`/System/Applications`, `/System/Applications/Utilities` and
`~/Applications`. Only XML `Info.plist` files are understood (binary plists
are skipped). `CFBundleDocumentTypes`' `CFBundleTypeExtensions` and
`CFBundleURLTypes`' `CFBundleURLSchemes` register claims. The bundle's
`Contents/MacOS/<CFBundleExecutable>` is executed directly, with documents in
argv: there are no Apple Events, so `odoc`/`GURL` delivery is a documented
degradation, and nothing tracks running instances.

### Accepted, not implemented

`-n` is always true (every open launches). `-g`, `-j`, `-F` and `--arch` are
accepted with a warning: there is no window server. `-R` opens each item's
enclosing directory with `type:directory`, with a warning, since nothing can
select an item. `-W` waits for the processes this request launched, not for
earlier instances.

## Development

`opend --socket PATH --system-handlers PATH --applications DIR --idle-timeout 0`
serves a private socket without launchd; point `open` at it with
`MINIDARWIN_OPEN_SOCKET`. `nix build .#openTest` runs `test-open.py`
against host builds of both (`openBootstrap`), including the shipped launchd
job under a foreground launchd.
