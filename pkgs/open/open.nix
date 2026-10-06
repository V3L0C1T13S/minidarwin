{ lib, mkDarwinPackage, toolchain, libxml2 }:

let
  # open sends its environment; libdyld defines `environ` (as for env, find).
  allowUndefined = { "_environ" = "dyld"; };
in
mkDarwinPackage {
  pname = "minidarwin-open";
  version = "0.1.0";
  # open and opend share launchd's plist and framing code.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [ ./. ../launchd/common.cpp ../launchd/common.hpp ];
  };
  sourceRoot = "source/open";
  inherit toolchain;
  passthru = { inherit allowUndefined; };

  buildPhase = ''
    runHook preBuild
    make CPPFLAGS="-I${libxml2}/usr/include/libxml2" \
      CXXFLAGS="-O2" LDFLAGS="-L${libxml2}/usr/lib ${lib.concatMapStringsSep " " (s: "-Wl,-U,${s}") (lib.attrNames allowUndefined)}" LDLIBS="-lxml2 -lc++"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 open $out/usr/bin/open
    install -Dm755 opend $out/usr/libexec/opend
    install -Dm644 handlers $out/private/etc/open/handlers
    install -Dm644 org.minidarwin.opend.plist $out/System/Library/LaunchDaemons/org.minidarwin.opend.plist
    install -Dm644 README.md $out/usr/share/doc/open/README.md
    install -Dm644 ${../../docs/open-protocol.md} $out/usr/share/doc/open/open-protocol.md
    install -Dm644 ${../../LICENSE} $out/usr/share/licenses/open/LICENSE
    for binary in $out/usr/bin/open $out/usr/libexec/opend; do
      md_verify_pure "$binary"
      md_verify_signed "$binary"
      deps=$($OTOOL -L "$binary" | tail -n +2 | awk '{ print $1 }' | sort)
      expected=$(printf '%s\n' /usr/lib/libSystem.B.dylib /usr/lib/libc++.1.dylib /usr/lib/libc++abi.dylib /usr/lib/libxml2.2.dylib | sort)
      if [ "$deps" != "$expected" ]; then
        echo "open: unexpected load commands in $binary: $deps" >&2
        exit 1
      fi
    done
    runHook postInstall
  '';

  meta.description = "open(1) client and default open service for MiniDarwin";
}
