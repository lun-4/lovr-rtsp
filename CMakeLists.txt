cmake_minimum_required(VERSION 3.1.0)
project(rtsp)

add_library(funny MODULE 
funny.c
)

# android: use prebuilt .so from allonet project
# TODO maybe an automated way to get the .so's?
if(ANDROID)
set_target_properties(funny PROPERTIES PREFIX "")
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

set(LOVR_PLUGIN_TARGETS funny libavformat libavutil libavcodec libswresample libswscale)
include_directories(./q2_include)
target_link_libraries(funny libavformat libavutil libavcodec libswresample libswscale)
endif()

# desktop: use ffmpeg provided by system
if(UNIX AND NOT ANDROID)
include_directories(/usr/include/lua5.1)
target_link_libraries(funny avformat avutil avcodec swresample swscale)
endif()

set_target_properties(funny PROPERTIES POSITION_INDEPENDENT_CODE TRUE)
