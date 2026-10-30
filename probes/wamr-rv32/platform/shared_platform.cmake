# Compile/test model only. The two nihos owner hooks remain unresolved on RV32.
add_definitions(-DBH_PLATFORM_NIHOS_COMPILE_ONLY)
include_directories(${CMAKE_CURRENT_LIST_DIR})
include_directories(${WAMR_ROOT_DIR}/core/shared/platform/include)
include(${WAMR_ROOT_DIR}/core/shared/platform/common/math/platform_api_math.cmake)
set(PLATFORM_SHARED_SOURCE
    ${CMAKE_CURRENT_LIST_DIR}/nihos_platform.c
    ${PLATFORM_COMMON_MATH_SOURCE})
