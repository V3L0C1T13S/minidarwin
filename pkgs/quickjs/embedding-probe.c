#include <string.h>
#include <quickjs.h>

/* Exercise the API an installer can use without exposing std/os modules. */
int main(void)
{
    const char script[] =
        "var choices = { app: { selected: true } };"
        "function installationCheck() {"
        "  return choices.app.selected && /darwin/i.test('Darwin');"
        "}"
        "installationCheck() ? JSON.stringify({ answer: 6 * 7 }) : 'failed';";
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) return 1;
    JS_SetMemoryLimit(rt, 16 * 1024 * 1024);
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) {
        JS_FreeRuntime(rt);
        return 1;
    }

    JSValue result = JS_Eval(ctx, script, sizeof(script) - 1,
                             "distribution.js", JS_EVAL_TYPE_GLOBAL);
    const char *text = JS_IsException(result) ? NULL : JS_ToCString(ctx, result);
    int ok = text && strcmp(text, "{\"answer\":42}") == 0;
    if (text) JS_FreeCString(ctx, text);
    JS_FreeValue(ctx, result);

    const char invalid[] = "throw new Error('installer check failed');";
    result = JS_Eval(ctx, invalid, sizeof(invalid) - 1,
                     "invalid.js", JS_EVAL_TYPE_GLOBAL);
    ok = ok && JS_IsException(result);
    JS_FreeValue(ctx, result);
    result = JS_GetException(ctx);
    JS_FreeValue(ctx, result);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return !ok;
}
