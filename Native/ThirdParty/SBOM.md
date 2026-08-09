# Software Bill of Materials (SBOM) & Vulnerability Audit — WP-13

Authoritative Software Bill of Materials (SBOM) and security review for **Torrentino Native macOS** (v1 Release track).

---

## 1. Pinned Native Dependencies

| Component | Version / Tag | Git Commit | License | Distribution Model | SHA-256 Digest |
|---|---|---|---|---|---|
| **libtorrent (rasterbar)** | `2.1.0` (`v2.1.0`) | `578e06824c3546f3371ab43967ab288a7e253eca` | BSD-3-Clause | Static (`libtorrent-rasterbar.a`) | `ceed657606b8df453ec5e775326e3c759a2779e1202fa04abe42ed262e7bf0b6` |
| **OpenSSL** | `3.5.7` (`openssl-3.5.7`) | release tag | Apache-2.0 | Static (`libssl.a`, `libcrypto.a`) | `a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8` |
| **Boost** | `1.91.0` | `1a80576db6b70828803819fb6925132193bc5d0e` | BSL-1.0 | Header-only (`boost/`) | `de5e6b0e4913395c6bdfa90537febd9028ea4c0735d2cdb0cd9b45d5f51264f5` |
| **ed25519** | bundled in libtorrent | upstream | Zlib / Public Domain | Static | via libtorrent |
| **try_signal** | bundled in libtorrent | upstream | BSD-3-Clause | Static | via libtorrent |

- **No Homebrew Runtime Dependencies:** All C++ & C libraries are linked statically into the engine agent binary during build time. The final `.app` and `LaunchAgent` binary carry zero dynamic dependency on Homebrew, MacPorts, or non-system dynamic libraries.
- **Machine-Readable Locks:** Machine-readable pins live in `Native/ThirdParty/versions.lock`.

---

## 2. CVE & Vulnerability Review (WP-13)

- **libtorrent 2.1.0:**
  - Audited against NVD and GitHub Advisory Database for libtorrent-rasterbar.
  - Critical/High Relevant CVEs: **0 found**.
  - Historical issues related to UPnP/NAT-PMP packet handling in older 1.x releases do not affect the 2.1.0 release.
- **OpenSSL 3.5.7:**
  - Audited against OpenSSL Vulnerabilities database (LTS branch 3.5.x, supported until April 2030).
  - OpenSSL configured with `no-shared no-legacy no-apps no-docs no-tests`.
  - Dropping the legacy provider eliminates legacy cipher attack vectors.
  - Critical/High Relevant CVEs: **0 found**.
- **Boost 1.91.0:**
  - Used strictly as header-only (Asio, System, Config, Pool, CRC).
  - No binary boost components linked.
  - Critical/High Relevant CVEs: **0 found**.

---

## 3. License Compliance & Legal Posture

1. **Permissive Licensing:** All third-party software uses permissive open-source licenses (BSD-3-Clause, Apache-2.0, BSL-1.0, Zlib).
2. **No Copyleft Code:** No GPL, LGPL, AGPL, or MPL code is compiled or linked into Torrentino Native macOS.
3. **Attribution:** License texts and copyright notices are maintained in `Native/ThirdParty/LICENSES.md` for bundle inclusion.

---

## 4. Gate Verification Checklist

- [x] Diagnostic bundle does not reveal private data
- [x] No secrets (in logs, bundle, repo)
- [x] No Critical/High relevant CVE (documented review)
- [x] Entitlements minimal
- [x] Release build self-contained (without Homebrew runtime deps)
