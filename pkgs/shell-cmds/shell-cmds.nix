# Stage 6: the first userland -- shell_cmds targets (see ../cmds/mk-cmds.nix).
# Not reproduced: apple-generic versioning's generated <tool>_vers.c (the
# __<tool>VersionString symbol), which nothing references. The "All"
# aggregate's install-files.sh is: its hardlinks (id to groups and whoami,
# test to [, hexdump to od, alias to each regular builtin) as symlinks, and its
# scripts and files, in extraInstall.
#
# Not built: apply (<usbuf.h>, from libsbuf, which Apple has not released),
# su (links libpam; and it is set-uid, which the rootfs format cannot say),
# w/uptime (written against libxo, which Apple has not released either); the
# test helpers killall_test_prog and su_test_setauid.
#
# users is C++, so this package links with toolchainStage4 (see mk-cmds.nix).
{ lib
, mkCmds
, sources
, toolchain
, shGenerated
, libedit
, bison
}:

let
  # Per target, what differs from the project's Release settings; the
  # attributes are described in mk-cmds.nix.
  tools = {
    basename = { };
    chroot = {
      installDir = "/usr/sbin";
      man = { "chroot/chroot.8" = "/usr/share/man/man8/chroot.8"; };
      # -u, -g, -G: users and groups by name.
      allowUndefined = {
        "_getgrnam" = "system_info";
        "_getpwnam" = "system_info";
      };
    };
    date = {
      installDir = "/bin";
      # Setting the clock logs it to utmpx and to syslog; both are in
      # libsystem_asl (see who).
      allowUndefined = {
        "_pututxline" = "system_asl";
        "_syslog$DARWIN_EXTSN" = "system_asl";
      };
    };
    dirname = { };
    echo = { installDir = "/bin"; };
    env = { allowUndefined."_environ" = "dyld"; }; # see find
    expr = {
      installDir = "/bin";
      cflags = [ "-fwrapv" ]; # OTHER_CFLAGS
    };
    false = { };
    find = {
      defines = [ "__FBSDID=__RCSID" "_DARWIN_USE_64_BIT_INODE" ];
      allowUndefined = {
        # -exec's execvp inherits it. Defined by libdyld (libdyldGlue.cpp),
        # which also carries the executable's NXArgv and __progname.
        "_environ" = "dyld";
        # -user, -group, -nouser, -nogroup, -ls.
        "_getgrnam" = "system_info";
        "_getpwnam" = "system_info";
        "_group_from_gid" = "system_info";
        "_user_from_uid" = "system_info";
      };
    };
    getopt = { };
    hexdump = {
      man = {
        "hexdump/hexdump.1" = "/usr/share/man/man1/hexdump.1";
        "hexdump/od.1" = "/usr/share/man/man1/od.1";
      };
      links."/usr/bin/od" = "/usr/bin/hexdump";
    };
    hostname = { installDir = "/bin"; };
    id = {
      defines = [ "__FBSDID=__RCSID" "USE_BSM_AUDIT" ];
      man = {
        "id/groups.1" = "/usr/share/man/man1/groups.1";
        "id/id.1" = "/usr/share/man/man1/id.1";
        "id/whoami.1" = "/usr/share/man/man1/whoami.1";
      };
      links = {
        "/usr/bin/groups" = "/usr/bin/id";
        "/usr/bin/whoami" = "/usr/bin/id";
      };
      allowUndefined = {
        "_getgrgid" = "system_info";
        "_getgrouplist_2" = "system_info";
        "_getpwnam" = "system_info";
        "_getpwuid" = "system_info";
      };
    };
    jot = { };
    kill = { installDir = "/bin"; };
    killall = {
      # -u: a user by name, or the invoking user's own.
      allowUndefined = {
        "_getpwnam" = "system_info";
        "_getpwuid" = "system_info";
      };
    };
    lastcomm = {
      allowUndefined = {
        "_fmod" = "system_m"; # the elapsed-time column
        "_user_from_uid" = "system_info";
      };
    };
    locate = {
      man = {
        "locate/locate/locate.1" = "/usr/share/man/man1/locate.1";
        "locate/locate/locate.updatedb.8" = "/usr/share/man/man8/locate.updatedb.8";
      };
    };
    "locate.bigram" = {
      installDir = "/usr/libexec";
      includes = [ "locate/locate" ]; # locate.h, found by Xcode's header map
      man = { "locate/bigram/locate.bigram.8" = "/usr/share/man/man8/locate.bigram.8"; };
    };
    "locate.code" = {
      installDir = "/usr/libexec";
      includes = [ "locate/locate" ]; # see locate.bigram
      man = { "locate/code/locate.code.8" = "/usr/share/man/man8/locate.code.8"; };
    };
    lockf = { cflags = [ "-std=gnu11" ]; }; # GCC_C_LANGUAGE_STANDARD
    logname = { };
    mktemp = { };
    nice = { };
    nohup = { };
    path_helper = {
      installDir = "/usr/libexec";
      man = { "path_helper/path_helper.8" = "/usr/share/man/man8/path_helper.8"; };
    };
    printenv = { allowUndefined."_environ" = "dyld"; }; # see find
    printf = { };
    pwd = { installDir = "/bin"; };
    realpath = { installDir = "/bin"; };
    renice = {
      man = { "renice/renice.8" = "/usr/share/man/man8/renice.8"; };
      allowUndefined."_getpwnam" = "system_info"; # -u user
    };
    script = { };
    seq = { };
    # xcconfigs/sh.xcconfig: installed as ash (its TODO is to become /bin/sh).
    sh = {
      installDir = "/usr/local/bin";
      product = "ash";
      defines = [ "SHELL" ];
      includes = [ "BUILT_PRODUCTS_DIR" "sh" ];
      libraries = [{ pkg = libedit; l = "edit"; }]; # OTHER_LDFLAGS = -ledit
      cflags = [
        "-Werror=incompatible-pointer-types" # GCC_TREAT_INCOMPATIBLE_POINTER_TYPE_WARNINGS_AS_ERRORS
        "-Werror=return-type" # GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR
      ];
      builtProducts = shGenerated;
      man = { "sh/sh.1" = "/usr/local/share/man/man1/ash.1"; };
      allowUndefined = {
        "_environ" = "dyld"; # see find
        "_getpwnam" = "system_info"; # ~user expansion
      };
    };
    shlock = { };
    sleep = { installDir = "/bin"; };
    stdbuf = {
      installDir = "/usr/local/bin";
      cflags = [ "-std=gnu17" ]; # GCC_C_LANGUAGE_STANDARD
    };
    systime = {
      installDir = "/usr/local/bin";
      man = { "systime/systime.1" = "/usr/local/share/man/man1/systime.1"; };
    };
    tee = { };
    test = {
      installDir = "/bin";
      man = {
        "test/test.1" = "/usr/share/man/man1/test.1";
        "test/[.1" = "/usr/share/man/man1/[.1";
      };
      links."/bin/[" = "/bin/test";
    };
    time = { };
    true = { };
    uname = { };
    users = {
      allowUndefined = {
        "_endutxent" = "system_asl"; # see who
        "_getutxent" = "system_asl";
        "_setutxent" = "system_asl";
      };
    };
    what = { };
    whereis = { };
    which = { };
    who = {
      defines = [ "__FBSDID=__RCSID" "_UTMPX_COMPAT" "SUPPORT_UTMPX" ];
      # Libc's utmpx is not in libsystem_c: utmpx-darwin.c (which utmpx.c
      # cannot do without) is written against <asl.h>. See libsystem-c.nix.
      allowUndefined = {
        "_endutxent" = "system_asl";
        "_getutxent" = "system_asl";
        "_getutxline" = "system_asl";
        "_utmpxname" = "system_asl";
        "_wtmpxname" = "system_asl";
        # whoami(), when the tty is not in utmpx.
        "_getpwuid" = "system_info";
      };
    };
    xargs = { allowUndefined."_environ" = "dyld"; }; # see find
    yes = { };
  };

  # xcodescripts/builtins.txt: the regular builtins POSIX requires to exist
  # as utilities, each a link to alias/generic.sh.
  builtins = [ "bg" "cd" "command" "fc" "fg" "getopts" "hash" "jobs" "read" "type" "ulimit" "umask" "unalias" "wait" ];
in

mkCmds {
  pname = "shell_cmds";
  src = sources.shell_cmds;
  inherit toolchain tools;
  sourceLists = import ./shell-cmds-sources.nix;

  nativeBuildInputs = [ bison ]; # find's getdate.y, expr's expr.y

  # nohup detaches from the console's bootstrap namespace through launchd's
  # private <vproc.h>, which was never released. Without it, nohup does
  # everything else POSIX asks of it (SIGHUP ignored, output to nohup.out).
  postPatch = ''
    sed -i nohup/nohup.c \
      -e 's|^#include <vproc.h>$|#if __has_include(<vproc_priv.h>)\n&|' \
      -e 's|^#include <vproc_priv.h>$|&\n#endif|' \
      -e 's|^#if defined(__APPLE__) && !(TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR)$|& \&\& __has_include(<vproc_priv.h>)|'
    [ "$(grep -c '__has_include(<vproc_priv.h>)' nohup/nohup.c)" = 2 ] || {
      echo "nohup.c: the vproc guard no longer applies" >&2; exit 1; }
  '';

  # Project-level Release settings (shell_cmds.xcodeproj).
  cflags = [
    "-std=gnu99" # GCC_C_LANGUAGE_STANDARD
    "-Os" # GCC_OPTIMIZATION_LEVEL (Release default)
    "-fno-common" # GCC_NO_COMMON_BLOCKS
    "-Wall"
    "-Werror=format-nonliteral" # WARNING_CFLAGS
    "-Werror=implicit-function-declaration" # GCC_TREAT_IMPLICIT_FUNCTION_DECLARATIONS_AS_ERRORS
  ];
  defines = [ "__FBSDID=__RCSID" ]; # GCC_PREPROCESSOR_DEFINITIONS
  ldflags = [ "-Wl,-dead_strip" ]; # DEAD_CODE_STRIPPING

  # The rest of xcodescripts/install-files.sh (su's pam.d file aside).
  extraInstall = ''
    install -Dm755 alias/generic.sh $out/usr/bin/alias
    install -Dm644 alias/builtin.1 $out/usr/share/man/man1/builtin.1
    for b in ${lib.escapeShellArgs builtins}; do
      ln -s alias $out/usr/bin/$b
    done
    while IFS= read -r page; do
      echo ".so man1/builtin.1" > $out/usr/share/man/man1/$page
    done < xcodescripts/builtins-manpages.txt

    install -Dm755 locate/locate/updatedb.sh $out/usr/libexec/locate.updatedb
    install -Dm755 locate/locate/concatdb.sh $out/usr/libexec/locate.concatdb
    install -Dm755 locate/locate/mklocatedb.sh $out/usr/libexec/locate.mklocatedb
    echo ".so man8/locate.updatedb.8" > $out/usr/share/man/man8/locate.concatdb.8
    echo ".so man8/locate.updatedb.8" > $out/usr/share/man/man8/locate.mklocatedb.8
    # The locate target's copy phase.
    install -Dm644 locate/locate/locate.rc $out/private/etc/locate.rc
  '';
}
