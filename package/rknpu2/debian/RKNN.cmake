if(NOT TARGET RKNN::rknnrt)
    find_path(RKNN_INCLUDE_DIR NAMES rknn_api.h)
    find_library(RKNN_LIBRARY NAMES rknnrt)
    if(RKNN_INCLUDE_DIR AND RKNN_LIBRARY)
        add_library(RKNN::rknnrt SHARED IMPORTED)
        set_target_properties(RKNN::rknnrt PROPERTIES
            IMPORTED_LOCATION "${RKNN_LIBRARY}"
            INTERFACE_INCLUDE_DIRECTORIES "${RKNN_INCLUDE_DIR}")
        set(RKNN_FOUND TRUE)
    endif()
endif()
