/* Host register boundary adapted from display_notice/retire-replay.c. */
static struct { struct { uint32_t val; } chen0; } DW_GDMA;
static struct { struct { uint32_t val; } out; } GPIO;
static unsigned MIPI_DSI_BRIDGE;
static struct { struct { uint32_t val; } vid_pkt_status; } MIPI_DSI_HOST;
static bool video_enabled;
static unsigned fifo;
static bool fifo_stuck, lane_stuck;
#define MIPI_DSI_LL_CLOCK_LANE_STATE_LP 0
static bool dma_owned, pause_requested, stuck;
static uint32_t fault, completions, backlight_offs;
static unsigned restarts, disabled, stopped_domains;
static bool stop_dma(bool blank);
static bool restart_dma(void);
static void gpio_ll_set_level(void *io, unsigned pin, unsigned level) {
    (void)io; assert(pin == 22);
    if (level) GPIO.out.val |= 1u << 22; else GPIO.out.val &= ~(1u << 22);
}
static void dw_gdma_ll_channel_enable_intr_propagation(void *io, unsigned channel, uint32_t mask, bool on) {
    (void)io; assert(channel == 0 && mask == UINT32_MAX && !on);
}
static void dw_gdma_ll_channel_enable(void *io, unsigned channel, bool on) {
    (void)io; assert(channel == 0 && !on); ++disabled;
    if (!stuck) DW_GDMA.chen0.val = 0;
}
static void mipi_dsi_brg_ll_enable_interrupt(void *io, uint32_t mask, bool on) {
    (void)io; assert(mask == UINT32_MAX && !on);
}
static uint32_t mipi_dsi_brg_ll_get_fifo_depth(void *io) {
    (void)io; assert(video_enabled);
    if (fifo && !fifo_stuck) --fifo;
    if (!fifo) MIPI_DSI_HOST.vid_pkt_status.val = 5;
    return fifo;
}
static void mipi_dsi_host_ll_enable_video_mode(void *io, bool on) {
    (void)io; assert(!on);
    if (GPIO.out.val) assert(!fifo && MIPI_DSI_HOST.vid_pkt_status.val == 5);
    video_enabled = false;
}
static void mipi_dsi_host_ll_set_clock_lane_state(void *io, unsigned state) { (void)io; assert(state == MIPI_DSI_LL_CLOCK_LANE_STATE_LP && !video_enabled); }
static bool mipi_dsi_phy_ll_are_lanes_stopped(void *io, unsigned lanes) { (void)io; assert(lanes == 2); return !lane_stuck; }
static void mipi_dsi_brg_ll_enable_dpi_output(void *io, bool on) { (void)io; assert(!on && !video_enabled); }
static void mipi_dsi_brg_ll_enable(void *io, bool on) { (void)io; assert(!on); }
static void mipi_dsi_ll_enable_dpi_clock(unsigned id, bool on) { assert(id == 0 && !on); }
static void dw_gdma_ll_enable_intr_global(void *io, bool on) { (void)io; assert(!on); }
static void dw_gdma_ll_enable_controller(void *io, bool on) { (void)io; assert(!on); }
static void dw_gdma_ll_enable_bus_clock(unsigned id, bool on) { assert(id == 0 && !on); ++stopped_domains; }
static bool dw_domain_release(uint32_t channel) {
    assert(channel == 0);
    dw_gdma_ll_enable_intr_global(&DW_GDMA, false);
    dw_gdma_ll_enable_controller(&DW_GDMA, false);
    dw_gdma_ll_enable_bus_clock(0, false);
    return true;
}
