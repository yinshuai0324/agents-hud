cmake_minimum_required(VERSION 3.5)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

add_compile_options(-Wno-format)
project(agents_hud_amoled)
