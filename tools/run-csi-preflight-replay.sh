#!/bin/sh
# Host replay of the pinned IDF register layout; not a PHY simulator.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
zig=${NIHOS_ZIG:-"$repo_root/.tools/zig-0.17.0/zig"}
idf=${NIHOS_IDF_PATH:-${IDF_PATH:-"$HOME/esp32/esp-idf-v5.4.4"}}
config=${NIHOS_CSI_SDKCONFIG_DIR:-"$repo_root/build/native-device-devices-camera-id/loader/config"}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/nihos-csi-preflight.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
"$zig" cc -O2 -UNDEBUG -std=gnu17 -Wall -Wextra -Werror -Wno-unused-parameter \
    -I "$config" -I "$idf/components/hal/include" -I "$idf/components/hal/platform_port/include" \
    -I "$idf/components/hal/esp32p4/include" -I "$idf/components/soc/include" \
    -I "$idf/components/soc/esp32p4/include" -I "$idf/components/soc/esp32p4/register/hw_ver1" \
    -I "$idf/components/esp_common/include" -I "$idf/components/esp_hw_support/include" \
    -I "$idf/components/esp_rom/include" -I "$idf/components/esp_rom/esp32p4/include" \
    -I "$idf/components/esp_rom/esp32p4/include/esp32p4" -I "$idf/components/esp_rom/esp32p4" \
    "$repo_root/probes/camera/csi-prepare-replay.c" -o "$tmp/replay"
"$zig" cc -O2 -UNDEBUG -std=gnu17 -Wall -Wextra -Werror -Wno-unused-parameter \
    -I "$config" -I "$idf/components/hal/include" -I "$idf/components/hal/platform_port/include" \
    -I "$idf/components/hal/esp32p4/include" -I "$idf/components/soc/include" \
    -I "$idf/components/soc/esp32p4/include" -I "$idf/components/soc/esp32p4/register/hw_ver1" \
    -I "$idf/components/esp_common/include" -I "$idf/components/esp_hw_support/include" \
    -I "$idf/components/esp_rom/include" -I "$idf/components/esp_rom/esp32p4/include" \
    -I "$idf/components/esp_rom/esp32p4/include/esp32p4" -I "$idf/components/esp_rom/esp32p4" \
    "$repo_root/probes/camera/dma-transfer-replay.c" -o "$tmp/dma-replay"
"$tmp/replay"
"$tmp/dma-replay"

for name in csi-dma-config csi-dma-run csi-inflight-adapter xclk isp; do
    extra=
    case "$name" in xclk) extra=-Wno-int-to-pointer-cast ;; isp) extra=-Wno-pointer-to-int-cast ;; esac
    "$zig" cc -O2 -UNDEBUG -std=gnu17 -Wall -Wextra -Werror -Wno-unused-parameter $extra \
        -I "$config" -I "$idf/components/hal/include" -I "$idf/components/hal/platform_port/include" \
        -I "$idf/components/hal/esp32p4/include" -I "$idf/components/soc/include" \
        -I "$idf/components/soc/esp32p4/include" -I "$idf/components/soc/esp32p4/register/hw_ver1" \
        -I "$idf/components/esp_common/include" -I "$idf/components/esp_hw_support/include" \
        -I "$idf/components/esp_rom/include" -I "$idf/components/esp_rom/esp32p4/include" \
        -I "$idf/components/esp_rom/esp32p4/include/esp32p4" -I "$idf/components/esp_rom/esp32p4" \
        "$repo_root/probes/camera/$name-replay.c" -o "$tmp/$name"
    "$tmp/$name"
done
