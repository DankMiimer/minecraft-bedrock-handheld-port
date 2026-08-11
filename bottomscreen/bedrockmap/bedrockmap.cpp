/*
 * bedrockmap — Bedrock world LevelDB → minimap tile cache + player.json.
 * Spec: RGDS_DUALSCREEN_PLAN.md Component 2; contract: README.md here.
 *
 * ALWAYS run against a SNAPSHOT copy of the db, never the live one.
 *
 *   bedrockmap --db <world>/db --out <tiledir> --center <x> <z>
 *              --radius-chunks N [--dim 0|1|2] [--cave <y>]
 *
 * Output: <out>/<dim>/<surface|cave>/r.<tx>.<tz>.png (256x256, 1px/block,
 * tile = 16x16 chunks) + parallel .raw cache (256*256*3) so incremental
 * passes never need a PNG decoder. <out>/player.json from ~local_player
 * + ../level.dat.
 *
 * Index conventions used (VERIFY in golden test vs uNmINeD; if the map
 * renders transposed, swap here, in ONE place each):
 *   heightmap:  hm[z*16 + x]            (ZX order)
 *   blocks:     idx = (x<<8)|(z<<4)|y   (XZY order)
 */
#include "nbt.hpp"
#include "png_write.hpp"

#define MCPE_TELEMETRY_IMPLEMENT_READER
#include "../telemetry/mcpe_telemetry_abi.h"

#include <leveldb/cache.h>
#include <leveldb/db.h>
#include <leveldb/decompress_allocator.h>
#include <leveldb/filter_policy.h>
#include <leveldb/options.h>
#include <leveldb/zlib_compressor.h>

#include <algorithm>
#include <cinttypes>
#include <cmath>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <sstream>
#include <map>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_map>
#include <vector>

/* ---------- key helpers ------------------------------------------- */
static std::string chunk_key(int32_t cx, int32_t cz, int32_t dim,
                             uint8_t tag, int has_sub = 0,
                             int8_t sub = 0)
{
    std::string k;
    k.append((const char *)&cx, 4);
    k.append((const char *)&cz, 4);
    if (dim != 0) k.append((const char *)&dim, 4);
    k.push_back((char)tag);
    if (has_sub) k.push_back((char)sub);
    return k;
}

static int32_t floordiv(int32_t a, int32_t b)
{
    return (int32_t)std::floor((double)a / b);
}
static int32_t posmod(int32_t a, int32_t b)
{
    int32_t m = a % b;
    return m < 0 ? m + b : m;
}

/* ---------- block colors ------------------------------------------ */
struct Rgb { uint8_t r, g, b; };

static std::unordered_map<std::string, Rgb> g_colors;
/* Optional 5th TSV column: light emission 0-15, the same scale
 * Minecraft uses. Drives the .lum tiles so torches, lava and fire keep
 * glowing when bottomd shades the map for night. */
static std::unordered_map<std::string, uint8_t> g_emission;

static void load_colors(const std::string &exe_dir)
{
    std::ifstream f(exe_dir + "/block_colors.tsv");
    /* Line-wise, NOT `f >> name >> r >> g >> b`: with stream extraction
     * an optional 5th column gets swallowed as the NEXT row's block
     * name, silently corrupting every colour after the first emissive
     * entry. */
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream ls(line);
        std::string name;
        int r, g, b, e = 0;
        if (!(ls >> name >> r >> g >> b)) continue;
        g_colors[name] = {(uint8_t)r, (uint8_t)g, (uint8_t)b};
        if ((ls >> e) && e > 0)
            g_emission[name] = (uint8_t)(e > 15 ? 15 : e);
    }
    if (g_colors.empty())
        fprintf(stderr, "bedrockmap: WARNING block_colors.tsv missing/"
                        "empty in %s — hash colors only\n",
                exe_dir.c_str());
}

static uint8_t block_emission(const std::string &name)
{
    auto it = g_emission.find(name);
    return it == g_emission.end() ? 0 : it->second;
}

static Rgb block_color(const std::string &name)
{
    auto it = g_colors.find(name);
    if (it != g_colors.end()) return it->second;
    /* stable hash color for unknown blocks — never black */
    uint32_t h = 2166136261u;
    for (char ch : name) h = (h ^ (uint8_t)ch) * 16777619u;
    return { (uint8_t)(64 + (h & 0x7f)), (uint8_t)(64 + ((h >> 8) & 0x7f)),
             (uint8_t)(64 + ((h >> 16) & 0x7f)) };
}

/* ---------- subchunk decoding -------------------------------------- */
/* One decoded block storage: 4096 palette indices + palette names. */
struct SubChunk {
    std::vector<uint16_t> idx;         /* 4096, XZY */
    std::vector<std::string> palette;
    int8_t y_index = 0;
    bool has_y_index = false;
    const std::string *at(int x, int y, int z) const {
        if (palette.empty()) return nullptr;
        uint16_t i = idx.empty() ? 0 : idx[(x << 8) | (z << 4) | y];
        if (i >= palette.size()) return nullptr;
        return &palette[i];
    }
};

/* One compact line in terrain.log makes version-format regressions diagnosable
 * from a support bundle without dumping any world contents. */
static std::map<uint8_t, size_t> g_subchunk_versions;
static size_t g_subchunk_parsed = 0;
static size_t g_subchunk_parse_failed = 0;
static size_t g_subchunk_y_rebased = 0;

/* Parse storage 0 of a serialized subchunk (versions 1/8/9). */
static bool parse_subchunk(const std::string &val, SubChunk &out)
{
    nbt::Cursor c{(const uint8_t *)val.data(),
                  (const uint8_t *)val.data() + val.size()};
    try {
        uint8_t ver = c.u8();
        g_subchunk_versions[ver]++;
        int nstorage = 1;
        if (ver == 8 || ver == 9) {
            nstorage = c.u8();
            if (ver == 9) {
                /* Since caves-and-cliffs, the key suffix is not a reliable
                 * world-section coordinate. v9 embeds the signed section Y
                 * explicitly; using the old suffix shifts modern overworld
                 * blocks vertically and renders most surface columns void. */
                out.y_index = (int8_t)c.u8();
                out.has_y_index = true;
            }
        } else if (ver != 1) {
            return false; /* pre-1.13 block-id format: unsupported */
        }
        if (nstorage < 1) return false;

        uint8_t bpb_byte = c.u8();
        int bpb = bpb_byte >> 1;
        if (bpb > 0) {
            int blocks_per_word = 32 / bpb;
            int words = (4096 + blocks_per_word - 1) / blocks_per_word;
            c.need((size_t)words * 4);
            out.idx.resize(4096);
            const uint8_t *w = c.p;
            for (int i = 0; i < 4096; ++i) {
                int word = i / blocks_per_word;
                int bit = (i % blocks_per_word) * bpb;
                uint32_t wv;
                memcpy(&wv, w + (size_t)word * 4, 4);
                out.idx[i] = (uint16_t)((wv >> bit) & ((1u << bpb) - 1));
            }
            c.p += (size_t)words * 4;
        }
        int32_t pal_n = c.i32();
        if (pal_n < 1 || pal_n > 4096) return false;
        for (int32_t i = 0; i < pal_n; ++i) {
            nbt::Value root = nbt::parse_root(c);
            const nbt::Value *nm = root.find("name");
            out.palette.push_back(nm ? nm->str : "?");
        }
        return true;
    } catch (const std::exception &) {
        return false;
    }
}

/* ---------- tile cache --------------------------------------------- */
#define TILE_PX 256 /* 16 chunks * 16 blocks */

struct Tile {
    std::vector<uint8_t> rgb; /* TILE_PX*TILE_PX*3 */
    std::vector<uint8_t> lum; /* TILE_PX*TILE_PX, emission 0-255 */
    bool dirty = false;
    bool from_disk = false; /* .raw existed & loaded fully */
};

static std::map<std::pair<int32_t, int32_t>, Tile> g_tiles;
static std::string g_tile_dir;

static Tile &get_tile(int32_t tx, int32_t tz)
{
    auto key = std::make_pair(tx, tz);
    auto it = g_tiles.find(key);
    if (it != g_tiles.end()) return it->second;
    Tile &t = g_tiles[key];
    t.rgb.assign(TILE_PX * TILE_PX * 3, 0);
    t.lum.assign(TILE_PX * TILE_PX, 0);
    char p[512];
    snprintf(p, sizeof p, "%s/r.%d.%d.raw", g_tile_dir.c_str(), tx, tz);
    std::ifstream f(p, std::ios::binary);
    if (f) {
        f.read((char *)t.rgb.data(), (std::streamsize)t.rgb.size());
        t.from_disk = f && (size_t)f.gcount() == t.rgb.size();
    }
    /* Light plane rides alongside as a plain byte array — keeps the
     * colour tiles in the existing RGB format so nothing else has to
     * change. Missing .lum simply means "no light data yet". */
    snprintf(p, sizeof p, "%s/r.%d.%d.lum", g_tile_dir.c_str(), tx, tz);
    {
        std::ifstream lf(p, std::ios::binary);
        if (lf) lf.read((char *)t.lum.data(), (std::streamsize)t.lum.size());
    }
    return t;
}

/* ---------- unchanged-chunk skip ----------------------------------- */
/* chunks.hash (in the tile dir, so per dim+mode): one "cx cz hash"
 * line per chunk ever rendered. A chunk whose raw LevelDB bytes hash
 * identically to the cache AND whose tile .raw is present on disk is
 * skipped entirely (no NBT parse, no render, tile stays clean → no
 * PNG re-encode). Delete chunks.hash (or the tile dir) after changing
 * block_colors.tsv or render code, else stale pixels persist. */
static std::unordered_map<uint64_t, uint64_t> g_chunk_hashes;
static bool g_hashes_dirty = false;
/* Bump whenever decoding/rendering semantics change so an upgrade never
 * treats tiles produced by older code as current. */
static constexpr uint64_t RENDER_SCHEMA = 2;

static uint64_t ck_key(int32_t cx, int32_t cz)
{
    return ((uint64_t)(uint32_t)cx << 32) | (uint32_t)cz;
}

static void load_chunk_hashes(void)
{
    std::ifstream f(g_tile_dir + "/chunks.hash");
    int64_t cx, cz;
    uint64_t h;
    while (f >> cx >> cz >> h)
        g_chunk_hashes[ck_key((int32_t)cx, (int32_t)cz)] = h;
}

static void save_chunk_hashes(void)
{
    if (!g_hashes_dirty) return;
    std::string tmp = g_tile_dir + "/chunks.hash.tmp";
    std::ofstream f(tmp);
    for (auto &kv : g_chunk_hashes)
        f << (int32_t)(kv.first >> 32) << ' ' << (int32_t)kv.first << ' '
          << kv.second << '\n';
    f.close();
    rename(tmp.c_str(), (g_tile_dir + "/chunks.hash").c_str());
}

static void flush_tiles(void)
{
    for (auto &kv : g_tiles) {
        if (!kv.second.dirty) continue;
        char raw[512], png[512];
        snprintf(raw, sizeof raw, "%s/r.%d.%d.raw", g_tile_dir.c_str(),
                 kv.first.first, kv.first.second);
        snprintf(png, sizeof png, "%s/r.%d.%d.png", g_tile_dir.c_str(),
                 kv.first.first, kv.first.second);
        std::string tmp = std::string(raw) + ".tmp";
        std::ofstream f(tmp, std::ios::binary);
        f.write((const char *)kv.second.rgb.data(),
                (std::streamsize)kv.second.rgb.size());
        f.close();
        rename(tmp.c_str(), raw);
        pngw::write_rgb(png, kv.second.rgb.data(), TILE_PX, TILE_PX);
        {
            char lp[512];
            snprintf(lp, sizeof lp, "%s/r.%d.%d.lum",
                     g_tile_dir.c_str(), kv.first.first, kv.first.second);
            std::string ltmp = std::string(lp) + ".tmp";
            std::ofstream lf(ltmp, std::ios::binary);
            lf.write((const char *)kv.second.lum.data(),
                     (std::streamsize)kv.second.lum.size());
            lf.close();
            rename(ltmp.c_str(), lp);
        }
        kv.second.dirty = false;
    }
}

/* ---------- player.json -------------------------------------------- */
static void write_player_json(leveldb::DB *db,
                              const leveldb::ReadOptions &ro,
                              const std::string &db_dir,
                              const std::string &out_dir)
{
    double px = 0, py = 0, pz = 0, yaw = 0, health = -1, hunger = -1;
    long long dim = 0, day_time = -1;
    long long spawn[3] = {0, 0, 0};
    bool have_player = false;

    std::string val;
    if (db->Get(ro, "~local_player", &val).ok()) {
        try {
            nbt::Cursor c{(const uint8_t *)val.data(),
                          (const uint8_t *)val.data() + val.size()};
            nbt::Value root = nbt::parse_root(c);
            if (const nbt::Value *pos = root.find("Pos");
                pos && pos->list.size() == 3) {
                px = pos->list[0].num();
                py = pos->list[1].num();
                pz = pos->list[2].num();
                have_player = true;
            }
            if (const nbt::Value *rot = root.find("Rotation");
                rot && rot->list.size() >= 1)
                yaw = rot->list[0].num();
            if (const nbt::Value *d = root.find("DimensionId"))
                dim = d->i;
            if (const nbt::Value *sx = root.find("SpawnX")) {
                spawn[0] = sx->i;
                if (const nbt::Value *v = root.find("SpawnY")) spawn[1] = v->i;
                if (const nbt::Value *v = root.find("SpawnZ")) spawn[2] = v->i;
            }
            if (const nbt::Value *attrs = root.find("Attributes"))
                for (const nbt::Value &a : attrs->list) {
                    const nbt::Value *nm = a.find("Name");
                    const nbt::Value *cur = a.find("Current");
                    if (!nm || !cur) continue;
                    if (nm->str == "minecraft:health")
                        health = cur->num();
                    else if (nm->str == "minecraft:player.hunger")
                        hunger = cur->num();
                }
        } catch (const std::exception &e) {
            fprintf(stderr, "bedrockmap: ~local_player parse: %s\n",
                    e.what());
        }
    }

    /* level.dat: 8-byte header (version, length), then NBT */
    std::ifstream lf(db_dir + "/../level.dat", std::ios::binary);
    if (lf) {
        std::vector<uint8_t> buf((std::istreambuf_iterator<char>(lf)),
                                 std::istreambuf_iterator<char>());
        if (buf.size() > 8) {
            try {
                nbt::Cursor c{buf.data() + 8, buf.data() + buf.size()};
                nbt::Value root = nbt::parse_root(c);
                if (const nbt::Value *t = root.find("Time"))
                    day_time = t->i;
                if (!have_player) {
                    if (const nbt::Value *v = root.find("SpawnX"))
                        spawn[0] = v->i;
                    if (const nbt::Value *v = root.find("SpawnY"))
                        spawn[1] = v->i;
                    if (const nbt::Value *v = root.find("SpawnZ"))
                        spawn[2] = v->i;
                }
            } catch (const std::exception &) {}
        }
    }

    std::string tmp = out_dir + "/player.json.tmp";
    FILE *f = fopen(tmp.c_str(), "w");
    if (!f) return;
    fprintf(f,
            "{\"have_player\":%s,\"pos\":[%.2f,%.2f,%.2f],"
            "\"yaw\":%.1f,\"dimension\":%lld,\"health\":%.1f,"
            "\"hunger\":%.1f,\"spawn\":[%lld,%lld,%lld],"
            "\"day_time\":%lld}\n",
            have_player ? "true" : "false", px, py, pz, yaw, dim, health,
            hunger, spawn[0], spawn[1], spawn[2], day_time);
    fclose(f);
    std::string fin = out_dir + "/player.json";
    rename(tmp.c_str(), fin.c_str());
}

/* ---------- chunk rendering ---------------------------------------- */
struct ChunkData {
    std::map<int8_t, SubChunk> subs;
    std::vector<uint16_t> hm; /* 256, ZX order; empty if none */
    int32_t min_y = 0;
};

/* Stage 1: raw LevelDB bytes only — cheap, hashable, no NBT parsing. */
struct RawChunk {
    std::string hm; /* Data2D/Data3D value (>=512 bytes) */
    int32_t min_y = 0;
    std::vector<std::pair<int8_t, std::string>> subs; /* sy, raw value */
};

static bool read_chunk_raw(leveldb::DB *db, const leveldb::ReadOptions &ro,
                           int32_t cx, int32_t cz, int32_t dim,
                           RawChunk &out)
{
    /* heightmap: Data2D (pre-1.18) or first 512 bytes of Data3D */
    if (db->Get(ro, chunk_key(cx, cz, dim, 0x2d), &out.hm).ok() &&
        out.hm.size() >= 512) {
        out.min_y = 0;
    } else if (db->Get(ro, chunk_key(cx, cz, dim, 0x2b), &out.hm).ok() &&
               out.hm.size() >= 512) {
        out.min_y = dim == 0 ? -64 : 0;
    } else {
        return false; /* chunk not generated / no heightmap */
    }

    /* all subchunks via prefix scan */
    std::string prefix = chunk_key(cx, cz, dim, 0x2f);
    std::unique_ptr<leveldb::Iterator> it(db->NewIterator(ro));
    for (it->Seek(prefix);
         it->Valid() && it->key().ToString().rfind(prefix, 0) == 0;
         it->Next()) {
        leveldb::Slice k = it->key();
        if (k.size() != prefix.size() + 1) continue;
        int8_t sy = (int8_t)k[k.size() - 1];
        out.subs.emplace_back(sy, it->value().ToString());
    }
    return true;
}

static uint64_t hash_raw_chunk(const RawChunk &rc, uint64_t seed)
{
    uint64_t h = 14695981039346656037ull ^ seed;
    auto mix = [&h](const void *p, size_t n) {
        const uint8_t *b = (const uint8_t *)p;
        for (size_t i = 0; i < n; ++i)
            h = (h ^ b[i]) * 1099511628211ull;
    };
    mix(rc.hm.data(), rc.hm.size());
    mix(&rc.min_y, sizeof rc.min_y);
    for (auto &s : rc.subs) {
        mix(&s.first, 1);
        mix(s.second.data(), s.second.size());
    }
    return h;
}

/* Stage 2: NBT/palette parse of the raw bytes. */
static void parse_chunk(const RawChunk &rc, ChunkData &out)
{
    out.min_y = rc.min_y;
    out.hm.resize(256);
    memcpy(out.hm.data(), rc.hm.data(), 512);
    for (auto &s : rc.subs) {
        SubChunk sc;
        if (parse_subchunk(s.second, sc)) {
            int8_t section_y = sc.has_y_index ? sc.y_index : s.first;
            if (section_y != s.first) g_subchunk_y_rebased++;
            out.subs[section_y] = std::move(sc);
            g_subchunk_parsed++;
        } else {
            g_subchunk_parse_failed++;
        }
    }
}

static const std::string *block_at(const ChunkData &cd, int x, int32_t y,
                                   int z)
{
    int8_t sy = (int8_t)floordiv(y, 16);
    auto it = cd.subs.find(sy);
    if (it == cd.subs.end()) return nullptr;
    return it->second.at(x, posmod(y, 16), z);
}

static bool is_water(const std::string &n)
{
    return n == "minecraft:water" || n == "minecraft:flowing_water";
}
static bool is_airlike(const std::string &n)
{
    return n == "minecraft:air" || n == "minecraft:cave_air";
}

static void render_chunk(const ChunkData &cd, int32_t cx, int32_t cz,
                         int cave_mode, int32_t cave_y)
{
    int32_t tx = floordiv(cx, 16), tz = floordiv(cz, 16);
    Tile &tile = get_tile(tx, tz);
    int ox = posmod(cx, 16) * 16, oz = posmod(cz, 16) * 16;

    int32_t topy[16][16];
    Rgb col[16][16];
    uint8_t emis[16][16] = {{0}};
    memset(topy, 0, sizeof topy);

    for (int z = 0; z < 16; ++z)
        for (int x = 0; x < 16; ++x) {
            col[z][x] = {24, 26, 32}; /* void */
            topy[z][x] = cd.min_y;

            int32_t y;
            const std::string *name = nullptr;
            if (!cave_mode) {
                uint16_t h = cd.hm.empty() ? 0 : cd.hm[z * 16 + x];
                if (h == 0) continue;
                y = cd.min_y + (int32_t)h - 1;
                name = block_at(cd, x, y, z);
                /* tolerate off-by-one heightmap semantics */
                for (int fix = 0; fix < 2 && name && is_airlike(*name);
                     ++fix)
                    name = block_at(cd, x, --y, z);
            } else {
                y = cave_y;
                name = block_at(cd, x, y, z);
                int32_t limit = cd.min_y;
                while (y > limit && (!name || is_airlike(*name)))
                    name = block_at(cd, x, --y, z);
            }
            if (!name || is_airlike(*name)) continue;

            if (is_water(*name)) {
                /* find water depth for tinting */
                int32_t wy = y;
                const std::string *b = name;
                while (wy > cd.min_y && b && is_water(*b))
                    b = block_at(cd, x, --wy, z);
                int depth = y - wy;
                float k = 1.0f - 0.05f * (depth > 12 ? 12 : depth);
                Rgb wc = block_color("minecraft:water");
                col[z][x] = {(uint8_t)(wc.r * k), (uint8_t)(wc.g * k),
                             (uint8_t)(wc.b * k)};
            } else {
                col[z][x] = block_color(*name);
                emis[z][x] = block_emission(*name);
            }
            topy[z][x] = y;
        }

    /* vanilla-style height shading vs west neighbor (in-chunk) */
    for (int z = 0; z < 16; ++z)
        for (int x = 0; x < 16; ++x) {
            int32_t w = x > 0 ? topy[z][x - 1] : topy[z][x];
            float k = topy[z][x] > w ? 1.12f
                      : topy[z][x] < w ? 0.85f : 1.0f;
            Rgb &c = col[z][x];
            auto sc = [&](uint8_t v) {
                int r = (int)(v * k);
                return (uint8_t)(r > 255 ? 255 : r);
            };
            size_t idx = (size_t)(oz + z) * TILE_PX + (ox + x);
            size_t off = idx * 3;
            tile.rgb[off] = sc(c.r);
            tile.rgb[off + 1] = sc(c.g);
            tile.rgb[off + 2] = sc(c.b);
            /* 0-15 -> 0-255. bottomd uses this to keep light sources
             * bright while the rest of the map is shaded for night. */
            tile.lum[idx] = (uint8_t)(emis[z][x] * 17);
        }
    tile.dirty = true;
}

/* ---------- main ---------------------------------------------------- */
int main(int argc, char **argv)
{
    std::string db_dir, out_dir;
    int32_t center_x = 0, center_z = 0, radius = 12, dim = 0;
    int cave_mode = 0, center_telemetry = 0, dim_set = 0, diagnose = 0;
    int32_t cave_y = 0;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&]() { return std::string(argv[++i]); };
        if (a == "--db") db_dir = next();
        else if (a == "--out") out_dir = next();
        else if (a == "--center") {
            center_x = atoi(argv[++i]);
            center_z = atoi(argv[++i]);
        }
        else if (a == "--center-telemetry") center_telemetry = 1;
        else if (a == "--radius-chunks") radius = atoi(argv[++i]);
        else if (a == "--dim") { dim = atoi(argv[++i]); dim_set = 1; }
        else if (a == "--cave") { cave_mode = 1; cave_y = atoi(argv[++i]); }
        else if (a == "--diagnose") diagnose = 1;
    }

    /* --center-telemetry: center on the live camera position from the
     * game's shm feed; silently succeed-with-no-work when the game
     * isn't in a world (bottomd's terrain loop calls this every pass). */
    if (center_telemetry) {
        const char *shm_name = getenv("MCPE_TELEMETRY_SHM");
        if (!shm_name || shm_name[0] != '/')
            shm_name = MCPE_TELEMETRY_SHM_DEFAULT;
        int tfd = shm_open(shm_name, O_RDONLY, 0);
        if (tfd < 0) return 0;
        const volatile McpeTelemetry *tshm =
            (const volatile McpeTelemetry *)mmap(
                NULL, sizeof(McpeTelemetry), PROT_READ, MAP_SHARED, tfd,
                0);
        close(tfd);
        if (tshm == MAP_FAILED) return 0;
        McpeTelemetry tel;
        if (!mcpe_telemetry_read(tshm, &tel) ||
            !(tel.flags & MCPE_TF_IN_GAME))
            return 0;
        center_x = (int32_t)tel.cam_x;
        center_z = (int32_t)tel.cam_z;
    }
    if (db_dir.empty() || out_dir.empty()) {
        fprintf(stderr,
                "usage: bedrockmap --db <world>/db --out <dir> "
                "--center <x> <z> [--radius-chunks N] [--dim D] "
                "[--cave <y>]\n");
        return 2;
    }

    /* colors live next to the binary */
    std::string exe_dir = ".";
    {
        std::string self = argv[0];
        size_t sl = self.find_last_of('/');
        if (sl != std::string::npos) exe_dir = self.substr(0, sl);
    }
    load_colors(exe_dir);

    leveldb::Options opts;
    opts.compressors[0] = new leveldb::ZlibCompressorRaw(-1);
    opts.compressors[1] = new leveldb::ZlibCompressor();
    opts.block_cache = leveldb::NewLRUCache(8 * 1024 * 1024);
    opts.filter_policy = leveldb::NewBloomFilterPolicy(10);
    leveldb::DB *db = nullptr;
    leveldb::Status st = leveldb::DB::Open(opts, db_dir, &db);
    if (!st.ok()) {
        fprintf(stderr, "bedrockmap: open %s: %s\n", db_dir.c_str(),
                st.ToString().c_str());
        return 1;
    }
    leveldb::ReadOptions ro;
    ro.decompress_allocator = new leveldb::DecompressAllocator();

    /* default the dimension to where the player actually is */
    if (!dim_set) {
        std::string lpv;
        if (db->Get(ro, "~local_player", &lpv).ok()) {
            try {
                nbt::Cursor c{(const uint8_t *)lpv.data(),
                              (const uint8_t *)lpv.data() + lpv.size()};
                nbt::Value root = nbt::parse_root(c);
                if (const nbt::Value *d = root.find("DimensionId"))
                    dim = (int32_t)d->i;
            } catch (const std::exception &) {}
        }
    }

    char dirbuf[512];
    snprintf(dirbuf, sizeof dirbuf, "%s/%d/%s", out_dir.c_str(), dim,
             cave_mode ? "cave" : "surface");
    g_tile_dir = dirbuf;
    /* mkdir -p */
    for (size_t i = 1; i <= g_tile_dir.size(); ++i)
        if (i == g_tile_dir.size() || g_tile_dir[i] == '/')
            mkdir(g_tile_dir.substr(0, i).c_str(), 0755);

    load_chunk_hashes();
    /* renderer inputs beyond the chunk bytes → part of the hash seed */
    uint64_t seed = 0xbed0000000000000ull ^ RENDER_SCHEMA;
    if (cave_mode) seed ^= 0x10000u + (uint32_t)cave_y;

    int32_t ccx = floordiv(center_x, 16), ccz = floordiv(center_z, 16);
    /* Render the visible area first and publish it before scanning the outer
     * cache ring. This makes newly flushed chunks appear promptly even when a
     * wider user-configured radius contains mostly absent chunks. */
    std::vector<std::pair<int32_t, int32_t>> offsets;
    offsets.reserve((size_t)(radius * 2 + 1) * (radius * 2 + 1));
    for (int32_t dz = -radius; dz <= radius; ++dz)
        for (int32_t dx = -radius; dx <= radius; ++dx)
            offsets.emplace_back(dx, dz);
    std::sort(offsets.begin(), offsets.end(), [](const auto &a, const auto &b) {
        int64_t ad = (int64_t)a.first * a.first + (int64_t)a.second * a.second;
        int64_t bd = (int64_t)b.first * b.first + (int64_t)b.second * b.second;
        if (ad != bd) return ad < bd;
        return a < b;
    });
    int32_t priority_radius = std::min<int32_t>(radius, 10);
    int64_t priority_limit = (int64_t)priority_radius * priority_radius;
    bool priority_flushed = false;
    int rendered = 0, missing = 0, skipped = 0;
    for (const auto &offset : offsets) {
            int64_t dist = (int64_t)offset.first * offset.first +
                           (int64_t)offset.second * offset.second;
            if (!priority_flushed && dist > priority_limit) {
                flush_tiles();
                priority_flushed = true;
            }
            int32_t cx = ccx + offset.first;
            int32_t cz = ccz + offset.second;
            RawChunk rc;
            if (!read_chunk_raw(db, ro, cx, cz, dim, rc)) {
                missing++;
                continue;
            }
            uint64_t h = hash_raw_chunk(rc, seed);
            uint64_t key = ck_key(cx, cz);
            auto hit = g_chunk_hashes.find(key);
            if (hit != g_chunk_hashes.end() && hit->second == h &&
                get_tile(floordiv(cx, 16), floordiv(cz, 16)).from_disk) {
                skipped++;
                continue;
            }
            ChunkData cd;
            parse_chunk(rc, cd);
            if (diagnose && cx == ccx && cz == ccz) {
                uint16_t hmin = UINT16_MAX, hmax = 0;
                for (uint16_t h : cd.hm) { hmin = std::min(hmin, h); hmax = std::max(hmax, h); }
                int lx = posmod(center_x, 16), lz = posmod(center_z, 16);
                uint16_t raw_h = cd.hm[(size_t)lz * 16 + lx];
                int32_t mapped_y = cd.min_y + (int32_t)raw_h - 1;
                const std::string *mapped = block_at(cd, lx, mapped_y, lz);
                int32_t scan_y = cd.subs.empty() ? cd.min_y :
                    ((int32_t)cd.subs.rbegin()->first + 1) * 16 - 1;
                const std::string *scanned = nullptr;
                while (scan_y >= cd.min_y) {
                    scanned = block_at(cd, lx, scan_y, lz);
                    if (scanned && !is_airlike(*scanned)) break;
                    --scan_y;
                }
                fprintf(stderr,
                        "bedrockmap: center chunk=(%d,%d) local=(%d,%d) min-y=%d "
                        "height-range=%u..%u raw-height=%u mapped-y=%d mapped=%s "
                        "scan-y=%d scanned=%s sections=",
                        cx, cz, lx, lz, cd.min_y, (unsigned)hmin, (unsigned)hmax,
                        (unsigned)raw_h, mapped_y, mapped ? mapped->c_str() : "<missing>",
                        scan_y, scanned ? scanned->c_str() : "<missing>");
                for (const auto &section : cd.subs)
                    fprintf(stderr, "%d,", (int)section.first);
                fputc('\n', stderr);
            }
            render_chunk(cd, cx, cz, cave_mode, cave_y);
            g_chunk_hashes[key] = h;
            g_hashes_dirty = true;
            rendered++;
        }
    flush_tiles();
    save_chunk_hashes();
    write_player_json(db, ro, db_dir, out_dir);
    delete db;

    fprintf(stderr, "bedrockmap: %d chunks rendered, %d skipped "
                    "(unchanged), %d absent, %zu tiles touched\n",
            rendered, skipped, missing, g_tiles.size());
    fprintf(stderr, "bedrockmap: subchunks parsed=%zu failed=%zu y-rebased=%zu versions=",
            g_subchunk_parsed, g_subchunk_parse_failed, g_subchunk_y_rebased);
    for (const auto &entry : g_subchunk_versions)
        fprintf(stderr, "%s%u:%zu", entry == *g_subchunk_versions.begin() ? "" : ",",
                (unsigned)entry.first, entry.second);
    fputc('\n', stderr);
    return 0;
}
