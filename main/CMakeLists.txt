idf_component_register(
    SRCS "../compat/espidf/platform.c"
         "../compat/espidf/native_timer.c"
         "../src/arch/riscv32/trap_entry.S"
         "../src/arch/riscv32/fpu.S"
    INCLUDE_DIRS "../include" "../src/arch/riscv32" "../src/kernel"
    PRIV_REQUIRES esp_system spi_flash heap esp_rom esp_mm esp_hw_support
                  esp_timer esp_driver_gptimer esp_lcd esp_lcd_touch
                  m5stack_tab5_noglib
)

if(NOT CMAKE_BUILD_EARLY_EXPANSION)
    # Only the bring-up resource lease depends on IDF's private channel map.
    target_include_directories(${COMPONENT_LIB} PRIVATE
        "$ENV{IDF_PATH}/components/esp_driver_gptimer/src")
    set(NIHOS_ROOT "${CMAKE_CURRENT_LIST_DIR}/..")
    set(NIHOS_ZIG "${NIHOS_ROOT}/.tools/zig-0.17.0/zig")
    set(NIHOS_ZIG_SOURCE "${NIHOS_ROOT}/src/platform/espidf_main.zig")
    set(NIHOS_ZIG_NATIVE_TRAP "${NIHOS_ROOT}/src/arch/riscv32/native_trap.zig")
    set(NIHOS_ZIG_CONTEXT "${NIHOS_ROOT}/src/arch/riscv32/context.zig")
    set(NIHOS_ZIG_TRAP "${NIHOS_ROOT}/src/arch/riscv32/trap.zig")
    set(NIHOS_ZIG_TIMER_GROUP "${NIHOS_ROOT}/src/soc/esp32p4/timer_group.zig")
    set(NIHOS_ZIG_PREEMPTION "${NIHOS_ROOT}/src/arch/riscv32/preemption_test.zig")
    set(NIHOS_ZIG_SCHEDULER "${NIHOS_ROOT}/src/kernel/scheduler.zig")
    set(NIHOS_ZIG_TICK_CLOCK "${NIHOS_ROOT}/src/kernel/tick_clock.zig")
    set(NIHOS_ZIG_TASK_CONTROL "${NIHOS_ROOT}/src/kernel/task_control.zig")
    set(NIHOS_ZIG_TASK_NUMBERS "${NIHOS_ROOT}/src/kernel/task_call_numbers.inc")
    set(NIHOS_ZIG_TASK_RUNTIME "${NIHOS_ROOT}/src/arch/riscv32/task_runtime.zig")
    set(NIHOS_ZIG_TASK_CALLS "${NIHOS_ROOT}/src/arch/riscv32/task_calls.zig")
    set(NIHOS_ZIG_LIFECYCLE "${NIHOS_ROOT}/src/arch/riscv32/lifecycle_test.zig")
    set(NIHOS_ZIG_IPC_SCENARIO "${NIHOS_ROOT}/src/arch/riscv32/ipc_scenario.zig")
    set(NIHOS_ZIG_REMOTE_SCENARIO "${NIHOS_ROOT}/src/arch/riscv32/remote_scenario.zig")
    set(NIHOS_ZIG_REMOTE_EVENTS "${NIHOS_ROOT}/src/kernel/remote_events.zig")
    set(NIHOS_ZIG_SOFTWARE_IPI "${NIHOS_ROOT}/src/soc/esp32p4/software_ipi.zig")
    set(NIHOS_ZIG_CHANNEL "${NIHOS_ROOT}/src/kernel/spsc_channel.zig")
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
            --dep timer_group
            --dep scheduler
            --dep tick_clock
            --dep task_control
            --dep spsc_ring
            --dep spsc_channel
            --dep remote_events
            --dep software_ipi
            "-Mnative_trap=${NIHOS_ZIG_NATIVE_TRAP}"
            "-Mtimer_group=${NIHOS_ZIG_TIMER_GROUP}"
            "-Mscheduler=${NIHOS_ZIG_SCHEDULER}"
            "-Mtick_clock=${NIHOS_ZIG_TICK_CLOCK}"
            "-Mtask_control=${NIHOS_ZIG_TASK_CONTROL}"
            "-Mspsc_ring=${NIHOS_ZIG_SPSC}"
            "-Mspsc_channel=${NIHOS_ZIG_CHANNEL}"
            "-Mremote_events=${NIHOS_ZIG_REMOTE_EVENTS}"
            "-Msoftware_ipi=${NIHOS_ZIG_SOFTWARE_IPI}"
            "-Mtick_counter=${NIHOS_ZIG_TICK_COUNTER}"
            "-Mtest_pattern=${NIHOS_ZIG_PATTERN}"
            "-femit-bin=${NIHOS_ZIG_LIBRARY}"
        DEPENDS "${NIHOS_ZIG_SOURCE}" "${NIHOS_ZIG_ABI}"
                "${NIHOS_ZIG_NATIVE_TRAP}" "${NIHOS_ZIG_CONTEXT}"
                "${NIHOS_ZIG_TRAP}" "${NIHOS_ZIG_TIMER_GROUP}"
                "${NIHOS_ZIG_PREEMPTION}" "${NIHOS_ZIG_SCHEDULER}"
                "${NIHOS_ZIG_TICK_CLOCK}"
                "${NIHOS_ZIG_TASK_CONTROL}" "${NIHOS_ZIG_TASK_NUMBERS}"
                "${NIHOS_ZIG_TASK_RUNTIME}" "${NIHOS_ZIG_TASK_CALLS}"
                "${NIHOS_ZIG_LIFECYCLE}"
                "${NIHOS_ZIG_IPC_SCENARIO}" "${NIHOS_ZIG_CHANNEL}"
                "${NIHOS_ZIG_REMOTE_SCENARIO}" "${NIHOS_ZIG_REMOTE_EVENTS}"
                "${NIHOS_ZIG_SOFTWARE_IPI}"
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
