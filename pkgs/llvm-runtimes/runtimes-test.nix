# Stage 3 check: verify the four runtimes close over each other (C++ runtime, unwind, builtins).
{ lib
, stdenvNoCC
, writeText
, toolchain
, compilerRtBuiltins
, sdkStage2
, buildSupport
}:

let
  probe = writeText "runtimes-probe.cpp" ''
    #include <exception>
    #include <stdexcept>
    #include <string>
    #include <vector>
    #include <map>
    #include <memory>
    #include <iostream>
    #include <sstream>
    #include <typeinfo>
    #include <regex>
    #include <mutex>
    #include <filesystem>
    #include <charconv>
    #include <cxxabi.h>
    #include <unwind.h>

    /* Exceptions */
    struct probe_error : std::runtime_error {
      explicit probe_error(const std::string &w) : std::runtime_error(w) {}
    };

    static int throw_and_catch() {
      try {
        throw probe_error("stage 3");
      } catch (const std::exception &e) {
        return static_cast<int>(std::string(e.what()).size());
      }
    }

    /* RTTI and dynamic_cast */
    struct Base { virtual ~Base() = default; };
    struct Derived : Base { int x = 1; };

    static int rtti(Base *b) {
      if (auto *d = dynamic_cast<Derived *>(b))
        return d->x + static_cast<int>(typeid(*b).name()[0]);
      return 0;
    }

    /* Function-local static */
    static int guarded() {
      static const std::vector<int> v = { 1, 2, 3 };
      return static_cast<int>(v.size());
    }

    /* 128-bit arithmetic (from libclang_rt) */
    static unsigned long long int128_math(unsigned __int128 a,
                                          unsigned __int128 b) {
      return static_cast<unsigned long long>((a * b) / (b + 1) % 1000003u);
    }

    /* Out-of-line libc++ */
    static int library_bits() {
      std::ostringstream os;
      os << "n=" << guarded() << ' ' << std::hex << 255;
      std::map<std::string, int> m{ { os.str(), 1 } };
      std::regex re("n=[0-9]+.*");
      double d = 0;
      auto s = std::string("3.5");
      std::from_chars(s.data(), s.data() + s.size(), d);
      std::error_code ec;
      auto sz = std::filesystem::file_size(".", ec);
      std::mutex mu;
      std::lock_guard<std::mutex> lock(mu);
      return static_cast<int>(m.size() + std::regex_match(os.str(), re) +
                              (d > 3) + (ec ? 1 : 0) + (sz == 0));
    }

    /* Force references to ABI library and unwinder */
    static void *const unwind_entry =
        reinterpret_cast<void *>(&_Unwind_Backtrace);

    static int abi_and_unwind() {
      int status = 0;
      char *dem = abi::__cxa_demangle("_Z4funcv", nullptr, nullptr, &status);
      int n = (dem && status == 0) ? 1 : 0;
      std::free(dem);
      return n + (unwind_entry != nullptr);
    }

    int probe_main(void);
    int probe_main(void) {
      Derived d;
      return throw_and_catch() + rtti(&d) + guarded() +
             static_cast<int>(int128_math(7, 11)) + library_bits() +
             abi_and_unwind();
    }
  '';
in

stdenvNoCC.mkDerivation {
  pname = "minidarwin-runtimes-test";
  version = compilerRtBuiltins.version;

  dontUnpack = true;
  dontFixup = true;

  nativeBuildInputs = [ toolchain ];

  buildPhase = ''
    runHook preBuild
    source ${buildSupport}

    echo "== the driver's runtime library is ours"
    rt=$($CC -print-libgcc-file-name)
    echo "-- $rt"
    if [ "$(readlink -f "$rt")" != \
         "$(readlink -f ${compilerRtBuiltins}/lib/darwin/libclang_rt.osx.a)" ]; then
      echo "the driver's runtime library is not minidarwin's compiler-rt" >&2
      exit 1
    fi

    echo "== C++ include search path"
    paths=$($CXX -E -v -x c++ /dev/null 2>&1 |
            sed -n '/#include <\.\.\.>/,/End of search/p' |
            grep '^ /')
    echo "$paths"
    if echo "$paths" | grep -vq '^ /nix/store/'; then
      echo "IMPURE: non-store directory on the C++ include search path" >&2
      exit 1
    fi
    if ! echo "$paths" | grep -q '^ ${sdkStage2}/usr/include/c++/v1$'; then
      echo "libc++'s headers are not on the C++ include search path" >&2
      exit 1
    fi

    echo "== compiling the probe"
    $CXX -std=c++23 -Wall -O1 -c ${probe} -o probe.o

    echo "== linking against nothing but our own runtimes"
    $CXX -dynamiclib -o probe.dylib probe.o \
      -install_name /usr/lib/minidarwin-runtimes-probe.dylib \
      -Wl,-undefined,dynamic_lookup \
      ${sdkStage2}/usr/lib/libc++.a \
      ${sdkStage2}/usr/lib/libc++abi.a \
      ${sdkStage2}/usr/lib/libunwind.a \
      ${compilerRtBuiltins}/lib/darwin/libclang_rt.osx.a

    md_verify_pure probe.dylib
    md_verify_signed probe.dylib

    echo "== undefined symbols must all be libSystem's job"
    $NM -u probe.dylib | sort -u > undefined.txt
    echo "-- $(wc -l < undefined.txt) undefined symbols remain"

    # Unresolved C++/unwind/builtins symbols mean incomplete archives.
    if grep -E '^(___cxa_|___gxx_|__Unwind_|_unw_|__Z|___udivti3|___umodti3|___multi3|__aarch64_)' \
         undefined.txt |
       grep -vE '^(___cxa_atexit|___cxa_thread_atexit_impl|___cxa_finalize)$' \
         > leftover.txt; then
      echo "the stage 3 runtimes do not close over each other:" >&2
      cat leftover.txt >&2
      exit 1
    fi

    # Remaining undefs must be plain C symbols (for libSystem).
    grep -vE '^_[A-Za-z_][A-Za-z_0-9]*(\$[A-Za-z_0-9]+)?$' \
      undefined.txt > unexpected.txt || true
    if [ -s unexpected.txt ]; then
      echo "unexpected undefined symbols:" >&2
      cat unexpected.txt >&2
      exit 1
    fi

    runHook postBuild
  '';

  installPhase = ''
    mkdir -p $out
    cp probe.dylib undefined.txt $out/
    echo "stage 3 runtimes ok" > $out/result
  '';

  meta.description = "Links a C++ program against minidarwin's own LLVM runtimes";
}
