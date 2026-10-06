# The open protocol, version 1

`/usr/bin/open` holds no policy. It parses Apple's command line, canonicalizes
it, and sends one request to whatever daemon serves the open socket. Which
program handles an item, how it is launched, and where it runs are that
daemon's decisions. MiniDarwin ships one daemon (`/usr/libexec/opend`, see
`pkgs/open/README.md`); an environment such as Rosemary replaces it with its
own, behind this protocol, without changing the client.

This document is the contract. A change to anything below is a new `Version`,
not an edit.

## Transport

- An `AF_UNIX` `SOCK_STREAM` socket at `/private/var/run/org.minidarwin.open.sock`.
  The client honors `MINIDARWIN_OPEN_SOCKET` instead, when set and nonempty.
- One request per connection. The client sends one `Request` frame; the daemon
  answers with one `Reply` frame and, if the reply says `Waiting`, later one
  `Completion` frame. Either side then closes.
- A frame is a big-endian `uint32` byte length (1 to 1 MiB) followed by that
  many bytes of an XML property list (`<plist version="1.0">`), UTF-8. This is
  the framing of launchd's control socket. Values used: `string`, `integer`,
  `true`/`false`, `array`, `dict`. Unknown dictionary keys are ignored by
  readers, so a later version can add optional keys.
- File descriptors travel as one `SCM_RIGHTS` control message on the request's
  first byte, at most six. Their meaning is the request's `Descriptors` key.
- Peer identity is the socket's: `LOCAL_PEERCRED` (`struct xucred`, effective
  UID and groups) and `LOCAL_PEERPID`. A daemon acts with the caller's
  credentials, never its own.

The daemon must not assume it shares the client's working directory, mount
namespace view, environment or terminal; everything it needs is in the request.

## Request

| Key | Type | Meaning |
| --- | --- | --- |
| `Version` | integer | `1`. |
| `Items` | array of dict | What to open, in command-line order (`-u` URLs first). Each is `{Type, Value}`: `Type` `file` with `Value` an absolute, symlink-resolved path that existed when the client checked; or `Type` `url` with `Value` a URL with a scheme. `file:` URLs are sent as their paths. May be empty when an application or role is named. |
| `Application` | dict, optional | Exactly one of `Path` (absolute, resolved; a `.app` bundle or an executable), `Name` (`-a NAME` without a slash, `-e` sends `TextEdit`), or `BundleIdentifier` (`-b`). Every item goes to this application. |
| `Role` | string, optional | `TextEditor` for `-t` and `-f`: the user's default text editor. Not sent with `Application`. |
| `Arguments` | array of string | `--args`: the application's argv after its name. |
| `Environment` | dict of string | The client's whole environment. |
| `EnvironmentOverrides` | dict of string | `--env` entries, applied over `Environment`. `--env NAME` is the empty string. |
| `WorkingDirectory` | string, optional | The client's working directory. |
| `Options` | dict | Booleans `Wait` (`-W`), `NewInstance` (`-n`), `Background` (`-g`), `Hide` (`-j`), `Fresh` (`-F`), `Reveal` (`-R`); string `Architecture` (`--arch`), present only when given. |
| `Descriptors` | array of string | One name per descriptor sent, in order. `stdin`, `stdout`, `stderr`: `-i`, `-o`, `--stderr`, opened by the client with its own permissions (outputs `O_WRONLY|O_CREAT|O_TRUNC`). `caller-stdin`, `caller-stdout`, `caller-stderr`: the client's own terminal streams, for handlers that run on it (for `-f`, which consumed stdin, `caller-stdin` is `/dev/tty` when there is one). Each name at most once. |

The client resolves `-f` itself: standard input is copied to
`$TMPDIR/open_XXXXXXXX.txt`, which becomes the only item, with `Role`
`TextEditor` unless an application was named.

## Reply

| Key | Type | Meaning |
| --- | --- | --- |
| `Version` | integer | `1`. |
| `OK` | bool | False: nothing more will come, and `open` exits 1. |
| `Message` | string | When not `OK`, printed verbatim to stderr. Use macOS's wording where it has one (below). |
| `Warnings` | array of string | Printed verbatim to stderr, success or not. |
| `Launched` | array of dict | `{PID, Program}` per process started. `PID` is a process group the client may signal, containing the handler; 0 means none (a host process, for example). |
| `Waiting` | bool | A `Completion` follows. The daemon sets it for `-W`, and may set it when a handler runs on the caller's terminal. |
| `Terminal` | bool | Some launched process uses the caller's terminal. While waiting, the client forwards SIGINT, SIGQUIT, SIGTERM and SIGHUP to the process group of each nonzero `PID` (it is the terminal's foreground group; the handler is not). |

## Completion

`{Version: 1, Event: "exited", Results: [{PID, ExitStatus | ExitSignal}]}`.
`open` exits 0 when it arrives, as macOS's `open -W` does.

If the client closes the connection before the completion (it was killed, or
its user gave up), the daemon stops waiting. A daemon that gave a handler the
caller's terminal should hang that handler up (SIGHUP to its process group).

## Errors and exit status

The client exits 1, after printing one line, for:

| Case | Text |
| --- | --- |
| A file argument that does not exist | `The file /abs/path does not exist.` |
| `-a NAME` not found | `Unable to find application named 'NAME'` |
| `-b ID` not found | `Unable to find application with bundle identifier ID` |
| No handler for a file / URL | `No application knows how to open /abs/path.` / `No application knows how to open URL url.` |
| No daemon | `open: the open service is unavailable (...)` |
| Bad usage | The usage text |

A daemon reports its own failures through `Message` and should keep to the
same wording. Requests the daemon cannot parse get a `Message` beginning
`open: invalid request:`.

Not supported by the client: `-h` and `-s` (header search) exit 1.

## Replacing the daemon

On MiniDarwin the daemon is a launchd job with an on-demand socket
(`/System/Library/LaunchDaemons/org.minidarwin.opend.plist`): launchd owns the
socket and starts the job when a client connects. To serve the socket with
another daemon:

1. Disable the default job, so it no longer claims the socket at boot:
   `launchctl disable system/org.minidarwin.opend`, or, when building an image,
   `/private/var/db/minidarwin-launchd/disabled.plist` containing
   `<dict><key>org.minidarwin.opend</key><true/></dict>` (root-owned, not
   group/world writable).
2. Install a job claiming the same path, for example
   `/Library/LaunchDaemons/com.example.opend.plist` with
   `Sockets` → `Listener` → `SockPathName`
   `/private/var/run/org.minidarwin.open.sock`, `SockPathMode` `438` (0666).
   launchd refuses a second job claiming a path another job owns.
3. The job finds the listening socket as descriptor `N` in
   `MINIDARWIN_LAUNCHD_SOCKETS="Listener=N"`, accepts connections, and may
   exit when idle: launchd keeps the socket and relaunches it on the next
   connection.

Everything the client sends speaks the guest's view: guest paths, the guest
environment, guest descriptors. A daemon forwarding to another system (a Linux
host's `xdg-open` or the `org.freedesktop.portal.OpenURI` portal) translates
paths itself; the protocol never carries host paths.
