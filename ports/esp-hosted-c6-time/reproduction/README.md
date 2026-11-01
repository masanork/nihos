# C6 2.13.1 time candidate source

These are the complete source deltas and configuration used for the physical
C6 OTA reported in `docs/measurements/2026-11-01-c6-time-ota-upgrade.md`.
The patch targets Espressif ESP-Hosted MCU commit
`0e8d0e3f0c2723deaf15441200cb4d8c53fea230`; original upstream material is
Apache-2.0 and is not vendored here. The patch includes the classifier, status
synchronization, telemetry, OTA activation fix, integration and default config
changes. The HTTPS files are retained under `unused-https/` as build provenance;
`CONFIG_NIHOS_HTTPS_SERVICE` is disabled in the measured configuration.

On a disposable clean checkout at the pinned revision:

```sh
python3 ports/esp-hosted-c6-time/reproduction/apply.py /path/to/esp-hosted-mcu
cp ports/esp-hosted-c6-time/reproduction/sdkconfig.time /tmp/nihos-c6-sdkconfig
idf.py -C /path/to/esp-hosted-mcu/slave -B /tmp/nihos-c6-build \
  -D IDF_TARGET=esp32c6 -D SDKCONFIG=/tmp/nihos-c6-sdkconfig build
```

The measured build used ESP-IDF 5.5.2 commit
`30aaf64524299d3bde422ca9a2848090d1bc5d0f`; sdkconfig SHA-256 is
`6b97d7d2f9faed0a1fc31974c3f43d41fdaf90c69fbb44c44c46446e6663ae8f`.
The measured C6 app SHA-256 was
`7f036e616df4d4782015caf30f185f7859af115438f394463600d0f8d69995be`.
A new build must be independently checked against that digest and the measured
partition table; build success does not establish byte identity or authorize a
flash. As recorded in the measurement, the original build used a temporary
component-manager parent-PID fallback because sandbox process inspection was
blocked. The exact C6 running-image contents have not been read back.

A clean-checkout source reconstruction plus the pinned sdkconfig and managed
components built successfully with the same partition-table hash, but the app
hash differed when the checkout path differed: protobuf-c embeds its absolute
source path. A repeat build using the original source path
`/private/tmp/nihos-hosted-213-time` produced the exact measured app SHA-256.
The clean-path artifact is therefore build evidence only, not byte-identical
proof; its SHA-256 was
`29b2a7fa5c4712e6278eb1a097e5aaf3a37840bdf65c037987cb75aeade48f2a`.
The locked dependencies are included in `dependencies.lock`; components must
be available to ESP-IDF's component manager.
