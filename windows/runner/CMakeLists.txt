cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# A safe build (--dart-define=SAFE_MODE=true) leaves the system proxy alone
# before Dart runs too. Flutter passes each define base64-encoded; this one is
# SAFE_MODE=true.
get_directory_property(FLCLASH_TOOL_ENVIRONMENT
  DIRECTORY "${FLUTTER_MANAGED_DIR}" DEFINITION FLUTTER_TOOL_ENVIRONMENT)
set(FLCLASH_SAFE_MODE 0)
foreach(FLCLASH_ENTRY IN LISTS FLCLASH_TOOL_ENVIRONMENT)
  if(FLCLASH_ENTRY MATCHES "^DART_DEFINES=(.*)$")
    string(REPLACE "," ";" FLCLASH_DEFINES "${CMAKE_MATCH_1}")
    if("U0FGRV9NT0RFPXRydWU=" IN_LIST FLCLASH_DEFINES)
      set(FLCLASH_SAFE_MODE 1)
    endif()
  endif()
endforeach()
target_compile_definitions(${BINARY_NAME} PRIVATE "FLCLASH_SAFE_MODE=${FLCLASH_SAFE_MODE}")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
