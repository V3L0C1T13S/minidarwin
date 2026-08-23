# Stage 3: libc++ headers (split from library so libc++abi can build against them).
# __config_site is generated from __config_site.in with explicit values for every #cmakedefine.
{ lib
, mkDarwinPackage
, llvmSource
, llvmVersion
, toolchain
, python3
}:

let
  # Values for every #cmakedefine in __config_site.in (from stock aarch64-apple-darwin build).
  configSite = {
    _LIBCPP_ABI_VERSION = "1";
    _LIBCPP_ABI_NAMESPACE = "__1";
    _LIBCPP_ABI_FORCE_ITANIUM = "0";
    _LIBCPP_ABI_FORCE_MICROSOFT = "0";

    # Threads from libsystem_pthread; threading_support deduces pthreads for Darwin.
    _LIBCPP_HAS_THREADS = "1";
    _LIBCPP_HAS_MONOTONIC_CLOCK = "1";
    _LIBCPP_HAS_THREAD_API_PTHREAD = "0";
    _LIBCPP_HAS_THREAD_API_EXTERNAL = "0";
    _LIBCPP_HAS_THREAD_API_WIN32 = "0";

    _LIBCPP_HAS_TERMINAL = "1";
    _LIBCPP_HAS_MUSL_LIBC = "0";
    _LIBCPP_HAS_FILESYSTEM = "1";
    _LIBCPP_HAS_RANDOM_DEVICE = "1";
    _LIBCPP_HAS_LOCALIZATION = "1";
    _LIBCPP_HAS_UNICODE = "1";
    _LIBCPP_HAS_WIDE_CHARACTERS = "1";
    _LIBCPP_HAS_NO_STD_MODULES = "";
    _LIBCPP_INSTRUMENTED_WITH_ASAN = "0";

    _LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS = "0"; # all symbols available in our rootfs

    _LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS = "";
    _LIBCPP_NO_VCRUNTIME = "";
    _LIBCPP_TYPEINFO_COMPARISON_IMPLEMENTATION = "";

    _LIBCPP_HAS_TIME_ZONE_DATABASE = "0"; # in libc++experimental, not built here

    _LIBCPP_PSTL_BACKEND_SERIAL = "";
    _LIBCPP_PSTL_BACKEND_STD_THREAD = "1";
    _LIBCPP_PSTL_BACKEND_LIBDISPATCH = ""; # libdispatch not yet available

    _LIBCPP_HARDENING_MODE_DEFAULT = "2"; # fast mode (upstream default)
  };

  # Distinguish `#define X 1` from `#define X` (boolean vs valued).
  configSiteJSON = builtins.toJSON configSite;

  configure = ''
    import json, re, sys

    values = json.loads(sys.argv[1])
    src, dst = sys.argv[2], sys.argv[3]

    seen = set()
    out = []
    for line in open(src):
        m = re.match(r'#cmakedefine(01)?\s+(\w+)(\s+@(\w+)@)?\s*$', line)
        if m:
            numeric, var, _, ref = m.groups()
            if var not in values:
                sys.exit(f'{src}: no value configured for {var}')
            seen.add(var)
            v = values[var]
            if numeric:
                if v not in ('0', '1'):
                    sys.exit(f'{var}: #cmakedefine01 needs 0 or 1, got {v!r}')
                out.append(f'#define {var} {v}\n')
            elif not v:
                out.append(f'/* #undef {var} */\n')
            elif ref:
                out.append(f'#define {var} {v}\n')
            else:
                out.append(f'#define {var}\n')
            continue
        # The two blocks CMake fills from LIBCXX_ABI_DEFINES and
        # LIBCXX_EXTRA_SITE_DEFINES; we set neither.
        if line.strip() in ('@_LIBCPP_ABI_DEFINES@', '@_LIBCPP_EXTRA_SITE_DEFINES@'):
            continue
        if '@' in line and re.search(r'@\w+@', line):
            sys.exit(f'{src}: unhandled substitution: {line.strip()}')
        out.append(line)

    unused = sorted(set(values) - seen)
    if unused:
        sys.exit(f'{src}: configured values not present upstream: {unused}')

    open(dst, 'w').writelines(out)
  '';
in

mkDarwinPackage {
  pname = "libcxx-headers";
  version = llvmVersion;

  inherit toolchain;
  nativeBuildInputs = [ python3 ];
  dontUnpack = true;

  buildPhase = ''
    runHook preBuild

    cp -R ${llvmSource}/libcxx/include v1
    chmod -R u+w v1

    cat > configure_config_site.py <<'PY'
    ${configure}
    PY

    python3 configure_config_site.py ${lib.escapeShellArg configSiteJSON} \
      v1/__config_site.in v1/__config_site

    # Assertion handler (hardening failures -> __libcpp_verbose_abort).
    cp ${llvmSource}/libcxx/vendor/llvm/default_assertion_handler.in \
      v1/__assertion_handler

    # Expand module map substitution for __config_site.
    sed 's|@LIBCXX_CONFIG_SITE_MODULE_ENTRY@|textual header "__config_site"|' \
      v1/module.modulemap.in > v1/module.modulemap

    rm v1/CMakeLists.txt v1/module.modulemap.in
    rm v1/__config_site.in v1/__cxx03/__config_site.in
    rm v1/__cxx03/__iterator/cpp17_iterator_concepts.h # orphan not in install list

    if grep -rl '@[A-Z_][A-Z_0-9]*@' v1 | grep -q .; then
      echo "unexpanded CMake substitution left in the header tree" >&2
      grep -rn '@[A-Z_][A-Z_0-9]*@' v1 >&2
      exit 1
    fi

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/usr/include/c++
    cp -R v1 $out/usr/include/c++/v1
    chmod -R a-w $out/usr/include/c++/v1

    runHook postInstall
  '';

  meta.description = "libc++ headers, with a generated __config_site";
}
