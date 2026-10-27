/* SPDX-License-Identifier: MIT
 * Temporary ESP-IDF diagnostic, separate from the native nihOS kernel.
 * Enumerates USB descriptors only; sends no smart-card commands.
 */
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include "driver/i2c_master.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "hal/usb_dwc_ll.h"
#include "usb/usb_host.h"

static const char *TAG = "usb_scan";
static bool pending[128];
static uint32_t enumerated;
static uint8_t saved[3];
static const uint8_t power_regs[] = {0x05, 0x03, 0x07};

static void reg_write(i2c_master_dev_handle_t dev, uint8_t reg, uint8_t value)
{
    const uint8_t data[] = {reg, value};
    ESP_ERROR_CHECK(i2c_master_transmit(dev, data, sizeof(data), 100));
}

static i2c_master_dev_handle_t power_init(void)
{
    const i2c_master_bus_config_t bus_config = {
        .i2c_port = I2C_NUM_0, .sda_io_num = 31, .scl_io_num = 32,
        .clk_source = I2C_CLK_SRC_DEFAULT, .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true,
    };
    i2c_master_bus_handle_t bus;
    ESP_ERROR_CHECK(i2c_new_master_bus(&bus_config, &bus));
    const i2c_device_config_t config = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = 0x44, .scl_speed_hz = 100000,
    };
    i2c_master_dev_handle_t dev;
    ESP_ERROR_CHECK(i2c_master_bus_add_device(bus, &config, &dev));
    for (size_t i = 0; i < sizeof(power_regs); ++i) {
        ESP_ERROR_CHECK(i2c_master_transmit_receive(dev, &power_regs[i], 1,
                                                   &saved[i], 1, 100));
    }
    ESP_LOGI(TAG, "power_before output=%02x direction=%02x highz=%02x",
             saved[0], saved[1], saved[2]);
    // PI4IOE5V6408 at 0x44, bit 3 = USB5V_EN. Preserve all other pins.
    // Set the output latch first, then output direction and push-pull mode.
    reg_write(dev, 0x05, saved[0] | 0x08);
    reg_write(dev, 0x03, saved[1] | 0x08);
    reg_write(dev, 0x07, saved[2] & (uint8_t)~0x08);
    ESP_LOGI(TAG, "USB-A 5V enabled (0x44 bit 3)");
    return dev;
}

static void client_event(const usb_host_client_event_msg_t *event, void *arg)
{
    (void)arg;
    if (event->event == USB_HOST_CLIENT_EVENT_NEW_DEV &&
        event->new_dev.address < 128) {
        pending[event->new_dev.address] = true;
    }
}

static void dump_device(usb_host_client_handle_t client, uint8_t address)
{
    usb_device_handle_t dev;
    esp_err_t error = usb_host_device_open(client, address, &dev);
    if (error != ESP_OK) {
        ESP_LOGW(TAG, "open address=%u: %s", address, esp_err_to_name(error));
        return;
    }
    const usb_device_desc_t *desc;
    const usb_config_desc_t *config;
    usb_device_info_t info;
    error = usb_host_get_device_descriptor(dev, &desc);
    if (error == ESP_OK) {
        ++enumerated;
        ESP_LOGI(TAG, "DEVICE address=%u vid=%04x pid=%04x class=%02x "
                 "subclass=%02x protocol=%02x", address, desc->idVendor,
                 desc->idProduct, desc->bDeviceClass, desc->bDeviceSubClass,
                 desc->bDeviceProtocol);
        usb_print_device_descriptor(desc);
    }
    if (usb_host_device_info(dev, &info) == ESP_OK) {
        ESP_LOGI(TAG, "speed=%d (0=low,1=full,2=high)", info.speed);
        if (info.str_desc_manufacturer) {
            printf("MANUFACTURER ");
            usb_print_string_descriptor(info.str_desc_manufacturer);
        }
        if (info.str_desc_product) {
            printf("PRODUCT ");
            usb_print_string_descriptor(info.str_desc_product);
        }
    }
    if (usb_host_get_active_config_descriptor(dev, &config) == ESP_OK) {
        usb_print_config_descriptor(config, NULL);
        // Keep the complete configuration, including class-specific descriptors.
        const uint8_t *raw = (const uint8_t *)config;
        printf("CONFIG_HEX ");
        for (unsigned i = 0; i < config->wTotalLength; ++i) printf("%02x", raw[i]);
        printf("\n");
        unsigned offset = config->bLength;
        while (offset + 2 <= config->wTotalLength) {
            unsigned length = raw[offset];
            if (length < 2 || offset + length > config->wTotalLength) {
                ESP_LOGW(TAG, "malformed descriptor at %u", offset);
                break;
            }
            if (raw[offset + 1] == 4 && length >= 9) {
                ESP_LOGI(TAG, "INTERFACE number=%u alternate=%u class=%02x "
                         "subclass=%02x protocol=%02x%s", raw[offset + 2],
                         raw[offset + 3], raw[offset + 5], raw[offset + 6],
                         raw[offset + 7], raw[offset + 5] == 0x0b ? " smart-card" : "");
            }
            offset += length;
        }
    }
    ESP_ERROR_CHECK_WITHOUT_ABORT(usb_host_device_close(client, dev));
    fflush(stdout);
}

void app_main(void)
{
    ESP_LOGI(TAG, "NIHOS_USB_SCAN_BEGIN hosted=esp-idf duration_s=30");
    i2c_master_dev_handle_t power = power_init();
    const usb_host_config_t host = {
        .skip_phy_setup = false, .intr_flags = ESP_INTR_FLAG_LEVEL1,
        .peripheral_map = 1, // P4 high-speed OTG / UTMI, Tab5 USB-A.
    };
    ESP_ERROR_CHECK(usb_host_install(&host));
    const usb_host_client_config_t client_config = {
        .is_synchronous = false, .max_num_event_msg = 8,
        .async = {.client_event_callback = client_event},
    };
    usb_host_client_handle_t client;
    ESP_ERROR_CHECK(usb_host_client_register(&client_config, &client));
    const int64_t deadline = esp_timer_get_time() + INT64_C(30000000);
    int64_t next_status = 0;
    while (esp_timer_get_time() < deadline) {
        uint32_t flags;
        ESP_ERROR_CHECK(usb_host_lib_handle_events(0, &flags));
        esp_err_t error = usb_host_client_handle_events(client, 0);
        if (error != ESP_OK && error != ESP_ERR_TIMEOUT) ESP_ERROR_CHECK(error);
        for (unsigned address = 1; address < 128; ++address) {
            if (pending[address]) {
                pending[address] = false;
                dump_device(client, address);
            }
        }
        if (esp_timer_get_time() >= next_status) {
            usb_host_lib_info_t info;
            ESP_ERROR_CHECK(usb_host_lib_info(&info));
            ESP_LOGI(TAG, "STATUS devices=%d enumerated=%" PRIu32 " connected=%u",
                     info.num_devices, enumerated,
                     (unsigned)usb_dwc_ll_hprt_get_conn_status(USB_DWC_LL_GET_HW(0)));
            next_status = esp_timer_get_time() + INT64_C(5000000);
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
    ESP_ERROR_CHECK(usb_host_client_deregister(client));
    esp_err_t free_result = usb_host_device_free_all();
    if (free_result == ESP_ERR_NOT_FINISHED) {
        uint32_t flags;
        do {
            ESP_ERROR_CHECK(usb_host_lib_handle_events(portMAX_DELAY, &flags));
        } while (!(flags & USB_HOST_LIB_EVENT_FLAGS_ALL_FREE));
    } else {
        ESP_ERROR_CHECK(free_result);
    }
    ESP_ERROR_CHECK(usb_host_uninstall());
    // Restore expander state before the original firmware is reinstalled.
    for (size_t i = 0; i < sizeof(power_regs); ++i) reg_write(power, power_regs[i], saved[i]);
    ESP_LOGI(TAG, "NIHOS_USB_SCAN_END enumerated=%" PRIu32 " power_restored=1", enumerated);
}
