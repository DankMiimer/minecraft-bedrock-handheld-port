#!/usr/bin/env python3
"""
apply_client_patch.py — wire the telemetry module into the mcpelauncher
WSL source tree (/root/mcpe/work/source/mcpelauncher).

Idempotent: skips edits that are already applied; aborts loudly if an
anchor string is missing (tree drifted — re-inspect before forcing).
Backups of the pristine files: /root/bedrockmap/backup_pre_telemetry/.

Run from WSL:  python3 apply_client_patch.py [tree_root]
"""
import shutil
import sys
from pathlib import Path

TREE = Path(sys.argv[1] if len(sys.argv) > 1 else
            "/root/mcpe/work/source/mcpelauncher")
HERE = Path(__file__).resolve().parent

MARKER = "mcpe_telemetry"  # presence in a file => that edit already applied


def patch(relpath, old, new, must_contain_if_applied=MARKER):
    p = TREE / relpath
    text = p.read_text()
    if new in text:
        print(f"  = {relpath}: already applied")
        return
    if old not in text:
        if must_contain_if_applied in text:
            print(f"  = {relpath}: marker present, anchor gone — assuming"
                  " an equivalent edit exists, SKIPPING")
            return
        sys.exit(f"ABORT: anchor not found in {relpath}:\n---\n{old}\n---")
    p.write_text(text.replace(old, new, 1))
    print(f"  + {relpath}: patched")


def main():
    if not TREE.is_dir():
        sys.exit(f"ABORT: tree not found: {TREE}")

    # 0) copy module sources into the client
    dst = TREE / "mcpelauncher-client/src/telemetry"
    dst.mkdir(exist_ok=True)
    for f in ("mcpe_telemetry_abi.h", "telemetry_writer.h",
              "telemetry_writer.c", "fmod_listener_hook.c",
              "telemetry_integration.h", "mcpe_companion_abi.h",
              "companion_bridge.h", "companion_bridge.c",
              "frame_freezer.h", "frame_freezer.c"):
        shutil.copyfile(HERE / f, dst / f)
    print(f"  + copied module sources -> {dst}")

    # 0b) Observe Bedrock's translated UDP peers in libc-shim. The observers
    # are weak so libc-shim remains independently linkable; the RGDS client
    # supplies them from telemetry_writer.c. IPv4 and IPv6 are classified,
    # while packet contents and addresses are never retained or published.
    observer_v1 = '''
// RGDS LAN-world classifier (implemented by telemetry_writer.c).
extern "C" __attribute__((weak)) void
mcpe_telemetry_network_peer_ipv4(uint32_t address_host, uint16_t port);

static void mcpe_telemetry_observe_peer(const struct sockaddr* addr)
{
    if (!addr || addr->sa_family != AF_INET ||
        !&mcpe_telemetry_network_peer_ipv4) return;
    const struct sockaddr_in* peer =
        reinterpret_cast<const struct sockaddr_in*>(addr);
    mcpe_telemetry_network_peer_ipv4(ntohl(peer->sin_addr.s_addr),
                                      ntohs(peer->sin_port));
}
'''
    observer_v2 = '''
// RGDS remote-world classifier v2 (implemented by telemetry_writer.c).
extern "C" __attribute__((weak)) void
mcpe_telemetry_network_peer_ipv4(uint32_t address_host, uint16_t port);
extern "C" __attribute__((weak)) void
mcpe_telemetry_network_peer_ipv6(const uint8_t address[16], uint16_t port);

static void mcpe_telemetry_observe_peer(const struct sockaddr* addr)
{
    if (!addr) return;
    if (addr->sa_family == AF_INET &&
        &mcpe_telemetry_network_peer_ipv4) {
        const struct sockaddr_in* peer =
            reinterpret_cast<const struct sockaddr_in*>(addr);
        mcpe_telemetry_network_peer_ipv4(ntohl(peer->sin_addr.s_addr),
                                          ntohs(peer->sin_port));
    } else if (addr->sa_family == AF_INET6 &&
               &mcpe_telemetry_network_peer_ipv6) {
        const struct sockaddr_in6* peer =
            reinterpret_cast<const struct sockaddr_in6*>(addr);
        mcpe_telemetry_network_peer_ipv6(peer->sin6_addr.s6_addr,
                                          ntohs(peer->sin6_port));
    }
}
'''
    network_path = TREE / "libc-shim/src/network.cpp"
    network_text = network_path.read_text()
    if observer_v2 in network_text:
        print("  = libc-shim/src/network.cpp: IPv4/IPv6 observer already applied")
    elif observer_v1 in network_text:
        network_path.write_text(network_text.replace(observer_v1, observer_v2, 1))
        print("  + libc-shim/src/network.cpp: upgraded observer to IPv4/IPv6")
    else:
        patch(
            "libc-shim/src/network.cpp",
            "using namespace shim;\n",
            "using namespace shim;\n" + observer_v2,
            must_contain_if_applied="RGDS remote-world classifier v2")
    patch(
        "libc-shim/src/network.cpp",
        "    detail::sock_send_flags hflags (sockfd, flags);\n"
        "    return ::sendto(sockfd, buf, len, hflags.flags,"
        " haddr.ptr(), haddr.len);\n",
        "    detail::sock_send_flags hflags (sockfd, flags);\n"
        "    mcpe_telemetry_observe_peer(haddr.ptr());\n"
        "    return ::sendto(sockfd, buf, len, hflags.flags,"
        " haddr.ptr(), haddr.len);\n",
        must_contain_if_applied="mcpe_telemetry_observe_peer(haddr.ptr())")
    patch(
        "libc-shim/src/network.cpp",
        "    int ret = ::recvfrom(sockfd, buf, len, flags, haddr.ptr(),"
        " &haddr.len);\n"
        "    if (ret >= 0)\n"
        "        haddr.apply(addr, addrlen);\n"
        "        return ret;\n"
        "    }\n",
        "    int ret = ::recvfrom(sockfd, buf, len, flags, haddr.ptr(),"
        " &haddr.len);\n"
        "    if (ret >= 0) {\n"
        "        mcpe_telemetry_observe_peer(haddr.ptr());\n"
        "        haddr.apply(addr, addrlen);\n"
        "    }\n"
        "    return ret;\n"
        "}\n",
        must_contain_if_applied="mcpe_telemetry_observe_peer(haddr.ptr())")

    # 1) loadLibraryOS: pre-seeded syms are interposers — don't overwrite
    patch(
        "mcpelauncher-core/src/hybris_utils.cpp",
        "        void* ptr = dlsym(handle, sym);\n"
        "        if (ptr)\n"
        "            syms[sym] = ptr;",
        "        void* ptr = dlsym(handle, sym);\n"
        "        // pre-seeded entries are interposers (e.g. telemetry"
        " fmod hook) - keep them\n"
        "        if (ptr && syms.find(sym) == syms.end())\n"
        "            syms[sym] = ptr;",
        must_contain_if_applied="interposers")

    # 2) loadFMod signature: header
    patch(
        "mcpelauncher-core/include/mcpelauncher/minecraft_utils.h",
        "    static void* loadFMod();",
        "    // overrides are pre-seeded into the fake libfmod.so symbol"
        " table and\n"
        "    // take precedence over host symbols (telemetry interposer)\n"
        "    static void* loadFMod(std::unordered_map<std::string, void*>"
        " overrides = {});")

    # 3) loadFMod impl: accept + forward overrides
    patch(
        "mcpelauncher-core/src/minecraft_utils.cpp",
        "void* MinecraftUtils::loadFMod() {",
        "void* MinecraftUtils::loadFMod(std::unordered_map<std::string,"
        " void*> overrides) {")
    patch(
        "mcpelauncher-core/src/minecraft_utils.cpp",
        "), fmod_symbols);",
        "), fmod_symbols, std::move(overrides));")

    # 4) client main.cpp: includes + hook wiring
    patch(
        "mcpelauncher-client/src/main.cpp",
        '#include "main.h"\n',
        '#include "main.h"\n'
        '#include <dlfcn.h>\n'
        '#include "telemetry/telemetry_integration.h"\n')
    patch(
        "mcpelauncher-client/src/main.cpp",
        "    if(!disableFmod) {\n"
        "        try {\n"
        "            MinecraftUtils::loadFMod();\n",
        "    if(!disableFmod) {\n"
        "        try {\n"
        "            // bottom-screen telemetry: interpose the FMOD"
        " 3D-listener call\n"
        "            // to publish camera pos/heading (see src/telemetry/)\n"
        "            void* fmodHostLib = MinecraftUtils::loadFMod(\n"
        "                {{MCPE_TELEMETRY_FMOD_LISTENER_SYM,\n"
        "                  (void*) &mcpe_telemetry_fmod_listener_hook}});\n"
        "            if (fmodHostLib)\n"
        "                mcpe_telemetry_set_real_fmod_listener(dlsym(\n"
        "                    fmodHostLib,"
        " MCPE_TELEMETRY_FMOD_LISTENER_SYM));\n")

    # 5) fake_egl.cpp: frame metrics -> telemetry (works with CSV off)
    patch(
        "mcpelauncher-client/src/fake_egl.cpp",
        "        if(!file)\n"
        "            return;\n",
        "        {\n"
        "            auto frameUs = std::chrono::duration_cast<\n"
        "                std::chrono::microseconds>(frameStart -"
        " previousFrame).count();\n"
        "            auto swapUs = std::chrono::duration_cast<\n"
        "                std::chrono::microseconds>(swapEnd -"
        " frameStart).count();\n"
        "            if (frame)\n"
        "                mcpe_telemetry_frame((float)frameUs / 1000.0f,\n"
        "                                     (float)swapUs / 1000.0f);\n"
        "        }\n"
        "        if(!file) {\n"
        "            previousFrame = frameStart;\n"
        "            frame++;\n"
        "            return;\n"
        "        }\n")
    patch(
        "mcpelauncher-client/src/fake_egl.cpp",
        '#include "fake_egl.h"\n',
        '#include "fake_egl.h"\n'
        '#include "telemetry/telemetry_writer.h"\n'
        '#include "telemetry/companion_bridge.h"\n'
        '#include "telemetry/frame_freezer.h"\n')
    patch(
        "mcpelauncher-client/src/fake_egl.cpp",
        "#endif\n"
        "    static bool affinityApplied = false;",
        "#endif\n"
        "    // Independent RGDS Chat/Items bridge. It is fail-closed and\n"
        "    // performs no game-library write unless the exact version,\n"
        "    // SHA, RTTI, vtable slot and prologue all match.\n"
        "    mcpe_companion_frame();\n"
        "    static bool affinityApplied = false;",
        must_contain_if_applied="mcpe_companion_frame()")
    patch(
        "mcpelauncher-client/src/fake_egl.cpp",
        "    auto frameStart = FrameMetricsState::Clock::now();\n"
        "    ((GameWindow *)surface)->swapBuffers();",
        "    auto frameStart = FrameMetricsState::Clock::now();\n"
        "    // A bottom-screen move needs Bedrock's native inventory context\n"
        "    // for server validation. Keep that short-lived UI off the top\n"
        "    // panel by restoring the last GPU-only gameplay frame before swap.\n"
        "    {\n"
        "        int freezeWidth = 0, freezeHeight = 0;\n"
        "        ((GameWindow *)surface)->getWindowSize(freezeWidth,\n"
        "                                               freezeHeight);\n"
        "        mcpe_frame_freezer_apply(mcpe_companion_top_frame_action(),\n"
        "                                 freezeWidth, freezeHeight);\n"
        "    }\n"
        "    ((GameWindow *)surface)->swapBuffers();",
        must_contain_if_applied="mcpe_frame_freezer_apply")

    # 5b) core loadMinecraftLib: interpose the listener on the ANDROID
    # libfmod path (used when no host libfmod.so.12.0 exists — e.g. the
    # RG DS). Weak refs (FILE scope — extern "C" is illegal inside a
    # function) keep mcpelauncher-core linkable without the client's
    # telemetry objects; the dlsym!=hook guard prevents re-wrapping when
    # the host-FMOD pre-seed path already installed the interposer.
    patch(
        "mcpelauncher-core/src/minecraft_utils.cpp",
        "#include <minecraft/imported/fmod_symbols.h>\n",
        "#include <minecraft/imported/fmod_symbols.h>\n"
        "\n// bottom-screen telemetry FMOD interposer (defined in the"
        " client's\n"
        "// telemetry module; weak so mcpelauncher-core links without"
        " it)\n"
        'extern "C" {\n'
        "__attribute__((weak)) void"
        " mcpe_telemetry_set_real_fmod_listener(void*);\n"
        "__attribute__((weak)) int"
        " mcpe_telemetry_fmod_listener_hook(void*, int, const void*,"
        " const void*, const void*, const void*);\n"
        "}\n")
    patch(
        "mcpelauncher-core/src/minecraft_utils.cpp",
        "    void* fmod = linker::dlopen(\"libfmod.so\", 0);\n"
        "    if(fmod) {\n",
        "    void* fmod = linker::dlopen(\"libfmod.so\", 0);\n"
        "    if(fmod) {\n"
        "        // bottom-screen telemetry: interpose the FMOD 3D-listener"
        " call on\n"
        "        // the android-libfmod path (weak: only active when the"
        " final\n"
        "        // executable also links the telemetry module)\n"
        "        static const char* telemetryFmodSym ="
        " \"_ZN4FMOD6System23set3DListenerAttributesEiPK11FMOD_VECTORS3_"
        "S3_S3_\";\n"
        "        if (&mcpe_telemetry_set_real_fmod_listener &&"
        " &mcpe_telemetry_fmod_listener_hook) {\n"
        "            void* realListener = linker::dlsym(fmod,"
        " telemetryFmodSym);\n"
        "            if (realListener && realListener !="
        " (void*)&mcpe_telemetry_fmod_listener_hook) {\n"
        "                mcpe_telemetry_set_real_fmod_listener("
        "realListener);\n"
        "                hooks.emplace_back(mcpelauncher_hook_t{"
        " telemetryFmodSym,"
        " (void*)&mcpe_telemetry_fmod_listener_hook });\n"
        "            }\n"
        "        }\n")

    # 6) CMake: add sources to the client target
    patch(
        "mcpelauncher-client/CMakeLists.txt",
        "src/settings.cpp src/settings.h )",
        "src/settings.cpp src/settings.h "
        "src/telemetry/telemetry_writer.c src/telemetry/telemetry_writer.h "
        "src/telemetry/fmod_listener_hook.c "
        "src/telemetry/telemetry_integration.h "
        "src/telemetry/mcpe_telemetry_abi.h "
        "src/telemetry/companion_bridge.c "
        "src/telemetry/companion_bridge.h "
        "src/telemetry/mcpe_companion_abi.h "
        "src/telemetry/frame_freezer.c "
        "src/telemetry/frame_freezer.h )",
        must_contain_if_applied="src/telemetry/frame_freezer.c")

    print("done. Rebuild with eglut_build/_container_build_incr.sh")


if __name__ == "__main__":
    main()
