# SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
# SPDX-License-Identifier: GPL-3.0-or-later

# Lichii for iOS: an app bundle around the SDL3 frontend (yuzu_cmd's window classes) with a UIKit
# game list, on-screen controls and controller support. The bundle is unsigned; sideloading tools
# sign it. MoltenVK.framework is copied into Frameworks/ from IOS_MOLTENVK_FRAMEWORK.

enable_language(OBJCXX)

set(IOS_MOLTENVK_FRAMEWORK "" CACHE PATH "Path to an iOS arm64 MoltenVK.framework")
set(LICHII_IOS_BUNDLE_ID "io.github.lichii.ios" CACHE STRING "CFBundleIdentifier of the iOS app")

set(YUZU_CMD_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../yuzu_cmd)

add_executable(lichii_ios MACOSX_BUNDLE
    ios_main.mm
    ios_ui.h
    ios_ui.mm
    ${YUZU_CMD_DIR}/emu_window/emu_window_sdl3.cpp
    ${YUZU_CMD_DIR}/emu_window/emu_window_sdl3.h
    ${YUZU_CMD_DIR}/emu_window/emu_window_sdl3_null.cpp
    ${YUZU_CMD_DIR}/emu_window/emu_window_sdl3_null.h
    ${YUZU_CMD_DIR}/emu_window/emu_window_sdl3_vk.cpp
    ${YUZU_CMD_DIR}/emu_window/emu_window_sdl3_vk.h
    ${YUZU_CMD_DIR}/sdl_config.cpp
    ${YUZU_CMD_DIR}/sdl_config.h
)

# yuzu_cmd sources include "yuzu_cmd/..." and the generated window icon header (same generator as
# src/yuzu_cmd, which is not configured on iOS).
file(READ "${CMAKE_SOURCE_DIR}/dist/eden.bmp" yuzu_icon_hex HEX)
string(REGEX REPLACE "([0-9a-f][0-9a-f])" "0x\\1," yuzu_icon_hex ${yuzu_icon_hex})
file(WRITE "${PROJECT_BINARY_DIR}/dist/yuzu_cmd/yuzu_icon.h"
    "const unsigned char yuzu_icon[] = {${yuzu_icon_hex}};\nconst unsigned yuzu_icon_size = sizeof(yuzu_icon);\n")
target_include_directories(lichii_ios PRIVATE ${PROJECT_BINARY_DIR}/dist ${CMAKE_CURRENT_SOURCE_DIR}/..)

target_link_libraries(lichii_ios PRIVATE common core input_common frontend_common video_core network
    SDL3::SDL3 ${PLATFORM_LIBRARIES} Threads::Threads)

target_compile_options(lichii_ios PRIVATE
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
    $<$<COMPILE_LANGUAGE:C,CXX,OBJCXX>:-Wno-conversion>
    $<$<COMPILE_LANGUAGE:C,CXX,OBJCXX>:-Wno-unused-variable>
    $<$<COMPILE_LANGUAGE:C,CXX,OBJCXX>:-Wno-unused-parameter>
    $<$<COMPILE_LANGUAGE:C,CXX,OBJCXX>:-Wno-missing-field-initializers>
    $<$<COMPILE_LANGUAGE:C,CXX,OBJCXX>:-Wno-shadow>)

set_target_properties(lichii_ios PROPERTIES
    OUTPUT_NAME "Lichii"
    MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in
    MACOSX_BUNDLE_GUI_IDENTIFIER ${LICHII_IOS_BUNDLE_ID}
    MACOSX_BUNDLE_BUNDLE_NAME "Lichii"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0"
    MACOSX_BUNDLE_BUNDLE_VERSION "1"
    BUILD_RPATH "@executable_path/Frameworks"
    INSTALL_RPATH "@executable_path/Frameworks")

# App icon (legacy CFBundleIconFiles, so no asset catalog compiler is needed).
add_custom_command(TARGET lichii_ios POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_SOURCE_DIR}/dist/lichii.png"
            "$<TARGET_BUNDLE_DIR:lichii_ios>/lichii.png"
    VERBATIM)

if (IOS_MOLTENVK_FRAMEWORK)
    add_custom_command(TARGET lichii_ios POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_BUNDLE_DIR:lichii_ios>/Frameworks"
        COMMAND ${CMAKE_COMMAND} -E copy_directory "${IOS_MOLTENVK_FRAMEWORK}"
                "$<TARGET_BUNDLE_DIR:lichii_ios>/Frameworks/MoltenVK.framework"
        VERBATIM)
else()
    message(WARNING "IOS_MOLTENVK_FRAMEWORK is not set: the app will have no Vulkan driver")
endif()
