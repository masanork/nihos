#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "driver/i2c.h"
#include "driver/gpio.h"
#include "esp32_sdio_port.h"
#include "esp_loader.h"
#include "mbedtls/sha256.h"
/* Build-only experiment: manual GPIO9 strap required. No flash write API. */
static esp_err_t rd(uint8_t reg, uint8_t *v) { return i2c_master_write_read_device(I2C_NUM_0,0x44,&reg,1,v,1,pdMS_TO_TICKS(200)); }
static esp_err_t wr(uint8_t reg, uint8_t v) { uint8_t b[]={reg,v}; return i2c_master_write_to_device(I2C_NUM_0,0x44,b,sizeof(b),pdMS_TO_TICKS(200)); }
static bool power_on(void) {
    const i2c_config_t cfg={.mode=I2C_MODE_MASTER,.sda_io_num=31,.scl_io_num=32,.sda_pullup_en=GPIO_PULLUP_ENABLE,.scl_pullup_en=GPIO_PULLUP_ENABLE,.master.clk_speed=100000};
    if(i2c_param_config(I2C_NUM_0,&cfg)!=ESP_OK || i2c_driver_install(I2C_NUM_0,I2C_MODE_MASTER,0,0,0)!=ESP_OK) return false;
    uint8_t a,b,c,aa,bb,cc;
    bool ok=rd(5,&a)==ESP_OK && rd(3,&b)==ESP_OK && rd(7,&c)==ESP_OK && wr(5,a|1)==ESP_OK && wr(7,c&~1)==ESP_OK && wr(3,b|1)==ESP_OK && rd(5,&aa)==ESP_OK && rd(3,&bb)==ESP_OK && rd(7,&cc)==ESP_OK && aa==(uint8_t)(a|1) && bb==(uint8_t)(b|1) && cc==(uint8_t)(c&~1);
    i2c_driver_delete(I2C_NUM_0); return ok;
}
void app_main(void) {
    puts("BUILD ONLY: external C6 GPIO9 strap required; no flash writes.");
    puts("Type READ followed by newline after installing the GPIO9 low strap:");
    char gate[16];
    if (!fgets(gate, sizeof(gate), stdin) || strcmp(gate, "READ\n") != 0) { puts("Not armed"); return; }
    if(!power_on()) { puts("power error"); return; }
    esp32_sdio_port_t port={.port.ops=&esp32_sdio_ops,.slot=SDMMC_HOST_SLOT_1,.max_freq_khz=SDMMC_FREQ_DEFAULT,.reset_pin=GPIO_NUM_15,.boot_pin=GPIO_NUM_NC,.bus_width=SDIO_4BIT,.sdio_d0_pin=GPIO_NUM_11,.sdio_d1_pin=GPIO_NUM_10,.sdio_d2_pin=GPIO_NUM_9,.sdio_d3_pin=GPIO_NUM_8,.sdio_clk_pin=GPIO_NUM_12,.sdio_cmd_pin=GPIO_NUM_13};
    esp_loader_t loader;
    if(esp_loader_init_sdio(&loader,&port.port)!=ESP_LOADER_SUCCESS) { puts("init error"); return; }
    esp_loader_connect_args_t args=ESP_LOADER_CONNECT_DEFAULT();
    if(esp_loader_connect(&loader,&args)!=ESP_LOADER_SUCCESS) { puts("connect error"); return; }
    if(esp_loader_get_target(&loader)!=ESP32C6_CHIP) { puts("wrong target"); return; }
    esp_loader_target_security_info_t info;
    if (esp_loader_get_security_info(&loader,&info)!=ESP_LOADER_SUCCESS) { puts("security read error"); return; }
    printf("C6_SECURITY secure_boot=%d flash_encryption=%d secure_download=%d\n", info.secure_boot_enabled, info.flash_encryption_enabled, info.secure_download_mode_enabled);
    if (info.secure_download_mode_enabled || info.flash_encryption_enabled) { puts("protected flash; stop"); return; }
    uint32_t size=0;
    if(esp_loader_flash_detect_size(&loader,&size)!=ESP_LOADER_SUCCESS) { puts("flash size error"); return; }
    printf("C6_FLASH_SIZE=%lu\n",(unsigned long)size);
    static uint8_t first[4096],second[4096];
    if(esp_loader_flash_read(&loader,first,0x8000,sizeof(first))!=ESP_LOADER_SUCCESS || esp_loader_flash_read(&loader,second,0x8000,sizeof(second))!=ESP_LOADER_SUCCESS || memcmp(first,second,sizeof(first))) { puts("partition read mismatch"); return; }
    unsigned char hash[32]; mbedtls_sha256(first,3072,hash,0);
    printf("C6_PARTITION_3K_SHA256="); for(unsigned i=0;i<32;i++) printf("%02x",hash[i]); puts("");
    mbedtls_sha256_context ctx; mbedtls_sha256_init(&ctx); mbedtls_sha256_starts(&ctx,0);
    for (uint32_t off=0; off<0x8000; off+=sizeof(first)) {
        if (esp_loader_flash_read(&loader,first,off,sizeof(first))!=ESP_LOADER_SUCCESS ||
            esp_loader_flash_read(&loader,second,off,sizeof(second))!=ESP_LOADER_SUCCESS ||
            memcmp(first,second,sizeof(first))) { puts("bootloader read mismatch"); mbedtls_sha256_free(&ctx); return; }
        mbedtls_sha256_update(&ctx,first,sizeof(first));
    }
    mbedtls_sha256_finish(&ctx,hash); mbedtls_sha256_free(&ctx);
    printf("C6_BOOT_REGION_SHA256="); for(unsigned i=0;i<32;i++) printf("%02x",hash[i]); puts("");
    puts("Read only; remove GPIO9 strap before resetting C6.");
}
