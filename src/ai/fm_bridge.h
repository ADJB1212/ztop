#ifndef FM_BRIDGE_H
#define FM_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*fm_stream_callback)(const char *chunk, void *context);

int fm_is_available(void);
char *fm_generate_text(const char *prompt);
char *fm_generate_diagnosis(const char *prompt);
int fm_stream_text(const char *prompt, fm_stream_callback callback, void *context);
void fm_free_string(char *ptr);

#ifdef __cplusplus
}
#endif

#endif
