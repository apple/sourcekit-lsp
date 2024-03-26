
cmake_minimum_required(VERSION 3.16.1)

list(APPEND CMAKE_MODULE_PATH ${CMAKE_SOURCE_DIR}/cmake/modules)

project(SourceKit-LSP
  LANGUAGES C Swift)

set(CMAKE_Swift_MODULE_DIRECTORY ${CMAKE_BINARY_DIR}/swift)

set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

find_package(dispatch QUIET)
find_package(Foundation QUIET)
find_package(TSC QUIET)
find_package(IndexStoreDB QUIET)
find_package(SwiftPM QUIET)
find_package(LLBuild QUIET)
find_package(ArgumentParser CONFIG REQUIRED)
find_package(SwiftCollections QUIET)
find_package(SwiftDriver CONFIG REQUIRED)
find_package(SwiftSystem CONFIG REQUIRED)
find_package(SwiftSyntax CONFIG REQUIRED)
find_package(SwiftCrypto CONFIG REQUIRED)

include(SwiftSupport)

add_subdirectory(Sources)
