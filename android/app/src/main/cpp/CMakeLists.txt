cmake_minimum_required(VERSION 3.10)
project(multichannel_preview)

set(CMAKE_CXX_STANDARD 17)

add_library(multichannel_preview SHARED
    multichannel_preview.cpp
)

target_link_libraries(multichannel_preview
    aaudio
    log
)