idf_component_register(
    SRCS "../compat/espidf/platform.c"
         "../src/arch/riscv32/trap_entry.S"
    INCLUDE_DIRS "../include" "../src/arch/riscv32"
    PRIV_REQUIRES esp_system spi_flash heap esp_rom esp_mm esp_hw_support
                  esp_timer esp_driver_gptimer esp_lcd esp_lcd_touch
                  m5stack_tab5_noglib
)

if(NOT CMAKE_BUILD_EARLY_EXPANSION)
    set(NIHOS_ROOT "${CMAKE_CURRENT_LIST_DIR}/..")
    set(NIHOS_ZIG "${NIHOS_ROOT}/.tools/zig-0.17.0/zig")
    set(NIHOS_ZIG_SOURCE "${NIHOS_ROOT}/src/platform/espidf_main.zig")
    set(NIHOS_ZIG_NATIVE_TRAP "${NIHOS_ROOT}/src/arch/riscv32/native_trap.zig")
    set(NIHOS_ZIG_CONTEXT "${NIHOS_ROOT}/src/arch/riscv32/context.zig")
    set(NIHOS_ZIG_TRAP "${NIHOS_ROOT}/src/arch/riscv32/trap.zig")
    set(NIHOS_ZIG_ABI "${NIHOS_ROOT}/src/platform/abi.zig")
    set(NIHOS_ZIG_ARENA "${NIHOS_ROOT}/src/kernel/arena.zig")
    set(NIHOS_ZIG_SPSC "${NIHOS_ROOT}/src/kernel/spsc_ring.zig")
    set(NIHOS_ZIG_TICK_COUNTER "${NIHOS_ROOT}/src/kernel/tick_counter.zig")
    set(NIHOS_ZIG_PATTERN "${NIHOS_ROOT}/src/graphics/test_pattern.zig")
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
            --dep abi
            --dep arena
            --dep native_trap
            --dep spsc_ring
            --dep tick_counter
            --dep test_pattern
            "-Mroot=${NIHOS_ZIG_SOURCE}"
            "-Mabi=${NIHOS_ZIG_ABI}"
            "-Marena=${NIHOS_ZIG_ARENA}"
            "-Mnative_trap=${NIHOS_ZIG_NATIVE_TRAP}"
            "-Mspsc_ring=${NIHOS_ZIG_SPSC}"
            "-Mtick_counter=${NIHOS_ZIG_TICK_COUNTER}"
            "-Mtest_pattern=${NIHOS_ZIG_PATTERN}"
            "-femit-bin=${NIHOS_ZIG_LIBRARY}"
        DEPENDS "${NIHOS_ZIG_SOURCE}" "${NIHOS_ZIG_ABI}"
                "${NIHOS_ZIG_NATIVE_TRAP}" "${NIHOS_ZIG_CONTEXT}"
                "${NIHOS_ZIG_TRAP}"
                "${NIHOS_ZIG_ARENA}" "${NIHOS_ZIG_SPSC}"
                "${NIHOS_ZIG_TICK_COUNTER}"
                "${NIHOS_ZIG_PATTERN}"
        COMMENT "Building the freestanding nihOS Zig entry"
        VERBATIM
    )
    add_custom_target(nihos_zig_archive DEPENDS "${NIHOS_ZIG_LIBRARY}")

    add_dependencies(${COMPONENT_LIB} nihos_zig_archive)
    target_link_options(${COMPONENT_LIB} INTERFACE
        "LINKER:--undefined=nih_riscv_exception_roundtrip")
    target_link_libraries(${COMPONENT_LIB} INTERFACE "${NIHOS_ZIG_LIBRARY}")
endif()
