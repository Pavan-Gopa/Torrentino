# Torrentino engine harness (WP-01).
#
# Role:    headless C++ executable that exercises the pinned libtorrent build
#          the same way the future ObjC++ PIMPL facade will (C ABI entry point,
#          no exception may cross it).
# Must not: depend on anything outside the pinned prefix produced by
#          Native/ThirdParty/libtorrent/build.sh.
cmake_minimum_required(VERSION 3.20)
project(torrentino_engine_harness LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT APPLE)
	message(FATAL_ERROR "The Torrentino harness targets macOS on Apple Silicon only")
endif()

find_package(LibtorrentRasterbar REQUIRED CONFIG)

add_executable(torrentino-harness
	src/main.cpp
	src/harness_api.cpp
	src/support.cpp
	src/session_fixture.cpp
	src/torrent_factory.cpp
	src/engine_ops.cpp
	src/scenario_registry.cpp
	src/scenarios_core.cpp
	src/scenarios_persistence.cpp
	src/soak.cpp
	src/hash_bench.cpp
)

target_include_directories(torrentino-harness PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(torrentino-harness PRIVATE LibtorrentRasterbar::torrent-rasterbar)

# Warnings are errors for our own code. libtorrent/Boost headers arrive through
# an imported target and are treated as SYSTEM, so they cannot break the build.
target_compile_options(torrentino-harness PRIVATE
	-Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wsign-conversion
	-Wold-style-cast -Wnon-virtual-dtor -Werror
	# Using a deprecated libtorrent API in new code is a design bug, not a hint:
	# the bridge in WP-04 must be written against the modern API surface only.
	-Werror=deprecated-declarations
)

# Exceptions are required: they are the harness-internal error channel and are
# caught at the C ABI boundary (see harness_api.cpp).
target_compile_options(torrentino-harness PRIVATE -fexceptions)

install(TARGETS torrentino-harness RUNTIME DESTINATION bin)
