# Running C6 application description and OTA boot boundary

On 2026-11-01, a P4-only read-only diagnostic built from clean commit
`6cf0344f8315995dedc8d409ab37caf71fdaca95`, app SHA-256
`0cd43620113e15d2e066b6f096d4aa75f05f3a9c1208aade1c91f69256f80001`,
queried the attached C6. Hosted firmware version was 2.13.1; its standard
AppGetDesc response reported project `network_adapter`, application version
`2.13.1`, and ESP-IDF version `v5.5.2`. It did not report an ELF SHA-256.
The response matches those three description fields in the previously reviewed
2.13.1 application binary, SHA-256
`7f036e616df4d4782015caf30f185f7859af115438f394463600d0f8d69995be`.
These fields are self-reported and shared by potentially many builds: this
is not a running-image digest, C6 flash readback, bootloader identification,
or proof that the device contains those exact binary bytes.

The same diagnostic received `ESP_ERR_NOT_FOUND` for the new OTA layout
query, so the displayed zero partition and security fields were placeholders.
It used an outgoing stream guard that permits the exact Hosted setup, version,
read-only AppGetDesc and the one OTA-info CustomRpc, rejecting OTA updates and
other CustomRpc IDs. This guard is covered by host tests, not an independent
packet capture. The P4 write lock, verified serial exclusion, P4 identity and
full-flash backup preceded installation. The original 16 MiB P4 flash was
restored and verified against SHA-256
`06140086d05c94f5e8586c89f516d56d31b6340429526796448582a2e1bec435`.
Capture SHA-256:
`4b7c71bd359d5b795a72e1f2deaa1910468cf782d37157b4086aa1b47653828c`.
The [redacted checked result](evidence/2026-11-01-c6-app-description.json)
was produced by `tools/c6_app_desc_evidence.py`; its negative tests reject
missing or duplicate reports, wrong metadata, candidate mismatch and traps.
The raw capture, app description and backup are private under
`/private/tmp/nihos-c6-app-desc-physical-20261101/`. The restored P4 app's
subsequent boot was not captured; the C6 app was not updated.

The reviewed 2.13.1 application's reproduction sdkconfig has
`CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE` disabled. In the corresponding IDF
5.5.2 OTA implementation, `esp_ota_set_boot_partition` writes the new slot
state as `ESP_OTA_IMG_UNDEFINED` when that option is disabled, rather than
`ESP_OTA_IMG_NEW`. If the running application is that exact build and the
normal activation path is used, its configuration alone does not request
first-boot rollback monitoring. The actual running bytes were not read, so
this is conditional on that identity. The candidate 3.x build also has the
option disabled. Enabling it only in a later image cannot retroactively change
the state written by the currently running updater.

Espressif's [C6 bootloader guide](https://docs.espressif.com/projects/esp-idf/en/v5.2/esp32c6/api-guides/bootloader.html)
describes the supported direction as an older bootloader starting a newer IDF
app, and recommends retaining the older bootloader for downgrade. Its
[IDF 5.5.6 OTA guide](https://docs.espressif.com/projects/esp-idf/en/v5.5.6/esp32c6/api-reference/system/ota.html)
describes automatic first-boot rollback only when the rollback configuration
and relevant OTA states are in use. Neither the C6's bootloader version nor
its rollback configuration has been physically read here. A same-device test
of the actual bootloader and a recovery route are still required before
claiming that a failed 3.x boot can be recovered.
