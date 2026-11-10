#ifndef MACKIT_CORE_H
#define MACKIT_CORE_H

#include <stdbool.h>
#include <stdint.h>

bool mk_dir_size(const char *path, uint64_t timeout_ms, uint32_t max_depth, uint64_t *out_bytes);
char *mk_large_files_json(const char *root, uint64_t min_bytes, int64_t older_than, uint32_t limit, uint64_t timeout_ms, const char *excluded_dir);
void mk_string_free(char *text);

typedef struct MKTypingEngine MKTypingEngine;
MKTypingEngine *mk_typing_new(void);
void mk_typing_free(MKTypingEngine *engine);
void mk_typing_configure(MKTypingEngine *engine, uint32_t flags);
char *mk_typing_restore(MKTypingEngine *engine, uint32_t *out_backspaces);
void mk_typing_set_macros(MKTypingEngine *engine, const char *lines);
char *mk_typing_key(MKTypingEngine *engine, uint32_t ch, uint32_t *out_backspaces);
char *mk_typing_finish(MKTypingEngine *engine, uint32_t separator, uint32_t *out_backspaces);
void mk_typing_backspace(MKTypingEngine *engine);
void mk_typing_reset(MKTypingEngine *engine);

bool mk_calc(const char *input, double *out_value, uint32_t *out_closed);
char *mk_convert(const char *input);
char *mk_rank(const char *query, const char *rows);
char *mk_ai_usage(const char *request);

#endif
