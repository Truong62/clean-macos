#ifndef MACKIT_CORE_H
#define MACKIT_CORE_H

#include <stdbool.h>
#include <stdint.h>

bool mk_dir_size(const char *path, uint64_t timeout_ms, uint32_t max_depth, uint64_t *out_bytes);
char *mk_large_files_json(const char *root, uint64_t min_bytes, int64_t older_than, uint32_t limit, uint64_t timeout_ms, const char *excluded_dir);
void mk_string_free(char *text);

#endif
