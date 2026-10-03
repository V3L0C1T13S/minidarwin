#ifndef INSTALLER_JS_H
#define INSTALLER_JS_H

#include "mdpkg.h"
#include <quickjs.h>

typedef struct {
  JSRuntime *runtime;
  JSContext *context;
  JSValue global, target, result, choices;
  char *root;
  int live;
  struct timespec deadline;
} InstallerJS;

InstallerJS *installer_js_new(const char *root, int live);
void installer_js_free(InstallerJS *js);
void installer_js_compile(InstallerJS *js, const char *source,
                          const char *label, int expression);
JSValue installer_js_eval(InstallerJS *js, const char *source,
                          const char *label, int expression);
int installer_js_boolean(InstallerJS *js, const char *source, const char *label);
void installer_js_my(InstallerJS *js, JSValueConst choice);
void installer_js_check(InstallerJS *js, xmlNode *node);
void installer_js_require(InstallerJS *js, JSValueConst value, const char *label);
JSValue js_plist_read(JSContext *ctx, const char *path);

#endif
