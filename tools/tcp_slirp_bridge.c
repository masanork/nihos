/* Test-only adapter for driving the experimental TCP client through libslirp. */
#define main tcp_slirp_unused_echo_main
#include "tcp_slirp_probe.c"
#undef main

static struct context bridge_ctx;
static Slirp *bridge_slirp;
static bool bridge_failed;
static SlirpCb bridge_callbacks;
extern bool tcp_link_begin(uint16_t);
extern size_t tcp_link_next(uint64_t, uint8_t *, size_t);
extern bool tcp_link_sent(uint64_t);
extern bool tcp_link_receive(const uint8_t *, size_t, uint64_t);
extern bool tcp_link_ready(void);
extern ssize_t tcp_link_write(const uint8_t *, size_t, uint64_t);
extern ssize_t tcp_link_read(uint8_t *, size_t);
extern bool tcp_link_close(uint64_t);
extern bool tcp_link_closed(uint64_t);

bool bridge_open(uint16_t port) {
    epoch_ns = clock_ns();
    memset(&bridge_ctx, 0, sizeof(bridge_ctx));
    bridge_callbacks=(SlirpCb){.send_packet=output,.guest_error=guest_error,.clock_get_ns=slirp_clock,.timer_new=timer_new,.timer_free=timer_free,.timer_mod=timer_mod,.register_poll_fd=register_fd,.unregister_poll_fd=unregister_fd,.notify=notify};
    SlirpConfig cfg={0}; cfg.version=1; cfg.in_enabled=true;
    inet_pton(AF_INET,"10.0.2.0",&cfg.vnetwork); inet_pton(AF_INET,"255.255.255.0",&cfg.vnetmask);
    inet_pton(AF_INET,"10.0.2.2",&cfg.vhost); inet_pton(AF_INET,"10.0.2.15",&cfg.vdhcp_start); inet_pton(AF_INET,"10.0.2.3",&cfg.vnameserver);
    bridge_slirp=slirp_new(&cfg,&bridge_callbacks,&bridge_ctx);
    if (!bridge_slirp || !tcp_link_begin(port)) return false;
    return true;
}
bool bridge_poll(void) {
    if (!bridge_slirp || bridge_failed) return false;
    uint8_t frame[1614]; uint64_t now=elapsed();
    size_t n=tcp_link_next(now,frame,sizeof(frame));
    if (n) {
        if (!tcp_link_sent(now)) return false;
        slirp_input(bridge_slirp,frame,(int)n);
    }
    bridge_ctx.nfds=0; uint32_t timeout=0;
    slirp_pollfds_fill(bridge_slirp,&timeout,add_fd,&bridge_ctx);
    int rc=poll(bridge_ctx.fds,bridge_ctx.nfds,0);
    slirp_pollfds_poll(bridge_slirp,rc<0,revents,&bridge_ctx);
    while (bridge_ctx.count) {
        struct frame f=bridge_ctx.frames[0]; memmove(bridge_ctx.frames,bridge_ctx.frames+1,(--bridge_ctx.count)*sizeof(bridge_ctx.frames[0]));
        if (f.len>=42 && f.data[12]==8 && f.data[13]==6 && f.data[21]==1 && !memcmp(f.data+38,(uint8_t[]){10,0,2,15},4)) { arp_reply(bridge_slirp,f.data); continue; }
        if (f.len >= 42 && !tcp_link_receive(f.data,f.len,elapsed())) bridge_failed=true;
    }
    return !bridge_failed && !bridge_ctx.overflow;
}
bool bridge_ready(void) { return tcp_link_ready(); }
ssize_t bridge_read(uint8_t *out, size_t cap) { return tcp_link_read(out,cap); }
ssize_t bridge_write(const uint8_t *data, size_t len) {
    return tcp_link_write(data,len,elapsed());
}
bool bridge_close_write(void) { return tcp_link_close(elapsed()); }
bool bridge_closed(void) { return tcp_link_closed(elapsed()); }
void bridge_destroy(void) { if (bridge_slirp) slirp_cleanup(bridge_slirp); bridge_slirp=NULL; }
