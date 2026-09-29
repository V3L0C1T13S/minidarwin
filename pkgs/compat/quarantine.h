/*
 * Minimal private quarantine API declarations for copyfile.
 * MiniDarwin does not include Apple's private quarantine framework.
 */
#pragma once

#include <stddef.h>
#include <stdint.h>

typedef struct _qtn_file *qtn_file_t;

#define QTN_SERIALIZED_DATA_MAX 4096
#define QTN_FLAG_DO_NOT_TRANSLOCATE 0x00000001

extern const char *qtn_xattr_name;

qtn_file_t qtn_file_alloc(void);
int qtn_file_init_with_fd(qtn_file_t, int);
int qtn_file_init_with_path(qtn_file_t, const char *);
int qtn_file_init_with_data(qtn_file_t, const void *, size_t);
void qtn_file_free(qtn_file_t);
int qtn_file_apply_to_fd(qtn_file_t, int);
int qtn_file_apply_to_path(qtn_file_t, const char *);
char *qtn_error(int);
int qtn_file_to_data(qtn_file_t, char *, size_t *);
qtn_file_t qtn_file_clone(qtn_file_t);
uint32_t qtn_file_get_flags(qtn_file_t);
int qtn_file_set_flags(qtn_file_t, uint32_t);
