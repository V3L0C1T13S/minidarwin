# MiniDarwin launchd

An independent C++23 init and process supervisor. Target binaries use MiniDarwin's
SDK, libc++, libSystem, and libxml2. This is a documented subset of launchd, with
no Apple launch/bootstrap ABI, Mach service registration, XPC, calendars, user
login domains, or account name lookup. On-demand Unix sockets are supported,
handed to jobs by descriptor rather than through `launch_activate_socket`.

MiniDarwin does not yet include dyld or boot infrastructure. Installing this
package adds `/sbin/launchd` and `/bin/launchctl`; it does not make the rootfs
bootable. No service or console shell is enabled by default.

## Running

Normal invocation requires PID 1. It loads XML `.plist` files in sorted order
from `/System/Library/LaunchDaemons`, then `/Library/LaunchDaemons`. Directories
and files must be root-owned and not group/world writable; symlinked job files
are refused. Invalid files are logged and skipped. Duplicate labels never
replace an existing job. Binary plists are unsupported.

For development, use the host-only `launchdBootstrap` package with an isolated
instance (the socket parent must belong to your UID and have no group/world
write permission):

```sh
mkdir -m 700 /tmp/my-launchd
mkdir /tmp/my-launchd/jobs
launchd --foreground --socket /tmp/my-launchd/control.sock --jobs-dir /tmp/my-launchd/jobs
launchctl --socket /tmp/my-launchd/control.sock list
```

Foreground mode requires explicit socket and job paths, refuses the system
socket and system job directories, and disallows all per-job identity changes.
Use the actual host package paths to avoid invoking macOS's launchd/launchctl.

## Job keys

The supported keys follow [Apple's launchd.plist documentation](https://github.com/apple-oss-distributions/launchd/blob/main/man/launchd.plist.5)
where described below. Other keys and incorrect types are rejected.

| Key | Type and behavior |
| --- | --- |
| `Label` | Required string, 1–255 ASCII letters, digits, dots, underscores, or hyphens; unique per daemon. |
| `Program` | Absolute executable path. |
| `ProgramArguments` | Nonempty string array passed verbatim as argv. When Program is absent, argv[0] must be an absolute executable path. If omitted, Program supplies argv[0]. |
| `RunAtLoad` | Boolean, default false. Start once when loaded. |
| `KeepAlive` | Boolean, default false. Start immediately and restart after any exit or launch failure. Dictionary conditions are unsupported. |
| `Disabled` | Boolean, default false. True prevents loading; there is no persistent override database. |
| `ThrottleInterval` | Integer seconds, default 10, maximum 86400. Minimum time between attempts, including manual starts; zero is clamped to 1 to prevent crash loops. |
| `ExitTimeOut` | Integer seconds, default 20, range 0–86400. Grace period before SIGKILL; zero means immediate escalation. |
| `EnvironmentVariables` | Dictionary of strings. Base environment contains only PATH=/usr/bin:/bin:/usr/sbin:/sbin, then job overrides. Parent environment is not inherited. |
| `WorkingDirectory` | Absolute path; otherwise inherits the daemon's working directory. |
| `StandardInPath` | Absolute regular-file path; default /dev/null. |
| `StandardOutPath`, `StandardErrorPath` | Absolute regular-file paths opened for append, created with mode 0600, or exactly `/dev/console`; default /dev/null. Parent directories must already exist. Symlinks and other device/FIFO paths are refused. |
| `UserID`, `GroupID` | MiniDarwin extensions: numeric UID and GID, supplied together; require root and normal PID 1 mode. The reserved all-ones ID is rejected. |
| `SupplementaryGroups` | MiniDarwin extension: up to 16 numeric GIDs; requires UserID and GroupID. Groups are cleared when identity is specified without this key. |
| `Sockets` | Dictionary of 1–16 sockets, each named like a Label and described by a dictionary: `SockPathName` (required, absolute), `SockPathMode` (integer, default 0600), and optionally `SockType` `stream`, `SockFamily` `Unix`, `SockPassive` true. Only listening Unix stream sockets exist. See below. |

Job files are limited to 1 MiB, 32 levels of value nesting, and 16384 values.
Duplicate dictionary keys, unknown keys, invalid integers, embedded NULs,
entity declarations, and external resource loading are rejected. A conventional
plist DOCTYPE is accepted without retrieving its DTD. Jobs execute directly,
with no PATH search or implicit shell. Use an explicit shell in argv when wanted.

The example plist is installed under `/usr/share/doc/launchd`, outside the active
job directories. Copy and adjust it deliberately before enabling a service.

## Sockets (on-demand jobs)

launchd creates, binds and listens on a job's sockets when it loads the job,
replacing a stale socket at the path (never any other file type), and removes
them when the job is unloaded or launchd exits. Two jobs cannot claim the same
path. While such a job is idle and enabled, a pending connection on any of its
sockets starts it, subject to ThrottleInterval; the connection waits in the
backlog. The job's sockets become descriptors 3, 4, ... in sorted name order,
named by `MINIDARWIN_LAUNCHD_SOCKETS`, for example `Listener=3`. launchd never
accepts on them. A job may exit when idle: launchd watches the sockets again
and relaunches it for the next client. `stop` disables activation until
`start`. `/usr/libexec/opend` (`pkgs/open`) is the shipped example.

## Overrides

`launchctl disable LABEL` and `launchctl enable LABEL` (a `system/` prefix is
accepted) record an override in `/private/var/db/minidarwin-launchd/disabled.plist`,
an XML dictionary of label to boolean, written atomically, mode 0644. As in
Apple's launchd, an override beats the job's own `Disabled` key, and takes
effect at the next load: it neither stops nor starts a loaded job. An image can
ship the file directly (root-owned, not group/world writable) to keep a system
job from loading, for example to let another job own its socket. Foreground
mode has no database unless given `--overrides PATH`.

## Control and lifecycle

```sh
launchctl load /absolute/path/to/job.plist
launchctl list [label]
launchctl start label
launchctl stop label
launchctl unload label
launchctl disable label
launchctl enable label
```

Commands return nonzero on errors. Load registers a job; it does not wait for
exec success. Start/stop/unload acknowledge the requested transition; consult
list for completion. List shows PID, state, last exit status or signal, label,
and last launch error. Exit results remain available until the next exit.

Stop disables automatic restarts until an explicit start. Start is idempotent
for a running job; it fails while that job is stopping. Unload removes the job
after stopping; a new job with the same label cannot be loaded until removal
completes. Manual starts respect throttling. States are idle, waiting,
launching, running, and stopping.

Each job runs in its own process group. Stop sends SIGTERM, followed by SIGKILL
after ExitTimeOut. Leader exit also triggers group cleanup before reaping and
restarting. A daemon must remain in the foreground; descendants deliberately
leaving its process group cannot be contained by this version. Setup or exec
failure prevents the requested program from executing and is reported through
a close-on-exec error pipe. Stdio files are opened by the supervisor before
credential dropping; use trusted output directories and deliberate file ownership.

SIGTERM/SIGINT disable restarts and stop all managed jobs. Foreground mode exits
after cleanup; PID 1 remains alive, serving status and reaping children. It does
not reboot or power off. SIGHUP is consumed without reloading; load/unload are
explicit. Fatal PID 1 initialization errors are logged, then a minimal child
reaper stays alive; recovery and boot policy are future work.

The control socket is `/private/var/run/minidarwin-launchd/control.sock`, mode
0600, authenticated to the daemon's UID using peer credentials. Requests and
responses are big-endian uint32 byte lengths followed by UTF-8 XML plists.
Requests contain Version=1, Command, and Argument; responses contain Version=1,
OK, Message, and Jobs. Messages are bounded to 1 MiB, with at most 32 clients and
5-second request/response deadlines. One request is accepted per connection.
The singleton lock inode persists across runs; only the owned socket is removed.

## Verification

`nix build .#launchd .#launchdTest` builds target artifacts and runs isolated host
unit/integration tests, including socket activation and overrides. `nix flake check` includes launchdTest. Cross builds never
execute target binaries. Tests cover configuration rejection, descriptor
ownership, lifecycle transitions, environment/cwd/stdio, rapid exits, restart
throttling, failed launches, group cleanup, stalled clients, and shutdown. They
never contact macOS launchd. Runtime tests use host libSystem. Unit probes test credential dropping when
run as root and otherwise report a skip; foreground identity rejection is always
covered. Actual PID 1 and target-runtime validation require a future bootable
MiniDarwin system.
