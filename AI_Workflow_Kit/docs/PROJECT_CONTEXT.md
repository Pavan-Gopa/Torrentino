# Torrentino — Project Context

## Identity

Torrentino — нативный, локальный, минималистичный BitTorrent-клиент для Apple Silicon.
Целевая платформа: macOS 13+, только arm64.
Главный критерий: стабильность и сохранность данных.

## Architecture (one-liner)

SwiftUI/AppKit UI ↔ versioned XPC ↔ TorrentinoEngineAgent (LaunchAgent) ↔ ObjC++ PIMPL facade ↔ libtorrent 2.x ↔ SQLite WAL persistence.

## Repo map

```
Torrentino/
├── TORRENTINO_NATIVE_MACOS_IMPLEMENTATION_PLAN.md   # authoritative plan
├── AI_Workflow_Kit/                                  # agent workflow
│   ├── docs/
│   │   ├── AI/                                       # roles, state, kicks
│   │   ├── TORRENTINO_STEPS.md                       # condensed WP cards
│   │   ├── DECISIONS.md                              # ADR log
│   │   └── PROJECT_CONTEXT.md                        # this file
│   └── script/
│       └── checkpoint.sh                             # git tag helper
├── Native/                                           # NEW: native macOS app
│   ├── Torrentino.xcodeproj
│   ├── Config/                                       # xcconfig, entitlements
│   ├── TorrentinoApp/                                # UI target
│   ├── TorrentinoEngineAgent/                        # LaunchAgent target
│   ├── TorrentinoEngineBridge/                       # ObjC++/C++ facade
│   ├── TorrentinoIPC/                                # XPC protocol types
│   ├── TorrentinoDomain/                             # value types, state machines
│   ├── TorrentinoHashing/                            # CPU + optional Metal
│   ├── ThirdParty/                                   # libtorrent manifests, patches
│   └── Tests/                                        # all test targets
├── Legacy/
│   └── Tauri/                                        # FROZEN: old Tauri prototype
├── scripts/                                          # build/release scripts
└── artifacts/                                        # ignored; build outputs
```

## Build commands (after Native/ exists)

```bash
cd "/Users/pavan/Documents/AI Projects/Torrentino"

# Build
xcodebuild build \
  -project Native/Torrentino.xcodeproj \
  -scheme Torrentino \
  -destination 'platform=macOS,arch=arm64'

# Test
xcodebuild test \
  -project Native/Torrentino.xcodeproj \
  -scheme Torrentino \
  -destination 'platform=macOS,arch=arm64' \
  -resultBundlePath artifacts/tests/Torrentino.xcresult

# Analyze
xcodebuild analyze \
  -project Native/Torrentino.xcodeproj \
  -scheme Torrentino \
  -configuration Debug

# Archive (release)
xcodebuild clean archive \
  -project Native/Torrentino.xcodeproj \
  -scheme Torrentino \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath build/release/Torrentino.xcarchive \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO
```

## Key constraints

- Swift 6 strict concurrency: Complete from day one
- No Homebrew runtime dependencies
- No App Sandbox in v1
- Developer ID distribution (not App Store)
- Hardened Runtime for all executables
- libtorrent pinned: exact tag + commit + SHA-256
- Metal is research only (ADOPT/REJECT gate)
- 168h soak test before "stable" claim

## Git conventions

- Tags: `torrentino/pre-<WP>`, `torrentino/<WP>-done`
- Branch: `native-macos` for all native work
- Legacy frozen: never modify `Legacy/Tauri/`
- One WP per commit series, atomic commits within WP
