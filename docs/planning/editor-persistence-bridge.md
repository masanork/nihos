# Editor persistence bridge

The launcher editor is RAM-only. The browser fixture can save a host file. Neither path saves a file on Tab5.

The experimental `storage/sector_media.zig` adapter maps a checkpoint-store byte range onto an explicitly granted exclusive sector range. It does not choose a partition, format media, grant ownership, or register a driver. Its owner must validate the lease and exclusive range atomically with each operation, stop accessing borrowed buffers before returning, and provide a real ordered durability barrier. Any write, read, or barrier error faults the adapter; an interrupted publication has an unknown outcome until the store is reopened and recovered.

The host fault model exercises bounded sector access and checkpoint recovery after interrupted writes and barriers. It is not an SD controller, a Tab5 boot, or evidence that an SD card provides the assumed barrier. The normal SDMMC path remains read-only.

Before connecting the editor to device storage, a native owner needs a separately identified writable region, serialized read/write access shared with the existing SD/Wi-Fi host, write-DMA cache ownership and quiescence, card-ready/status handling, a justified barrier, and removal/error recovery. It must never auto-format a card or write into an existing FAT volume. The end-to-end acceptance path is edit, acknowledged save, restart, and exact readback while UI/input remain usable; physical removal and power-loss testing are separate gates.
