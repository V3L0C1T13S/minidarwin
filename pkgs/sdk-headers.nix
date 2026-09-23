# Stage 1: SDK headers. Assembles ~1720 headers from pinned Apple sources via copytree/unifdef/mig.
{ lib
, stdenvNoCC
, sources
, mig
, unifdef
, perl
, python3
, writeText
, ed
, bootstrapClang
, targetArch
}:

let
  machoArch = if targetArch == "aarch64" then "arm64" else targetArch;

  bsdArchDir = if targetArch == "aarch64" then "arm" else "i386";
  machArchDir = if targetArch == "aarch64" then "arm" else "i386";

  libmArchDir = if targetArch == "aarch64" then "ARM" else "Intel";

  archIncDir = bsdArchDir;

  migArch = if targetArch == "aarch64" then "armv7" else "i386";

  # xnu's installhdrs unifdef sets (makedefs/MakeInc.def), less the platform
  # part. They differ only in MODULES_SUPPORTED, so they are spelled once.
  commonUnifdef = [
    "-UMACH_KERNEL_PRIVATE"
    "-UBSD_KERNEL_PRIVATE"
    "-UIOKIT_KERNEL_PRIVATE"
    "-ULIBKERN_KERNEL_PRIVATE"
    "-ULIBSA_KERNEL_PRIVATE"
    "-UPEXPERT_KERNEL_PRIVATE"
    "-UXNU_KERNEL_PRIVATE"
    "-UKERNEL_PRIVATE"
    "-UKERNEL"
    "-DPRIVATE"
    "-UDRIVERKIT"
    "-UEXCLAVEKIT"
    "-UEXCLAVECORE"
    "-U_OPEN_SOURCE_"
    "-U__OPEN_SOURCE__"
    "-USCHED_TEST_HARNESS"
    "-DXNU_PLATFORM_MacOSX"
    "-UXNU_PLATFORM_iPhoneOS"
    "-UXNU_PLATFORM_AppleTVOS"
    "-UXNU_PLATFORM_WatchOS"
    "-UXNU_PLATFORM_BridgeOS"
  ];

  # SPINCFRAME_UNIFDEF: usr/include. The internal SDK's /usr/local/include --
  # what Apple builds its userland against. With MODULES_SUPPORTED defined,
  # public headers do not textually include their *_private.h companions,
  # as in every SDK Apple ships.
  unifdefFlags = lib.escapeShellArgs (commonUnifdef ++ [ "-DMODULES_SUPPORTED" ]);

  # SFPINCFRAME_UNIFDEF: System.framework/PrivateHeaders. The same headers
  # with those textual includes kept. The libsystem members put this
  # directory first (SYSTEM_HEADER_SEARCH_PATHS in their xcconfigs) and rely
  # on it: libsyscall's fcntl wrapper gets F_OPENFROM etc. from
  # <sys/fcntl_private.h> by way of <fcntl.h>.
  sfUnifdefFlags = lib.escapeShellArgs (commonUnifdef ++ [ "-UMODULES_SUPPORTED" ]);

  # Relative to the sysroot; what the members pass to -iwithsysroot.
  systemFrameworkHeaders = "/System/Library/Frameworks/System.framework/PrivateHeaders";

  migPublic = [
    "clock" "clock_priv" "clock_reply" "exc" "host_priv" "host_security"
    "mach_eventlink" "mach_host" "mach_port" "mach_voucher" "memory_entry"
    "processor" "processor_set" "task" "thread_act" "vm_map" "mach_vm"
  ];

  migInternal = [ "mach_port" "mach_vm" "task" "thread_act" "vm_map" ];

  # xros alias missing in AvailabilityVersions-157.2; graft visionos alias.
  xrosAliasHeader = writeText "xros-availability-alias.h" ''
    #ifndef __API_AVAILABLE_PLATFORM_xros
      #define __API_AVAILABLE_PLATFORM_xros(x) visionos,introduced=x
      #define __API_DEPRECATED_PLATFORM_xros(x,y) visionos,introduced=x,deprecated=y
      #define __API_OBSOLETED_PLATFORM_xros(x,y,z) visionos,introduced=x,deprecated=y,obsoleted=z
      #define __API_UNAVAILABLE_PLATFORM_xros visionos,unavailable
    #endif
  '';

  # DYLD_MACOSX_VERSION_15_4 missing; append 0x000f0400.
  dyldMacos154Define = writeText "dyld-macosx-15-4.h" ''
    #ifndef DYLD_MACOSX_VERSION_15_4
      #define DYLD_MACOSX_VERSION_15_4                      0x000f0400
    #endif
  '';

  # mig's preprocessor - clang -E with our sysroot, no host SDK.
  migccTemplate = writeText "migcc" ''
    #!${stdenvNoCC.shell}
    exec ${bootstrapClang}/bin/clang -nostdinc -nostdlibinc -I@INC@ "$@"
  '';
in

stdenvNoCC.mkDerivation {
  pname = "minidarwin-sdk-headers";
  version = lib.removePrefix "xnu-" sources.xnu.rev;

  dontUnpack = true;
  dontFixup = true;

  nativeBuildInputs = [ mig unifdef perl python3 ed ];

  SOURCE_DATE_EPOCH = "1";
  LC_ALL = "C";

  buildPhase = ''
    runHook preBuild

    inc=$PWD/include
    mkdir -p $inc

    # Copy headers preserving subdirs; never silently clobber.
    copytree() {
      local src="$1" dst="$inc/$2"
      [ -d "$src" ] || { echo "missing header tree: $src" >&2; return 1; }
      mkdir -p "$dst"
      ( cd "$src" && find . \( -name '*.h' -o -name '*.modulemap' -o -name '*.apinotes' \) -print0 ) |
        ( cd "$src" && xargs -0 -I{} sh -c '
            mkdir -p "'"$dst"'/$(dirname {})"
            cp -f "{}" "'"$dst"'/{}"
          ' )
      chmod -R u+w "$dst"
    }

    # Availability headers - generated from DSL, not xnu's stale EXTERNAL_HEADERS copies.
    avobj=$PWD/availability-obj
    mkdir -p $avobj

    # Preprocess DSL into availability.pl.
    python3 ${sources.AvailabilityVersions}/availability \
      --av_version ${lib.removePrefix "AvailabilityVersions-" sources.AvailabilityVersions.rev} \
      --preprocess ${sources.AvailabilityVersions}/availability \
      $avobj/availability
    chmod +x $avobj/availability

    for t in Availability.h AvailabilityInternal.h AvailabilityInternalLegacy.h \
             AvailabilityInternalPrivate.h AvailabilityMacros.h \
             AvailabilityProhibitedInternal.h AvailabilityVersions.h \
             VersionMap.h for_dyld_priv.inc dyld_version_defines.h \
             os_availability.h; do
      python3 $avobj/availability --preprocess \
        ${sources.AvailabilityVersions}/templates/$t "$avobj/$t"
    done

    # Graft xros alias (visionos alias missing in this release).
    chmod u+w $avobj/AvailabilityInternal.h
    cat ${xrosAliasHeader} >> $avobj/AvailabilityInternal.h

    mkdir -p $inc/os $inc/dyld $inc/mach-o
    for h in Availability.h AvailabilityInternal.h AvailabilityInternalLegacy.h \
             AvailabilityMacros.h AvailabilityVersions.h \
             AvailabilityInternalPrivate.h AvailabilityProhibitedInternal.h; do
      install -m444 "$avobj/$h" $inc/$h
    done
    install -m444 $avobj/os_availability.h    $inc/os/availability.h
    install -m444 $avobj/VersionMap.h         $inc/dyld/VersionMap.h
    install -m444 $avobj/for_dyld_priv.inc    $inc/dyld/for_dyld_priv.inc
    # Append missing DYLD_MACOSX_VERSION_15_4 define.
    chmod u+w $avobj/dyld_version_defines.h
    cat ${dyldMacos154Define} >> $avobj/dyld_version_defines.h
    install -m444 $avobj/dyld_version_defines.h $inc/mach-o/dyld_version_defines.h

    mkdir -p $PWD/sdkroot/usr/local/libexec
    install -m555 $avobj/availability $PWD/sdkroot/usr/local/libexec/availability.pl

    # Freestanding headers; drop stale Availability copies from EXTERNAL_HEADERS.
    copytree ${sources.xnu}/EXTERNAL_HEADERS ""
    rm -f $inc/Availability.h $inc/AvailabilityInternal.h $inc/AvailabilityMacros.h

    # Drop kernel-only headers (stdatomic etc) that would shadow clang's builtins.
    rm -f $inc/stdatomic.h $inc/stdarg.h $inc/stdbool.h $inc/stddef.h
    for h in Availability.h AvailabilityInternal.h AvailabilityInternalLegacy.h \
             AvailabilityMacros.h AvailabilityVersions.h \
             AvailabilityInternalPrivate.h AvailabilityProhibitedInternal.h; do
      install -m444 "$avobj/$h" $inc/$h
    done

    # BSD userspace interface.
    for d in sys net netinet netinet6 miscfs nfs uuid dev bsm security vm \
             libkern crypto skywalk; do
      copytree ${sources.xnu}/bsd/$d $d
    done
    # skywalk headers installed flat.
    find $inc/skywalk -mindepth 2 -name '*.h' -exec cp -f {} $inc/skywalk/ \;

    # pthread kernel SPI, 3 headers.
    for h in bsdthread_private.h priority_private.h workqueue_syscalls.h; do
      install -Dm444 ${sources.xnu}/bsd/pthread/$h $inc/pthread/$h
    done

    copytree ${sources.xnu}/bsd/machine machine
    copytree ${sources.xnu}/bsd/${bsdArchDir} ${bsdArchDir}
    copytree ${sources.xnu}/bsd/${bsdArchDir} machine

    # Mach interface.
    copytree ${sources.xnu}/osfmk/mach mach
    copytree ${sources.xnu}/osfmk/mach_debug mach_debug
    copytree ${sources.xnu}/osfmk/device device
    copytree ${sources.xnu}/osfmk/${machArchDir} ${machArchDir}

    # Install mach/<arch>/asm.h from osfmk/<arch>/asm.h.
    for a in ${lib.optionalString (targetArch == "aarch64") "arm arm64"} \
             ${lib.optionalString (targetArch != "aarch64") "i386 x86_64"}; do
      if [ -f ${sources.xnu}/osfmk/$a/asm.h ]; then
        install -Dm444 ${sources.xnu}/osfmk/$a/asm.h $inc/mach/$a/asm.h
      fi
    done
    copytree ${sources.xnu}/osfmk/machine machine

    # kern SPI headers (INSTALL_SF_MI_LCL_LIST).
    for h in exc_guard.h exc_resource.h kern_cdata.h kcdata.h \
             arithmetic_128.h block_hint.h cambria_layout.h cs_blobs.h \
             debug.h panic_call.h ecc.h llc_error.h lock_stat.h monotonic.h \
             remote_time.h restartable.h stackshot_kpi.h telemetry.h \
             trustcache.h turnstile.h socd_client.h kcdata_private.h; do
      install -Dm644 ${sources.xnu}/osfmk/kern/$h $inc/kern/$h
    done

    copytree ${sources.xnu}/libkern/libkern libkern
    copytree ${sources.xnu}/libkern/os os

    copytree ${sources.xnu}/libkern/firehose firehose

    copytree ${sources.xnu}/iokit/IOKit IOKit

    # Libsyscall exported headers.
    copytree ${sources.xnu}/libsyscall/mach/mach mach
    copytree ${sources.xnu}/libsyscall/mach/servers servers
    copytree ${sources.xnu}/libsyscall/os os
    # libproc.h ships flat in /usr/include.
    copytree ${sources.xnu}/libsyscall/wrappers/libproc ""
    for h in ${sources.xnu}/libsyscall/wrappers/*.h; do
      install -m444 "$h" "$inc/$(basename "$h")"
    done

    # spawn.h / spawn_private.h.
    for h in ${sources.xnu}/libsyscall/wrappers/spawn/*.h; do
      install -m444 "$h" "$inc/$(basename "$h")"
    done

    # Replace empty thread_self_restrict.h stub with compat shim.
    if [ "$(grep -cv -e '^\s*$' -e '^\s*[/*]' -e '^#\(ifndef\|define\|endif\)' \
              $inc/os/thread_self_restrict.h)" != 0 ]; then
      echo "xnu's os/thread_self_restrict.h is no longer an empty stub" >&2
      exit 1
    fi
    install -Dm444 ${./compat/os/thread_self_restrict.h} \
      $inc/os/thread_self_restrict.h

    # Generate sys/syscall.h from syscalls.master via makesyscalls.sh.
    ( cd $(mktemp -d)
      ${stdenvNoCC.shell} ${sources.xnu}/bsd/kern/makesyscalls.sh \
        ${sources.xnu}/bsd/kern/syscalls.master header
      install -Dm644 syscall.h $inc/sys/syscall.h
    )

    # Generate sys/_symbol_aliasing.h and sys/_posix_availability.h.
    ${stdenvNoCC.shell} ${sources.xnu}/bsd/sys/make_symbol_aliasing.sh \
      "$PWD/sdkroot" $inc/sys/_symbol_aliasing.h
    ${stdenvNoCC.shell} ${sources.xnu}/bsd/sys/make_posix_availability.sh \
      $inc/sys/_posix_availability.h

    # Strip kernel-only material via unifdef.
    # -m edits in place; -o with existing file silently empties it.
    md_unifdef() {
      local f="$1" rc=0; shift
      unifdef -m "$@" "$f" || rc=$?
      if [ "$rc" -ge 2 ]; then
        echo "unifdef failed on $f" >&2
        return 1
      fi
      return 0
    }

    # System.framework/PrivateHeaders. Its install lists
    # (INSTALL_SF_MI_LCL_LIST = DATAFILES + PRIVATE_DATAFILES) are the same
    # headers as usr/include's, and the two renderings differ only where a
    # header tests MODULES_SUPPORTED -- so those are the headers it holds.
    # For every other header a member's search falls through to an identical
    # usr/include copy. sforig/ keeps the sources, checked again below.
    sfh=$PWD/sfheaders
    sforig=$PWD/sforig
    while IFS= read -r -d "" f; do
      rel=''${f#$inc/}
      install -Dm644 "$f" "$sforig/$rel"
      install -Dm644 "$f" "$sfh/$rel"
      md_unifdef "$sfh/$rel" ${sfUnifdefFlags} || exit 1
    done < <(grep -rlZ --include='*.h' MODULES_SUPPORTED $inc)
    if [ -z "$(ls -A $sfh 2>/dev/null)" ]; then
      echo "no header tests MODULES_SUPPORTED: System.framework would be empty" >&2
      exit 1
    fi

    while IFS= read -r -d "" f; do
      md_unifdef "$f" ${unifdefFlags} || exit 1
    done < <(find $inc -name '*.h' -print0)

    # Generate Mach RPC headers via mig.
    export MIGCC="$PWD/migcc"
    substitute ${migccTemplate} "$MIGCC" --subst-var-by INC "$inc"
    chmod +x "$MIGCC"

    migsrc=${sources.xnu}/libsyscall/mach
    migflags="-novouchers -arch ${migArch} -cc $MIGCC -I${sources.xnu}/osfmk"

    # Internal mig headers for Libsyscall (private include path).
    internalinc=$PWD/internal_hdr/include
    mkdir -p $inc/mach $inc/servers $internalinc/mach

    mig $migflags -header "$inc/servers/netname.h" $migsrc/servers/netname.defs

    for m in ${lib.concatStringsSep " " migPublic}; do
      mig $migflags -DLIBSYSCALL_INTERFACE \
        -header "$inc/mach/$m.h" "$migsrc/$m.defs"
      awk -f ${sources.xnu}/libsyscall/xcodescripts/filter_mig.awk \
        $migsrc/add_attributes_to_mig.txt "$inc/mach/$m.h" > "$inc/mach/$m.h.tmp"
      mv "$inc/mach/$m.h.tmp" "$inc/mach/$m.h"
    done

    for m in ${lib.concatStringsSep " " migInternal}; do
      mig $migflags -header "$internalinc/mach/''${m}_internal.h" "$migsrc/$m.defs"
    done

    # Install .defs needed by libdispatch (mach/std_types.defs etc).
    for d in clock_types.defs mach_types.defs std_types.defs \
             audit_triggers.defs clock.defs clock_priv.defs clock_reply.defs \
             doubleagent_mig.defs exc.defs host_notify_reply.defs \
             host_priv.defs host_security.defs mach_exc.defs mach_host.defs \
             mach_port.defs mach_vm.defs mach_voucher.defs \
             mach_voucher_attr_control.defs memory_entry.defs \
             memory_error_notification.defs notify.defs processor.defs \
             processor_set.defs task.defs task_access.defs \
             telemetry_notification.defs thread_act.defs vm_map.defs; do
      install -Dm444 ${sources.xnu}/osfmk/mach/$d $inc/mach/$d
    done
    # voucher header (osfmk/voucher).
    copytree ${sources.xnu}/osfmk/voucher voucher

    # bank header (osfmk/bank).
    copytree ${sources.xnu}/osfmk/bank bank

    install -Dm444 ${sources.xnu}/osfmk/mach/machine/machine_types.defs \
      $inc/mach/machine/machine_types.defs

    # System framework compat (sys/fsctl.h etc via /usr/include/System).
    for h in sys/fsctl.h ${lib.optionalString (targetArch != "aarch64") "i386/cpu_capabilities.h"}; do
      install -Dm444 $inc/$h $inc/System/$h
    done

    # Libc headers gated on per-platform features via generate_features.pl.
    # Run real script; apply only to Libc headers.
    export SRCROOT=${sources.Libc}
    export ARCHS=${machoArch}
    export VARIANT_PLATFORM_NAME=macosx
    export DERIVED_FILES_DIR=$PWD/libc-derived
    mkdir -p "$DERIVED_FILES_DIR"

    libcUnifdef=$(perl ${sources.Libc}/xcodescripts/generate_features.pl --unifdef)
    echo "[minidarwin] Libc feature flags:$libcUnifdef" >&2

    perl ${sources.Libc}/xcodescripts/generate_features.pl >/dev/null
    cp "$DERIVED_FILES_DIR/${machoArch}/libc-features.h" $inc/libc-features.h

    libcstage=$PWD/libc-headers
    mkdir -p $libcstage
    (
      inc=$libcstage
      copytree ${sources.Libc}/include ""
      copytree ${sources.Libc}/darwin os
      copytree ${sources.Libc}/libdarwin/h os

      # LOCALHDRS: flat /usr/local/include.
      install -Dm644 ${sources.Libc}/darwin/libc_private.h    $libcstage/libc_private.h
      install -Dm644 ${sources.Libc}/darwin/libc_hooks.h      $libcstage/libc_hooks.h
      install -Dm644 ${sources.Libc}/darwin/subsystem.h       $libcstage/subsystem.h
      install -Dm644 ${sources.Libc}/darwin/_libc_init.h      $libcstage/_libc_init.h
      install -Dm644 ${sources.Libc}/gen/utmpx_thread.h       $libcstage/utmpx_thread.h
      install -Dm644 ${sources.Libc}/gen/thread_stack_pcs.h   $libcstage/thread_stack_pcs.h
      install -Dm644 ${sources.Libc}/nls/FreeBSD/msgcat.h     $libcstage/msgcat.h
      install -Dm644 ${sources.Libc}/libdarwin/h/dirstat.h    $libcstage/dirstat.h

      # OS_LOCALHDRS: /usr/local/include/os.
      install -Dm644 ${sources.Libc}/os/assumes.h        $libcstage/os/assumes.h
      install -Dm644 ${sources.Libc}/os/debug_private.h  $libcstage/os/debug_private.h

      for h in ${sources.Libc}/collections/PublicHeader/*.h; do
        install -Dm644 "$h" $libcstage/os/"$(basename "$h")"
      done

      install -Dm644 ${sources.Libc}/gen/get_compat.h        $libcstage/get_compat.h
      install -Dm644 ${sources.Libc}/gen/execinfo.h          $libcstage/execinfo.h
      install -Dm644 ${sources.Libc}/stdtime/FreeBSD/tzfile.h $libcstage/tzfile.h
      install -Dm644 ${sources.Libc}/include/FreeBSD/nl_types.h $libcstage/nl_types.h
      install -Dm644 ${sources.Libc}/include/NetBSD/utmpx.h  $libcstage/utmpx.h
    )

    # Only 3 headers from include/sys; rest would overwrite xnu's sys/cdefs.h.
    find $libcstage/sys -type f \
      ! -name acl.h ! -name rbtree.h ! -name statvfs.h -delete

    rm -rf $libcstage/FreeBSD $libcstage/NetBSD

    # Strip //Begin-Libc regions with strip-header.ed.
    while IFS= read -r -d "" f; do
      if grep -q '^//Begin-Libc' "$f"; then
        chmod u+w "$f"
        ed - "$f" < ${sources.Libc}/xcodescripts/strip-header.ed
      fi
    done < <(find $libcstage -name '*.h' -print0)

    while IFS= read -r -d "" f; do
      rc=0
      unifdef -m $libcUnifdef "$f" || rc=$?
      if [ "$rc" -ge 2 ]; then echo "unifdef failed on $f" >&2; exit 1; fi
    done < <(find $libcstage -name '*.h' -print0)

    cp -R $libcstage/. $inc/
    chmod -R u+w $inc

    # Libm: per-arch math.h/fenv.h; dispatcher only knows ppc/i386/arm32.
    install -Dm444 ${sources.Libm}/Source/${libmArchDir}/math.h $inc/math.h
    install -Dm444 ${sources.Libm}/Source/${libmArchDir}/math.h \
      $inc/architecture/${archIncDir}/math.h
    install -Dm644 ${sources.Libm}/Source/${libmArchDir}/fenv.h $inc/fenv.h
    ${lib.optionalString (targetArch == "aarch64") ''
      # ARM fenv.h gated on __VFP_FP__ (AArch32); relax for arm64.
      substituteInPlace $inc/fenv.h \
        --replace-fail '#if !defined(__VFP_FP__) || defined(__SOFTFP__)' \
          '#if (!defined(__VFP_FP__) || defined(__SOFTFP__)) && !defined(__arm64__)'
    ''}
    chmod 444 $inc/fenv.h
    install -Dm444 $inc/fenv.h \
      $inc/architecture/${archIncDir}/fenv.h
    install -Dm444 ${sources.Libm}/Source/nan.h     $inc/nan.h

    # complex.h: widen __arm__ guard to include __arm64__ (long double is double).
    install -Dm644 ${sources.Libm}/Source/complex.h $inc/complex.h
    ${lib.optionalString (targetArch == "aarch64") ''
      substituteInPlace $inc/complex.h \
        --replace-fail '#elif defined(__arm__)' '#elif defined(__arm__) || defined(__arm64__)'
    ''}
    chmod 444 $inc/complex.h

    copytree ${sources.libplatform}/include ""
    copytree ${sources.libplatform}/private ""

    copytree ${sources.libpthread}/include ""
    copytree ${sources.libpthread}/private ""

    copytree ${sources.libmalloc}/include ""
    copytree ${sources.libmalloc}/private ""

    copytree ${sources.libdispatch}/dispatch dispatch
    copytree ${sources.libdispatch}/os os
    copytree ${sources.libdispatch}/private dispatch

    install -Dm444 ${sources.Libsystem}/alloc_once_private.h \
      $inc/os/alloc_once_private.h

    install -Dm444 ${sources.libclosure}/Block.h         $inc/Block.h
    install -Dm444 ${sources.libclosure}/Block_private.h $inc/Block_private.h

    install -Dm444 ${sources.copyfile}/copyfile.h         $inc/copyfile.h
    install -Dm444 ${sources.copyfile}/copyfile_private.h $inc/copyfile_private.h
    install -Dm444 ${sources.copyfile}/xattr_flags.h      $inc/xattr_flags.h
    install -Dm444 ${sources.copyfile}/xattr_properties.h $inc/xattr_properties.h

    install -Dm444 ${sources.removefile}/removefile.h $inc/removefile.h
    install -Dm444 ${sources.removefile}/checkint.h   $inc/checkint.h

    install -Dm444 ${sources.libnotify}/notify.h         $inc/notify.h
    install -Dm444 ${sources.libnotify}/notify_keys.h    $inc/notify_keys.h
    install -Dm444 ${sources.libnotify}/notify_private.h $inc/notify_private.h

    install -Dm444 ${sources.libutil}/libutil.h $inc/libutil.h
    install -Dm444 ${sources.libutil}/mntopts.h $inc/mntopts.h
    install -Dm444 ${sources.libutil}/wipefs.h  $inc/wipefs.h

    copytree ${sources.libresolv}/arpa arpa
    install -Dm444 ${sources.libresolv}/resolv.h    $inc/resolv.h
    install -Dm444 ${sources.libresolv}/resolv_mt.h $inc/resolv_mt.h
    install -Dm444 ${sources.libresolv}/nameser.h  $inc/nameser.h
    install -Dm444 ${sources.libresolv}/dns.h      $inc/dns.h
    install -Dm444 ${sources.libresolv}/dns_util.h $inc/dns_util.h

    for d in ${sources.Libinfo}/*.subproj; do
      copytree "$d" ""
    done

    for h in ConditionalMacros.h MacTypes.h Endian.h MacErrors.h; do
      install -m444 ${sources.CarbonHeaders}/$h $inc/$h
    done
    install -m444 ${./compat/TargetConditionals.h} $inc/TargetConditionals.h

    ${lib.optionalString (targetArch == "aarch64") ''
      install -Dm444 ${./compat/architecture/arm/asm_help.h} \
        $inc/architecture/arm/asm_help.h
    ''}

    # cctools mach-o headers: install 5 not elsewhere; fat.h/nlist.h supersets from cctools; loader.h graft missing PLATFORM/TOOL constants from cctools.
    for h in arch.h getsect.h ldsyms.h ranlib.h swap.h; do
      if [ -e "$inc/mach-o/$h" ]; then
        echo "cctools mach-o/$h would overwrite an existing header" >&2
        exit 1
      fi
      install -Dm444 ${sources.cctools}/include/mach-o/$h $inc/mach-o/$h
    done

    if ! grep -q fat_arch_64 ${sources.cctools}/include/mach-o/fat.h; then
      echo "cctools mach-o/fat.h no longer defines fat_arch_64" >&2
      exit 1
    fi
    install -Dm444 ${sources.cctools}/include/mach-o/fat.h $inc/mach-o/fat.h

    for sym in N_COLD_FUNC N_ALT_ENTRY N_SYMBOL_RESOLVER N_WEAK_DEF; do
      grep -q "define $sym" ${sources.cctools}/include/mach-o/nlist.h || {
        echo "cctools mach-o/nlist.h no longer defines $sym" >&2; exit 1; }
    done
    install -Dm444 ${sources.cctools}/include/mach-o/nlist.h $inc/mach-o/nlist.h

    cctoolsLoader=${sources.cctools}/include/mach-o/loader.h
    missing=$(grep -E '^#define (PLATFORM|TOOL)_[A-Z0-9_]+[[:space:]]+[0-9]+$' $cctoolsLoader |
              while read -r define name value; do
                grep -qE "^#define $name[[:space:]]" $inc/mach-o/loader.h || echo "#define $name $value"
              done)
    if [ -z "$missing" ]; then
      echo "xnu mach-o/loader.h has caught up with cctools; drop this graft" >&2
      exit 1
    fi
    echo "grafting $(echo "$missing" | wc -l | tr -d ' ') constants onto loader.h" >&2
    chmod u+w $inc/mach-o/loader.h
    guard=$(grep -n '^#endif' $inc/mach-o/loader.h | tail -1 | cut -d: -f1)
    {
      head -n $((guard - 1)) $inc/mach-o/loader.h
      echo "/* Grafted from cctools by minidarwin's pkgs/sdk-headers.nix. */"
      echo "$missing"
      echo
      tail -n +$guard $inc/mach-o/loader.h
    } > loader.h.grafted
    install -m444 loader.h.grafted $inc/mach-o/loader.h
    rm loader.h.grafted

    copytree ${sources.dyld}/include ""

    # Define DYLD_EXCLAVEKIT_UNAVAILABLE (missing in open source, defined to nothing).
    chmod u+w $inc/mach-o/dyld.h
    substituteInPlace $inc/mach-o/dyld.h --replace-fail \
      '#ifdef __DRIVERKIT_19_0' \
      '#ifndef DYLD_EXCLAVEKIT_UNAVAILABLE
 #define DYLD_EXCLAVEKIT_UNAVAILABLE
#endif

#ifdef __DRIVERKIT_19_0' 

    # Historical symlink shims (pthread.h etc).
    ln -sfn pthread/pthread.h      $inc/pthread.h
    ln -sfn pthread/pthread_impl.h $inc/pthread_impl.h
    ln -sfn pthread/pthread_spis.h $inc/pthread_spis.h
    ln -sfn pthread/sched.h        $inc/sched.h
    for pair in \
      posix_sched.h:posix_sched.h \
      spinlock_private.h:pthread_spinlock.h \
      workqueue_private.h:pthread_workqueue.h
    do
      src=''${pair%%:*}; dst=''${pair##*:}
      if [ -e "$inc/pthread/$src" ]; then ln -sfn "pthread/$src" "$inc/$dst"; fi
    done

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/usr/local
    cp -R include $out/usr/include
    cp -R internal_hdr $out/usr/local/internal_hdr

    # A framework's layout: Versions/B holds it, the rest are links.
    fw=$out/System/Library/Frameworks/System.framework
    mkdir -p $fw/Versions/B
    cp -R sfheaders $fw/Versions/B/PrivateHeaders
    ln -s B $fw/Versions/Current
    ln -s Versions/Current/PrivateHeaders $fw/PrivateHeaders
    [ -d "$out${systemFrameworkHeaders}" ]

    # Each framework header's usr/include twin must still be the SPINCFRAME
    # rendering of the same source -- a later edit to one but not the other
    # would give members and everyone else different declarations.
    ntwins=0
    while IFS= read -r -d "" f; do
      ntwins=$((ntwins + 1))
      rel=''${f#sforig/}
      cp "$f" twin.h; chmod u+w twin.h
      md_unifdef twin.h ${unifdefFlags} || exit 1
      if ! cmp -s twin.h "$out/usr/include/$rel"; then
        echo "usr/include/$rel was changed after unifdef; System.framework's copy was not" >&2
        exit 1
      fi
    done < <(find sforig -name '*.h' -print0)
    [ "$ntwins" -gt 0 ]
    echo "System.framework: $ntwins headers, each still usr/include's twin"

    mkdir -p $out/usr/lib/system

    # Empty header check.
    empty=$(find $out/usr/include -name '*.h' -size 0 | head -20)
    if [ -n "$empty" ]; then
      echo "SDK contains empty headers:" >&2
      echo "$empty" >&2
      exit 1
    fi

    # Required header check.
    for required in \
      stdio.h stdlib.h string.h math.h unistd.h pthread.h dlfcn.h Block.h \
      sys/types.h sys/cdefs.h sys/syscall.h machine/_types.h \
      mach/mach.h mach/task.h mach/vm_map.h mach/mach_port.h \
      mach/${machArchDir}/thread_status.h \
      os/lock.h malloc/malloc.h dispatch/dispatch.h \
      Availability.h AvailabilityInternal.h AvailabilityMacros.h \
      mach-o/loader.h mach-o/dyld.h
    do
      if [ ! -f "$out/usr/include/$required" ]; then
        echo "SDK is missing usr/include/$required" >&2
        exit 1
      fi
    done

    runHook postInstall
  '';

  passthru = { inherit machoArch systemFrameworkHeaders; };

  meta.description = "Darwin SDK headers generated from pinned Apple sources";
}
