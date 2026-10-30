idf_component_register(SRCS "region_protect.c" REQUIRES hal)

# bootloader main already pulls this object with -u bootloader_hooks_include.
# Calls of esp_cpu_configure_region_protection must not reach the IDF copy:
# that copy locks entries 0, 1, and 15, and a lock cannot be cleared here.
target_link_libraries(${COMPONENT_LIB} INTERFACE "-Wl,--wrap=esp_cpu_configure_region_protection")
