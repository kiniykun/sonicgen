# Browser (wasm) build of the Sonic Generations recomp port.
#
# Consumes rexglue-sdk as a subproject (core, kernel, filesystem, system,
# ui, input, audio, codegen + rexgpu-xenos plugin with the WebGPU backend)
# and adds the recompiled game code + port app shell.
#
# Configure via emscripten/build.sh (it stages the generated code and applies
# the wasm overload rewrite first).
#
# Bring-up builds are -O2 without LTO: 295 TUs at -O3 -flto will eat the wasm
# heap and the runner's RAM at link before it finishes. Set WASM_LTO=1 (build.sh
# passes -DWASM_LTO=1) once the tree links cleanly end to end.

cmake_minimum_required(VERSION 3.24)
project(sonicgenerations_wasm CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(WASM_LTO "Enable -O3 + LTO (slow, memory hungry)" OFF)
if(WASM_LTO)
  set(WASM_OPT_FLAGS -O3 -flto)
else()
  set(WASM_OPT_FLAGS -O2)
endif()
message(STATUS "wasm optimization flags: ${WASM_OPT_FLAGS}")

set(REXGLUE_SDK_DIR "${REXGLUE_SDK_DIR}" CACHE PATH "rexglue-sdk root")
set(REXGLUE_APP_SRC_DIR "${REXGLUE_APP_SRC_DIR}" CACHE PATH "staged generated code root")

# ---- SDK subproject -------------------------------------------------------
# Tracy/perf counters off for the web build; WebGPU backend on (option set by
# build.sh; defaults resolve inside the SDK for EMSCRIPTEN).
set(REXGLUE_ENABLE_TRACY OFF CACHE BOOL "" FORCE)
set(REXGLUE_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory("${REXGLUE_SDK_DIR}" rexglue-sdk-build EXCLUDE_FROM_ALL)

# ---- Recompiled game code --------------------------------------------------
set(GEN "${REXGLUE_APP_SRC_DIR}/generated/default")
file(GLOB REXGEN_SOURCES "${GEN}/*.cpp")
add_library(rexgen OBJECT ${REXGEN_SOURCES})
target_include_directories(rexgen PRIVATE
    "${GEN}"
    "${REXGLUE_SDK_DIR}/include"
)
# SIMD128 must be enabled at compile time (not just link time) or simde's SSE
# calls compile to a scalar fallback instead of mapping onto wasm v128_t
# intrinsics.
target_compile_options(rexgen PRIVATE ${WASM_OPT_FLAGS} -fno-rtti -w
    -msimd128 -fwasm-exceptions)

# ---- App shell -------------------------------------------------------------
add_executable(sonicgenerations
    "${REXGLUE_APP_SRC_DIR}/app/main.cpp"
)
target_include_directories(sonicgenerations PRIVATE
    "${REXGLUE_APP_SRC_DIR}"
    "${REXGLUE_SDK_DIR}/include"
)
target_link_libraries(sonicgenerations PRIVATE
    rexgen
    rex::core
    rex::filesystem
    rex::ui
    rex::input
    rex::audio
    rex::system
    rex::kernel
    rex::codegen
    # NOTE: do NOT link "rexglue" here -- it is the SDK's CLI recompiler tool
    # (an EXECUTABLE); the component rex::* libraries above are the runtime.
)

# ---- Emscripten link flags -------------------------------------------------
# Memory: guest image + heap live in the wasm32 linear memory (matches PPC 32-bit
# pointers). 1 GB initial, up to 4 GB growth; ALLOW_MEMORY_GROWTH is required.
# Threads: kernel vblank/timer/GPU threads -> pthread pool (needs COOP/COEP;
# web/serve.py sets the headers).
# JSPI: fibers (kernel host callbacks) switch via stack switching; Asyncify is
# the fallback (-sJSPI=0 -sASYNCIFY=1) if the target browser lacks JSPI.
# Filesystem: FORCE_FILESYSTEM + IDBFS for save persistence; the shell mounts
# the user-provided game files under /game before boot.
target_link_options(sonicgenerations PRIVATE
    ${WASM_OPT_FLAGS}
    -msimd128
    -sWASM=1 -sALLOW_MEMORY_GROWTH=1
    -sINITIAL_MEMORY=1GB -sMAXIMUM_MEMORY=4GB
    -sUSE_PTHREADS=1 -sPTHREAD_POOL_SIZE=4
    -sJSPI=1
    -sSTACK_SIZE=8MB
    -sFORCE_FILESYSTEM=1 -lidbfs.js
    -sMODULARIZE=1 -sEXPORT_NAME=SonicGenerationsRecomp -sEXPORT_ES6=0
    -sENVIRONMENT=web,worker
    -sALLOW_TABLE_GROWTH=1
    -sDYNAMIC_EXECUTION=0
    -fwasm-exceptions
    -sEXIT_RUNTIME=0
    -sEXPORTED_RUNTIME_METHODS=ccall,cwrap,FS,HEAPU8,addFunction
    -sEXPORTED_FUNCTIONS=_main
    "SHELL:--use-port=emdawnwebgpu"
)
target_compile_options(sonicgenerations PRIVATE ${WASM_OPT_FLAGS} -fno-rtti -w
    -msimd128 -fwasm-exceptions --use-port=emdawnwebgpu)

# The GPU plugin consumes WebGPU headers (Dawn port) as well.
target_compile_options(rexgpu-xenos PRIVATE --use-port=emdawnwebgpu)

# The GPU plugin stays a side module (dlopen'd at runtime like on native);
# the runtime falls back to graceful "no GPU plugin" if the load fails.
set_target_properties(rexgpu-xenos PROPERTIES
    SUFFIX ".wasm"
)
