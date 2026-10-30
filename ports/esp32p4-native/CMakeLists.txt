# The second-stage bootloader and partition table are built here.
# bootloader_components/region_protect denies PMP entries 0 and 1 to U-mode
# (unlocked NAPOT, no R/W/X) and leaves entry 15 OFF.
# The native app is linked separately by Zig; this project has no app sources.
cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(nihos_native_loader)
