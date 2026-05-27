cmake_minimum_required(VERSION 3.13)

include($ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(vibestick_rp2040 C CXX ASM)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

pico_sdk_init()

add_executable(vibestick_rp2040
    src/main.c
    src/usb_descriptors.c
)

target_include_directories(vibestick_rp2040 PRIVATE src)
target_link_libraries(vibestick_rp2040 PRIVATE pico_stdlib tinyusb_device tinyusb_board)

pico_add_extra_outputs(vibestick_rp2040)
