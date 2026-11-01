#ifndef NIHOS_NET_TERMINAL_H
#define NIHOS_NET_TERMINAL_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NIH_TERM_MAX_TITLE      48
#define NIH_TS_MAX_PEERS        64

/* Terminal cell attributes for 1280x720 MIPI-DSI rendering */
typedef struct {
    uint32_t codepoint;     /* Unicode UTF-32 / ASCII */
    uint16_t fg_rgb565;     /* Foreground color in RGB565 */
    uint16_t bg_rgb565;     /* Background color in RGB565 */
    uint8_t  flags;         /* bit0: bold, bit1: underline, bit2: reverse */
} nih_term_cell_t;

/* Snapshot of terminal grid state */
typedef struct {
    uint16_t cols;
    uint16_t rows;
    uint16_t cursor_col;
    uint16_t cursor_row;
    bool     cursor_visible;
    const nih_term_cell_t *cells; /* Pointer to contiguous cols * rows array */
} nih_term_view_t;

/* Tailscale client state */
typedef enum {
    NIH_TS_STOPPED = 0,
    NIH_TS_CONNECTING,
    NIH_TS_NEEDS_LOGIN,
    NIH_TS_RUNNING,
    NIH_TS_ERROR,
} nih_ts_state_t;

typedef struct {
    char     hostname[48];
    uint8_t  ip[4];
    bool     online;
} nih_ts_peer_t;

typedef struct {
    nih_ts_state_t state;
    uint8_t        my_ip[4];
    char           hostname[32];
    char           auth_url[160];
    int            peer_count;
    nih_ts_peer_t  peers[NIH_TS_MAX_PEERS];
} nih_ts_status_t;

/* =========================================================================
 * Tailscale Subsystem API
 * ========================================================================= */
bool nih_tailscale_init(void);
bool nih_tailscale_up(const char *auth_key);
void nih_tailscale_down(void);
void nih_tailscale_get_status(nih_ts_status_t *out);
bool nih_tailscale_resolve(const char *hostname, uint8_t out_ip[4]);

/* =========================================================================
 * SSH Terminal Session API
 * ========================================================================= */
typedef struct nih_ssh_session nih_ssh_session_t;

typedef void (*nih_term_dirty_cb_t)(void *user_ctx);

nih_ssh_session_t *nih_ssh_create(uint16_t cols, uint16_t rows, nih_term_dirty_cb_t cb, void *user_ctx);
bool nih_ssh_connect(nih_ssh_session_t *s, const char *host, uint16_t port, const char *user, const char *pass);
void nih_ssh_disconnect(nih_ssh_session_t *s);
void nih_ssh_destroy(nih_ssh_session_t *s);

/* Terminal input/output and driving operations */
void nih_ssh_send_input(nih_ssh_session_t *s, const uint8_t *bytes, size_t len);
void nih_ssh_resize(nih_ssh_session_t *s, uint16_t cols, uint16_t rows);
void nih_ssh_poll(nih_ssh_session_t *s); /* Non-blocking event loop / packet tick */
void nih_ssh_get_view(nih_ssh_session_t *s, nih_term_view_t *out_view);

#ifdef __cplusplus
}
#endif

#endif /* NIHOS_NET_TERMINAL_H */
