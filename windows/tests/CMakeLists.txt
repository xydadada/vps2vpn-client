cmake_minimum_required(VERSION 3.14)
project(vps2vpn_runner_tests LANGUAGES CXX)

enable_testing()
add_executable(runner_utils_test utils_test.cpp ../runner/utils.cpp)
target_compile_features(runner_utils_test PRIVATE cxx_std_17)
target_include_directories(runner_utils_test PRIVATE ../runner stubs)
target_link_libraries(runner_utils_test PRIVATE shell32)
add_test(NAME runner_utils COMMAND runner_utils_test)
