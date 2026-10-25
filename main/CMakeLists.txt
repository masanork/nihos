idf_component_register(
    SRCS "../compat/espidf/platform.c"
    INCLUDE_DIRS "../include"
    PRIV_REQUIRES esp_system spi_flash heap esp_rom
)

if(NOT CMAKE_BUILD_EARLY_EXPANSION)
    set(NIHOS_ROOT "${CMAKE_CURRENT_LIST_DIR}/..")
    set(NIHOS_ZIG "${NIHOS_ROOT}/.tools/zig-0.17.0/zig")
    set(NIHOS_ZIG_SOURCE "${NIHOS_ROOT}/src/platform/espidf_main.zig")
    set(NIHOS_ZIG_ABI "${NIHOS_ROOT}/src/platform/abi.zig")
    set(NIHOS_ZIG_LIBRARY "${CMAKE_CURRENT_BINARY_DIR}/libnihos_zig.a")

    if(NOT EXISTS "${NIHOS_ZIG}")
        message(FATAL_ERROR
            "Zig 0.17.0 not found. Run: sh tools/bootstrap-zig.sh")
    endif()

    add_custom_command(
        OUTPUT "${NIHOS_ZIG_LIBRARY}"
        COMMAND "${NIHOS_ZIG}" build-lib
            -target riscv32-freestanding-none
            -mcpu=generic_rv32+m+a+c+f+zicsr+zifencei
            -Osafe
            -fstrip
            "-femit-bin=${NIHOS_ZIG_LIBRARY}"
            "${NIHOS_ZIG_SOURCE}"
        DEPENDS "${NIHOS_ZIG_SOURCE}" "${NIHOS_ZIG_ABI}"
        COMMENT "Building the freestanding nihOS Zig entry"
        VERBATIM
    )
    add_custom_target(nihos_zig_archive DEPENDS "${NIHOS_ZIG_LIBRARY}")

    add_dependencies(${COMPONENT_LIB} nihos_zig_archive)
    target_link_libraries(${COMPONENT_LIB} INTERFACE "${NIHOS_ZIG_LIBRARY}")
endif()
