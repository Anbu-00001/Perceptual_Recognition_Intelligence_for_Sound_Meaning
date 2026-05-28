# Reserved for Phase 5+ — OpenCV scene segmentation + NCNN fast guard before Gemma3n
# multimodal inference. Empty stub so cmake is wired but builds nothing yet.
cmake_minimum_required(VERSION 3.22)
project(prism_native LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Placeholder library. Real sources arrive in Phase 5.
add_library(prism_native_stub STATIC src/stub.cpp)
target_include_directories(prism_native_stub PUBLIC include)
