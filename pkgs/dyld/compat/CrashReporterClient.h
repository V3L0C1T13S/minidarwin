/* CrashReporterClient.h - shim. Real header ships with internal-SDK-only
 * libCrashReporterClient.a; dyld treats it as optional. No-ops here.
 * Must stay out of SDK - libplatform __has_include would expect gCRAnnotations. */
#ifndef _CRASHREPORTERCLIENT_H
#define _CRASHREPORTERCLIENT_H

#define CRSetCrashLogMessage(m)  ((void)(m))
#define CRSetCrashLogMessage2(m) ((void)(m))
#define CRGetCrashLogMessage()   ((const char *)0)

#endif /* _CRASHREPORTERCLIENT_H */
