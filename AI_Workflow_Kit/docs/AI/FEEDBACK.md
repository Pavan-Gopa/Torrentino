# FEEDBACK — WP-04 Review

**Reviewer:** Verification Engineer
**Date:** 2026-08-02
**Commit:** `e6f2d7e` — feat(torrentino): WP-04 — bridge и engine kernel
**RESULT:** CHANGES_REQUESTED → **FIXES APPLIED (waiting_review)**

---

## Coder fixes — all 7 CHANGES_REQUESTED items addressed

| # | Severity | Item | Fix | Verification |
|---|----------|------|-----|--------------|
| 1 | HARD | `EngineBridgeAdapter.mm` не компилируется | `bytesToBase64` переведён на скобочный вызов `base64EncodedStringWithOptions:`; `runBridge` переписан на вложенный C++ `try/catch` (`std::exception` → what(), `...` → unknown) + `@catch (id)` для ObjC-исключений; `.mm` компилируется в `test_bridge_headless.sh` (новый шаг «building bridge adapter [objc++ compile check]`, `-fobjc-arc -Werror`) и линкуется в smoke-бинарник | `test_bridge_headless.sh` PASS; `xcodebuild` CompileC `EngineBridgeAdapter.mm` без warnings |
| 2 | HARD | WP-04 не в Xcode project | `EngineBridgeAdapter.h/.mm`, `EngineCoordinator.swift`, `EngineBridgeDTOs.swift`, `EngineCoordinatorError.swift` добавлены в target `TorrentinoEngineAgent` (+ `EngineBridge.cpp` и статические `libtorrent-rasterbar.a`/`libssl.a`/`libcrypto.a` для линковки); создан `TorrentinoEngineAgent-Bridging-Header.h` (`#import "EngineBridgeAdapter.h"`) и задан `SWIFT_OBJC_BRIDGING_HEADER`; добавлены `GCC_PREPROCESSOR_DEFINITIONS` (TORRENT_*), `HEADER_SEARCH_PATHS`/`LIBRARY_SEARCH_PATHS` на pinned ThirdParty-префиксы, `CLANG_CXX_LANGUAGE_STANDARD=c++17`, `CLANG_ENABLE_OBJC_ARC=YES`, `OTHER_LDFLAGS` (`-framework CoreFoundation/SystemConfiguration`) | `xcodebuild build -scheme TorrentinoEngineAgent` BUILD SUCCEEDED; лог содержит `Compiling EngineCoordinator.swift` / `EngineBridgeDTOs.swift` / `EngineCoordinatorError.swift` / `EngineBridge.cpp` / `EngineBridgeAdapter.mm` (не вакуумно) |
| 3 | HIGH | pause/resume/recheck теряют torrentID | `voidCall` принимает явный payload; все три метода кодируют `TorrentIDPayload(torrentID:)` (`{"torrent-id": …}`) как в `requestResumeData` | `test_bridge_swift.sh` (новый, QA `test_wp04_bridge_swift.sh`): pause/resume/recheck по реальному id проходят до C++-движка, неизвестный id → `notFound` (доказывает, что id доезжает) |
| 4 | MEDIUM | boot report peer-id хардкод | `start()` записывает `config.peer_id_prefix` в `last_peer_id_`; убрано двойное присваивание `started` | Swift-тест: `peerIDPrefix: "-TT9001-"` → `boot.peerID == "-TT9001-"` |
| 5 | MEDIUM | deadline/cancellation не тестированы | `bridge_smoke.cpp`: `setOperationTimeout(1)` + `requestResumeData` → `BridgeError::timeout`; второй engine + in-flight `requestResumeData` (4 MiB торрент) + `shutdown()` → `BridgeError::stopped` без зависания (bounded join 10s, handshake-atomic) | `test_bridge_headless.sh` PASS (0 FAIL строк); ASan/UBSan/TSan 0 reports |
| 6 | LOW | alert_dump.cpp | удалён | `git status`: `D alert_dump.cpp`, ни один скрипт его не ссылается |
| 7 | LOW | мелочи | `classify()` удалён (все 3 вызова → `BridgeError::engine_failure`); DTO: `public var` → `public let` (37 свойств); `EngineAlertDTO.progress` заполняется из `handle.status().progress` (9 alert-типов); двойной `started = Clock::now()` убран | `xcodebuild` + swiftc typecheck (Swift 6 strict concurrency, warnings-as-errors) clean |

---

### 1. Build & tests

| Check | Result | Evidence |
|-------|--------|----------|
| Headless bridge lifecycle | **PASS** | `test_bridge_headless.sh` — `bridge smoke: PASS` (start→add→checked→pause→resume→recheck→remove→shutdown, 2.1.0/release). Log: `runs/smoke-2.1.0-release-20260802T142057Z/smoke.log` |
| ASan + UBSan | **PASS** | `run_bridge_sanitizers.sh` — asan/ubsan status 0, reports 0 |
| TSan | **PASS** | same run — tsan status 0, reports 0 (`runs/sanitizers-bridge-2.1.0-20260802T142103Z/`) |
| `xcodebuild TorrentinoEngineAgent` | **BUILD SUCCEEDED — но вакуумно** | 0 warnings/errors, **однако** `project.pbxproj` содержит **0** упоминаний `EngineBridge*`/`EngineCoordinator*` и не имеет `SWIFT_OBJC_BRIDGING_HEADER` — WP-04 файлы в сборку не входят вообще (см. §3-2). |
| QA regression suite | **PASS** | `run_qa_suite.sh` — 32/32 PASS, `SUITE RESULT: GREEN` (wp01 11, wp02 13, wp03 8) |
| Адаптер `.mm` компилируется | **FAIL** | Стенд-алон компиляция `EngineBridgeAdapter.mm` системным clang (те же defines/flags, что у smoke): 3 ошибки (см. §3-1). В репозитории нет ни одной сборки, которая его компилирует. |

### 2. Gate checklist

| Gate | Verdict | Evidence |
|------|---------|----------|
| C++ types не видны Swift API | **PASS по дизайну / FAIL по интеграции** | `EngineBridge.h` чист (только std). `EngineBridgeAdapter.h` чист (только Foundation, NSData/NSError). Но адаптер не собирается, Swift-слой не в проекте — end-to-end не проверяемо. |
| add/pause/resume/recheck работают headless | **PARTIAL** | C++ bridge: PASS (smoke покрывает все 4). Swift `EngineCoordinator`: **broken** — `pause/resume/recheck(torrentID:)` теряют id (см. §3-3). |
| ASan/UBSan/TSan runs чисты | **PASS** | 0 отчётов во всех трёх конфигурациях (см. §1). |
| Нет race/uncaught exception | **PASS на bridge-уровне** | TSan 0; все публичные методы `noexcept` + firewall; `shutdown()` noexcept/idempotent; `@catch(...)` закрывает. Adapter-уровень не компилируется — там не проверено. |
| Cancellation/deadline протестированы | **PARTIAL** | Deadline-механика есть (bounded waits, `wait_wake_`, `setOperationTimeout`), shutdown разблокирует ожидания и покрыт тестом идемпотентности. Но **ни один тест не провоцирует фактический timeout** (нет ожидания `BridgeError::timeout`) и нет теста прерывания ожидания через shutdown (см. §3-5). |

### 3. Code quality

**3-1. HARD — `EngineBridgeAdapter.mm` не компилируется (2 реальные синтаксические ошибки).**
Минимальные репро подтвердили ошибки системным clang (`-x objective-c++`):
- **строка 130**: `...].base64EncodedStringWithOptions:0` — dot-синтаксис с аргументом невалиден в ObjC (`property 'base64EncodedStringWithOptions' not found`). Нужно `[[NSData alloc] initWithBytes:…] base64EncodedStringWithOptions:0]` (скобки).
- **строка 255**: `@catch (const std::exception& e)` — `@catch` принимает только указатель на ObjC-интерфейс (`@catch parameter is not a pointer to an interface type`). Trampoline `runBridge` должен использовать C++ `try/catch` для C++-исключений (или `@catch (id)`), отдельно — `@catch` для ObjC.
Файл **нигде не собирался**: ни скрипт, ни xcodeproj его не компилируют.

**3-2. HARD — WP-04 не интегрирован в Xcode-проект.**
`grep -c "EngineBridge\|EngineCoordinator" Native/Torrentino.xcodeproj/project.pbxproj` → **0**. В target agent не входят: `EngineBridgeAdapter.h/.mm`, `EngineCoordinator.swift`, `EngineBridgeDTOs.swift`, `EngineCoordinatorError.swift`; нет bridging header. Итог: `xcodebuild BUILD SUCCEEDED` проверял только WP-03 agent, а не WP-04 bridge; Swift actor — мёртвый код относительно сборки.

**3-3. HIGH — `EngineCoordinator.pause/resume/recheck` теряют `torrentID`.**
Все три метода идут через `voidCall`, который жёстко шлёт `Data("{}".utf8)`, а замыкания (`adapter.pause(payloadData: $0, error: &$1)`) параметр `torrentID` не используют. Adapter читает `"torrent-id"` → пустая строка → `findHandleLocked("")` → **всегда** `not_found`. Контраст: `prepareRemoval`/`requestResumeData` корректно кодируют id через `TorrentIDPayload`/`RemovalTokenDTO`. Фикс: кодировать `TorrentIDPayload(torrentID:)` для трёх методов (или дать `voidCall` builder payload'а).

**3-4. MEDIUM — boot report врёт про peer-id.**
`report.peer_id = last_peer_id_`, а `last_peer_id_` инициализируется `"-TT0400-"` и **нигде не обновляется** из `config.peer_id_prefix` (в `start()`). Реальный engine получает префикс через `peer_fingerprint`, но отчёт покажет хардкод. Отчёт должен отражать фактически сконфигурированный префикс.

**3-5. MEDIUM — deadline/cancellation не протестированы по-настоящему.**
Нет ни одного теста, где операция реально возвращает `BridgeError::timeout` (например, `setOperationTimeout(1)` + запрос resume data), и нет теста, что `shutdown()` разблокирует in-flight ожидание (код для этого есть — `wait_wake_`/`stop_requested_`, но не покрыт).

**3-6. LOW (не блокеры):**
- `classify()` — обе ветки возвращают `engine_failure`; таксономия `io` не производится никогда. Упростить или убрать.
- DTO — `var`-свойства, а требование «immutable»; как value-типы они Sendable-безопасны, но формулировка завышена (можно `let`).
- `EngineAlertDTO.progress` нигде не заполняется (`convertAlert` всегда -1) — либо заполнять, либо убрать из схемы.
- `alert_dump.cpp` — временный debug-хелпер («temporary, WP-04»), закоммичен в дерево, ни одним скриптом не используется; убрать или подключить.
- `start()` дважды присваивает `started = Clock::now()` — косметика.

### 4. Architecture compliance

| Requirement | Verdict | Evidence |
|-------------|---------|----------|
| Role headers (1–5 строк) в каждом файле | **PASS** | Все 11 target-файлов имеют role/must-not/threading комментарии |
| PIMPL — header без libtorrent/Boost | **PASS** | `EngineBridge.h`: только `<cstdint>/<memory>/<string>/<vector>`; `Impl` в `.cpp`; `libtorrent`-инклюды только в `EngineBridge.cpp` |
| Exception firewall — все публичные методы `noexcept` + try/catch(...) | **PASS** | `start/add/pause/resume/requestRecheck/prepareRemoval/commitRemoval/drainAlerts/requestResumeData/saveSessionState/health/setOperationTimeout/shutdown` — все покрыты |
| Adapter `.h` без C++ типов | **PASS** | Только Foundation, NSData/NSError, kebab-case JSON |
| Coordinator actor — C++ pointer не пересекает границу | **PASS (дизайн)** | Adapter создаётся в `init()` actor'а; наружу только Sendable DTO |
| DTO — Codable + Sendable, kebab-case frozen | **PASS** | Все DTO Codable/Sendable/Equatable; CodingKeys kebab-case совпадают с wire-схемой адаптера |
| Alert batching — вектор, не по одному | **PASS** | `drainAlerts(max_count)` возвращает `std::vector<EngineAlertDTO>`; `alert_mask` фильтрует per-peer/per-piece |
| Deterministic shutdown | **PASS** | `shutdown() noexcept` idempotent; `pause() → pumpLocked() → abort() + join proxy`; unblocks waits |
| Legacy/ не тронут | **PASS** | В коммите нет ни одного legacy-файла |
| target_files only / нет будущих WP | **PASS** | Коммит затрагивает только WP-04 файлы (bridge, adapter, coordinator, scripts) |
| Why-comments у неочевидной логики | **PASS** | Отличные комментарии: ABI v1 `torrent_alert::alert_type`, save_resume_data filter, token nonce, `wait_for` predicate, boost/system category |

### 5. Concrete list (CHANGES_REQUESTED)

1. **Починить компиляцию `EngineBridgeAdapter.mm`**: строка 130 — заменить dot-синтаксис с аргументом на скобочный вызов; строка 255 — переписать `runBridge` на C++ `try/catch` + `@catch (id)` для ObjC-исключений. Добавить сборку `.mm` в какой-нибудь скрипт, чтобы ошибки ловились CI/QA (можно в `test_bridge_headless.sh` опциональным флагом или в QA-суиту).
2. **Интегрировать WP-04 в `Torrentino.xcodeproj`**: добавить `EngineBridgeAdapter.h/.mm` в target agent + `SWIFT_OBJC_BRIDGING_HEADER`; добавить `EngineCoordinator.swift`, `EngineBridgeDTOs.swift`, `EngineCoordinatorError.swift` в target. Пересобрать и убедиться, что Swift реально компилируется против bridging header (сейчас `xcodebuild` успешен вакуумно).
3. **Починить `pause/resume/recheck` в `EngineCoordinator`**: кодировать `{"torrent-id": …}` через `TorrentIDPayload` (как в `requestResumeData`); добавить юнит-тест, что payload содержит id.
4. **Boot report peer-id**: брать из `config.peer_id_prefix` (записывать в `last_peer_id_` в `start()`), а не из хардкода.
5. **Добавить тест deadline/cancellation**: `setOperationTimeout(1)` + `requestResumeData` → ожидать `BridgeError::timeout`; тест shutdown во время ожидания → `BridgeError::stopped`, без зависания.
6. **Убрать `alert_dump.cpp`** (временный хелпер) или подключить к скрипту.
7. **Low**: упростить `classify()`; `let` в DTO (immutability); заполнять или убрать `progress`; убрать двойное присваивание `started`.

**Резюме:** C++ ядро (PIMPL, firewall, batching, shutdown, sanitizers) выполнено чисто и подтверждено тестами. Но ключевой артефакт WP-04 — ObjC++ adapter — **не компилируется**, Swift-слой не входит в Xcode-проект, а три метода coordinator'а функционально сломаны. Gate «C++ types не видны Swift API» и «Build agent (includes bridge via xcodeproj)» прошли вакуумно. Вердикт: **CHANGES_REQUESTED**.
