# Software Bill of Materials (SBOM) & Vulnerability Audit — WP-13

Authoritative Software Bill of Materials (SBOM) and security review for **Torrentino Native macOS** (v1 Release track).

---

## 1. Pinned Native Dependencies

| Component | Version / Tag | Git Commit | License | Distribution Model | SHA-256 Digest |
|---|---|---|---|---|---|
| **libtorrent (rasterbar)** | `2.1.1` (`v2.1.1`) | `56ae8caba38bf154ffc210403cb23f91d0ecaa49` | BSD-3-Clause | Static (`libtorrent-rasterbar.a`) | `0f163516ecef2e3331500266751de3098835a3c3ae0c2290448046c632bc0e93` |
| **OpenSSL** | `3.5.7` (`openssl-3.5.7`) | release tag | Apache-2.0 | Static (`libssl.a`, `libcrypto.a`) | `a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8` |
| **Boost** | `1.91.0` | `1a80576db6b70828803819fb6925132193bc5d0e` | BSL-1.0 | Header-only (`boost/`) | `de5e6b0e4913395c6bdfa90537febd9028ea4c0735d2cdb0cd9b45d5f51264f5` |
| **ed25519** | bundled in libtorrent | upstream | Zlib / Public Domain | Static | via libtorrent |
| **try_signal** | bundled in libtorrent | upstream | BSD-3-Clause | Static | via libtorrent |

- **No Homebrew Runtime Dependencies:** All C++ & C libraries are linked statically into the engine agent binary during build time. The final `.app` and `LaunchAgent` binary carry zero dynamic dependency on Homebrew, MacPorts, or non-system dynamic libraries.
- **Machine-Readable Locks:** Machine-readable pins live in `Native/ThirdParty/versions.lock`.

---

## 2. CVE & Vulnerability Review (WP-13)

- **libtorrent 2.1.1** (SEC-2 refresh from 2.1.0; fallback pin 2.0.14):
  - Audited against NVD and GitHub Advisory Database for libtorrent-rasterbar.
  - Critical/High Relevant CVEs: **0 found** (upstream publishes no advisories).
  - The 2026-08-10 hardening releases (2.1.1/2.0.14) fix compiled-in
    memory-safety paths relevant to this build (DHT salt limit, i2p SAM stack
    buffer, merkle tree validation); the pins were moved to them under SEC-2.
  - Historical issues related to UPnP/NAT-PMP packet handling in older 1.x
    releases do not affect the 2.1.x release line.
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
