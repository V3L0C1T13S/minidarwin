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
            sdkStage3
            toolchainStage3
            libmachO
            libcxxabiDylib
            libcxxDylib
            rootfs;

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
          default = scope.sdkHeaders;
        });

      # Checks: native target only (cross same derivations; checked explicitly).
      checks = forAllSystems (system: pkgs:
        let scope = nativeScope pkgs;
        in {
          inherit (scope) sdkTest runtimesTest libsystemTest;
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
            packages = [ s.toolchainStage3 s.mig pkgs.python3 pkgs.perl pkgs.unifdef ];
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

      formatter = forAllSystems (system: pkgs: pkgs.nixpkgs-fmt);
    };
}
