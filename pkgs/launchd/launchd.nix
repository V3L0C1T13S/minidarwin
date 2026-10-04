{ mkDarwinPackage, toolchain, libxml2 }:

mkDarwinPackage {
  pname = "minidarwin-launchd";
  version = "0.1.0";
  src = ./.;
  inherit toolchain;

  buildPhase = ''
    runHook preBuild
    make CPPFLAGS="-I${libxml2}/usr/include/libxml2" \
      CXXFLAGS="-O2" LDFLAGS="-L${libxml2}/usr/lib" LDLIBS="-lxml2 -lc++"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 launchd $out/sbin/launchd
    install -Dm755 launchctl $out/bin/launchctl
    install -Dm644 ${../../LICENSE} $out/usr/share/licenses/launchd/LICENSE
    install -Dm644 README.md $out/usr/share/doc/launchd/README.md
    install -Dm644 example.plist $out/usr/share/doc/launchd/example.plist
    mkdir -p $out/System/Library/LaunchDaemons $out/Library/LaunchDaemons $out/private/var/run
    for binary in $out/sbin/launchd $out/bin/launchctl; do
      md_verify_pure "$binary"
      md_verify_signed "$binary"
      deps=$($OTOOL -L "$binary" | tail -n +2 | awk '{ print $1 }' | sort)
      expected=$(printf '%s\n' /usr/lib/libSystem.B.dylib /usr/lib/libc++.1.dylib /usr/lib/libc++abi.dylib /usr/lib/libxml2.2.dylib | sort)
      if [ "$deps" != "$expected" ]; then
        echo "launchd: unexpected load commands: $deps" >&2
        exit 1
      fi
    done
    runHook postInstall
  '';

  meta.description = "C++ init and core launchd process supervisor for MiniDarwin";
}
