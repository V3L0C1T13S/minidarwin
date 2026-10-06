{
  description =
    "Reproducible, pure Nix bootstrap of a minimal Darwin rootfs from Apple's released sources, starting from a barebones Clang";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];

      # Both targets build from either host (nothing target-side is executed).
      targetArches = [ "aarch64" "x86_64" ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f system nixpkgs.legacyPackages.${system});

      scopeFor = pkgs: targetArch:
        import ./default.nix { inherit pkgs targetArch; };

      nativeScope = pkgs: import ./default.nix { inherit pkgs; };
    in
    {
      packages = forAllSystems (system: pkgs:
        let scope = nativeScope pkgs;
        in {
          inherit (scope)
            mig
            sdkHeaders
            toolchainStage1
            libsyscall
            compilerRtBuiltins
            libunwind
            libcxxHeaders
            libcxxabi
            libcxx
            clangResourceDir
            sdkStage2
            toolchainStage2
            libsystemTree1
            libsystemTree2
            libSystem
            libdispatch
            sdkStage3
            toolchainStage3
            libmachO
            libdyld
            efiLoader
            efiBootImage
            qemuEfi
            libcxxabiDylib
            libcxxDylib
            copyfile
            removefile
            sdkStage4
            toolchainStage4
            ncurses
            ncursesPanel
            top
            terminfo
            certPem
            libedit
            shellCmds
            libutil
            libsbuf
            fileCmds
            libmd
            textCmds
            advCmds
            basicCmds
            systemCmds
            patchCmds
            miscCmds
            awk
            file
            curl
            zlib
            bzip2
            zip
            icu
            libxml2
            libxo
            quickjs
            libressl
            openssl098
            nano
            bash
            zsh
            ncursesTools
            su
            sudo
            rootfs
            rootfsRelease
            mdrootfs
            installer
            installerBootstrap
            launchd
            launchdBootstrap
            open
            openBootstrap;

          # Stage 4 pass-2 members (pass-1 at legacyPackages.<system>.libsystemPass1).
          inherit (scope.libsystemPass2)
            compilerRtDylib
            unwindDylib
            libmacho
            libsystemBlocks
            libsystemC
            libsystemCollections
            libsystemPlatform
            libsystemPthread
            libsystemMalloc;

          sdk = scope.sdkHeaders;
          kernel = (scopeFor pkgs "x86_64").kernel;
          kernelCollection = (scopeFor pkgs "x86_64").kernelCollection;
          kernelBootImage = (scopeFor pkgs "x86_64").kernelBootImage;
          qemuKernel = (scopeFor pkgs "x86_64").qemuKernel;
          bootImage = (scopeFor pkgs "x86_64").bootImage;
          bootRootfs = (scopeFor pkgs "x86_64").bootRootfs;
          bootRootPartition = (scopeFor pkgs "x86_64").bootRootPartition;
          qemuBoot = (scopeFor pkgs "x86_64").qemuBoot;
          rootMountProbeImage = (scopeFor pkgs "x86_64").rootMountProbeImage;
          perl = scope.darwinPerl;
          default = scope.sdkHeaders;
        });

      # Checks: native target only (cross same derivations; checked explicitly).
      checks = forAllSystems (system: pkgs:
        let scope = nativeScope pkgs;
        in {
          inherit (scope) sdkTest runtimesTest libsystemTest libdispatchTest cxxLinkTest libxml2Test libxoTest quickjsTest topTest archTest authTest releaseTest installerTest launchdTest openTest bootDiskTest trustCacheTest dyldDigestsTest runtimeCryptoTest;
          dyldTest = (scopeFor pkgs "x86_64").dyld;
          xnuClangTest = scope.xnuClang;
          kernelCryptoTest = scope.kernelCryptoTest;
          iigTest = scope.iig;
          kernelLinkTest = (scopeFor pkgs "x86_64").kernel;
          kernelCollectionTest = (scopeFor pkgs "x86_64").kernelCollection;
          kernelStartupTest = (scopeFor pkgs "x86_64").kernelStartupTest;
          platformCollectionTest = (scopeFor pkgs "x86_64").platformKernelCollection;
          storageCollectionTest = (scopeFor pkgs "x86_64").storageKernelCollection;
          rootMountTest = (scopeFor pkgs "x86_64").rootMountTest;
          bootTest = (scopeFor pkgs "x86_64").bootTest;
          libSystemRuntimeTest = (scopeFor pkgs "x86_64").libSystemRuntime;
        });

      # Full set for nix eval; cross.<arch> retargets it.
      legacyPackages = forAllSystems (system: pkgs:
        (nativeScope pkgs) // {
          cross = nixpkgs.lib.genAttrs targetArches (scopeFor pkgs);
        });

      devShells = forAllSystems (system: pkgs:
        let
          scope = nativeScope pkgs;
          shellFor = s: pkgs.mkShellNoCC {
            packages = [ s.toolchainStage4 s.mig pkgs.python3 pkgs.perl pkgs.unifdef ];
            shellHook = ''
              echo "minidarwin: CC=$CC"
              echo "            sysroot=$MINIDARWIN_SYSROOT"
            '';
          };
        in
        (nixpkgs.lib.mapAttrs' (arch: s: nixpkgs.lib.nameValuePair "cross-${arch}" (shellFor s))
          (nixpkgs.lib.genAttrs targetArches (scopeFor pkgs))) // {
          default = shellFor scope;
        });

      # `nix run .#mdrootfs -- verify --bundle ...` (docs/rootfs-spec.md).
      apps = forAllSystems (system: pkgs: {
        qemuBoot = {
          type = "app";
          program = "${(scopeFor pkgs "x86_64").qemuBoot}/bin/minidarwin-qemu-efi";
        };
        qemuKernel = {
          type = "app";
          program = "${(scopeFor pkgs "x86_64").qemuKernel}/bin/minidarwin-qemu-efi";
        };
        qemuEfi = {
          type = "app";
          program = "${(nativeScope pkgs).qemuEfi}/bin/minidarwin-qemu-efi";
        };
        mdpkg = {
          type = "app";
          program = "${(nativeScope pkgs).installerBootstrap}/bin/mdpkg";
        };
        mdrootfs = {
          type = "app";
          program = "${(nativeScope pkgs).mdrootfs}/bin/mdrootfs";
        };
      });

      formatter = forAllSystems (system: pkgs: pkgs.nixpkgs-fmt);
    };
}
