# Stage 7 release: the rootfs packed for distribution, with the manifest that
# describes it and the spec that pins both. Format: docs/rootfs-spec.md.
#
# Host world (nothing here is compiled for the target), and reproducible like
# everything else: every file in $out is what a published release carries,
# byte for byte, except that the published spec is *stamped* with the tag,
# commit and download URLs -- which changes none of the hashes it holds.
{ lib
, stdenvNoCC
, python3
, gnutar
, gzip
, rootfs
, sources
, llvmVersion
, targetArch
, minOS
, release
, mdrootfsScript
}:

let
  name = "minidarwin-rootfs-${targetArch}-r${toString release.sequence}";

  identity = {
    project = "minidarwin";
    arch = targetArch;
    min_os = minOS;
    libsystem = sources.Libsystem.rev;
    xnu = sources.xnu.rev;
  };

  # Every pinned Apple source, with the hash that pins it: the whole OS train,
  # not only what this tree happens to use so far.
  appleSources = lib.mapAttrsToList (n: s: "${n}=${s.rev}=${s.outputHash}") sources;
in

stdenvNoCC.mkDerivation {
  pname = "minidarwin-rootfs-release";
  version = "r${toString release.sequence}";

  dontUnpack = true;
  dontFixup = true;

  nativeBuildInputs = [ python3 gnutar gzip ];

  SOURCE_DATE_EPOCH = "1";
  TZ = "UTC";
  LC_ALL = "C";

  buildPhase = ''
    runHook preBuild
    mkdir -p $out
    md() { python3 ${mdrootfsScript} "$@"; }

    # The tree is already reproducible; the tarball must add nothing of its
    # own. Sorted names, no owner, the epoch the tree was built at, and the
    # canonical permissions (the store's 0555/0444 made owner-writable, which
    # is 0755/0644). --hard-dereference because `nix store optimise` may have
    # hardlinked two identical files, and whether it has is not the tree's
    # business. GNU format: nothing in it depends on atime or ctime.
    tar --sort=name --format=gnu \
        --numeric-owner --owner=0 --group=0 \
        --mtime=@1 --mode=u+w,go-w \
        --hard-dereference \
        -C ${rootfs} -cf - . | gzip -9n > $out/${name}.tar.gz

    md manifest ${rootfs} -o $out/${name}.manifest.yaml \
      ${lib.concatMapStringsSep " " (k: "--identity ${lib.escapeShellArg "${k}=${identity.${k}}"}") (lib.attrNames identity)} \
      --llvm ${lib.escapeShellArg llvmVersion} \
      ${lib.concatMapStringsSep " " (s: "--apple-source ${lib.escapeShellArg s}") appleSources}

    md spec --sequence ${toString release.sequence} \
      --manifest $out/${name}.manifest.yaml \
      --artifact $out/${name}.tar.gz \
      -o $out/${name}.spec.yaml

    md bundle -o $out/${name}.bundle.zip \
      --spec $out/${name}.spec.yaml \
      --manifest $out/${name}.manifest.yaml \
      --artifact $out/${name}.tar.gz

    # The manifest was made from the store path and the tarball by tar; this
    # is where the two are checked against each other, through the same
    # hardened extraction a consumer uses.
    md verify --spec $out/${name}.spec.yaml \
      --manifest $out/${name}.manifest.yaml \
      --artifact $out/${name}.tar.gz
    md verify --bundle $out/${name}.bundle.zip --spec $out/${name}.spec.yaml

    runHook postBuild
  '';

  dontInstall = true;

  passthru = {
    inherit identity;
    releaseName = name;
    spec = "${name}.spec.yaml";
    manifest = "${name}.manifest.yaml";
    artifact = "${name}.tar.gz";
    bundle = "${name}.bundle.zip";
  };

  meta.description = "minidarwin rootfs release: tarball, manifest, spec and bundle";
}
