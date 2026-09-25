# Pinned Apple releases (content-addressed). All from macOS 26 release (xnu-12377); don't mix.
{ fetchFromGitHub }:

let
  apple = repo: rev: hash:
    fetchFromGitHub {
      owner = "apple-oss-distributions";
      inherit repo rev hash;
      name = "${repo}-src";
    };
in
{
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

  cctools = apple "cctools" "cctools-1035.1.102"
    "sha256-/2yIOHOxmgtwkaE/XOf5jk+iO3B4gnxXq8V/+qb+Wwg=";

  dyld = apple "dyld" "dyld-1378"
    "sha256-1Q+FQmTIz6fU8BdyA6qF75mvTKfIe2bsysVK7762+D0=";

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
  awk = apple "awk" "awk-40"
    "sha256-QqBivftpeKxcEEwQEx+Fkh8H8JAC8E684H2YHWPzx5k=";
  file = apple "file" "file-106"
    "sha256-Je5ezH0g2bu/ccExJyKlOdt0LJn3DqUNnX3MybCm4iI=";
  curl = apple "curl" "curl-160"
    "sha256-fUFOM7WuF2TnmQcdq4H0oOxdg26XvyjzaZq94e511zs=";
  # Last Apple nano release; this project is not part of the macOS 26 source set.
  nano = apple "nano" "nano-12"
    "sha256-mWvLo0OrjkDsAz9MRa3STnW1wWU/xKvg2UFEic2DDks=";
  bash = apple "bash" "bash-144"
    "sha256-NbbE30OAlKS25OeB/kO30Y8UbmaLbuckFMsLoMSsYa8=";
  ksh = apple "ksh" "ksh-42"
    "sha256-pxWn1tQQQbK1opytoVwBVQDIQ2SaLO9a0p/AzBvI/Tc=";
  zsh = apple "zsh" "zsh-118"
    "sha256-4AR+rbsO9pJzFxnzM6xenZp94TboXpFNJVCzppUmsFQ=";
  # libedit.3.dylib (sh's line editing) and the libncurses it links.
  libedit = apple "libedit" "libedit-65"
    "sha256-p1YROiK6YPLLe8klHhcikjVeVWuEW9plghsKJHXj+EM=";
  ncurses = apple "ncurses" "ncurses-79"
    "sha256-Y46SCkdZsc3r7hX1Qq4y5L51RxHR3IkCoAPP6G2mBJs=";
}
