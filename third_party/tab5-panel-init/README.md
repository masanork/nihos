# Tab5 panel initialization tables

Source: Espressif `m5stack_tab5_noglib` component, version 1.3.2.
https://components.espressif.com/components/espressif/m5stack_tab5_noglib/versions/1.3.2

These three headers and LICENSE retain the upstream Apache-2.0 terms. The
ILI9881C and ST7121 headers are unchanged. In `disp_init_data_1.h` (ST7123),
two declared payload lengths exceeded their initialized arrays: A3 40 -> 39,
E8 15 -> 14. Only the lengths were corrected, with a comment in that header,
to avoid reading beyond initialized bytes. The original ST7123 header SHA-256
was `748882dad015816d1ca83853297b1751ae3e722f5385911061a56fed927056e2`.
ST7123 and ILI9881C have not been physically tested by this display work.

Run `python3 tools/boot-graphics/generate-panel-init.py --verify-c` to regenerate
the packed Zig input tables and their source/hash manifest. It bounds payloads,
checks that every initializer was parsed, and compares each output byte against
a C compiler reading these headers. This checks serialization, not panel
command correctness or physical compatibility.
