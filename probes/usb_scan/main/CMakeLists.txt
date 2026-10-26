idf_component_register(SRCS "scan.c" INCLUDE_DIRS "."
                       PRIV_REQUIRES usb esp_driver_i2c esp_timer)
