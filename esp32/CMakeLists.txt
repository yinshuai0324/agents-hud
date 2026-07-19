cmake_minimum_required(VERSION 3.5)

# Firmware version = repo-root VERSION file (single source of truth, shared
# with the Mac app / release tags). Reported via esp_app_get_description().
file(STRINGS ${CMAKE_CURRENT_LIST_DIR}/../VERSION PROJECT_VER LIMIT_COUNT 1)

# Target board: each model ships a "board" component under boards/<id>/.
# Override for other boards: idf.py -DAHUD_BOARD=xxx build
set(AHUD_BOARD "ws175" CACHE STRING "AgentsHUD board model id")
if(NOT EXISTS ${CMAKE_CURRENT_LIST_DIR}/boards/${AHUD_BOARD})
    message(FATAL_ERROR "Unknown AHUD_BOARD '${AHUD_BOARD}' (no boards/${AHUD_BOARD}/)")
endif()
list(APPEND EXTRA_COMPONENT_DIRS ${CMAKE_CURRENT_LIST_DIR}/boards/${AHUD_BOARD})

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

add_compile_options(-Wno-format)
project(agents_hud_amoled)
