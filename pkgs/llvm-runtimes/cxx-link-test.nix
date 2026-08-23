# Stage 4 check: a C++ program using RTTI links with nothing but -lc++.
# Guards the gap this sysroot exists to close -- against stage 3 the same link
# fails with `undefined symbol: __dynamic_cast` plus the __cxxabiv1 vtables.
{ lib
, stdenvNoCC
, writeText
, toolchain
, sdkStage4
, buildSupport
}:

let
  probe = writeText "cxx-link-probe.cpp" ''
    #include <typeinfo>
    #include <memory>
    #include <string>

    struct Base { virtual ~Base(); };
    struct Middle : Base { int m = 1; };
    struct Derived : Middle { int d = 2; };
    Base::~Base() = default;

    /* dynamic_cast down a hierarchy: ___dynamic_cast + the __cxxabiv1
       __class_type_info / __si_class_type_info vtables, all from libc++abi. */
    static int downcast(Base *b) {
      if (auto *d = dynamic_cast<Derived *>(b))
        return d->d + d->m;
      return 0;
    }

    /* dynamic_cast to a virtual base: __vmi_class_type_info. */
    struct VBase { virtual ~VBase() = default; int v = 4; };
    struct VLeft : virtual VBase { };
    struct VRight : virtual VBase { };
    struct VJoin : VLeft, VRight { };

    static int crosscast(VBase *b) {
      auto *j = dynamic_cast<VJoin *>(b);
      return j ? j->v : 0;
    }

    /* typeid on a polymorphic object, and a throw/catch that matches by type. */
    static int rtti_and_throw() {
      Derived d;
      Base &b = d;
      int n = typeid(b) == typeid(Derived) ? 1 : 0;
      try {
        throw std::string("stage 4");
      } catch (const std::string &s) {
        n += static_cast<int>(s.size());
      }
      return n;
    }

    extern "C" int probe_main(void);
    extern "C" int probe_main(void) {
      Derived d;
      VJoin j;
      auto p = std::make_unique<Derived>();
      return downcast(&d) + crosscast(&j) + rtti_and_throw() +
             downcast(p.get());
    }
  '';
in

stdenvNoCC.mkDerivation {
  pname = "minidarwin-cxx-link-test";
  version = sdkStage4.version;

  dontUnpack = true;
  dontFixup = true;

  nativeBuildInputs = [ toolchain ];

  buildPhase = ''
    runHook preBuild
    source ${buildSupport}

    echo "== compiling the probe"
    $CXX -std=c++23 -Wall -O1 -c ${probe} -o probe.o

    echo "== -lc++ alone must resolve the C++ ABI runtime"
    $CXX -dynamiclib -o probe.dylib probe.o \
      -install_name /usr/lib/minidarwin-cxx-link-probe.dylib \
      -lc++

    md_verify_pure   probe.dylib
    md_verify_signed probe.dylib

    echo "== -lc++ resolved to the dylib, not the archive"
    $OTOOL -L probe.dylib
    for l in /usr/lib/libc++.1.dylib /usr/lib/libSystem.B.dylib; do
      $OTOOL -L probe.dylib | tail -n +2 | grep -q "^	$l " || {
        echo "probe.dylib does not link $l" >&2; exit 1; }
    done

    echo "== the ABI symbols are imports, satisfied by libc++abi via libc++"
    $NM -u probe.dylib | sort -u > undefined.txt
    for s in ___dynamic_cast __ZTVN10__cxxabiv117__class_type_infoE \
             __ZTVN10__cxxabiv120__si_class_type_infoE \
             __ZTVN10__cxxabiv121__vmi_class_type_infoE \
             ___cxa_throw ___cxa_begin_catch; do
      grep -qx -- "$s" undefined.txt || {
        echo "probe.dylib does not import $s -- probe no longer exercises it" >&2
        exit 1; }
    done
    $NM -g --defined-only ${sdkStage4}/usr/lib/libc++abi.dylib |
      awk '{ print $NF }' | grep -qx ___dynamic_cast || {
      echo "libc++abi.dylib does not export ___dynamic_cast" >&2; exit 1; }

    runHook postBuild
  '';

  installPhase = ''
    mkdir -p $out
    cp probe.dylib undefined.txt $out/
    echo "stage 4 C++ link ok" > $out/result
  '';

  meta.description = "Links a C++ program using RTTI against the stage 4 sysroot's -lc++";
}
