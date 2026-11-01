/* Test-only adapter for driving the experimental TCP client through libslirp. */
#define main tcp_slirp_unused_echo_main
#include "tcp_slirp_probe.c"
#undef main

static struct context bridge_ctx;
static Slirp *bridge_slirp;
static bool bridge_failed;
static SlirpCb bridge_callbacks;

bool bridge_open(uint16_t port) {
    epoch_ns = clock_ns();
    memset(&bridge_ctx, 0, sizeof(bridge_ctx));
    bridge_callbacks=(SlirpCb){.send_packet=output,.guest_error=guest_error,.clock_get_ns=slirp_clock,.timer_new=timer_new,.timer_free=timer_free,.timer_mod=timer_mod,.register_poll_fd=register_fd,.unregister_poll_fd=unregister_fd,.notify=notify};
    SlirpConfig cfg={0}; cfg.version=1; cfg.in_enabled=true;
    inet_pton(AF_INET,"10.0.2.0",&cfg.vnetwork); inet_pton(AF_INET,"255.255.255.0",&cfg.vnetmask);
    inet_pton(AF_INET,"10.0.2.2",&cfg.vhost); inet_pton(AF_INET,"10.0.2.15",&cfg.vdhcp_start); inet_pton(AF_INET,"10.0.2.3",&cfg.vnameserver);
    bridge_slirp=slirp_new(&cfg,&bridge_callbacks,&bridge_ctx);
    if (!bridge_slirp || !tcp_probe_begin(port)) return false;
    arp_request(bridge_slirp);
    return true;
}
bool bridge_poll(void) {
    if (!bridge_slirp || bridge_failed) return false;
    uint8_t ip[1600], frame[1614]; uint64_t now=elapsed();
    size_t n=tcp_probe_next(now,ip,sizeof(ip));
    if (n) {
        memcpy(frame,gateway_mac,6); memcpy(frame+6,guest_mac,6); frame[12]=0x08; frame[13]=0x00; memcpy(frame+14,ip,n);
        if (!tcp_probe_sent(now)) return false;
        slirp_input(bridge_slirp,frame,(int)(n+14));
    }
    bridge_ctx.nfds=0; uint32_t timeout=0;
    slirp_pollfds_fill_socket(bridge_slirp,&timeout,add_fd,&bridge_ctx);
    int rc=poll(bridge_ctx.fds,bridge_ctx.nfds,0);
    slirp_pollfds_poll(bridge_slirp,rc<0,revents,&bridge_ctx);
    while (bridge_ctx.count) {
        struct frame f=bridge_ctx.frames[0]; memmove(bridge_ctx.frames,bridge_ctx.frames+1,(--bridge_ctx.count)*sizeof(bridge_ctx.frames[0]));
        if (f.len>=42 && f.data[12]==8 && f.data[13]==6 && f.data[21]==1 && !memcmp(f.data+38,(uint8_t[]){10,0,2,15},4)) { arp_reply(bridge_slirp,f.data); continue; }
        if (f.len >= 54 && f.data[12]==8 && f.data[13]==0 && f.data[23]==6 && !tcp_probe_receive(f.data+14,f.len-14,elapsed())) bridge_failed=true;
    }
    return !bridge_failed && !bridge_ctx.overflow;
}
bool bridge_ready(void) { return tcp_probe_ready(); }
ssize_t bridge_read(uint8_t *out, size_t cap) { return tcp_probe_read(out,cap); }
ssize_t bridge_write(const uint8_t *data, size_t len) {
    size_t n=tcp_probe_write(data,len,elapsed()); return n ? (ssize_t)n : -1;
}
bool bridge_close_write(void) { return tcp_probe_close(elapsed()); }
bool bridge_closed(void) { return tcp_probe_closed(elapsed()); }
void bridge_destroy(void) { if (bridge_slirp) slirp_cleanup(bridge_slirp); bridge_slirp=NULL; }
