#ifndef NIHOS_APP_SESSION_H
#define NIHOS_APP_SESSION_H
#include <stdint.h>
/* Experimental OS-internal owner ABI, not an app SDK or concurrent API. */
struct nih_app_session_hooks {
    void *context;
    int32_t (*acquire)(void *, uint8_t **, uint32_t *);
    int32_t (*open)(void *);
    int32_t (*render)(void *, uint32_t, uint8_t *, uint32_t);
    int32_t (*present)(void *, const uint8_t *, uint32_t);
    int32_t (*close)(void *);
    int32_t (*release)(void *, uint8_t *, uint32_t);
};
enum { NIH_APP_IDLE, NIH_APP_RUNNING, NIH_APP_STOPPED, NIH_APP_FAILED };
struct nih_app_session {
    struct nih_app_session_hooks hooks;
    uint8_t *storage;
    uint32_t capacity, state, selected, frames;
    int32_t last_error;
    uint32_t busy, opened;
};
int32_t nih_app_session_start(struct nih_app_session *);
int32_t nih_app_session_input(struct nih_app_session *, uint32_t byte);
int32_t nih_app_session_cancel(struct nih_app_session *);
int32_t nih_app_present_copy(uint8_t *, uint32_t, const uint8_t *, uint32_t);
#endif
