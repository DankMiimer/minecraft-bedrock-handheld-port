/* png_write.hpp — minimal RGB8 PNG encoder over zlib. */
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <zlib.h>

namespace pngw {

inline void be32(std::vector<uint8_t> &v, uint32_t x)
{
    v.push_back(x >> 24); v.push_back(x >> 16);
    v.push_back(x >> 8);  v.push_back(x);
}

inline void chunk(FILE *f, const char type[4], const uint8_t *data,
                  size_t len)
{
    std::vector<uint8_t> hdr;
    be32(hdr, (uint32_t)len);
    fwrite(hdr.data(), 1, 4, f);
    fwrite(type, 1, 4, f);
    if (len) fwrite(data, 1, len, f);
    uint32_t crc = crc32(0, (const Bytef *)type, 4);
    if (len) crc = crc32(crc, data, (uInt)len);
    std::vector<uint8_t> c;
    be32(c, crc);
    fwrite(c.data(), 1, 4, f);
}

/* rgb: w*h*3. Returns 0 on success. Writes atomically (tmp+rename). */
inline int write_rgb(const std::string &path, const uint8_t *rgb, int w,
                     int h)
{
    std::vector<uint8_t> raw((size_t)h * (w * 3 + 1));
    for (int y = 0; y < h; ++y) {
        raw[(size_t)y * (w * 3 + 1)] = 0; /* filter none */
        memcpy(&raw[(size_t)y * (w * 3 + 1) + 1], rgb + (size_t)y * w * 3,
               (size_t)w * 3);
    }
    uLongf clen = compressBound((uLong)raw.size());
    std::vector<uint8_t> comp(clen);
    if (compress2(comp.data(), &clen, raw.data(), (uLong)raw.size(), 6)
        != Z_OK)
        return -1;

    std::string tmp = path + ".tmp";
    FILE *f = fopen(tmp.c_str(), "wb");
    if (!f) return -1;
    static const uint8_t sig[8] = {0x89,'P','N','G','\r','\n',0x1a,'\n'};
    fwrite(sig, 1, 8, f);
    std::vector<uint8_t> ihdr;
    be32(ihdr, (uint32_t)w); be32(ihdr, (uint32_t)h);
    ihdr.push_back(8);  /* bit depth */
    ihdr.push_back(2);  /* color type RGB */
    ihdr.push_back(0); ihdr.push_back(0); ihdr.push_back(0);
    chunk(f, "IHDR", ihdr.data(), ihdr.size());
    chunk(f, "IDAT", comp.data(), clen);
    chunk(f, "IEND", nullptr, 0);
    fclose(f);
    return rename(tmp.c_str(), path.c_str());
}

} /* namespace pngw */
