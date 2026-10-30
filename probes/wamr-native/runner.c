#include "wasm_export.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

enum { RUNTIME_BYTES = 128 * 1024, LINEAR_BYTES = 256 * 1024 };
extern int nih_wamr_arena_init(void *, size_t, void *, size_t);
extern void *nih_wamr_arena_alloc(uint32_t, size_t);
extern int nih_wamr_arena_free(uint32_t, void *);
extern int nih_wamr_arena_recovered(uint32_t);
extern size_t nih_wamr_arena_free_bytes(uint32_t);
extern uint8_t *nih_wamr_stack_boundary(void);
extern uint8_t *nih_wamr_surface_storage(uint32_t *);
extern int nih_rom_putc(uint8_t);
extern int nih_rom_rx_one_char(uint8_t *);
extern int32_t nih_app_probe_attach(uint8_t *, uint32_t, uint32_t, uint32_t, uint32_t);
extern void nih_app_probe_detach(void);
extern int32_t nih_app_fill_rect(int32_t, int32_t, uint32_t, uint32_t, uint32_t);
extern int32_t nih_app_text(int32_t, int32_t, const uint8_t *, uint32_t, uint32_t);
enum { FRAME_WIDTH=160, FRAME_HEIGHT=80, FRAME_STRIDE=324, FRAME_GUARD=16,
       FRAME_BYTES=FRAME_STRIDE*FRAME_HEIGHT, FRAME_TOTAL=FRAME_BYTES+2*FRAME_GUARD };

struct nih_package_report {
    uint32_t trust_status, policy_status, wasm_offset, wasm_length;
    uint32_t services, sdk_abi, origin, attestation;
    uint32_t module_tag, digest_tag, instruction_budget;
    uint32_t sequence_low, sequence_high;
};
extern int nih_package_ed25519_admit(const uint8_t *, uint32_t,
                                     struct nih_package_report *);

struct nih_boot_report {
    uint32_t trust_status, policy_status, wasm_offset, wasm_length;
    uint32_t services, sdk_abi, origin, attestation;
    uint32_t module_tag, digest_tag, instruction_budget;
    uint32_t sequence_low, sequence_high, package_length;
    uint32_t trust_epoch_low, trust_epoch_high, boot_recovered;
    uint32_t initial_sequence_low, initial_sequence_high;
    uint32_t installed_sequence_low, installed_sequence_high;
    uint32_t package_syncs, simulated_reboot;
    uint32_t interrupted_update_recovered;
};
extern int nih_package_boot_recover(uint8_t *, uint32_t,
                                    struct nih_boot_report *);

struct nih_wamr_report {
    uint32_t status, calls, trapped, metered, bad_text, cycles;
    uint32_t cycle_recovered, recovered;
    uint32_t runtime_peak, linear_peak, runtime_free, linear_free;
    uint32_t export_count, stack_used, lease_bytes;
    uint32_t policy_status, services, sdk_abi, origin, attestation;
    uint32_t module_tag, digest_tag, instruction_budget;
    uint32_t signature_status, boot_admission_cycles, boot_admission_stack_used;
    uint32_t package_trust, package_sequence_low, package_sequence_high;
    uint32_t package_rejected, boot_recovered;
    uint32_t trust_epoch_low, trust_epoch_high;
    uint32_t initial_sequence_low, initial_sequence_high;
    uint32_t installed_sequence_low, installed_sequence_high;
    uint32_t package_syncs, simulated_reboot;
    uint32_t interrupted_update_recovered;
    uint32_t owner_checks, owners_released;
    uint32_t surface_checks;
    uint32_t event_checks, event_frames;
    uint32_t uart_status, uart_bytes, uart_frames, uart_rejected;
    uint32_t surface_width, surface_height, surface_stride, surface_bytes, surface_capacity;
};

static uint32_t frame_hash(const uint8_t *frame) {
    uint32_t value = 2166136261u;
    for (size_t i=0; i<FRAME_TOTAL; i++) value = (value ^ frame[i]) * 16777619u;
    return value;
}
static bool frame_guards(const uint8_t *frame) {
    for (size_t i=0; i<FRAME_GUARD; i++)
        if (frame[i]!=0xa5 || frame[FRAME_GUARD+FRAME_BYTES+i]!=0xa5) return false;
    for (size_t y=0; y<FRAME_HEIGHT; y++)
        for (size_t x=FRAME_WIDTH*2; x<FRAME_STRIDE; x++)
            if (frame[FRAME_GUARD+y*FRAME_STRIDE+x]!=0xa5) return false;
    return true;
}
static bool frame_state(const uint8_t *frame, bool pressed) {
    static const uint8_t ready[5][8]={
        {0x3f,0x66,0x66,0x3e,0x36,0x66,0x67,0},
        {0,0,0x1e,0x33,0x3f,0x03,0x1e,0},
        {0,0,0x1e,0x30,0x3e,0x33,0x6e,0},
        {0x38,0x30,0x30,0x3e,0x33,0x33,0x6e,0},
        {0,0,0x33,0x33,0x33,0x3e,0x30,0x1f}};
    static const uint8_t selected[7][8]={
        {0x3f,0x66,0x66,0x3e,0x06,0x06,0x0f,0},
        {0,0,0x3b,0x6e,0x66,0x06,0x0f,0},
        {0,0,0x1e,0x33,0x3f,0x03,0x1e,0},
        {0,0,0x3e,0x03,0x1e,0x30,0x1f,0},
        {0,0,0x3e,0x03,0x1e,0x30,0x1f,0},
        {0,0,0x1e,0x33,0x3f,0x03,0x1e,0},
        {0x38,0x30,0x30,0x3e,0x33,0x33,0x6e,0}};
    const uint8_t (*glyphs)[8] = pressed ? selected : ready;
    const size_t glyph_count = pressed ? 7u : 5u;
    const uint16_t background = pressed ? 0x220c : 0x1082;
    const uint8_t *pixels = frame+FRAME_GUARD;
    if (!frame_guards(frame) || pixels[0]!=(uint8_t)background ||
        pixels[1]!=(uint8_t)(background>>8)) return false;
    for (size_t y=0; y<FRAME_HEIGHT; y++) for (size_t x=0; x<FRAME_WIDTH; x++) {
        uint16_t expected = background;
        if (y>=8 && y<16 && x>=8 && (x-8)/8<glyph_count &&
            (glyphs[(x-8)/8][y-8] & (1u<<((x-8)%8)))) expected = 0xffff;
        const size_t offset = y*FRAME_STRIDE+x*2;
        if (pixels[offset]!=(uint8_t)expected || pixels[offset+1]!=(uint8_t)(expected>>8)) return false;
    }
    return true;
}

enum { SERVICE_GRAPHICS = 1 };
struct import_owner {
    wasm_module_inst_t instance;
    uint32_t services;
    bool active;
    bool frame_open;
    uint32_t selected, frames;
};

static struct import_owner *current_owner(wasm_exec_env_t env) {
    wasm_module_inst_t instance = wasm_runtime_get_module_inst(env);
    struct import_owner *owner = wasm_runtime_get_custom_data(instance);
    return owner && owner->active && owner->instance == instance ? owner : NULL;
}
static bool graphics_allowed(wasm_exec_env_t env) {
    struct import_owner *owner = current_owner(env);
    return owner && owner->frame_open && (owner->services & SERVICE_GRAPHICS) != 0;
}
static bool owner_call(wasm_exec_env_t env, wasm_function_inst_t function,
                       uint32_t argc, uint32_t *args) {
    struct import_owner *owner = current_owner(env);
    if (!owner || owner->frame_open) return false;
    owner->frame_open = true;
    const bool ok = wasm_runtime_call_wasm(env, function, argc, args);
    owner->frame_open = false;
    return ok;
}
static int32_t owner_input(wasm_exec_env_t env, uint32_t byte) {
    struct import_owner *owner = current_owner(env);
    if (!owner) return -5;
    if (owner->frame_open) return -3;
    if (byte != '0' && byte != '1') return -1;
    owner->selected = byte - '0';
    return 0;
}
static int32_t owner_render(wasm_exec_env_t env, wasm_function_inst_t function) {
    struct import_owner *owner = current_owner(env);
    if (!owner || !(owner->services & SERVICE_GRAPHICS)) return -5;
    if (owner->frame_open) return -3;
    if (owner->frames == UINT32_MAX) return -1;
    uint32_t args[1] = {owner->selected};
    if (!owner_call(env, function, 1, args)) return -6;
    if (args[0] != 0) return (int32_t)args[0];
    owner->frames++;
    return 0;
}

typedef union Header {
    max_align_t align;
    struct { size_t size; mem_alloc_usage_t usage; } value;
} Header;

static size_t live[2], peak[2], blocks[2];
static uint32_t calls;
static bool fail_rect;

static uint32_t private_stack_used(void) {
    uint8_t *low = nih_wamr_stack_boundary();
    size_t first = 128;
    if (!low) return 0;
    while (first < 64 * 1024 && low[first] == 0xa5) first++;
    return (uint32_t)(64 * 1024 - first);
}

static uint32_t cycle32(void) {
    uint32_t value;
    __asm__ volatile ("rdcycle %0" : "=r"(value));
    return value;
}

static int owner_uart(wasm_exec_env_t env, wasm_function_inst_t function,
                      const uint8_t *frame, struct nih_wamr_report *report) {
    static const char ready[] = "NIHOS_WAMR_UART_READY\r\n";
    static const uint32_t states[3] = {0,1,0};
    struct import_owner *owner = current_owner(env);
    if (!owner) return 44;
    for (size_t i=0; i<sizeof(ready)-1; i++) (void)nih_rom_putc((uint8_t)ready[i]);
    const uint32_t begin = cycle32();
    while ((uint32_t)(cycle32()-begin) < 64000000u) {
        uint8_t byte;
        if (nih_rom_rx_one_char(&byte) != 0) continue;
        if (++report->uart_bytes > 16) return 43;
        if (byte == 'q') {
            owner->active = false;
            report->uart_status = 1;
            return report->uart_frames == 3 && report->uart_rejected == 1 ? 0 : 44;
        }
        const uint32_t prior_hash = frame_hash(frame), prior_calls = calls;
        const uint32_t selected = owner->selected, frames = owner->frames;
        const int32_t status = owner_input(env, byte);
        if (byte != '0' && byte != '1') {
            if (status != -1 || owner->selected != selected || owner->frames != frames ||
                calls != prior_calls || frame_hash(frame) != prior_hash) return 44;
            report->uart_rejected++;
            continue;
        }
        if (status != 0 || report->uart_frames >= 3 ||
            owner->selected != states[report->uart_frames] || owner_render(env, function) != 0 ||
            !frame_state(frame, owner->selected == 1)) return 44;
        report->uart_frames++;
    }
    report->uart_status = 2;
    return 42;
}

static void *allocate(mem_alloc_usage_t usage, unsigned size) {
    Header *header;
    if ((unsigned)usage > 1) return NULL;
    header = nih_wamr_arena_alloc((uint32_t)usage, sizeof(*header) + (size_t)size);
    if (!header) return NULL;
    header->value.size = size;
    header->value.usage = usage;
    live[usage] += size;
    blocks[usage]++;
    if (peak[usage] < live[usage]) peak[usage] = live[usage];
    return header + 1;
}

static void release(mem_alloc_usage_t usage, void *pointer) {
    Header *header;
    if (!pointer) return;
    header = (Header *)pointer - 1;
    if ((unsigned)usage > 1 || header->value.usage != usage ||
        live[usage] < header->value.size || blocks[usage] == 0) return;
    live[usage] -= header->value.size;
    blocks[usage]--;
    (void)nih_wamr_arena_free((uint32_t)usage, header);
}

static void *resize(mem_alloc_usage_t usage, bool full_mapped, void *pointer,
                    unsigned size) {
    Header *old;
    void *next;
    (void)full_mapped;
    if (!pointer) return allocate(usage, size);
    if (!size) { release(usage, pointer); return NULL; }
    old = (Header *)pointer - 1;
    if (old->value.usage != usage) return NULL;
    next = allocate(usage, size);
    if (!next) return NULL;
    memcpy(next, pointer, old->value.size < size ? old->value.size : size);
    release(usage, pointer);
    return next;
}

static int32_t fill_rect(wasm_exec_env_t env, int32_t x, int32_t y,
                         uint32_t width, uint32_t height, uint32_t rgb) {
    if (!graphics_allowed(env)) return -5;
    if (x != 0 || y != 0 || width != 160 || height != 80 || rgb > 0xffffff)
        return -1;
    calls++;
    if (fail_rect) return -4;
    return nih_app_fill_rect(x, y, width, height, rgb);
}

static int32_t text(wasm_exec_env_t env, int32_t x, int32_t y,
                    uint32_t offset, uint32_t length, uint32_t rgb) {
    wasm_module_inst_t instance = wasm_runtime_get_module_inst(env);
    const uint8_t *source;
    uint32_t i;
    if (!graphics_allowed(env)) return -5;
    if (!wasm_runtime_validate_app_addr(instance, offset, length)) return -1;
    if (x != 8 || y != 8 || rgb != 0xffffff || length > 128) return -1;
    source = wasm_runtime_addr_app_to_native(instance, offset);
    if (!source && length) return -1;
    for (i = 0; i < length; i++) if (source[i] < 32 || source[i] > 126) return -2;
    calls++;
    return nih_app_text(x, y, source, length, rgb);
}

static NativeSymbol imports[] = {
    { "nih_app_fill_rect", (void *)fill_rect, "(iiiii)i", NULL },
    { "nih_app_text", (void *)text, "(iiiii)i", NULL },
};

static void destroy_cycle(wasm_exec_env_t *env, wasm_module_inst_t *instance,
                          wasm_module_t *module) {
    if (*env) { wasm_runtime_destroy_exec_env(*env); *env = NULL; }
    if (*instance) {
        struct import_owner *owner = wasm_runtime_get_custom_data(*instance);
        if (owner) { owner->active = false; owner->frame_open = false; }
        wasm_runtime_set_custom_data(*instance, NULL);
        wasm_runtime_deinstantiate(*instance); *instance = NULL;
    }
    if (*module) { wasm_runtime_unload(*module); *module = NULL; }
}

int nih_wamr_run(void *runtime, void *linear, uint8_t *wasm_first,
                 uint8_t *wasm_second,
                 uint32_t package_capacity, struct nih_wamr_report *report) {
    RuntimeInitArgs init = {0};
    wasm_module_t module = NULL;
    wasm_module_inst_t instance = NULL;
    wasm_exec_env_t env = NULL;
    wasm_function_inst_t function;
    uint32_t args[2];
    size_t initial[2] = {0, 0};
    size_t cycle_free[2] = {0, 0}, cycle_live[2] = {0, 0}, cycle_blocks[2] = {0, 0};
    char error[128] = {0};
    bool initialized = false;
    bool surface_attached = false;
    uint32_t frame_capacity = 0;
    uint8_t *frame = nih_wamr_surface_storage(&frame_capacity);
    uint32_t saved_frame_hash = 0;
    struct import_owner first_owner = {0}, second_owner = {0};
    uint32_t wasm_length = 0;
    int result = 1;
    memset(report, 0, sizeof(*report));
    memset(live, 0, sizeof(live));
    memset(peak, 0, sizeof(peak));
    memset(blocks, 0, sizeof(blocks));
    calls = 0;
    fail_rect = false;
    if (nih_wamr_arena_init(runtime, RUNTIME_BYTES, linear, LINEAR_BYTES) != 0)
        goto cleanup;
    initial[0] = nih_wamr_arena_free_bytes(0);
    initial[1] = nih_wamr_arena_free_bytes(1);
    {
        struct nih_boot_report admission = {0};
        struct nih_package_report rejected = {0};
        uint32_t begin, end;
        if (package_capacity < 4096) {
            result = 22;
            goto cleanup;
        }
        begin = cycle32();
        if (nih_package_boot_recover(wasm_first, package_capacity,
                                     &admission) != 0) {
            result = 23;
            goto cleanup;
        }
        end = cycle32();
        if (!admission.package_length ||
            admission.package_length > package_capacity ||
            nih_package_ed25519_admit(wasm_first,
                                      admission.package_length - 1,
                                      &rejected) == 0) {
            result = 25;
            goto cleanup;
        }
        report->package_rejected = 1;
        if ((size_t)admission.wasm_offset + admission.wasm_length >
                admission.package_length ||
            admission.wasm_length == 0 || admission.wasm_length > 4096) {
            result = 24;
            goto cleanup;
        }
        report->signature_status = 1;
        report->boot_admission_cycles = end - begin;
        report->boot_admission_stack_used = private_stack_used();
        report->package_trust = admission.trust_status;
        report->policy_status = admission.policy_status;
        report->services = admission.services;
        report->sdk_abi = admission.sdk_abi;
        report->origin = admission.origin;
        report->attestation = admission.attestation;
        report->module_tag = admission.module_tag;
        report->digest_tag = admission.digest_tag;
        report->instruction_budget = admission.instruction_budget;
        report->package_sequence_low = admission.sequence_low;
        report->package_sequence_high = admission.sequence_high;
        report->boot_recovered = admission.boot_recovered;
        report->trust_epoch_low = admission.trust_epoch_low;
        report->trust_epoch_high = admission.trust_epoch_high;
        report->initial_sequence_low = admission.initial_sequence_low;
        report->initial_sequence_high = admission.initial_sequence_high;
        report->installed_sequence_low = admission.installed_sequence_low;
        report->installed_sequence_high = admission.installed_sequence_high;
        report->package_syncs = admission.package_syncs;
        report->simulated_reboot = admission.simulated_reboot;
        report->interrupted_update_recovered =
            admission.interrupted_update_recovered;
        wasm_length = admission.wasm_length;
        memcpy(wasm_second, wasm_first + admission.wasm_offset, wasm_length);
        memcpy(wasm_first, wasm_second, wasm_length);
    }
    if (!frame || frame_capacity < FRAME_TOTAL) { result = 45; goto cleanup; }
    report->surface_width = FRAME_WIDTH;
    report->surface_height = FRAME_HEIGHT;
    report->surface_stride = FRAME_STRIDE;
    report->surface_bytes = FRAME_BYTES;
    report->surface_capacity = frame_capacity;
    memset(frame, 0xa5, frame_capacity);
    saved_frame_hash = frame_hash(frame);
    if (nih_app_probe_attach(frame+FRAME_GUARD, FRAME_BYTES, FRAME_WIDTH,
                             FRAME_HEIGHT, FRAME_STRIDE) != 0) { result = 30; goto cleanup; }
    surface_attached = true;
    init.mem_alloc_type = Alloc_With_Allocator;
    init.mem_alloc_option.allocator.malloc_func = (void *)allocate;
    init.mem_alloc_option.allocator.realloc_func = (void *)resize;
    init.mem_alloc_option.allocator.free_func = (void *)release;
    if (!(initialized = wasm_runtime_full_init(&init))) { result = 2; goto cleanup; }
    /* Keep registration outside full_init: its lock is deliberately
     * non-recursive, and allocation failure must not deadlock initialization. */
    if (!wasm_runtime_register_natives("nihos", imports, 2)) { result = 3; goto cleanup; }
    cycle_free[0] = nih_wamr_arena_free_bytes(0);
    cycle_free[1] = nih_wamr_arena_free_bytes(1);
    cycle_live[0] = live[0]; cycle_live[1] = live[1];
    cycle_blocks[0] = blocks[0]; cycle_blocks[1] = blocks[1];

    module = wasm_runtime_load(wasm_first, wasm_length, error, sizeof(error));
    if (!module) { result = 4; goto cleanup; }
    report->export_count = (uint32_t)wasm_runtime_get_export_count(module);
    instance = wasm_runtime_instantiate(module, 16384, 0, error, sizeof(error));
    if (!instance) { result = 5; goto cleanup; }
    first_owner.instance = instance;
    first_owner.services = report->services;
    first_owner.active = true;
    wasm_runtime_set_custom_data(instance, &first_owner);
    env = wasm_runtime_create_exec_env(instance, 16384);
    if (!env) { result = 6; goto cleanup; }

    function = wasm_runtime_lookup_function(instance, "nih_rust_app_frame");
    if (!function) { result = 7; goto cleanup; }
    args[0] = 0;
    if (!wasm_runtime_call_wasm(env, function, 1, args) ||
        (int32_t)args[0] != -5 || calls != 0) { result = 38; goto cleanup; }
    report->event_checks |= 16;
    /* Open a diagnostic call scope so the following checks exercise each
       owner condition independently of the outside-frame denial above. */
    first_owner.frame_open = true;
    first_owner.services = 0;
    args[0] = 0;
    if (!wasm_runtime_call_wasm(env, function, 1, args) ||
        (int32_t)args[0] != -5 || calls != 0 ||
        text(env, 8, 8, UINT32_MAX, 4, 0xffffff) != -5 ||
        wasm_runtime_get_exception(instance)) { result = 26; goto cleanup; }
    report->owner_checks |= 1;
    first_owner.services = report->services;
    first_owner.active = false;
    args[0] = 0;
    if (!wasm_runtime_call_wasm(env, function, 1, args) ||
        (int32_t)args[0] != -5 || calls != 0) { result = 27; goto cleanup; }
    report->owner_checks |= 2;
    first_owner.active = true;
    first_owner.instance = NULL;
    args[0] = 0;
    if (!wasm_runtime_call_wasm(env, function, 1, args) ||
        (int32_t)args[0] != -5 || calls != 0) { result = 28; goto cleanup; }
    report->owner_checks |= 4;
    first_owner.instance = instance;
    wasm_runtime_set_custom_data(instance, NULL);
    args[0] = 0;
    if (!wasm_runtime_call_wasm(env, function, 1, args) ||
        (int32_t)args[0] != -5 || calls != 0) { result = 29; goto cleanup; }
    report->owner_checks |= 8;
    wasm_runtime_set_custom_data(instance, &first_owner);
    first_owner.frame_open = false;
    if (frame_hash(frame) != saved_frame_hash) { result = 31; goto cleanup; }
    report->surface_checks |= 1;
    args[0] = 0;
    if (!owner_call(env, function, 1, args) || args[0] != 0) { result = 8; goto cleanup; }
    if (!frame_state(frame, false)) { result = 32; goto cleanup; }
    report->surface_checks |= 2;
    args[0] = 1;
    if (!owner_call(env, function, 1, args) || args[0] != 0) { result = 9; goto cleanup; }
    if (!frame_state(frame, true)) { result = 33; goto cleanup; }
    report->surface_checks |= 4;
    saved_frame_hash = frame_hash(frame);
    fail_rect = true;
    args[0] = 1;
    if (!owner_call(env, function, 1, args) || (int32_t)args[0] != -4) { result = 10; goto cleanup; }
    fail_rect = false;
    if (frame_hash(frame) != saved_frame_hash) { result = 34; goto cleanup; }
    report->surface_checks |= 8;

    function = wasm_runtime_lookup_function(instance, "nih_probe_raw_text");
    args[0] = UINT32_MAX; args[1] = 4;
    if (!function || owner_call(env, function, 2, args) ||
        !wasm_runtime_get_exception(instance)) { result = 11; goto cleanup; }
    report->trapped = 1;
    wasm_runtime_clear_exception(instance);

    function = wasm_runtime_lookup_function(instance, "nih_probe_bad_text");
    args[0] = 0;
    if (!function || !owner_call(env, function, 0, args) ||
        (int32_t)args[0] != -2) { result = 12; goto cleanup; }
    report->bad_text = 1;
    if (frame_hash(frame) != saved_frame_hash) { result = 35; goto cleanup; }
    report->surface_checks |= 16;

    function = wasm_runtime_lookup_function(instance, "nih_probe_spin");
    wasm_runtime_set_instruction_count_limit(env, 10000);
    if (!function || owner_call(env, function, 0, NULL) ||
        !wasm_runtime_get_exception(instance)) { result = 13; goto cleanup; }
    report->metered = 1;
    wasm_runtime_clear_exception(instance);
    destroy_cycle(&env, &instance, &module);
    if (live[0] != cycle_live[0] || live[1] != cycle_live[1] ||
        blocks[0] != cycle_blocks[0] || blocks[1] != cycle_blocks[1] ||
        nih_wamr_arena_free_bytes(0) != cycle_free[0] ||
        nih_wamr_arena_free_bytes(1) != cycle_free[1]) {
        result = 15;
        goto cleanup;
    }
    report->cycle_recovered = 1;

    module = wasm_runtime_load(wasm_second, wasm_length, error, sizeof(error));
    if (!module) { result = 16; goto cleanup; }
    if ((uint32_t)wasm_runtime_get_export_count(module) != report->export_count) {
        result = 17; goto cleanup;
    }
    instance = wasm_runtime_instantiate(module, 16384, 0, error, sizeof(error));
    if (!instance) { result = 18; goto cleanup; }
    second_owner.instance = instance;
    second_owner.services = report->services;
    second_owner.active = true;
    wasm_runtime_set_custom_data(instance, &second_owner);
    env = wasm_runtime_create_exec_env(instance, 16384);
    if (!env) { result = 19; goto cleanup; }
    function = wasm_runtime_lookup_function(instance, "nih_rust_app_frame");
    if (!function) { result = 20; goto cleanup; }
    {
        static const uint32_t events[3] = {'0','1','0'};
        for (unsigned i=0; i<3; i++) {
            if (owner_input(env, events[i]) != 0 || owner_render(env, function) != 0 ||
                !frame_state(frame, events[i]=='1')) { result = 21; goto cleanup; }
        }
    }
    report->event_checks |= 1;
    report->event_frames = second_owner.frames;
    saved_frame_hash = frame_hash(frame);
    {
        const uint32_t prior_calls = calls;
        if (owner_input(env, 'x') != -1 || second_owner.selected != 0 ||
            second_owner.frames != 3 || calls != prior_calls ||
            frame_hash(frame) != saved_frame_hash) { result = 39; goto cleanup; }
        report->event_checks |= 2;
        second_owner.frame_open = true;
        if (owner_input(env, '1') != -3 || owner_render(env, function) != -3 ||
            !second_owner.frame_open || second_owner.selected != 0 ||
            calls != prior_calls || frame_hash(frame) != saved_frame_hash) { result = 40; goto cleanup; }
        second_owner.frame_open = false;
        report->event_checks |= 4;
        result = owner_uart(env, function, frame, report);
        if (result != 0) goto cleanup;
        saved_frame_hash = frame_hash(frame);
        const uint32_t stopped_calls = calls;
        if (owner_input(env, '1') != -5 || owner_render(env, function) != -5 ||
            second_owner.frames != 6 || calls != stopped_calls ||
            frame_hash(frame) != saved_frame_hash) { result = 41; goto cleanup; }
        report->event_checks |= 8;
    }
    report->cycles = 2;
    if (!frame_state(frame, false)) { result = 36; goto cleanup; }
    report->surface_checks |= 32;
    result = 0;

cleanup:
    destroy_cycle(&env, &instance, &module);
    report->owners_released = (!first_owner.active && !second_owner.active) ? 1u : 0u;
    if (surface_attached) {
        nih_app_probe_detach();
        if (nih_app_fill_rect(0,0,1,1,0)==-3 && frame_guards(frame)) report->surface_checks |= 64;
        else if (result == 0) result = 37;
    }
    if (initialized) wasm_runtime_destroy();
    report->status = (uint32_t)result;
    report->calls = calls;
    report->runtime_peak = (uint32_t)peak[0];
    report->linear_peak = (uint32_t)peak[1];
    report->runtime_free = (uint32_t)nih_wamr_arena_free_bytes(0);
    report->linear_free = (uint32_t)nih_wamr_arena_free_bytes(1);
    if (!live[0] && !live[1] && !blocks[0] && !blocks[1] &&
        nih_wamr_arena_recovered(0) && nih_wamr_arena_recovered(1) &&
        report->runtime_free == initial[0] && report->linear_free == initial[1])
        report->recovered = 1;
    if (result == 0 && !report->recovered) result = 14;
    report->status = (uint32_t)result;
    return result;
}
