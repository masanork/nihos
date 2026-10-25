# Only the stock second-stage bootloader and partition table are built here.
# The native app is linked separately by Zig; this project has no app sources.
cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(nihos_native_loader)
