#!/usr/bin/env python3
"""One-off: move the weak telemetry declarations in minecraft_utils.cpp
from block scope (illegal for extern "C") to file scope. Idempotent."""
from pathlib import Path

p = Path("/root/mcpe/work/source/mcpelauncher/"
         "mcpelauncher-core/src/minecraft_utils.cpp")
t = p.read_text()

bad = ('        extern "C" __attribute__((weak)) void'
       ' mcpe_telemetry_set_real_fmod_listener(void*);\n'
       '        extern "C" __attribute__((weak)) int'
       ' mcpe_telemetry_fmod_listener_hook(void*, int, const void*,'
       ' const void*, const void*, const void*);\n')

decls = ('\n// bottom-screen telemetry FMOD interposer (defined in the'
         " client's\n"
         '// telemetry module; weak so mcpelauncher-core links without'
         ' it)\n'
         'extern "C" {\n'
         '__attribute__((weak)) void'
         ' mcpe_telemetry_set_real_fmod_listener(void*);\n'
         '__attribute__((weak)) int'
         ' mcpe_telemetry_fmod_listener_hook(void*, int, const void*,'
         ' const void*, const void*, const void*);\n'
         '}\n')

if decls in t and bad not in t:
    print("already fixed")
    raise SystemExit(0)

assert bad in t, "block-scope decls not found"
t = t.replace(bad, "", 1)

anchor = "#include <minecraft/imported/fmod_symbols.h>\n"
assert anchor in t
t = t.replace(anchor, anchor + decls, 1)
p.write_text(t)
print("fixed")
