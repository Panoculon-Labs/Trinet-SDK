cmake_minimum_required(VERSION 3.22.1)
project(trinet_native LANGUAGES C CXX)

# ---------------------------------------------------------------------------
# Dependencies — fetched once, then cached under build/_deps.
# libusb-cmake provides an official CMake wrapper around libusb 1.0.
# libuvc is the upstream H.264/MJPEG UVC decoder.
# ---------------------------------------------------------------------------
include(FetchContent)
set(FETCHCONTENT_QUIET OFF)

# libusb (the cmake wrapper) — built as a shared library so libuvc and
# trinet_native share a single libusb instance (otherwise each .so would carry
# its own static copy and contexts created in one would be invalid in the other).
set(LIBUSB_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LIBUSB_BUILD_TESTING  OFF CACHE BOOL "" FORCE)
set(LIBUSB_INSTALL_TARGETS OFF CACHE BOOL "" FORCE)
set(LIBUSB_ENABLE_UDEV    OFF CACHE BOOL "" FORCE)
set(LIBUSB_BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)
FetchContent_Declare(
    libusb_cmake
    GIT_REPOSITORY https://github.com/libusb/libusb-cmake.git
    GIT_TAG        v1.0.27-1
    GIT_SHALLOW    TRUE
)
FetchContent_MakeAvailable(libusb_cmake)

# libuvc — its CMakeLists calls find_package(LibUSB), which expects an
# imported target named LibUSB::LibUSB. libusb-cmake exposes the library as
# `usb-1.0`, so we create an INTERFACE wrapper that points to it.
add_library(_libusb_iface INTERFACE)
target_link_libraries(_libusb_iface INTERFACE usb-1.0)
target_include_directories(_libusb_iface INTERFACE
    "${libusb_cmake_SOURCE_DIR}/libusb/libusb"
)
add_library(LibUSB::LibUSB ALIAS _libusb_iface)
set(LibUSB_FOUND TRUE)
set(LibUSB_INCLUDE_DIRS "${libusb_cmake_SOURCE_DIR}/libusb/libusb")
set(LibUSB_LIBRARIES usb-1.0)

set(BUILD_UVC_TESTS OFF CACHE BOOL "" FORCE)
set(BUILD_EXAMPLE   OFF CACHE BOOL "" FORCE)
set(CMAKE_BUILD_TARGET "Shared" CACHE STRING "" FORCE)
FetchContent_Declare(
    libuvc
    GIT_REPOSITORY https://github.com/libuvc/libuvc.git
    GIT_TAG        v0.0.7
    GIT_SHALLOW    TRUE
)
FetchContent_MakeAvailable(libuvc)

# ---------------------------------------------------------------------------
# trinet_native — the JNI shim consumed by Kotlin via System.loadLibrary.
# ---------------------------------------------------------------------------
add_library(trinet_native SHARED
    libuvc_jni.cpp
)

target_include_directories(trinet_native PRIVATE
    ${libusb_cmake_SOURCE_DIR}/libusb/libusb
    ${libuvc_SOURCE_DIR}/include
    ${libuvc_BINARY_DIR}/include
)

find_library(log-lib log)
find_library(android-lib android)

target_link_libraries(trinet_native PRIVATE
    uvc
    usb-1.0
    ${log-lib}
    ${android-lib}
)

target_compile_options(trinet_native PRIVATE -Wall -Wextra -fvisibility=hidden)
target_compile_definitions(trinet_native PRIVATE TRINET_NATIVE_VERSION="0.1.0")
