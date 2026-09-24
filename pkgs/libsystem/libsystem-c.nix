# Stage 4: libsystem_c.dylib - Libc (12 targets: Base, FreeBSD, NetBSD, TRE, Platform, FortifySource + 6 Variant_*).
# Two-pass umbrella link via umbrella-link.nix; many Variant_* empty on arm64 (no file list for that arch).
# Dropped: -lCrashReporterClient (unreleased), -lsystem_m (no arm64 sources), -ldyld (stage 5), -lsystem_asl/-lxpc/-lcorecrypto/-lsystem_trace (closed/upward), -interposable/-unexported lists (need static archives, no export effect).
{ lib
, mkDarwinPackage
, sources
, perl
, toolchain
, systemFrameworkHeaders
, umbrellaLink
, targetArch
, libsystemStage1 ? null
}:

let
  sourceLists = import ./libc-sources.nix;

  # Resolve variant basename against candidates; exactly one match required (rename = build failure).
  variantFile = target: base:
    let
      matches = lib.filter (e: baseNameOf e.path == base) sourceLists.variants.${target};
    in
    if lib.length matches == 1 then lib.head matches
    else throw "libsystem_c: ${base} matches ${toString (lib.length matches)} files in Variant_${target}'s source list";

  # BASE_EXCLUDED from xcconfig (kvm.c/nlist.c/OSMemoryNotification.c) + utmpx/login files needing <asl.h>/<servers/bootstrap.h> (absent; matches DriverKit exclusion).
  baseExcluded = [ "kvm.c" "nlist.c" "OSMemoryNotification.c" ]
    ++ [ "utmpx-darwin.c" "utmpx.c" "logwtmp.c" "login.c" "logout.c" ];
  dropExcluded = lib.filter (e: !(lib.elem (baseNameOf e.path) baseExcluded));

  # daemon.c needs <servers/bootstrap.h> (launchd, unreleased); VARIANT_PRE1050 builds it without reparenting.
  extraFileFlags = {
    "gen/FreeBSD/daemon.c" = "-DVARIANT_PRE1050";
  };
  withExtraFlags = map (e:
    let extra = extraFileFlags.${e.path} or null; in
    if extra == null then e
    else e // { flags = lib.concatStringsSep " " (lib.filter (x: x != "") [ (e.flags or "") extra ]); });

  # Group files by COMPILER_FLAGS for one compile invocation per distinct flag set.
  compileGroups = target: entries:
    let
      byFlags = lib.groupBy (e: e.flags or "") entries;
    in
    lib.concatStringsSep " \\\n" (lib.mapAttrsToList (flags: es:
      "compile ${target} ${lib.escapeShellArg flags} -- "
      + lib.escapeShellArgs (map (e: e.path) es) + " ;") byFlags);

  # Platform target: forceLibcToBuild.c + $(ARCH_FAMILY)/gen/* (empty on arm64 - no arm64/ dir).
  archFamily = if targetArch == "aarch64" then "arm64" else "x86_64";
  platformSources = lib.filter
    (e: baseNameOf e.path == "forceLibcToBuild.c"
        || lib.hasPrefix "${archFamily}/gen/" e.path)
    sourceLists.Platform;

  # Variant targets from variants.xcconfig (macosx/arm64); empty ones kept explicit.
  variantTargets = {
    CANCELABLE = {
      macros = [ "-DVARIANT_CANCELABLE" ];
      files = [
        "creat.c" "sigcompat.c"
        "lockf.c" "nanosleep.c" "pause.c" "sleep.c" "termios.c" "usleep.c"
        "wait.c" "waitpid.c"
        "recv.c" "send.c"
        "system.c"
      ];
    };
    DARWINEXTSN = {
      macros = [ "-DVARIANT_DARWINEXTSN" ];
      files = [ "popen.c" "fdopen.c" "fopen.c" "realpath.c" "getgroups.c" ];
    };
    DARWINEXTSN_CANCELABLE = { # no INCLUDE defined; macros exist for alias purposes
      macros = [ "-DVARIANT_CANCELABLE" "-DVARIANT_DARWINEXTSN" ];
      files = [ ];
    };
    PRE1050 = { # x86_64 only (daemon.c)
      macros = [ "-U__DARWIN_VERS_1050" "-D__DARWIN_VERS_1050=0" "-DVARIANT_PRE1050" ];
      files = if targetArch == "aarch64" then [ ] else [ "daemon.c" ];
    };
    LEGACY = { # i386 only
      macros = [
        "-U__DARWIN_UNIX03" "-D__DARWIN_UNIX03=0"
        "-U__DARWIN_64_BIT_INO_T" "-D__DARWIN_64_BIT_INO_T=0"
        "-DVARIANT_LEGACY"
      ];
      files = [ ];
    };
    INODE32 = { # i386/x86_64 only
      macros = [ "-U__DARWIN_64_BIT_INO_T" "-D__DARWIN_64_BIT_INO_T=0" "-DVARIANT_INODE32" ];
      files =
        if targetArch == "aarch64" then [ ]
        else [
          "fts.c" "getmntinfo.c" "glob.c" "nftw.c" "opendir.c" "readdir.c"
          "rewinddir.c" "scandir.c" "seekdir.c" "telldir.c" "scandir_b.c"
          "statx_np.c"
        ];
    };
  };

  # Symbols from absent libs - allowed undefined until those libs exist.
  allowUndefined = {
    # dyld (stage 5) - backtrace/dladdr, SDK checks, TLV
    "_dladdr" = "dyld";
    "__dyld_get_image_uuid" = "dyld";
    "__dyld_get_shared_cache_range" = "dyld";
    "__dyld_get_shared_cache_uuid" = "dyld";
    "__dyld_images_for_addresses" = "dyld";
    "__dyld_stack_range" = "dyld";
    "_dyld_get_active_platform" = "dyld";
    "_dyld_get_program_min_os_version" = "dyld";
    "_dyld_image_header_containing_address" = "dyld";
    "_dyld_sdk_at_least" = "dyld";
    "__tlv_atexit" = "dyld";
    "__tlv_exit" = "dyld";
    # system_m - no arm64 sources (Libm-2026)
    "_fegetround" = "system_m";
    "___fpclassify" = "system_m";
    "_fegetenv" = "system_m";
    "_fesetenv" = "system_m";
    # system_info - passwd/group, mbr UUID, networking
    "_getpwnam" = "system_info";
    "_getpwuid" = "system_info";
    "_getgrnam" = "system_info";
    "_getgrgid" = "system_info";
    "_mbr_uid_to_uuid" = "system_info";
    "_mbr_gid_to_uuid" = "system_info";
    "_mbr_uuid_to_id" = "system_info";
    "_getgrouplist" = "system_info";
    "_getgroupcount" = "system_info";
    "_getifaddrs" = "system_info";
    "_freeifaddrs" = "system_info";
    "_if_nametoindex" = "system_info";
    # system_notify - timezone notification
    "_notify_post" = "system_notify";
    "_notify_cancel" = "system_notify";
    "_notify_check" = "system_notify";
    "_notify_monitor_file" = "system_notify";
    "_notify_register_check" = "system_notify";
    # system_asl - syslog fallback
    "_syslog$DARWIN_EXTSN" = "system_asl";
    # corecrypto - arc4random
    "_ccrng" = "corecrypto";
    "_ccrng_uniform" = "corecrypto";
    # dispatch - psort_b
    "_dispatch_get_global_queue" = "dispatch";
    "_dispatch_group_create" = "dispatch";
    "_dispatch_group_async_f" = "dispatch";
    "_dispatch_group_wait" = "dispatch";
    "_dispatch_release" = "dispatch";
  } // lib.optionalAttrs (targetArch != "aarch64") {
    # system_m x86_64-only - strtod/hdtoa (fma, __fpclassifyd)
    "_fma" = "system_m";
    "___fpclassifyd" = "system_m";
  };

  linkFlags = umbrellaLink {
    stage1 = libsystemStage1;
    libs = [ "compiler_rt" "system_kernel" "system_m" "system_malloc" "system_platform" "system_pthread" "dyld" ]; # LIBSYSTEM_C_LDFLAGS (absent filtered in umbrella-link.nix)
    upward = [ "dispatch" "macho" "system_asl" "system_blocks" "system_info" "system_notify" "xpc" "corecrypto" "system_trace" ]; # UPWARD_LDFLAGS
    inherit allowUndefined;
  };

  # From xcodescripts/libc.xcconfig (BASE_PREPROCESSOR_MACROS + OTHER_CFLAGS + WARNING_CFLAGS).
  commonCFlags = [
    "-std=gnu11" # GCC_C_LANGUAGE_STANDARD
    "-Os" # GCC_OPTIMIZATION_LEVEL = s
    "-fdollars-in-identifiers"
    "-fno-common"
    "-fverbose-asm"

    "-D__LIBC__"
    "-D__DARWIN_UNIX03=1"
    "-D__DARWIN_64_BIT_INO_T=1"
    "-D__DARWIN_NON_CANCELABLE=1"
    "-D__DARWIN_VERS_1050=1"
    "-D_FORTIFY_SOURCE=0"

    # WARNING_CFLAGS.
    "-Wall"
    "-Wno-error=shorten-64-to-32"
    "-Wno-error=incompatible-pointer-types-discards-qualifiers"
    "-Wno-nullability-completeness"
    "-Wno-error=deprecated"
  ];

  version = lib.removePrefix "Libc-" sources.Libc.rev;

  # Independent of libsystemStage1, so both passes share this one derivation.
  objects = mkDarwinPackage {
    pname = "libsystem_c-objects";
    inherit version toolchain;

    src = sources.Libc;
    nativeBuildInputs = [ perl ]; # patch_headers_variants.pl

    buildPhase = ''
      runHook preBuild

      export MD_SRCROOT=$PWD
      obj=$PWD/o
      mkdir -p $obj

      # os_log_pack is libsystem_trace's (unreleased os/log_private.h); _os_crash_fmt dlopens it and gives up if absent.
      # Drop the entry point rather than invent the struct (ABI risk). Also dropped from SDK's os/assumes.h.
      # printf builds match text (replacement at column 0 would dedent Nix string).
      packImplOpen=$(printf '__attribute__((always_inline))\nstatic inline bool\n_os_crash_fmt_impl(')
      packImplClose=$(printf 'pack, pack_size, composed, 0);\n}')
      packEntry=$(printf 'void _os_crash_fmt(os_log_pack_t pack, size_t pack_size)\n{\n\t_os_crash_fmt_impl(pack, pack_size);\n}')

      # arc4random.c/vfprintf.c enable libtrace crash path via os_log_send_and_compose (unreleased, libsystem_trace).
      # Their #else already falls back to plain string; guarded by !TARGET_OS_DRIVERKIT (off where libtrace absent).
      libtraceOptIn=$(printf '#if !TARGET_OS_DRIVERKIT\n#define OS_CRASH_ENABLE_EXPERIMENTAL_LIBTRACE 1\n#endif')
      for f in gen/FreeBSD/arc4random.c stdio/FreeBSD/vfprintf.c; do
        substituteInPlace $f --replace-fail "$libtraceOptIn" \
          '/* minidarwin: os_log_send_and_compose is libsystem_trace'"'"'s. */'
      done

      substituteInPlace os/assumes.c \
        --replace-fail "$packImplOpen" \
          "$(printf '#if 0 /* minidarwin: os_log_pack is libsystem_trace'"'"'s. */\n%s' "$packImplOpen")" \
        --replace-fail "$packImplClose" \
          "$(printf '%s\n#endif' "$packImplClose")" \
        --replace-fail "$packEntry" \
          '/* minidarwin: _os_crash_fmt dropped -- see above. */'

      # Patch Headers: rewrites __DARWIN_ALIAS_C -> LIBC_ALIAS_C (keyed on VARIANT_*) so variant targets get distinct symbols.
      # Runs patch_headers_variants.pl over SDK headers; Libc's own sys/cdefs.h defines LIBC_ALIAS_C. No-op on headers without aliases.
      # Its input is SDK_SYSTEM_FRAMEWORK_HEADERS: System.framework's headers.
      # Ours holds only the ones that differ from usr/include, so the input is
      # usr/include with those laid over it -- what a search of the framework,
      # then usr/include, finds. Named include/ so the output is too.
      derived=$PWD/derived
      sdkview=$PWD/sdkview/include
      mkdir -p $sdkview
      cp -R "$MINIDARWIN_SYSROOT/usr/include/." $sdkview/
      chmod -R u+w $sdkview
      cp -R "$MINIDARWIN_SYSROOT${systemFrameworkHeaders}/." $sdkview/
      perl xcodescripts/patch_headers_variants.pl \
        "$sdkview" "$derived/System.framework/Versions/B"
      patched=$derived/System.framework/Versions/B/include
      [ -e "$patched/sys/fcntl.h" ] || { echo "Patch Headers produced nothing" >&2; exit 1; }
      grep -q 'LIBC_ALIAS_CREAT' "$patched/sys/fcntl.h" ||
        { echo "Patch Headers did not rewrite the __DARWIN_ALIAS declarations" >&2; exit 1; }

      # Libc's include/ ahead of patched tree (its sys/cdefs.h defines LIBC_ALIAS_C via #include_next).
      incflags=( -I$PWD -I$PWD/include -I$PWD/gen -I$PWD/locale
                 -I$PWD/locale/FreeBSD -I$PWD/stdtime/FreeBSD -I$PWD/darwin
                 -isystem "$patched" )

      targetFlags=()

      # One compile invocation per COMPILER_FLAGS group; paths relative to $PWD (not escaped).
      compile() { # <target> <per-file flags> -- <relative source>...
        local target="$1" fileFlags="$2"; shift 2
        [ "$1" = "--" ] && shift
        fileFlags=''${fileFlags//'$(FreeBSD_CFLAGS)'/-include $MD_SRCROOT/fbsdcompat/_fbsd_compat_.h}
        fileFlags=''${fileFlags//'$(SRCROOT)'/$MD_SRCROOT}
        case "$fileFlags" in
          *'$('*) echo "libsystem_c: unexpanded variable in COMPILER_FLAGS: $fileFlags" >&2; exit 1 ;;
        esac
        local f srcs=()
        for f in "$@"; do srcs+=( "$MD_SRCROOT/$f" ); done
        md_log "libsystem_c/$target: ''${#srcs[@]} objects''${fileFlags:+ [$fileFlags]}"
        md_compile $obj/$target "$CC" ${lib.escapeShellArgs commonCFlags} \
          "''${targetFlags[@]}" $fileFlags "''${incflags[@]}" -- "''${srcs[@]}"
      }

      ${compileGroups "Base" (dropExcluded sourceLists.Base)}

      # FreeBSD_CFLAGS + FreeBSD_SEARCH_PATHS.
      fbsdFlags=( -include $PWD/fbsdcompat/_fbsd_compat_.h
                  -I$PWD/fbsdcompat -I$PWD/gdtoa -I$PWD/gdtoa/FreeBSD )
      targetFlags=( "''${fbsdFlags[@]}" )
      ${compileGroups "FreeBSD" (withExtraFlags (dropExcluded sourceLists.FreeBSD))}

      # NetBSD_CFLAGS + NetBSD_SEARCH_PATHS.
      targetFlags=( -include $PWD/nbsdcompat/_nbsd_compat_.h -I$PWD/nbsdcompat )
      ${compileGroups "NetBSD" (dropExcluded sourceLists.NetBSD)}

      # TRE_CFLAGS + TRE_SEARCH_PATHS.
      targetFlags=( -DHAVE_CONFIG_H -I$PWD/regex/TRE -I$PWD/regex/FreeBSD )
      ${compileGroups "TRE" (dropExcluded sourceLists.TRE)}

      targetFlags=()
      ${compileGroups "Platform" platformSources}
      ${compileGroups "FortifySource" (dropExcluded sourceLists.FortifySource)}

      # Variant targets: -DBUILDING_VARIANT + per-variant macros + FreeBSD search paths (no -include shim here).
      targetFlags=( -I$PWD/fbsdcompat -I$PWD/gdtoa -I$PWD/gdtoa/FreeBSD )
      ${lib.concatStringsSep "\n    " (lib.mapAttrsToList (name: v:
        if v.files == [ ] then
          "md_log 'libsystem_c/Variant_${name}: 0 objects (no file list for this architecture)'"
        else
          "targetFlags=( -I$PWD/fbsdcompat -I$PWD/gdtoa -I$PWD/gdtoa/FreeBSD -DBUILDING_VARIANT "
          + "${lib.escapeShellArgs v.macros} )\n    "
          + compileGroups "Variant_${name}" (map (variantFile name) v.files)
      ) variantTargets)}

      # The two files in the libsystem_c.dylib target itself.
      targetFlags=()
      compile Dylib "" -- darwin/compatibility_hacks.c darwin/forceLibcToBuild.c

      runHook postBuild
    '';

    installPhase = "cp -R $obj $out";
  };
in

mkDarwinPackage {
  pname = "libsystem_c-pass${if libsystemStage1 == null then "1" else "2"}";
  inherit version toolchain;
  dontUnpack = true;

  passthru.libsystemName = "system_c";
  passthru.allowUndefined = allowUndefined; # checked by rootfs.nix
  passthru.objects = objects;

  buildPhase = ''
    runHook preBuild

    # alias.list (22 libplatform symbols like __platform_memmove→_memcpy) skipped: ld64.lld can't alias imported symbols; applied in libplatform where targets are local.
    md_dylib libsystem_c.dylib /usr/lib/system/libsystem_c.dylib ${objects} \
      ${lib.escapeShellArgs linkFlags}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 libsystem_c.dylib $out/usr/lib/system/libsystem_c.dylib

    md_verify_pure   $out/usr/lib/system/libsystem_c.dylib
    md_verify_signed $out/usr/lib/system/libsystem_c.dylib

    # Symbols from every target - empty target fails here, not at stage-6 link.
    md_verify_symbols $out/usr/lib/system/libsystem_c.dylib \
      _printf _fprintf _snprintf _vsnprintf _fopen _fclose _fread _fwrite \
      _asprintf \
      _strtod _strtol _qsort _bsearch _getenv _setenv _atexit _exit _abort \
      _strdup _strtok_r _strerror _strsignal \
      _opendir _readdir _closedir _scandir _glob _fts_open \
      _regcomp _regexec _regfree \
      _localtime _strftime _mktime _gettimeofday \
      _err _warn _getopt _getopt_long \
      _uuid_generate _uuid_parse _uuid_unparse \
      _dbopen _fnmatch _basename _dirname _realpath \
      ___memcpy_chk ___strcpy_chk ___snprintf_chk \
      __os_assert_log __os_assumes_log \
      _memset_s _strfmon \
      ___sprintf_chk

    runHook postInstall
  '';

  meta.description = "Libc -- the C library";
}
