# ESP-IDF owns the initial boot and final firmware link. The project component
# builds the Zig kernel entry as a freestanding static library.
cmake_minimum_required(VERSION 3.16)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(nihos)
