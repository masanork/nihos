# Native JPEG fixture development

Opt-in JPEG/DMA2D code follows the register sequencing in ESP-IDF v5.4.4, commit `296b6eab9445fd720e71aecab961e2d3fbca9944`: `esp_driver_jpeg/jpeg_encode.c`, `esp_hw_support/dma/dma2d.c`, and the JPEG/DMA2D LL headers (Espressif Systems, Apache-2.0). The software JPEG header and quantizers are generated with Pillow; the device accelerator must produce the complete entropy-coded payload.

This fixture disables networking and normal FS. It retains source, output and descriptor allocations until reset, including after errors. It does not establish DMA2D resource retirement or coexistence with another DMA2D user. Physical qualification is pending.

Build: `NIHOS_NATIVE_NETWORK=0 NIHOS_NATIVE_NORMAL_STORAGE=0 NIHOS_NATIVE_CAMERA_JPEG=1 sh tools/build-native.sh device`.
