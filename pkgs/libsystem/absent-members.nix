# requiredlibs entries not produced, with reason. Filtered in umbrella-link.nix and checked in libsystem-umbrella.nix.
# system_m reason differs by targetArch (Libm Intel complete, arm64 empty).
{ targetArch }:

{
  # Never released by Apple.
  xpc = "closed source";
  corecrypto = "closed source";
  commonCrypto = "closed source";
  cache = "closed source";
  system_asl = "closed source";
  system_trace = "closed source";
  system_sandbox = "closed source";
  system_coreservices = "closed source";
  system_configuration = "closed source";
  system_dnssd = "closed source";
  # Released but not buildable: Libm arm64 files are zero-byte; others need closed deps (opendirectory/xpc/etc.).
  system_m =
    if targetArch == "aarch64"
    then "Libm-2026 has no arm64"
    else "Libm-2026 Intel sources not built yet";
  system_info = "Libinfo needs opendirectory and xpc";
  system_notify = "libnotify needs xpc and bootstrap";
  system_darwin = "libdarwin needs xpc and bootstrap";
  dispatch = "libdispatch needs the work_interval instance API";
  copyfile = "copyfile needs xpc and quarantine";
  removefile = "not built yet";
  # Later stages.
  dyld = "stage 5";
}
