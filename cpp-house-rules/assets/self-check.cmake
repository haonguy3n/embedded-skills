# Include from the top-level CMakeLists.txt (after project()):
#   option(BUILD_TESTING "Build the self-checks for ctest" OFF)
#   if(BUILD_TESTING)
#       enable_testing()
#   endif()
#   include(cmake/self-check.cmake)
#
# add_self_check(<name> <sources...> LIBS <libraries...>)
# One standalone, assert-based executable per check, registered with CTest. Asserts stay on in a release build
# (-UNDEBUG), and the check runs from the project's source directory so it can read test data by relative path.
# Declare it in the library's CMakeLists.txt:
#   if(BUILD_TESTING)
#       add_self_check(StreamManagerCheck test/StreamManagerCheck.cpp LIBS Stream)
#   endif()
# Run all:  cmake --workflow --preset host-debug      Run one:  ctest --preset host-debug -R '^StreamManagerCheck$'
function(add_self_check name)
    cmake_parse_arguments(PARSE_ARGV 1 arg "" "" "LIBS")
    add_executable(${name} ${arg_UNPARSED_ARGUMENTS})
    target_compile_options(${name} PRIVATE -Wall -Wextra -UNDEBUG)
    target_link_libraries(${name} PRIVATE ${arg_LIBS})
    add_test(NAME ${name} COMMAND ${name} WORKING_DIRECTORY ${PROJECT_SOURCE_DIR})
endfunction()

# The shape of a check file (Libs/<Lib>/test/<Name>.cpp):
#
#   /**
#    * @file DeviceSecretCheck.cpp
#    * @brief Self-check for Platform::ReadDeviceSecret: the text without the NULs and line breaks around it, a
#    * missing or empty file an error.
#    *
#    * Run (from the project dir): ctest --preset host-debug -R '^DeviceSecretCheck$'
#    */
#   #include <Platform/DeviceSecret.h>
#   #include <cassert>
#   #include <cstdio>
#
#   namespace
#   {
#   void CheckTrimmed() { ... assert(secret && *secret == "1423"); }
#   void CheckMissing() { assert(!Platform::ReadDeviceSecret("/nonexistent")); }
#   } // namespace
#
#   int main()
#   {
#   	CheckTrimmed();
#   	CheckMissing();
#   	std::puts("DeviceSecretCheck: ok");
#   	return 0;
#   }
