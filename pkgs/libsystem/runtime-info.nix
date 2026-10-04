# libsystem_info: Libinfo's `Libinfo` target with its file, search and cache
# backends. No DirectoryService, DarwinDirectory or mDNS; notify reports no
# notifyd (runtime-notify.c), so the file backends revalidate on each use.
{ lib, mkDarwinPackage, sources, toolchain, systemFrameworkHeaders, libsystemTree2, libdyld, runtimeNotify, python3, darwin }:
let
  # Files the generated list names that cannot be compiled here, with reason.
  # ds_module.c, darwin_directory.c and muser_module.c stay in the list: each
  # is guarded by its own DS_AVAILABLE/DARWIN_DIRECTORY_AVAILABLE/MUSER_AVAILABLE
  # and compiles to nothing, as it does for Apple when the define is off.
  notCompiled = {
    "Libinfo/od_debug.c" = "os/variant_private.h is libsystem_darwin's; only DS_AVAILABLE code logs through it";
    "gen.subproj/configuration_profile.c" = "xpc (closed source)";
    "lookup.subproj/mdns_module.c" = "dns_sd_private.h, mDNSResponder's (system_dnssd, closed source)";
    "dns.subproj/res_query.c" = "dns_sd.h, mDNSResponder's (system_dnssd, closed source)";
  };
  files = import ./libinfo-sources.nix;
  compiled = lib.filter (f: !(notCompiled ? ${f})) files;
in
assert lib.all (f: lib.elem f files) (lib.attrNames notCompiled);
mkDarwinPackage {
  pname = "minidarwin-runtime-info";
  version = lib.removePrefix "Libinfo-" sources.Libinfo.rev;
  src = sources.Libinfo;
  inherit toolchain;
  # Host world: rpcgen, as Librpcsvc's install_rpcsvc.sh runs it.
  nativeBuildInputs = [ python3 darwin.developer_cmds ];
  patchPhase = ''
    python3 ${./patch-runtime-info.py}
  '';
  buildPhase = ''
    runHook preBuild
    export MD_SRCROOT=$PWD
    mkdir -p o hdrs/rpc hdrs/rpcsvc
    # install_files.sh's <rpc/...> and <rpcsvc/...> headers, which the
    # sources include by their installed names.
    cp rpc.subproj/{auth,auth_unix,clnt,rpc,rpc_msg,svc,svc_auth,types,xdr}.h \
      rpc.subproj/{pmap_clnt,pmap_prot,pmap_rmt}.h hdrs/rpc/
    cp nis.subproj/{yp_prot,ypclnt}.h hdrs/rpcsvc/
    # Librpcsvc's <rpcsvc/yp.h> and <rpcsvc/yppasswd.h>, which the NIS
    # sources also include.
    for x in yp yppasswd; do
      cp ${sources.Librpcsvc}/$x.x hdrs/rpcsvc/
      (cd hdrs/rpcsvc && rpcgen -h -o $x.h $x.x)
    done
    files=()
    for f in ${lib.escapeShellArgs compiled}; do files+=( "$PWD/$f" ); done
    # Libinfo.xcconfig's macOS GCC_PREPROCESSOR_DEFINITIONS, less
    # DS_AVAILABLE (opendirectory, xpc) and DARWIN_DIRECTORY_AVAILABLE
    # (DarwinDirectory): both name closed-source services. SYNTH_ROOTFS and
    # CONFIG_MAC are kept. info-compat compiles the os_log diagnostics out
    # (libsystem_trace is closed). DEBUG is left
    # undefined rather than 0: `#if DEBUG` reads the same, and ils.c's
    # `#ifdef DEBUG` would otherwise include <asl.h> (system_asl, closed).
    md_compile o "$CC" -Os -std=gnu99 -fblocks -fvisibility=hidden \
      -D__DARWIN_NON_CANCELABLE=1 -D__MigTypeCheck=1 -DINET6=1 \
      -DCONFIG_MAC -DSYNTH_ROOTFS \
      -I${./info-compat} -Ihdrs \
      -ILibinfo -Ilookup.subproj -Igen.subproj -Irpc.subproj -Inis.subproj \
      -Imembership.subproj -Idns.subproj -Iutil.subproj \
      -iwithsysroot ${systemFrameworkHeaders} \
      -- "''${files[@]}"
    # OTHER_LDFLAGS, less the libraries that are not built.
    md_dylib libsystem_info.dylib /usr/lib/system/libsystem_info.dylib o \
      -Wl,-umbrella,System -L${libsystemTree2}/usr/lib/system \
      -L${libdyld}/usr/lib/system -L${runtimeNotify}/usr/lib/system \
      -lcompiler_rt -ldyld -lsystem_kernel -lsystem_malloc -lsystem_platform \
      -lsystem_pthread -lsystem_c -ldispatch -lsystem_blocks -lsystem_notify
    runHook postBuild
  '';
  installPhase = ''
    install -Dm755 libsystem_info.dylib $out/usr/lib/system/libsystem_info.dylib
    install -Dm644 APPLE_LICENSE $out/usr/share/licenses/Libinfo/APPLE_LICENSE
    md_verify_pure $out/usr/lib/system/libsystem_info.dylib
    md_verify_signed $out/usr/lib/system/libsystem_info.dylib
    # Every import the rest of the tree labels system_info (rootfs.nix checks
    # the whole set; these are the ones the boot path reaches first).
    md_verify_symbols $out/usr/lib/system/libsystem_info.dylib \
      _gethostbyname _gethostbyaddr _getaddrinfo _freeaddrinfo _getnameinfo \
      _gai_strerror _getservbyname _h_errno _getpwnam _getpwuid _getpwnam_r \
      _getpwuid_r _getpwent _setpwent _endpwent _setpassent _getgrnam _getgrgid \
      _endgrent _setgroupent _getgrouplist _getgroupcount _initgroups \
      _getifaddrs _freeifaddrs _if_nametoindex _innetgr _getdomainname \
      _mbr_uid_to_uuid _mbr_gid_to_uuid _mbr_uuid_to_id \
      _mbr_identifier_to_uuid _mbr_identifier_translate
  '';
}
