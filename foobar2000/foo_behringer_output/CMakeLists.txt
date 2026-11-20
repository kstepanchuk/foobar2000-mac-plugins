cmake_minimum_required(VERSION 3.24)
project(foo_behringer_output VERSION 0.1.0 LANGUAGES C CXX OBJC OBJCXX)
file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/version.h" COMPONENT_VERSION_LINE REGEX "^#define COMPONENT_VERSION ")
string(REGEX REPLACE ".*\"([^\"]+)\".*" "\\1" COMPONENT_VERSION "${COMPONENT_VERSION_LINE}")
if(NOT COMPONENT_VERSION)
  message(FATAL_ERROR "Could not read COMPONENT_VERSION from version.h")
endif()
set(PROJECT_VERSION "${COMPONENT_VERSION}")

if(NOT APPLE)
  message(FATAL_ERROR "This component requires macOS CoreAudio.")
endif()

set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "Minimum macOS version")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "Target architectures")
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Reuse the foobar2000 SDK already included at the repository root.
get_filename_component(REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(PFC_ROOT "${REPO_ROOT}/pfc")
set(FB2K_ROOT "${REPO_ROOT}/foobar2000")
set(SDK_ROOT "${FB2K_ROOT}/SDK")
set(HELPERS_ROOT "${FB2K_ROOT}/helpers")
set(SHARED_ROOT "${FB2K_ROOT}/shared")

add_library(fb2k_sdk_includes INTERFACE)
target_include_directories(fb2k_sdk_includes INTERFACE
  "${REPO_ROOT}" "${FB2K_ROOT}" "${SDK_ROOT}" "${SHARED_ROOT}"
  "${HELPERS_ROOT}" "${PFC_ROOT}")

function(fb2k_sdk_lib name std prefix)
  target_link_libraries(${name} PRIVATE fb2k_sdk_includes)
  set_target_properties(${name} PROPERTIES CXX_STANDARD ${std} C_STANDARD 11)
  if(NOT prefix STREQUAL "")
    target_compile_options(${name} PRIVATE -include "${prefix}")
  endif()
endfunction()

file(GLOB PFC_SOURCES CONFIGURE_DEPENDS "${PFC_ROOT}/*.cpp" "${PFC_ROOT}/*.mm")
add_library(pfc STATIC ${PFC_SOURCES})
fb2k_sdk_lib(pfc 20 "${PFC_ROOT}/pfc-lite.h")

file(GLOB FB2K_SDK_SOURCES CONFIGURE_DEPENDS "${SDK_ROOT}/*.cpp" "${SDK_ROOT}/*.mm")
add_library(foobar2000_SDK STATIC ${FB2K_SDK_SOURCES})
fb2k_sdk_lib(foobar2000_SDK 20 "${SDK_ROOT}/foobar2000-sdk-pch.h")
target_link_libraries(foobar2000_SDK PRIVATE pfc)

file(GLOB FB2K_HELPERS_SOURCES CONFIGURE_DEPENDS "${HELPERS_ROOT}/*.cpp" "${HELPERS_ROOT}/*.mm")
list(FILTER FB2K_HELPERS_SOURCES EXCLUDE REGEX
  "/(AutoComplete|CTableEditHelper-Legacy|DarkMode|WindowPositionUtils|image_load_save|inplace_edit|ui_element_helpers|win32_dialog|window_placement_helper)\\.cpp$")
add_library(foobar2000_SDK_helpers STATIC ${FB2K_HELPERS_SOURCES})
fb2k_sdk_lib(foobar2000_SDK_helpers 20 "${HELPERS_ROOT}/StdAfx.h")
target_link_libraries(foobar2000_SDK_helpers PRIVATE pfc foobar2000_SDK)

add_library(foobar2000_component_client STATIC
  "${FB2K_ROOT}/foobar2000_component_client/component_client.cpp")
fb2k_sdk_lib(foobar2000_component_client 20 "")
target_link_libraries(foobar2000_component_client PRIVATE pfc foobar2000_SDK)

file(GLOB SHARED_SOURCES CONFIGURE_DEPENDS "${SHARED_ROOT}/*.cpp" "${SHARED_ROOT}/*.mm")
list(FILTER SHARED_SOURCES EXCLUDE REGEX
  "/(Utility|crash_info|filedialogs|filedialogs_vista|font_description|minidump|modal_dialog|systray|text_drawing|utf8api)\\.cpp$")
add_library(shared STATIC ${SHARED_SOURCES})
fb2k_sdk_lib(shared 20 "${SHARED_ROOT}/shared.h")
target_link_libraries(shared PRIVATE pfc)

add_library(foo_behringer_output MODULE main.cpp src/multichannel_output.cpp)
set(MACOSX_BUNDLE_GUI_IDENTIFIER "ru.nanor.foo-behringer-output")
configure_file(cmake/Info.plist.in "${CMAKE_CURRENT_BINARY_DIR}/Info.plist" @ONLY)
set_target_properties(foo_behringer_output PROPERTIES
  BUNDLE TRUE BUNDLE_EXTENSION "component" OUTPUT_NAME "foo_behringer_output"
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist")
target_compile_options(foo_behringer_output PRIVATE -include "${CMAKE_CURRENT_SOURCE_DIR}/src/predef.h")
target_include_directories(foo_behringer_output PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_link_libraries(foo_behringer_output PRIVATE
  fb2k_sdk_includes foobar2000_component_client foobar2000_SDK_helpers foobar2000_SDK shared pfc
  "-framework CoreAudio" "-framework AudioToolbox" "-framework Cocoa")
add_custom_command(TARGET foo_behringer_output POST_BUILD
  COMMAND codesign --force --timestamp=none --sign "-" "$<TARGET_BUNDLE_DIR:foo_behringer_output>"
  COMMENT "Ad-hoc signing foobar2000 component bundle"
  VERBATIM)
