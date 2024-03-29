cmake_minimum_required(VERSION 3.1.0)
include(ExternalProject)
project(rtsp)

set(ZIG_RTSP "${CMAKE_CURRENT_SOURCE_DIR}/zig-out/lib/rtsp.so")

add_library(funny MODULE IMPORTED GLOBAL)
set_target_properties(funny PROPERTIES IMPORTED_LOCATION ${ZIG_RTSP})

# android: use prebuilt .so from allonet project
# TODO maybe an automated way to get the .so's?
if(ANDROID)
add_custom_target(
  zigrtsp
  COMMAND zig build -Dandroid=true -Dandroid-ndk=/home/luna/Downloads/abc/android-cli/sdkroot/ndk/21.1.6352462 -Dluajit=$<TARGET_FILE:luajit>
  WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
  VERBATIM
)

set(RELATIVE_PREFIX "plugins/lovr-rtsp")
set(RTSP_PREFIX "${CMAKE_CURRENT_SOURCE_DIR}/${RELATIVE_PREFIX}")
set(LIBAV_LIB_PATH "${rtsp_SOURCE_DIR}/q2_lib")

add_library(libavformat SHARED IMPORTED GLOBAL)
set_target_properties(libavformat PROPERTIES
  IMPORTED_LOCATION "${LIBAV_LIB_PATH}/libavformat.so"
)
add_library(libavcodec SHARED IMPORTED GLOBAL)
set_target_properties(libavcodec PROPERTIES
  IMPORTED_LOCATION "${LIBAV_LIB_PATH}/libavcodec.so"
)
add_library(libavutil SHARED IMPORTED GLOBAL)
set_target_properties(libavutil PROPERTIES
  IMPORTED_LOCATION "${LIBAV_LIB_PATH}/libavutil.so"
)
add_library(libswresample SHARED IMPORTED GLOBAL)
set_target_properties(libswresample PROPERTIES
  IMPORTED_LOCATION "${LIBAV_LIB_PATH}/libswresample.so"
)
add_library(libswscale SHARED IMPORTED GLOBAL)
set_target_properties(libswscale PROPERTIES
  IMPORTED_LOCATION "${LIBAV_LIB_PATH}/libswscale.so"
)

# set_target_properties(real PROPERTIES PREFIX "")

set(LOVR_PLUGIN_TARGETS funny libavformat libavutil libavcodec libswresample libswscale)
endif()

# desktop: use ffmpeg provided by system (done in build.zig)
if(UNIX AND NOT ANDROID)
add_custom_target(
  zigrtsp
  COMMAND zig build
  WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
  VERBATIM
)


set(LOVR_PLUGIN_TARGETS funny)
endif()

add_dependencies(funny zigrtsp)


#set_target_properties(funny PROPERTIES LINKER_LANGUAGE C)
#set_target_properties(funny PROPERTIES PREFIX "")

# build.zig already sets PIC
# set_target_properties(funny PROPERTIES POSITION_INDEPENDENT_CODE TRUE)
set_directory_properties( PROPERTIES LOVR_PLUGIN_TARGETS funny)
