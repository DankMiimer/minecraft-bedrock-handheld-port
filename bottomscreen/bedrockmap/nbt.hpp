/*
 * nbt.hpp — minimal little-endian (Bedrock) NBT parser. Read-only,
 * enough for subchunk palettes, ~local_player and level.dat.
 */
#pragma once
#include <cstdint>
#include <cstring>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace nbt {

enum Tag : uint8_t {
    TAG_End = 0, TAG_Byte, TAG_Short, TAG_Int, TAG_Long, TAG_Float,
    TAG_Double, TAG_ByteArray, TAG_String, TAG_List, TAG_Compound,
    TAG_IntArray, TAG_LongArray
};

struct Value;
using Compound = std::map<std::string, Value>;

struct Value {
    uint8_t tag = TAG_End;
    int64_t i = 0;          /* byte/short/int/long */
    double d = 0;           /* float/double */
    std::string str;
    std::vector<Value> list;
    std::shared_ptr<Compound> comp;

    const Value *find(const std::string &k) const {
        if (tag != TAG_Compound || !comp) return nullptr;
        auto it = comp->find(k);
        return it == comp->end() ? nullptr : &it->second;
    }
    double num() const { return tag == TAG_Float || tag == TAG_Double
                                    ? d : (double)i; }
};

struct Cursor {
    const uint8_t *p, *end;
    void need(size_t n) const {
        if ((size_t)(end - p) < n) throw std::runtime_error("nbt: eof");
    }
    uint8_t u8() { need(1); return *p++; }
    uint16_t u16() { need(2); uint16_t v; memcpy(&v, p, 2); p += 2; return v; }
    int32_t i32() { need(4); int32_t v; memcpy(&v, p, 4); p += 4; return v; }
    int64_t i64() { need(8); int64_t v; memcpy(&v, p, 8); p += 8; return v; }
    float f32() { need(4); float v; memcpy(&v, p, 4); p += 4; return v; }
    double f64() { need(8); double v; memcpy(&v, p, 8); p += 8; return v; }
    std::string str() {
        uint16_t n = u16(); need(n);
        std::string s((const char *)p, n); p += n; return s;
    }
};

inline Value parse_payload(Cursor &c, uint8_t tag)
{
    Value v; v.tag = tag;
    switch (tag) {
    case TAG_Byte:   v.i = (int8_t)c.u8(); break;
    case TAG_Short:  v.i = (int16_t)c.u16(); break;
    case TAG_Int:    v.i = c.i32(); break;
    case TAG_Long:   v.i = c.i64(); break;
    case TAG_Float:  v.d = c.f32(); break;
    case TAG_Double: v.d = c.f64(); break;
    case TAG_String: v.str = c.str(); break;
    case TAG_ByteArray: {
        int32_t n = c.i32(); c.need((size_t)n); c.p += n; break;
    }
    case TAG_IntArray: {
        int32_t n = c.i32(); c.need((size_t)n * 4); c.p += (size_t)n * 4; break;
    }
    case TAG_LongArray: {
        int32_t n = c.i32(); c.need((size_t)n * 8); c.p += (size_t)n * 8; break;
    }
    case TAG_List: {
        uint8_t et = c.u8();
        int32_t n = c.i32();
        for (int32_t k = 0; k < n; ++k)
            v.list.push_back(parse_payload(c, et));
        break;
    }
    case TAG_Compound: {
        v.comp = std::make_shared<Compound>();
        for (;;) {
            uint8_t t = c.u8();
            if (t == TAG_End) break;
            std::string name = c.str();
            (*v.comp)[name] = parse_payload(c, t);
        }
        break;
    }
    default:
        throw std::runtime_error("nbt: bad tag " + std::to_string(tag));
    }
    return v;
}

/* Parse one named root tag; cursor advances past it. */
inline Value parse_root(Cursor &c)
{
    uint8_t t = c.u8();
    if (t == TAG_End) return Value{};
    c.str(); /* root name, ignored */
    return parse_payload(c, t);
}

} /* namespace nbt */
