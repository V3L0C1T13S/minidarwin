# Stage 3: libc++ -- C++ standard library (static archive; dylib in stage 4).
{ lib
, mkDarwinPackage
, llvmSource
, llvmVersion
, toolchain
, libcxxHeaders
, libcxxabi
}:

let
  # Release flags from cxx_add_basic_build_flags().
  cxxFlags = [
    "-std=c++23"
    "-O3"
    "-DNDEBUG"
    "-fPIC"
    "-nostdinc++"
    "-faligned-allocation"
    # Hide inline functions not explicitly marked visible (avoid ODR duplication).
    "-fvisibility-inlines-hidden"
    "-fvisibility=hidden"
    "-fsized-deallocation"
    "-D_LIBCPP_BUILDING_LIBRARY"
    "-D_LIBCPP_REMOVE_TRANSITIVE_INCLUDES"
    # HandleLibCXXABI.cmake, for LIBCXX_CXX_ABI = libcxxabi.
    "-DLIBCXX_BUILDING_LIBCXXABI"
    # <charconv> float parsing shared with llvm-libc.
    "-DLIBC_NAMESPACE=__llvm_libc_common_utils"
  ];

  # Conditional sources (all ON for hosted build).
  threadSources = [
    "atomic.cpp"
    "barrier.cpp"
    "condition_variable.cpp"
    "condition_variable_destructor.cpp"
    "future.cpp"
    "mutex.cpp"
    "mutex_destructor.cpp"
    "shared_mutex.cpp"
    "thread.cpp"
  ];
  randomDeviceSources = [ "random.cpp" ];
  localizationSources = [
    "fstream.cpp"
    "ios.cpp"
    "ios.instantiations.cpp"
    "iostream.cpp"
    "locale.cpp"
    "ostream.cpp"
    "regex.cpp"
    "strstream.cpp"
  ];
  filesystemSources = [
    "filesystem/directory_entry.cpp"
    "filesystem/directory_iterator.cpp"
    "filesystem/operations.cpp"
  ];

  # Excluded: new.cpp (in libc++abi), int128_builtins, experimental/pstl, platform-specific.
in

mkDarwinPackage {
  pname = "libcxx";
  version = llvmVersion;

  inherit toolchain;
  dontUnpack = true;

  buildPhase = ''
    runHook preBuild

    mkdir -p src && cd src
    cp -R ${llvmSource}/libcxx/src libcxx
    chmod -R u+w libcxx
    export MD_SRCROOT=$PWD

    # Only .cpp entries are compiled (headers/.ipp are IDE-only).
    {
      md_cmake_list libcxx/CMakeLists.txt LIBCXX_SOURCES | grep '\.cpp$'
      printf '%s\n' ${lib.escapeShellArgs (threadSources ++ randomDeviceSources
                                           ++ localizationSources ++ filesystemSources)}
    } | sort -u | sed 's,^,libcxx/,' > sources.list

    md_log "libcxx: $(wc -l < sources.list) sources"
    for f in $(cat sources.list); do
      [ -e "$f" ] || { echo "missing libc++ source: $f" >&2; exit 1; }
    done

    incflags=(
      -Ilibcxx
      -I${llvmSource}/libc
      -I${libcxxHeaders}/usr/include/c++/v1
      -I${libcxxabi}/usr/include/c++/v1
    )

    obj=$PWD/o
    mkdir -p $obj
    md_compile $obj "$CXX" ${lib.escapeShellArgs cxxFlags} "''${incflags[@]}" \
      -- $(cat sources.list)

    md_archive $PWD/libc++.a $obj

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm644 libc++.a $out/usr/lib/libc++.a

    # Spot-check one symbol per out-of-line library component.
    md_verify_symbols $out/usr/lib/libc++.a \
      __ZNSt3__14coutE __ZNSt3__16locale5facet16__on_zero_sharedEv \
      __ZNSt3__112__next_primeEm \
      __ZNSt3__120__throw_system_errorEiPKc \
      __ZNSt3__122__libcpp_verbose_abortEPKcz \
      __ZNSt3__14__fs10filesystem11__file_sizeERKNS1_4pathEPNS_10error_codeE

    runHook postInstall
  '';

  meta.description = "LLVM libc++ -- the C++ standard library, static";
}
