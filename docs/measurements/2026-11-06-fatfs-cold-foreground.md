# FatFs RPC cold-Flash foreground placement

The manual `native.yml` FatFs RPC fixture failed the cold-Flash audit because
its primary SRAM resident size exceeded the existing 106,496-byte limit. The
foreground-only `main.qualificationSoak` is entered after Flash mapping and
is not an interrupt handler. In the cold-Flash native FatFs profile it now
resides in the existing mapped storage Flash span. Other profiles keep their
previous placement, including the photo profile. The IRQ hooks and required
resident callbacks continue to be checked by the existing image audit.

Local macOS build of the CI fixture using the ESP-IDF 5.4.4 toolchain:

- ELF SHA-256: `baf5c31a50313df155aaad7ba4e42b99c1baafc55724202c9ea2d17861a68a5c`.
- `main.qualificationSoak`: `0x400a9fa4` through `0x400aad9a` in mapped Flash;
  audit requires a single copy, rejecting an SRAM copy or compiler clone.
- Primary resident bytes: 104,704, within the unchanged 106,496-byte cap;
  heap: 59,136 bytes, above the existing 49,152-byte floor.
- Input fixture and native ELF audit passed. The structural stack analysis
  reported unresolved indirect calls; this is not a whole-call-stack proof.
- The normal device build passed with a 52,928-byte heap. The alternative
  FatFs fixture with cold Flash disabled still fails the existing 48 KiB link
  floor; it is not newly qualified by this change.

These are build and host-audit results, not execution of this candidate on
Tab5. In particular, Flash/cache behavior, interrupt timing, and physical card
I/O remain device qualification boundaries.
