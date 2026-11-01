/* Host-only interoperability fixture; links against external BSD libslirp. */
#include <arpa/inet.h>
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <slirp/libslirp.h>

extern bool tcp_probe_begin(uint16_t);
extern size_t tcp_probe_next(uint64_t, uint8_t *, size_t);
extern bool tcp_probe_sent(uint64_t);
extern bool tcp_probe_receive(const uint8_t *, size_t, uint64_t);
extern bool tcp_probe_ready(void);
extern size_t tcp_probe_write(const uint8_t *, size_t, uint64_t);
extern ssize_t tcp_probe_read(uint8_t *, size_t);
extern bool tcp_probe_close(uint64_t);
extern bool tcp_probe_closed(uint64_t);

static uint64_t epoch_ns;
static uint64_t clock_ns(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec; }
static uint64_t elapsed(void) { return (clock_ns() - epoch_ns) / 1000000; }
static int64_t slirp_clock(void *opaque) { (void)opaque; return (int64_t)clock_ns(); }
static void guest_error(const char *s, void *opaque) { (void)opaque; fprintf(stderr, "slirp: %s\n", s); }
static void notify(void *opaque) { (void)opaque; }
static void register_fd(int fd, void *opaque) { (void)fd; (void)opaque; }
static void unregister_fd(int fd, void *opaque) { (void)fd; (void)opaque; }
static void *timer_new(SlirpTimerCb cb, void *arg, void *opaque) { (void)cb; (void)arg; (void)opaque; return NULL; }
static void timer_free(void *timer, void *opaque) { (void)timer; (void)opaque; }
static void timer_mod(void *timer, int64_t when, void *opaque) { (void)timer; (void)when; (void)opaque; }

struct frame { size_t len; uint8_t data[2048]; };
struct context { struct frame frames[64]; unsigned count; struct pollfd fds[128]; unsigned nfds; bool overflow; };
static ssize_t output(const void *data, size_t len, void *opaque) {
    struct context *ctx = opaque;
    if (ctx->count == 64 || len > sizeof(ctx->frames[0].data)) { ctx->overflow = true; return -1; }
    struct frame *f = &ctx->frames[ctx->count++]; f->len = len; memcpy(f->data, data, len); return (ssize_t)len;
}
static int add_fd(int fd, int events, void *opaque) {
    struct context *ctx = opaque;
    if (ctx->nfds == 128) { ctx->overflow = true; return -1; }
    unsigned i = ctx->nfds++; ctx->fds[i] = (struct pollfd){ .fd = fd };
    if (events & SLIRP_POLL_IN) ctx->fds[i].events |= POLLIN;
    if (events & SLIRP_POLL_OUT) ctx->fds[i].events |= POLLOUT;
    if (events & SLIRP_POLL_PRI) ctx->fds[i].events |= POLLPRI;
    return (int)i;
}
static int revents(int idx, void *opaque) {
    struct context *ctx = opaque; short e = ctx->fds[idx].revents; int r = 0;
    if (e & POLLIN) r |= SLIRP_POLL_IN;
    if (e & POLLOUT) r |= SLIRP_POLL_OUT;
    if (e & POLLPRI) r |= SLIRP_POLL_PRI;
    if (e & POLLERR) r |= SLIRP_POLL_ERR;
    if (e & POLLHUP) r |= SLIRP_POLL_HUP;
    return r;
}
static const uint8_t guest_mac[6] = {0x52,0x54,0x00,0x12,0x34,0x56};
static const uint8_t gateway_mac[6] = {0x52,0x55,0x0a,0x00,0x02,0x02};
static void arp_request(Slirp *slirp) {
    uint8_t f[42] = {0}; memset(f, 0xff, 6); memcpy(f+6, guest_mac, 6);
    f[12]=0x08; f[13]=0x06; f[15]=1; f[16]=0x08; f[18]=6; f[19]=4; f[21]=1;
    memcpy(f+22, guest_mac, 6); const uint8_t ip[4]={10,0,2,15}, target[4]={10,0,2,2};
    memcpy(f+28, ip, 4); memcpy(f+38, target, 4); slirp_input(slirp, f, sizeof(f));
}
static void arp_reply(Slirp *slirp, const uint8_t *request) {
    uint8_t f[42] = {0}; memcpy(f, request+6, 6); memcpy(f+6, guest_mac, 6);
    f[12]=0x08; f[13]=0x06; f[15]=1; f[16]=0x08; f[18]=6; f[19]=4; f[21]=2;
    memcpy(f+22, guest_mac, 6); memcpy(f+28, request+38, 4);
    memcpy(f+32, request+22, 6); memcpy(f+38, request+28, 4); slirp_input(slirp, f, sizeof(f));
}
int main(void) {
    int listener = socket(AF_INET, SOCK_STREAM, 0); if (listener < 0) return 1;
    struct sockaddr_in addr = { .sin_family=AF_INET, .sin_addr.s_addr=htonl(INADDR_LOOPBACK), .sin_port=0 };
    if (bind(listener, (void *)&addr, sizeof(addr)) || listen(listener, 1)) return 2;
    socklen_t alen=sizeof(addr); if (getsockname(listener, (void *)&addr, &alen)) return 3;
    pid_t child=fork(); if (child < 0) return 4;
    if (child == 0) {
        int client=accept(listener,NULL,NULL); if (client < 0) _exit(1);
        char b[128]; ssize_t n=read(client,b,sizeof(b));
        if (n <= 0 || write(client,b,(size_t)n) != n) _exit(2);
        shutdown(client,SHUT_WR); while (read(client,b,sizeof(b)) > 0) {}
        close(client); _exit(0);
    }
    close(listener); epoch_ns=clock_ns();
    struct context ctx={0};
    SlirpCb cb={.send_packet=output,.guest_error=guest_error,.clock_get_ns=slirp_clock,.timer_new=timer_new,.timer_free=timer_free,.timer_mod=timer_mod,.register_poll_fd=register_fd,.unregister_poll_fd=unregister_fd,.notify=notify};
    SlirpConfig cfg={0}; cfg.version=1; cfg.in_enabled=true;
    inet_pton(AF_INET,"10.0.2.0",&cfg.vnetwork); inet_pton(AF_INET,"255.255.255.0",&cfg.vnetmask);
    inet_pton(AF_INET,"10.0.2.2",&cfg.vhost); inet_pton(AF_INET,"10.0.2.15",&cfg.vdhcp_start); inet_pton(AF_INET,"10.0.2.3",&cfg.vnameserver);
    Slirp *slirp=slirp_new(&cfg,&cb,&ctx);
    if (!slirp || !tcp_probe_begin(ntohs(addr.sin_port))) {
        if (slirp) slirp_cleanup(slirp);
        kill(child,SIGTERM); waitpid(child,NULL,0); return 5;
    }
    arp_request(slirp);
    bool wrote=false, closing=false, dropped_syn=false, dropped_data=false, ok=false; size_t got=0;
    const char message[]="nihos tcp slirp echo"; uint8_t received[128];
    while (elapsed() < 35000 && !ctx.overflow) {
        uint64_t now=elapsed(); uint8_t ip[1600], frame[1614];
        size_t n=tcp_probe_next(now,ip,sizeof(ip));
        if (n) {
            if (getenv("TCP_PROBE_TRACE")) fprintf(stderr,"%llu TX flags=%02x seq=%02x%02x%02x%02x ack=%02x%02x%02x%02x len=%zu\n",(unsigned long long)now,ip[33],ip[24],ip[25],ip[26],ip[27],ip[28],ip[29],ip[30],ip[31],n);
            memcpy(frame,gateway_mac,6); memcpy(frame+6,guest_mac,6); frame[12]=0x08; frame[13]=0x00; memcpy(frame+14,ip,n);
            if (!tcp_probe_sent(now)) break;
            slirp_input(slirp,frame,(int)(n+14));
        }
        if (tcp_probe_ready() && !wrote) { wrote=tcp_probe_write((const uint8_t *)message,sizeof(message)-1,now)==sizeof(message)-1; }
        if (wrote && got < sizeof(message)-1) {
            ssize_t r=tcp_probe_read(received+got,sizeof(received)-got); if (r > 0) got+=(size_t)r;
        }
        if (got==sizeof(message)-1 && !closing) {
            if (memcmp(received,message,got)) break;
            closing=tcp_probe_close(now); if (!closing) break;
        }
        if (closing && tcp_probe_closed(now)) { ok=true; break; }
        ctx.nfds=0; uint32_t timeout=10; slirp_pollfds_fill(slirp,&timeout,add_fd,&ctx);
        int rc=poll(ctx.fds,ctx.nfds,(int)timeout); slirp_pollfds_poll(slirp,rc<0,revents,&ctx);
        while (ctx.count) {
            struct frame f=ctx.frames[0]; memmove(ctx.frames,ctx.frames+1,(--ctx.count)*sizeof(ctx.frames[0]));
            if (f.len>=42 && f.data[12]==8 && f.data[13]==6 && f.data[21]==1 && !memcmp(f.data+38,(uint8_t[]){10,0,2,15},4)) { arp_reply(slirp,f.data); continue; }
            if (f.len < 54 || f.data[12]!=8 || f.data[13]!=0 || f.data[23]!=6) continue;
            size_t ihl=(f.data[14]&15)*4, tcpoff=14+ihl;
            if (tcpoff+20>f.len) continue;
            uint8_t flags=f.data[tcpoff+13]; size_t hlen=(f.data[tcpoff+12]>>4)*4;
            size_t total=((size_t)f.data[16]<<8)|f.data[17];
            if (getenv("TCP_PROBE_TRACE")) fprintf(stderr,"%llu RX flags=%02x seq=%02x%02x%02x%02x ack=%02x%02x%02x%02x len=%zu\n",(unsigned long long)elapsed(),flags,f.data[tcpoff+4],f.data[tcpoff+5],f.data[tcpoff+6],f.data[tcpoff+7],f.data[tcpoff+8],f.data[tcpoff+9],f.data[tcpoff+10],f.data[tcpoff+11],total);
            if (!dropped_syn && (flags&0x12)==0x12) { dropped_syn=true; continue; }
            if (!dropped_data && total>ihl+hlen) { dropped_data=true; continue; }
            if (!tcp_probe_receive(f.data+14,f.len-14,elapsed())) { ctx.overflow=true; break; }
        }
    }
    slirp_cleanup(slirp);
    if (!ok) kill(child,SIGTERM);
    int status=0; waitpid(child,&status,0);
    if (!ok || !dropped_syn || !dropped_data || !WIFEXITED(status) || WEXITSTATUS(status)!=0) { fprintf(stderr,"failed ready=%d wrote=%d got=%zu close=%d syn_drop=%d data_drop=%d overflow=%d\n",tcp_probe_ready(),wrote,got,closing,dropped_syn,dropped_data,ctx.overflow); return 6; }
    puts("libslirp TCP and host echo: SYN/data loss, retransmission, echo and FIN OK"); return 0;
}
