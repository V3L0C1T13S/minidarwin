/* Not Apple's. libffi's ffi.h marks its API `iosmac(...)`, Apple's internal
 * spelling of macCatalyst; the public AvailabilityInternal.h this SDK is built
 * from has only `macCatalyst`. Force-included for libffi's own compile -- the
 * SDK is untouched, so (as for any Apple header using `iosmac`) a consumer of
 * the installed ffi.h needs the same two lines. */
#ifndef __API_AVAILABLE_PLATFORM_iosmac
  #define __API_AVAILABLE_PLATFORM_iosmac(x) macCatalyst,introduced=x
  #define __API_DEPRECATED_PLATFORM_iosmac(x,y) macCatalyst,introduced=x,deprecated=y
  #define __API_OBSOLETED_PLATFORM_iosmac(x,y,z) macCatalyst,introduced=x,deprecated=y,obsoleted=z
  #define __API_UNAVAILABLE_PLATFORM_iosmac macCatalyst,unavailable
#endif
