cmake_minimum_required(VERSION 3.24)
project(rewritedex_native LANGUAGES CXX)

add_executable(rewritedex-native WIN32 main.cpp host_workspace_state.cpp opik_telemetry.cpp)
target_compile_features(rewritedex-native PRIVATE cxx_std_20)
target_compile_definitions(rewritedex-native PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(rewritedex-native PRIVATE user32 shell32 ws2_32 shcore bcrypt ole32 winhttp)
