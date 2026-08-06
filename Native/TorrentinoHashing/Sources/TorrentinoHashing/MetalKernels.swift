// Layer: Hashing research (WP-12)
// Role: Metal Shading Language sources for the experimental SHA-256/SHA-1
// kernels, embedded so the library is compiled at runtime. Runtime
// compilation is deliberate: it enables the §12.8 fallback path "pipeline
// creation failure" to be exercised by tests, and the startup self-test can
// verify the compiled library before any production-size dispatch.
// Why MSL is handwritten here: CommonCrypto SHA-NI is CPU-only; no public
// Metal SHA library exists. The kernels below are standard FIPS 180-4 /
// FIPS 180-1 implementations with big-endian word loading.
// Invariants: thread-safe (no global state); each thread is fully
// independent; digests are written big-endian like CommonCrypto.

public enum MetalKernels {
    /// SHA-256: one thread per 16 KiB block; the thread chains the 256
    /// 64-byte sub-blocks serially (Merkle-Damgard), then the final FIPS 180-4
    /// padding block for a full 16 KiB message (0x80, zeros, 64-bit BE bit
    /// length), so the output is the standard SHA-256 digest of the whole
    /// block — byte-for-byte the value the CPU reference produces for a v2
    /// leaf. Blocks parallelize perfectly; sub-block order stays sequential.
    /// Buffer 0: input bytes (blockCount * 16384, contiguous)
    /// Buffer 1: output digests (blockCount * 32)
    /// Buffer 2: uint blockCount
    public static let sha256BlocksSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant uint32_t K[64] = {
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
    };

    inline uint32_t ror32(uint32_t x, uint n) {
        return (x >> n) | (x << (32u - n));
    }
    inline uint32_t bswap32(uint32_t x) {
        return ((x & 0xFFu) << 24) | ((x & 0xFF00u) << 8) | ((x >> 8) & 0xFF00u) | (x >> 24);
    }

    kernel void sha256_blocks(const device uchar* in [[buffer(0)]],
                              device uchar* out [[buffer(1)]],
                              constant uint& blockCount [[buffer(2)]],
                              uint tid [[thread_position_in_grid]]) {
        if (tid >= blockCount) return;
        uint32_t h[8] = {0x6a09e667u,0xbb67ae85u,0x3c6ef372u,0xa54ff53au,
                         0x510e527fu,0x9b05688cu,0x1f83d9abu,0x5be0cd19u};
        const device uchar* block = in + ((size_t)tid * 16384u);
        for (uint sub = 0; sub < 256u; sub++) {
            uint32_t w[64];
            for (uint j = 0; j < 16u; j++) {
                w[j] = bswap32(*(const device uint32_t*)(block + (size_t)sub * 64u + (size_t)j * 4u));
            }
            for (uint j = 16u; j < 64u; j++) {
                uint32_t s0 = ror32(w[j-15u],7u) ^ ror32(w[j-15u],18u) ^ (w[j-15u] >> 3u);
                uint32_t s1 = ror32(w[j-2u],17u) ^ ror32(w[j-2u],19u) ^ (w[j-2u] >> 10u);
                w[j] = w[j-16u] + s0 + w[j-7u] + s1;
            }
            uint32_t a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];
            for (uint j = 0; j < 64u; j++) {
                uint32_t S1 = ror32(e,6u) ^ ror32(e,11u) ^ ror32(e,25u);
                uint32_t ch = (e & f) ^ (~e & g);
                uint32_t t1 = hh + S1 + ch + K[j] + w[j];
                uint32_t S0 = ror32(a,2u) ^ ror32(a,13u) ^ ror32(a,22u);
                uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
                uint32_t t2 = S0 + maj;
                hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
            }
            h[0]+=a; h[1]+=b; h[2]+=c; h[3]+=d; h[4]+=e; h[5]+=f; h[6]+=g; h[7]+=hh;
        }
        // Final padding block for a full 16 KiB message: 0x80 at byte 0,
        // zeros, 64-bit big-endian bit length (16384 * 8 = 0x20000). It is
        // identical for every chunk, so the schedule is computed inline.
        {
            uint32_t w[64];
            for (uint j = 0; j < 64u; j++) w[j] = 0u;
            w[0] = 0x80000000u;
            w[15] = 0x20000u;
            for (uint j = 16u; j < 64u; j++) {
                uint32_t s0 = ror32(w[j-15u],7u) ^ ror32(w[j-15u],18u) ^ (w[j-15u] >> 3u);
                uint32_t s1 = ror32(w[j-2u],17u) ^ ror32(w[j-2u],19u) ^ (w[j-2u] >> 10u);
                w[j] = w[j-16u] + s0 + w[j-7u] + s1;
            }
            uint32_t a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];
            for (uint j = 0; j < 64u; j++) {
                uint32_t S1 = ror32(e,6u) ^ ror32(e,11u) ^ ror32(e,25u);
                uint32_t ch = (e & f) ^ (~e & g);
                uint32_t t1 = hh + S1 + ch + K[j] + w[j];
                uint32_t S0 = ror32(a,2u) ^ ror32(a,13u) ^ ror32(a,22u);
                uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
                uint32_t t2 = S0 + maj;
                hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
            }
            h[0]+=a; h[1]+=b; h[2]+=c; h[3]+=d; h[4]+=e; h[5]+=f; h[6]+=g; h[7]+=hh;
        }
        device uint32_t* d = (device uint32_t*)(out + (size_t)tid * 32u);
        for (uint j = 0u; j < 8u; j++) d[j] = bswap32(h[j]);
    }
    """

    /// SHA-1: one thread per v1 piece; the thread chains the 64-byte sub-
    /// blocks serially, so only piece-level parallelism is possible (v1 has
    /// no independent units below a piece). The final sub-block carries the
    /// FIPS 180-1 padding (0x80, zeros, 64-bit big-endian bit length).
    /// Buffer 0: input pieces, laid out contiguously at tid * pieceBytes
    ///           (short final piece: the buffer is zero-extended but only
    ///           pieceSizes[tid] bytes are hashed).
    /// Buffer 1: output digests (pieceCount * 20)
    /// Buffer 2: uint pieceBytes (fixed stride)
    /// Buffer 3: uint pieceCount
    /// Buffer 4: const uint* pieceSizes
    public static let sha1PiecesSource = """
    #include <metal_stdlib>
    using namespace metal;

    inline uint32_t s1_rol32(uint32_t x, uint n) { return (x << n) | (x >> (32u - n)); }
    inline uint32_t s1_bswap32(uint32_t x) {
        return ((x & 0xFFu) << 24) | ((x & 0xFF00u) << 8) | ((x >> 8) & 0xFF00u) | (x >> 24);
    }


    kernel void sha1_pieces(const device uchar* in [[buffer(0)]],
                            device uchar* out [[buffer(1)]],
                            constant uint& pieceBytes [[buffer(2)]],
                            constant uint& pieceCount [[buffer(3)]],
                            const device uint* pieceSizes [[buffer(4)]],
                            uint tid [[thread_position_in_grid]]) {
        if (tid >= pieceCount) return;
        const device uchar* piece = in + (size_t)tid * (size_t)pieceBytes;
        uint len = pieceSizes[tid];
        uint32_t h[5] = {0x67452301u,0xEFCDAB89u,0x98BADCFEu,0x10325476u,0xC3D2E1F0u};

        uint full = len / 64u;
        for (uint b = 0u; b < full; b++) {
            uint32_t w[80];
            for (uint j = 0u; j < 16u; j++) {
                w[j] = s1_bswap32(*(const device uint32_t*)(piece + (size_t)b * 64u + (size_t)j * 4u));
            }
            for (uint j = 16u; j < 80u; j++) {
                w[j] = s1_rol32(w[j-3u] ^ w[j-8u] ^ w[j-14u] ^ w[j-16u], 1u);
            }
            uint32_t a=h[0],b2=h[1],c=h[2],d=h[3],e=h[4];
            for (uint j = 0u; j < 80u; j++) {
                uint32_t f, k;
                if (j < 20u)      { f = (b2 & c) | ((~b2) & d); k = 0x5A827999u; }
                else if (j < 40u) { f = b2 ^ c ^ d;             k = 0x6ED9EBA1u; }
                else if (j < 60u) { f = (b2 & c) | (b2 & d) | (c & d); k = 0x8F1BBCDCu; }
                else              { f = b2 ^ c ^ d;             k = 0xCA62C1D6u; }
                uint32_t tmp = s1_rol32(a,5u) + f + e + k + w[j];
                e = d; d = c; c = s1_rol32(b2,30u); b2 = a; a = tmp;
            }
            h[0]+=a; h[1]+=b2; h[2]+=c; h[3]+=d; h[4]+=e;
        }

        // FIPS 180-1 padding over the real bytes only: 0x80, zero fill,
        // 64-bit big-endian bit length. rem >= 56 needs a second pad block.
        uint rem = len - full * 64u;
        ulong bitLen = (ulong)len * 8u;
        uchar pad[64];
        uint padBlocks = (rem >= 56u) ? 2u : 1u;
        for (uint blk = 0u; blk < padBlocks; blk++) {
            for (uint j = 0u; j < 64u; j++) pad[j] = 0u;
            if (blk == 0u) {
                for (uint j = 0u; j < rem; j++) pad[j] = piece[(size_t)full * 64u + j];
                pad[rem] = 0x80u;
            }
            // Length lands at bytes 56..63 of the final pad block.
            if (blk == padBlocks - 1u) {
                pad[63u] = (uchar)(bitLen & 0xFFu);
                pad[62u] = (uchar)((bitLen >> 8) & 0xFFu);
                pad[61u] = (uchar)((bitLen >> 16) & 0xFFu);
                pad[60u] = (uchar)((bitLen >> 24) & 0xFFu);
                pad[59u] = (uchar)((bitLen >> 32) & 0xFFu);
                pad[58u] = (uchar)((bitLen >> 40) & 0xFFu);
                pad[57u] = (uchar)((bitLen >> 48) & 0xFFu);
                pad[56u] = (uchar)((bitLen >> 56) & 0xFFu);
            }
            uint32_t w[80];
            for (uint j = 0u; j < 16u; j++) {
                w[j] = ((uint32_t)pad[j*4u] << 24) | ((uint32_t)pad[j*4u+1u] << 16) | ((uint32_t)pad[j*4u+2u] << 8) | (uint32_t)pad[j*4u+3u];
            }
            for (uint j = 16u; j < 80u; j++) {
                w[j] = s1_rol32(w[j-3u] ^ w[j-8u] ^ w[j-14u] ^ w[j-16u], 1u);
            }
            uint32_t a=h[0],b2=h[1],c=h[2],d=h[3],e=h[4];
            for (uint j = 0u; j < 80u; j++) {
                uint32_t f, k;
                if (j < 20u)      { f = (b2 & c) | ((~b2) & d); k = 0x5A827999u; }
                else if (j < 40u) { f = b2 ^ c ^ d;             k = 0x6ED9EBA1u; }
                else if (j < 60u) { f = (b2 & c) | (b2 & d) | (c & d); k = 0x8F1BBCDCu; }
                else              { f = b2 ^ c ^ d;             k = 0xCA62C1D6u; }
                uint32_t tmp = s1_rol32(a,5u) + f + e + k + w[j];
                e = d; d = c; c = s1_rol32(b2,30u); b2 = a; a = tmp;
            }
            h[0]+=a; h[1]+=b2; h[2]+=c; h[3]+=d; h[4]+=e;
        }

        device uchar* d = out + (size_t)tid * 20u;
        for (uint j = 0u; j < 5u; j++) {
            d[j*4u]   = (uchar)(h[j] >> 24);
            d[j*4u+1u] = (uchar)((h[j] >> 16) & 0xFFu);
            d[j*4u+2u] = (uchar)((h[j] >> 8) & 0xFFu);
            d[j*4u+3u] = (uchar)(h[j] & 0xFFu);
        }
    }
    """
}
