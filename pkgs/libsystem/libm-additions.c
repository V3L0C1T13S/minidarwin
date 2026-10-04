/* SPDX-License-Identifier: MIT
 * Entry points that compilers began emitting (macOS 10.9) after the last
 * Libm source release: pow(10, x) becomes __exp10(x), and a sin/cos pair of
 * one argument becomes __sincos_stret. Defined through Libm's own functions;
 * the struct returns follow the x86_64 ABI (xmm0/xmm1, or packed in xmm0).
 */
#include <math.h>

struct __float2 { float __sinval; float __cosval; };
struct __double2 { double __sinval; double __cosval; };

double __exp10(double x) { return pow(10.0, x); }
float __exp10f(float x) { return powf(10.0f, x); }

struct __double2 __sincos_stret(double x) {
    return (struct __double2){ sin(x), cos(x) };
}
struct __float2 __sincosf_stret(float x) {
    return (struct __float2){ sinf(x), cosf(x) };
}
