# Stage 6: file_cmds targets (see ../cmds/mk-cmds.nix).
# Not reproduced: apple-generic versioning's generated <tool>_vers.c, as for
# shell_cmds; and the targets' Copy Test Files phases (/AppleInternal/Tests).
# The aggregates that only hardlink a tool under another name (chgrp, link,
# readlink, sum, uncompress, unlink) are its `links`, as symlinks; shar, a
# script, is extraInstall.
#
# Not built: df (written against libxo, which Apple has not released), ipcs
# (Kernel.framework's private headers, for the kernel's struct layouts), gzip
# (zlib, libbz2 and liblzma), mtree (CoreFoundation); the test helpers
# gettime_ns, sparse and touch_epoch.
{ lib
, mkCmds
, sources
, toolchain
, libutil
, ncurses
, libmd
, commonCryptoHeaders
}:

let
  defines = [ "__FBSDID=__RCSID" "_DARWIN_USE_64_BIT_INODE" ]; # GCC_PREPROCESSOR_DEFINITIONS

  # xattr and truncate: targets from Xcode's newer template, which set these.
  modernCflags = [
    "-std=gnu11" # GCC_C_LANGUAGE_STANDARD
    "-Wshorten-64-to-32" # GCC_WARN_64_TO_32_BIT_CONVERSION
    "-Werror=return-type" # GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR
    "-Wconditional-uninitialized" # GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE
  ];

  # Per target, what differs from the project's Release settings; the
  # attributes are described in mk-cmds.nix.
  tools = {
    chflags = { };
    chmod = {
      installDir = "/bin";
      # +a/-a: an ACL entry's user or group name to its UUID.
      allowUndefined."_mbr_identifier_to_uuid" = "system_info";
    };
    chown = {
      installDir = "/usr/sbin";
      man = {
        "chown/chown.8" = "/usr/share/man/man8/chown.8";
        "chown/chgrp.1" = "/usr/share/man/man1/chgrp.1"; # the chgrp aggregate's
      };
      links."/usr/bin/chgrp" = "/usr/sbin/chown";
      # Owner and group given by name.
      allowUndefined = {
        "_getgrnam" = "system_info";
        "_getpwnam" = "system_info";
      };
    };
    cksum = {
      man = {
        "cksum/cksum.1" = "/usr/share/man/man1/cksum.1";
        "cksum/sum.1" = "/usr/share/man/man1/sum.1";
      };
      links."/usr/bin/sum" = "/usr/bin/cksum";
    };
    compress = {
      man = {
        "compress/compress.1" = "/usr/share/man/man1/compress.1";
        "compress/uncompress.1" = "/usr/share/man/man1/uncompress.1";
      };
      links."/usr/bin/uncompress" = "/usr/bin/compress";
    };
    cp = {
      installDir = "/bin";
      # Regular files are copied by fcopyfile() (data, then xattrs and ACLs
      # by copyfile's state), so without libcopyfile cp can make only
      # directories, links and special files.
      allowUndefined = {
        "_copyfile_state_alloc" = "copyfile";
        "_copyfile_state_free" = "copyfile";
        "_copyfile_state_get" = "copyfile";
        "_copyfile_state_set" = "copyfile";
        "_fcopyfile" = "copyfile";
      };
    };
    dd = {
      installDir = "/bin";
      libraries = [{ pkg = libutil; l = "util"; }]; # frameworks phase
    };
    du = { libraries = [{ pkg = libutil; l = "util"; }]; };
    install = {
      # Frameworks phase: libmd.tbd, for -M's digests.
      libraries = [{ pkg = libmd; l = "md"; }];
      cflags = [ "-I${commonCryptoHeaders}/usr/include" ]; # libmd's headers include it
      allowUndefined = lib.genAttrs
        (lib.concatMap (d: [ "_CC_${d}_Init" "_CC_${d}_Update" ]) [ "SHA1" "SHA256" "SHA512" ])
        (_: "commonCrypto") # libmd's #defines, as for md5 (text_cmds)
      // {
        "_environ" = "dyld"; # -s runs strip(1) with it; see shell_cmds' find
        "_fcopyfile" = "copyfile"; # the copied file's metadata, as for cp
        # -o, -g: owner and group by name.
        "_getgrnam" = "system_info";
        "_getpwnam" = "system_info";
      };
    };
    ipcrm = { };
    ln = {
      installDir = "/bin";
      man = {
        "ln/ln.1" = "/usr/share/man/man1/ln.1";
        "ln/link.1" = "/usr/share/man/man1/link.1"; # the link aggregate's
        "ln/symlink.7" = "/usr/share/man/man7/symlink.7";
      };
      links."/bin/link" = "/bin/ln";
    };
    ls = {
      installDir = "/bin";
      defines = defines ++ [ "COLORLS" ];
      # Frameworks phase: libutil.dylib (humanize_number, for -h) and
      # libcurses.dylib (termcap, for -G), which is libncurses' symlink.
      libraries = [
        { pkg = libutil; l = "util"; }
        { pkg = ncurses; l = "curses"; }
      ];
      allowUndefined = {
        # -l, -n, -o, -g: owner and group names.
        "_group_from_gid" = "system_info";
        "_user_from_uid" = "system_info";
        # -e: ACL entries name their user or group by UUID.
        "_mbr_identifier_translate" = "system_info";
      };
    };
    mkdir = { installDir = "/bin"; };
    mkfifo = { };
    mknod = {
      installDir = "/sbin";
      cflags = [ "-DHAVE_NBTOOL_CONFIG_H=0" ]; # OTHER_CFLAGS
      man = { "mknod/mknod.8" = "/usr/share/man/man8/mknod.8"; };
      allowUndefined."_getgrnam" = "system_info"; # -F's owner:group by name
    };
    mv = {
      installDir = "/bin";
      allowUndefined = {
        # Across file systems, fastcopy() copies the data itself, then
        # fcopyfile() the ACL and xattrs.
        "_fcopyfile" = "copyfile";
        # The prompt before overwriting a target it cannot write names its
        # owner and group.
        "_group_from_gid" = "system_info";
        "_user_from_uid" = "system_info";
      };
    };
    pathchk = { };
    pax = {
      installDir = "/bin";
      allowUndefined = {
        # Extracted files' xattrs and ACLs (Apple's ._ AppleDouble members).
        "_copyfile" = "copyfile";
        "_fcopyfile" = "copyfile";
        # Archive members' owner and group names, both ways (cache.c).
        "_endgrent" = "system_info";
        "_endpwent" = "system_info";
        "_getgrgid" = "system_info";
        "_getgrnam" = "system_info";
        "_getpwnam" = "system_info";
        "_getpwuid" = "system_info";
        "_setgroupent" = "system_info";
        "_setpassent" = "system_info";
      };
    };
    rm = {
      installDir = "/bin";
      man = {
        "rm/rm.1" = "/usr/share/man/man1/rm.1";
        "rm/unlink.1" = "/usr/share/man/man1/unlink.1"; # the unlink aggregate's
      };
      links."/bin/unlink" = "/bin/rm";
      allowUndefined = {
        "_removefile" = "removefile"; # -P overwrites, then unlinks
        # The prompt before removing a file it cannot write.
        "_group_from_gid" = "system_info";
        "_user_from_uid" = "system_info";
      };
    };
    rmdir = { installDir = "/bin"; };
    stat = {
      defines = defines ++ [ "HAVE_CONFIG_H=0" ];
      man = {
        "stat/stat.1" = "/usr/share/man/man1/stat.1";
        "stat/readlink.1" = "/usr/share/man/man1/readlink.1"; # the readlink aggregate's
      };
      links."/usr/bin/readlink" = "/usr/bin/stat";
      # %Su, %Sg: owner and group names.
      allowUndefined = {
        "_group_from_gid" = "system_info";
        "_user_from_uid" = "system_info";
      };
    };
    touch = { };
    truncate = {
      cflags = modernCflags;
      libraries = [{ pkg = libutil; l = "util"; }]; # OTHER_LDFLAGS = -lutil
    };
    xattr = { cflags = modernCflags; };
  };
in

mkCmds {
  pname = "file_cmds";
  src = sources.file_cmds;
  inherit toolchain tools;
  sourceLists = import ./file-cmds-sources.nix;

  # Project-level Release settings (file_cmds.xcodeproj). No
  # GCC_C_LANGUAGE_STANDARD: the compiler's default.
  cflags = [
    "-Os" # GCC_OPTIMIZATION_LEVEL (Release default)
    "-fno-common" # GCC_NO_COMMON_BLOCKS
    "-Wall"
    "-Werror=format-nonliteral"
    "-Werror=format"
    "-Werror"
    "-Wundef" # WARNING_CFLAGS
    # Not Apple's: LLVM 21's -Wall includes -Wunused-but-set-variable, and
    # -Werror makes it fatal. The variables are dead, not misused: ls.c's
    # labelstr is read only by FreeBSD's MAC label code (#ifndef __APPLE__),
    # chmod_acl.c's aindex counts loop iterations nothing reads.
    "-Wno-error=unused-but-set-variable"
  ];
  inherit defines;
  ldflags = [ "-Wl,-dead_strip" ]; # DEAD_CODE_STRIPPING

  # The shar aggregate.
  extraInstall = ''
    install -Dm755 shar/shar.sh $out/usr/bin/shar
    install -Dm644 shar/shar.1 $out/usr/share/man/man1/shar.1
  '';
}
