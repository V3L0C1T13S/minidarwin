/*
 * MiniDarwin compatibility implementation: quarantine metadata is not
 * available without Apple's private quarantine framework.
 */
#include "quarantine.h"

const char *qtn_xattr_name = "com.apple.quarantine";

qtn_file_t qtn_file_alloc(void) { return 0; }
int qtn_file_init_with_fd(qtn_file_t file, int fd) { (void)file; (void)fd; return -1; }
int qtn_file_init_with_path(qtn_file_t file, const char *path) { (void)file; (void)path; return -1; }
int qtn_file_init_with_data(qtn_file_t file, const void *data, size_t size) { (void)file; (void)data; (void)size; return -1; }
void qtn_file_free(qtn_file_t file) { (void)file; }
int qtn_file_apply_to_fd(qtn_file_t file, int fd) { (void)file; (void)fd; return -1; }
char *qtn_error(int error) { (void)error; return 0; }
int qtn_file_to_data(qtn_file_t file, char *data, size_t *size) { (void)file; (void)data; (void)size; return -1; }
qtn_file_t qtn_file_clone(qtn_file_t file) { (void)file; return 0; }
uint32_t qtn_file_get_flags(qtn_file_t file) { (void)file; return 0; }
int qtn_file_set_flags(qtn_file_t file, uint32_t flags) { (void)file; (void)flags; return -1; }
