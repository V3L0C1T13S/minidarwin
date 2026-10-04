/* SPDX-License-Identifier: MIT
 * libsystem_notify without notifyd. libnotify's client needs xpc, bootstrap
 * and os_variant, none of which are released, and MiniDarwin runs no notifyd.
 * Every call reports the server as not found, which is what a client sees
 * when notifyd is absent; callers (Libc's time zone and Libinfo's caches)
 * then revalidate on each use instead of waiting for a notification.
 */
#include <stdbool.h>
#include <stdint.h>
#include <unistd.h>
#include <mach/mach.h>
#include <dispatch/dispatch.h>
#include <notify.h>
#include <notify_private.h>

#define UNAVAILABLE NOTIFY_STATUS_SERVER_NOT_FOUND

static uint32_t no_token(int *out_token) {
    if (out_token) *out_token = -1;
    return UNAVAILABLE;
}

uint32_t notify_post(const char *name) { (void)name; return UNAVAILABLE; }
uint32_t notify_simple_post(const char *name) { (void)name; return UNAVAILABLE; }
uint32_t notify_register_check(const char *name, int *out_token) {
    (void)name; return no_token(out_token);
}
uint32_t notify_register_plain(const char *name, int *out_token) {
    (void)name; return no_token(out_token);
}
uint32_t notify_register_dispatch(const char *name, int *out_token,
                                  dispatch_queue_t queue, notify_handler_t handler) {
    (void)name; (void)queue; (void)handler; return no_token(out_token);
}
uint32_t notify_register_signal(const char *name, int sig, int *out_token) {
    (void)name; (void)sig; return no_token(out_token);
}
uint32_t notify_register_mach_port(const char *name, mach_port_t *notify_port,
                                   int flags, int *out_token) {
    (void)name; (void)notify_port; (void)flags; return no_token(out_token);
}
uint32_t notify_register_file_descriptor(const char *name, int *notify_fd,
                                         int flags, int *out_token) {
    (void)name; (void)notify_fd; (void)flags; return no_token(out_token);
}
uint32_t notify_check(int token, int *check) { (void)token; (void)check; return UNAVAILABLE; }
uint32_t notify_peek(int token, uint32_t *val) { (void)token; (void)val; return UNAVAILABLE; }
uint32_t notify_cancel(int token) { (void)token; return UNAVAILABLE; }
uint32_t notify_suspend(int token) { (void)token; return UNAVAILABLE; }
uint32_t notify_resume(int token) { (void)token; return UNAVAILABLE; }
uint32_t notify_suspend_pid(pid_t pid) { (void)pid; return UNAVAILABLE; }
uint32_t notify_resume_pid(pid_t pid) { (void)pid; return UNAVAILABLE; }
uint32_t notify_set_state(int token, uint64_t state64) { (void)token; (void)state64; return UNAVAILABLE; }
uint32_t notify_get_state(int token, uint64_t *state64) { (void)token; (void)state64; return UNAVAILABLE; }
uint32_t notify_monitor_file(int token, char *path, int flags) {
    (void)token; (void)path; (void)flags; return UNAVAILABLE;
}
uint32_t notify_get_event(int token, int *ev, char *buf, int *len) {
    (void)token; (void)ev; (void)buf; (void)len; return UNAVAILABLE;
}
bool notify_is_valid_token(int val) { (void)val; return false; }
