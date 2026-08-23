# Stage 3: libc++abi -- Itanium C++ ABI runtime (static archive; needs libSystem to link).
{ lib
, mkDarwinPackage
, llvmSource
, llvmVersion
, toolchain
, libcxxHeaders
, libunwind
}:

let
  # Exceptions, threads, and new/delete definitions enabled.
  cxxFlags = [
    "-std=c++23"
    "-O3"
    "-DNDEBUG"
    "-fPIC"
    "-nostdinc++"
    "-fstrict-aliasing"
    "-funwind-tables"
    "-fsized-deallocation"
    "-D_LIBCXXABI_BUILDING_LIBRARY"
    # libcxxabi includes libc++'s headers as if it were part of libc++.
    "-D_LIBCPP_BUILDING_LIBRARY"
  ];

  # Conditional sources for threaded Darwin with exceptions (cxa_thread_atexit.cpp excluded on APPLE).
  extraSources = [
    # if(LIBCXXABI_ENABLE_NEW_DELETE_DEFINITIONS)
    "stdlib_new_delete.cpp"
    # if(LIBCXXABI_ENABLE_EXCEPTIONS)
    "cxa_exception.cpp"
    "cxa_personality.cpp"
  ];
in

mkDarwinPackage {
  pname = "libcxxabi";
  version = llvmVersion;

  inherit toolchain;
  dontUnpack = true;

  buildPhase = ''
    runHook preBuild

    mkdir -p src && cd src
    cp -R ${llvmSource}/libcxxabi libcxxabi
    # Only libc++ private headers needed.
    mkdir -p libcxx
    cp -R ${llvmSource}/libcxx/src libcxx/src
    chmod -R u+w libcxxabi libcxx
    export MD_SRCROOT=$PWD

    {
      md_cmake_list libcxxabi/src/CMakeLists.txt LIBCXXABI_SOURCES
      printf '%s\n' ${lib.escapeShellArgs extraSources}
    } | sort -u | sed 's,^,libcxxabi/src/,' > sources.list

    md_log "libcxxabi: $(wc -l < sources.list) sources"

    incflags=(
      -Ilibcxxabi/include
      -Ilibcxxabi/src
      -Ilibcxx/src
      -I${libcxxHeaders}/usr/include/c++/v1
      -I${libunwind}/usr/include
     )

    obj=$PWD/o
    mkdir -p $obj
    md_compile $obj "$CXX" ${lib.escapeShellArgs cxxFlags} "''${incflags[@]}" \
      -- $(cat sources.list)

    md_archive $PWD/libc++abi.a $obj

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm644 libc++abi.a $out/usr/lib/libc++abi.a

    # Install cxxabi.h alongside libc++ headers (C++-only include path).
    inc=${llvmSource}/libcxxabi/include
    install -Dm644 $inc/cxxabi.h $out/usr/include/c++/v1/cxxabi.h
    install -Dm644 $inc/__cxxabi_config.h $out/usr/include/c++/v1/__cxxabi_config.h

    md_verify_symbols $out/usr/lib/libc++abi.a \
      ___cxa_throw ___cxa_rethrow ___cxa_begin_catch ___cxa_end_catch \
      ___cxa_allocate_exception ___cxa_free_exception \
      ___gxx_personality_v0 ___dynamic_cast ___cxa_guard_acquire \
      ___cxa_pure_virtual ___cxa_demangle \
      __ZdlPv __Znwm __ZnwmSt11align_val_t

    runHook postInstall
  '';

  meta.description = "LLVM libc++abi -- the Itanium C++ ABI runtime, static";
}
