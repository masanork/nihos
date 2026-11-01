#!/usr/bin/env python3
"""Apply the experimental Tab5 overlay to a clean pinned Hosted checkout."""
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent
REV = "4e029441bc0322b368c19767d91d84c6de197ba1"
tree = pathlib.Path(sys.argv[1]).resolve()
head = subprocess.check_output(["git", "-C", str(tree), "rev-parse", "HEAD"], text=True).strip()
if head != REV:
    sys.exit(f"Expected Hosted {REV}, got {head}")
example = tree / "examples/wifi/sta/cp"
main = example / "main"
defaults = example / "sdkconfig.defaults.esp32c6"
tracked = ["examples/wifi/sta/cp/sdkconfig.defaults.esp32c6",
           "examples/wifi/sta/cp/main/CMakeLists.txt", "examples/wifi/sta/cp/main/main.c"]
if subprocess.run(["git", "-C", str(tree), "diff", "--quiet", "HEAD", "--", *tracked]).returncode:
    sys.exit("Example files have local changes; use a clean checkout")
files = ("nihos_time_service.c", "nihos_time_service.h", "nihos_time_wire.c", "nihos_time_wire.h",
         "nihos_ota_info_service.c", "nihos_ota_info_wire.c", "nihos_ota_info_wire.h")
if any((main / f).exists() for f in files) or (example / "partitions.tab5-c6.csv").exists():
    sys.exit("Overlay files already exist; use a clean checkout")
for file in files:
    shutil.copyfile(ROOT / file, main / file)
shutil.copyfile(ROOT.parent / "esp-hosted-c6-time/reproduction/partitions.tab5-c6.csv", example / "partitions.tab5-c6.csv")
with defaults.open("a") as f:
    f.write('''\n# nihos Tab5 Hosted 3 overlay
CONFIG_PARTITION_TABLE_CUSTOM_FILENAME="partitions.tab5-c6.csv"
CONFIG_EH_TRANSPORT_CP_SDIO=y
CONFIG_EH_TRANSPORT_CP_SDIO_MODE_STREAM=y
CONFIG_ESP_HOSTED_CP_FEAT_NW_SPLIT=y
# CONFIG_ESP_HOSTED_CP_FEAT_NW_SPLIT_WIFI_AUTO_CONNECT_ON_STA_START is not set
CONFIG_ESP_HOSTED_CP_FEAT_PEER_DATA=y
# CONFIG_ESP_HOSTED_AUTO_CALL_INIT_BEFORE_APP_MAIN is not set
CONFIG_BT_ENABLED=y
CONFIG_BT_CONTROLLER_ONLY=y
CONFIG_BT_LE_HCI_INTERFACE_USE_RAM=y
CONFIG_ESP_HOSTED_CP_FEAT_BT=y
''')
cmake = main / "CMakeLists.txt"
cmake.write_text('''idf_component_register(SRCS "main.c" "nihos_time_service.c" "nihos_time_wire.c" "nihos_ota_info_service.c" "nihos_ota_info_wire.c"
    INCLUDE_DIRS "."
    REQUIRES esp_hosted
    PRIV_REQUIRES nvs_flash esp_wifi esp_netif esp_timer app_update bootloader_support spi_flash)
target_include_directories(${COMPONENT_LIB} PRIVATE
    "${CMAKE_CURRENT_LIST_DIR}/../../../../../coprocessor/eh_cp_core/include"
    "${CMAKE_CURRENT_LIST_DIR}/../../../../../coprocessor/features/eh_cp_feat_peer_data/include"
    "${CMAKE_CURRENT_LIST_DIR}/../../../../../common/eh_common/include")
''')
app = main / "main.c"
source = app.read_text()
source = source.replace('#include "esp_check.h"', '#include "esp_check.h"\n#include "nihos_time_service.h"\n#include "eh_cp.h"\nvoid nihos_ota_info_link_anchor(void);')
source = source.replace('    ESP_LOGI(TAG, "ESP-Hosted MCU WiFi Example Starting...");', '    nihos_time_service_link_anchor();\n    nihos_ota_info_link_anchor();\n    ESP_LOGI(TAG, "ESP-Hosted MCU WiFi Example Starting...");')
source = source.replace('    ESP_ERROR_CHECK(esp_event_loop_create_default());', '    ESP_ERROR_CHECK(esp_event_loop_create_default());\n    ESP_ERROR_CHECK(eh_cp_init());')
app.write_text(source)
