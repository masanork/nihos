# Hosted 2.13.1 OTA activation status experiment

This is an unintegrated candidate patch for Espressif `esp-hosted-mcu` commit
`0e8d0e3f0c2723deaf15441200cb4d8c53fea230`. The candidate HTTPS/Network Split
firmware has **not** been written to Tab5 and this patch is not part of the
currently installed C6 1.4.1 firmware.

The pinned `req_ota_activate_handler` initializes `ret = ESP_OK`. For
`OTA_NOT_STARTED`, `OTA_IN_PROGRESS`, `OTA_FAILED`, and the default branch
(including already activated), it jumps to the error label without changing
`ret`. The response can therefore contain success even though the handler did
not select a boot partition or schedule a reboot. This is a source/host-harness
finding, not an observed device error or a claim about other upstream versions.

The patch sets `ESP_ERR_INVALID_STATE` on each such branch. Its host harness
extracts the actual pinned handler, compiles it against small stubs and first
requires the original source to reproduce the incorrect-success negative
control. The patched handler must reject five invalid states and must select a
boot partition and schedule a timer in the completed state. It does not model
FreeRTOS, the real bootloader, power loss, actual firmware, or concurrency.

```sh
python3 ports/esp-hosted-c6-ota-activation/run.py /path/to/esp-hosted-2.13.1
```

The runner requires the exact unmodified upstream `slave_control.c` SHA-256
`337430b61a58f5179d12e867f4a1a17d4db28a70d2749d0e2fd45f0a6f8a4fd4`, applies
the patch only to a temporary copy, and never accesses a device. The current
HTTPS/Network Split overlay does not automatically apply this patch.

Even with the patch, an Activate error or lost response cannot be treated as
proof that boot selection is unchanged: upstream selects the boot partition
before creating/starting the restart timer. Stop and reconcile the observed
state; do not blindly retry. Successful response alone is not proof that the
new image booted. Verify the new peer after reboot and retain an independent
recovery path.
