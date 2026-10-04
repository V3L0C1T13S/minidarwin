# Content-addressed sources. Apple pins follow the macOS 26 / xnu-12377 set
# except for explicitly noted legacy projects; third-party projects are pinned upstream.
{ fetchFromGitHub, fetchurl }:

let
  apple = repo: rev: hash:
    fetchFromGitHub {
      owner = "apple-oss-distributions";
      inherit repo rev hash;
      name = "${repo}-src";
    };
in
{
  iig_tools = fetchFromGitHub {
    owner = "PureDarwin";
    repo = "iig-tools";
    rev = "28010c688caab7eb5400b9c98faa5b1e538e0108";
    hash = "sha256-MFc/y46GA3eolVC68nQT+2i8WGZ7R9/Ra3ux3lNJUEo=";
  };

  xnu_loader = fetchFromGitHub {
    owner = "PureDarwin";
    repo = "xnu-loader";
    rev = "8295cd89c184785896d007d0554b398d22d8e32f";
    hash = "sha256-Kumc+A8I0hWM7+mA2KXt4K1zwY/wpJFYbJ4C86JHgr8=";
  };

  kc_tools = fetchFromGitHub {
    owner = "PureDarwin";
    repo = "kc-tools";
    rev = "802fbc70ef5431950f24e79b02f2d938385d91bd";
    hash = "sha256-VwH7tU5+/6La41B2xwVtm/SWWJvUt46fNOudIWP7UiI=";
  };

  # Curate the open platform/storage drivers without importing PureDarwin's
  # kernel, userland, proprietary SDK input, or crypto provider.
  puredarwin_platform = fetchFromGitHub {
    owner = "PureDarwin";
    repo = "PureDarwin";
    rev = "1bbaeb2ee6aa41e6f792a0b1e2943cc295b3b290";
    hash = "sha256-8t2KGDJ79dGofwJw64lonHI9DIoXX3wLL6RQ+wdNVYI=";
    postFetch = ''
      mkdir -p "$TMPDIR/platform/Extensions"
      for driver in IOACPIFamily PDACPIPlatform IOPCIFamily AppleAPIC AppleI386PCI \
                    IOStorageFamily IOVirtIOFamily IOVirtIOBlock ext4 Ext4FileSystemDriver; do
        cp -R "$out/src/Kernel/Extensions/$driver" "$TMPDIR/platform/Extensions/"
      done
      cp -R "$out/src/Kernel/libkmod" "$TMPDIR/platform/"
      cp "$out"/*LICENSE* "$TMPDIR/platform/"
      rm -rf "$out"
      mv "$TMPDIR/platform" "$out"
    '';
  };

  gnu_efi = fetchFromGitHub {
    owner = "ncroxon";
    repo = "gnu-efi";
    rev = "4.0.2";
    hash = "sha256-oIj0aNY4xU5OcO69TTjh5FcWzzkFd6jbenwzVvTXjqo=";
  };

  bootstrap_cmds = apple "bootstrap_cmds" "bootstrap_cmds-138"
    "sha256-6JG0sysgqLlgcpIOXfN+F0/gxpIIHZZ5et3gmDBoBGQ=";

  # availability generator
  AvailabilityVersions = apple "AvailabilityVersions" "AvailabilityVersions-157.2"
    "sha256-v+ikUET6ByNEBRbPbl7ivqTJKJkZQDGG7Q20tIMt8pU=";

  # CarbonHeaders (TargetConditionals etc.)
  CarbonHeaders = apple "CarbonHeaders" "CarbonHeaders-18.1"
    "sha256-nIPXnLr21yVnpBhx9K5q3l/nPARA6JL/dED08MeyhP8=";

  xnu = apple "xnu" "xnu-12377.121.6"
    "sha256-bjnFbOcrkXTDQtrbG6l9ygTne20TYov7DJ9vKtZ2ZRw=";

  Libsystem = apple "Libsystem" "Libsystem-1356"
    "sha256-/NlSwPaoTVx+bl9hYsfz3C5MuLdqGv4vdAh0KDbDKmY=";
  Libc = apple "Libc" "Libc-1752.120.2"
    "sha256-Vqvw/gxwQuRiqaF3hA7Qow+wY1ZHmw8TIPzdHcTKhI4=";
  Libm = apple "Libm" "Libm-2026"
    "sha256-p4BndAag9d0XSMYWQ+c4myGv5qXbKx5E1VghudSbpTk=";
  Libinfo = apple "Libinfo" "Libinfo-600"
    "sha256-4InBEPi0n2EMo/8mIBib1Im4iTKRcRJ4IlAcLCigVGk=";
  # Last release (2023), older than this train: only yp.x is used, through
  # host rpcgen, for the <rpcsvc/yp.h> Libinfo's NIS client compiles against.
  Librpcsvc = apple "Librpcsvc" "Librpcsvc-31"
    "sha256-UWYdCQ9QsBqwM01bWr+igINAHSdSluB/FrOclC5AjTI=";
  libnotify = apple "libnotify" "Libnotify-348.120.4"
    "sha256-gs9SVkJfGydAe+79wmSxZVQB+ZVsz198T0kPTKtoKCY=";
  libplatform = apple "libplatform" "libplatform-375.120.2"
    "sha256-bghS+sClE2nygZMahh1udoMZmGvRSCKn+W4ywTi51Zw=";
  libpthread = apple "libpthread" "libpthread-539.100.4"
    "sha256-3Xoe0gYZ6RbMZqzsAG8ynnFb3cqypFYImPNYA5H6P9s=";
  libmalloc = apple "libmalloc" "libmalloc-812.100.31"
    "sha256-kwJ6vfk1PzDdE0n3Ba+3hXLSf63YmMgPluxrEuvOpF0=";
  libdispatch = apple "libdispatch" "libdispatch-1542.100.32"
    "sha256-1PHHUzPipwUdzk9uMHweG64J4EU4lixPApV7qwPBpWY=";
  libclosure = apple "libclosure" "libclosure-96"
    "sha256-pvwfcbeEJmTEPdt6/lgVswiabLRG+sMN6VT5FwG7C4Q=";
  copyfile = apple "copyfile" "copyfile-240"
    "sha256-IPwDBOtzdUiS1M4ZlhJ44z8Rv7Ot21QnKGxwUW8UZ8c=";
  removefile = apple "removefile" "removefile-85.100.6"
    "sha256-4E0LsE6b83AqP90tpIhnRdtSekToY7JUWa7lQ3+y3WI=";
  libresolv = apple "libresolv" "libresolv-96"
    "sha256-MAfzoyww1UK0o5TJ7XI4A9vi1T09Nz6Yb9iMrS/wX78=";
  libutil = apple "libutil" "libutil-73"
    "sha256-64+1CIRpYBon7skJRKdaXcxucPh9GrhAbUERhL2PLXA=";
  # libmd.dylib: md5(1) and install(1) digests. Its functions are wrappers
  # over CommonCrypto's.
  libmd = apple "libmd" "libmd-7"
    "sha256-4MLkSWIZusZjKC231V9lTLnkh5l9byGMXYZKkhaSS4c=";
  # Headers only, for <CommonCrypto/CommonDigest.h> (libmd, md5, install,
  # sort). Not this train: the last release there is, years older, and
  # CommonCrypto is closed source since (libcommonCrypto, absent-members.nix).
  # The digest API it declares has not changed. Nothing is compiled from it.
  CommonCrypto = apple "CommonCrypto" "CommonCrypto-600035"
    "sha256-+qAwL6+s7di9cX/qXtapLkjCFoDuZaSYltRJEG4qekM=";

  # The root store; only its certificate files are used, for /etc/ssl/cert.pem.
  security_certificates = apple "security_certificates" "security_certificates-55349.120.10"
    "sha256-i+CRO4xidBMy3rXbe1wNTQSDOWNa0vJhDl76i3emCh8=";

  cctools = apple "cctools" "cctools-1035.1.102"
    "sha256-/2yIOHOxmgtwkaE/XOf5jk+iO3B4gnxXq8V/+qb+Wwg=";

  dyld = apple "dyld" "dyld-1378"
    "sha256-1Q+FQmTIz6fU8BdyA6qF75mvTKfIe2bsysVK7762+D0=";

  sudo = apple "sudo" "sudo-114.100.11"
    "sha256-nwHzNeb2psd8JHO+sicIu3Gh8xivVE2NOCQJZwcDFig=";
  # Headers only: Apple's last released OpenPAM/OpenBSM sources, outside
  # the macOS 26 train. Authentication and audit implementations are absent.
  OpenPAM = apple "OpenPAM" "OpenPAM-35"
    "sha256-+z4Z38o0/CJkEdJE2RX/gP5vby9wQ/ERmUBVVAw3NBo=";
  OpenBSM = apple "OpenBSM" "OpenBSM-21"
    "sha256-WnlcTUvVgxNuxfW56J0zq7PAxuUIC8TQcAkWrQBWdj0=";

  shell_cmds = apple "shell_cmds" "shell_cmds-329"
    "sha256-mZ8DuxAMrv96gDnIG3nNXY906wNVDmjymOv/t3wDr2Q=";
  file_cmds = apple "file_cmds" "file_cmds-479"
    "sha256-4Ii7dbijMCYq0IyAYXt1wm+9igSqUCtS60hsAm8+dM8=";
  text_cmds = apple "text_cmds" "text_cmds-199"
    "sha256-Z2SKmsmCRX/CnRC9kkgCb8ozK+nit4GYsv1rrEWL3qs=";
  adv_cmds = apple "adv_cmds" "adv_cmds-237"
    "sha256-QSqEchXCBSUo6kpGb1FyCcrZx1RFfUP/9hoNbQK2lF8=";
  system_cmds = apple "system_cmds" "system_cmds-1042.120.1"
    "sha256-hheUl5AkA2OuAH6VsL/q6/qhJb2YCSwi9bC5tTMwEnM=";
  basic_cmds = apple "basic_cmds" "basic_cmds-70"
    "sha256-RQve2GqS9ke9hd8kupRMgoOKalTS229asi5tBGrBmS8=";
  misc_cmds = apple "misc_cmds" "misc_cmds-45"
    "sha256-04uBS16nNrg73Fqh4Obev7nQDjTTlY4f5+pEv3i0FIU=";
  patch_cmds = apple "patch_cmds" "patch_cmds-75"
    "sha256-XoLEVrvu9pfHPalkBQDH0IfzcX8FLkcEBmW03cq2jQY=";
  top = apple "top" "top-144"
    "sha256-F+P7yRQw4qa73JmQrMVgy3lVQRDBrFDy9kkOUJ135ys=";
  # Headers only for top's framework APIs; no host SDK or framework binaries.
  # CF is the last released CoreFoundation source, outside the macOS 26 train.
  CF = apple "CF" "CF-1153.18"
    "sha256-QmRK+rElOswP4XNb4MrFC18dgO8+b8+zMsFVWQLDh74=";
  IOKitUser = apple "IOKitUser" "IOKitUser-100231.120.3"
    "sha256-ILdL0s0MTK7Yo54ulVik4l0XbAXptF4NlElbP7z54CY=";
  IOStorageFamily = apple "IOStorageFamily" "IOStorageFamily-337.100.1"
    "sha256-whybjI8XIaihvo16oLq6xP5pNRPZeG7Jdy5jbyWqG1k=";
  awk = apple "awk" "awk-40"
    "sha256-QqBivftpeKxcEEwQEx+Fkh8H8JAC8E684H2YHWPzx5k=";
  file = apple "file" "file-106"
    "sha256-Je5ezH0g2bu/ccExJyKlOdt0LJn3DqUNnX3MybCm4iI=";
  curl = apple "curl" "curl-160"
    "sha256-fUFOM7WuF2TnmQcdq4H0oOxdg26XvyjzaZq94e511zs=";
  zlib = apple "zlib" "zlib-100"
    "sha256-EAlHKSdWHRbz6F1CjH+jubyEQehSmxE37Ua0iQ4ApcQ=";
  bzip2 = apple "bzip2" "bzip2-47"
    "sha256-5UGwwh407vsimlI0kfXeI6rCk/YOnucF8dUy83IrUnM=";
  # Last Apple release of Info-ZIP's zip and unzip utilities.
  zip = apple "zip" "zip-29"
    "sha256-7luQDz8bbWGUiQlxLQWBX3f6VNDEaXAsLmbgJeQuO3c=";
  libxml2 = apple "libxml2" "libxml2-39.10"
    "sha256-neMF3FibCpQT4qMBNc5tYCSDJgeyjzLx2wxYEVu+CcU=";
  ICU = apple "ICU" "ICU-76133"
    "sha256-P6uipoGzB6CkOD5SghaUIRKJ27F3x5gGx7BnrI0e59g=";
  libxo = fetchFromGitHub {
    owner = "juniper";
    repo = "libxo";
    rev = "2.0.0";
    hash = "sha256-Mtxa+iLSitpcQYDkT8C3gYOKQAsAzgPybhogqVA8DGc=";
  };
  # QuickJS 2026-06-04 release (upstream does not tag releases).
  quickjs = fetchFromGitHub {
    owner = "bellard";
    repo = "quickjs";
    rev = "3d5e064e9dd67c70f7962836505a7fa067bf0a4e";
    hash = "sha256-+EH0TJZHC009ImtLd2NyUyuNlHxNZZz6hN16LXB+cX8=";
  };
  # Apple does not publish its LibreSSL source. Use the portable upstream release.
  libressl = fetchurl {
    url = "https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-4.3.2.tar.gz";
    hash = "sha256-7fAa7iTGXWnmqe/LnUS82mgv+dTzu72V55Th36kIR7U=";
  };
  # Last Apple release of the legacy 0.9.8 libraries; outside the macOS 26 train.
  OpenSSL098 = apple "OpenSSL098" "OpenSSL098-85"
    "sha256-2cq99/hbCuK9vV3MOQQ/XXrPgkoSWBtevhrobLHBEdA=";
  # Last Apple nano release; this project is not part of the macOS 26 source set.
  nano = apple "nano" "nano-12"
    "sha256-mWvLo0OrjkDsAz9MRa3STnW1wWU/xKvg2UFEic2DDks=";
  bash = apple "bash" "bash-144"
    "sha256-NbbE30OAlKS25OeB/kO30Y8UbmaLbuckFMsLoMSsYa8=";
  perl = apple "perl" "perl-175"
    "sha256-q7yj2YUcXXGeqwq2zMh4cvc8AmIKeGUKbOVPdE3WhqM=";
  ksh = apple "ksh" "ksh-42"
    "sha256-pxWn1tQQQbK1opytoVwBVQDIQ2SaLO9a0p/AzBvI/Tc=";
  zsh = apple "zsh" "zsh-118"
    "sha256-4AR+rbsO9pJzFxnzM6xenZp94TboXpFNJVCzppUmsFQ=";
  # libedit.3.dylib (sh's line editing) and the libncurses it links.
  libedit = apple "libedit" "libedit-65"
    "sha256-p1YROiK6YPLLe8klHhcikjVeVWuEW9plghsKJHXj+EM=";
  ncurses = apple "ncurses" "ncurses-79"
    "sha256-Y46SCkdZsc3r7hX1Qq4y5L51RxHR3IkCoAPP6G2mBJs=";
  # Third-party binary fixture, only fetched by installer tests, never a base member.
  midnightCommanderPkg = fetchurl {
    url = "https://darling-misc.s3.eu-central-1.amazonaws.com/mc-4.8.7-0.pkg";
    hash = "sha256-WwR/YCJH3iuc2fTtb0uV+5CDoYpkNUd9rL+sXza/oDA=";
  };

}
