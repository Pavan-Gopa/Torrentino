# Torrentino — Work Package Cards

> Condensed cards for agent execution. Full details: `TORRENTINO_NATIVE_MACOS_IMPLEMENTATION_PLAN.md`.

---

## WP-00 — Recovery checkpoint и чистая рабочая ветка

**Track:** FOUNDATION
**Goal:** Гарантировать откат до текущего состояния.

**Target files:** `.gitignore`, `AI_Workflow_Kit/docs/AI/STATE.yaml`

**Tasks:**
1. Зафиксировать `git status`, commit и diff
2. Создать commit текущего dirty state без исправлений
3. Создать `backup/pre-native-macos-<timestamp>` tag
4. Добавить/создать GitHub remote (с участием владельца)
5. Push commit + backup tag/branch
6. Создать `codex/native-macos` branch
7. Записать failing `cargo check` как baseline evidence

**Gate:**
- [ ] Checkpoint доступен локально и на GitHub
- [ ] Dirty user work сохранён
- [ ] Recovery checkout проверен read-only
- [ ] Legacy failure честно документирован

**Запрещено:** исправлять Tauri-код, очищать target, начинать Native до off-site backup.

---

## WP-01 — libtorrent arm64 bakeoff

**Track:** FOUNDATION
**Goal:** Доказать выбранный engine до UI.

**Target files:** `Native/ThirdParty/`, `Native/TorrentinoEngineBridge/` (harness)

**Tasks:**
1. Выбрать stable libtorrent 2.x, зафиксировать tag/commit/SHA
2. Зафиксировать Boost/TLS dependencies
3. Собрать minimal headless arm64 harness
4. Проверить: add .torrent, magnet metadata, pause/resume, v1/v2/hybrid IDs, save/load resume, session state, clean shutdown, crash restore, torrent creation
5. Запустить initial 24h soak
6. ASan/UBSan
7. Проверить `file`, `lipo`, `otool -L`, rpaths, minOS
8. Сохранить license/SBOM draft

**Gate:**
- [ ] Restore без потери registry/partial data
- [ ] Нет Homebrew runtime links
- [ ] Точный dependency lock
- [ ] Все C++ exceptions остаются внутри harness
- [ ] 24h без crash/hang

---

## WP-02 — Signed SMAppService lifecycle spike

**Track:** FOUNDATION
**Goal:** Доказать process model.

**Target files:** `Native/TorrentinoApp/` (minimal), `Native/TorrentinoEngineAgent/` (minimal), `Native/Config/`

**Tasks:**
1. Создать минимальные Swift app + agent
2. Зарегистрировать agent через SMAppService
3. Поднять signed Mach XPC
4. Сделать hello/health/durable counter
5. Проверить: close UI, SIGKILL UI, reopen, SIGKILL agent, launchd restart, logout/login, reboot, denied/requiresApproval, update N-1→N
6. Зафиксировать plist/identity/lifecycle contract
7. Проверить update state machine §8.6
8. Повторить в Developer ID configuration и clean user

**Gate:**
- [ ] UI/agent lifecycle доказан на подписанной сборке
- [ ] Agent не требует root
- [ ] Нет второго экземпляра
- [ ] Reconnect возвращает authoritative state
- [ ] Helper корректно unregister-ится
- [ ] Denial не включает in-process fallback
- [ ] N-1/N/downgrade semantics доказаны

---

## WP-03 — Native project skeleton и strict concurrency

**Track:** FOUNDATION
**Goal:** Создать поддерживаемый native foundation.

**Target files:** `Native/Torrentino.xcodeproj`, `Native/Config/`, `Native/TorrentinoApp/`, `Native/TorrentinoDomain/`, `Native/TorrentinoIPC/`

**Tasks:**
- Xcode targets/modules из §5 плана
- macOS 13/arm64 settings
- Swift 6 strict concurrency complete
- Warnings as errors для CI
- String Catalog English/Russian
- Basic app shell, menu, Settings placeholder
- Test profiles не используют production Application Support
- Debug/Release xcconfig

**Gate:**
- [ ] Clean build без warnings
- [ ] Unit test target запускается
- [ ] App показывает native empty state
- [ ] Старая версия не затронута

---

## WP-04 — Bridge и engine kernel

**Track:** ENGINE
**Goal:** Безопасно подключить libtorrent к agent.

**Target files:** `Native/TorrentinoEngineBridge/`, `Native/TorrentinoEngineAgent/EngineCoordinator/`

**Gate:**
- [ ] C++ types не видны Swift API
- [ ] add/pause/resume/recheck работают headless
- [ ] ASan/UBSan/TSan runs чисты
- [ ] Нет race/uncaught exception
- [ ] Cancellation/deadline протестированы

---

## WP-05 — XPC protocol v1

**Track:** ENGINE
**Goal:** Связать UI и agent через устойчивый контракт.

**Target files:** `Native/TorrentinoIPC/`, `Native/TorrentinoEngineAgent/Agent/`, `Native/TorrentinoApp/EngineClient/`

**Gate:**
- [ ] Version mismatch handled
- [ ] Duplicate command idempotent
- [ ] Dropped delta → reconciliation
- [ ] Reconnect works
- [ ] Instance change → full snapshot
- [ ] Oversized/invalid payload rejected
- [ ] Unsigned peer rejected
- [ ] Settings rollback/version conflict
- [ ] Hierarchical file paging
- [ ] All contract tests green

---

## WP-06 — Durable persistence/recovery

**Track:** ENGINE
**Goal:** Восстановление после нормального и аварийного завершения.

**Target files:** `Native/TorrentinoEngineAgent/Persistence/`, `Native/TorrentinoEngineAgent/Recovery/`

**Gate:**
- [ ] Три clean restore cycles
- [ ] Repeated kill -9 restore
- [ ] No duplicate/lost records
- [ ] Desired states сохранены
- [ ] Corrupt resume → quarantine/recheck, не crash
- [ ] Corrupt DB → controlled recovery/degraded
- [ ] WAL-only commit восстанавливается
- [ ] clean_shutdown остаётся false при незавершённой фазе
- [ ] Payload не изменён

---

## WP-07 — Core transfer vertical slice

**Track:** PRODUCT
**Goal:** Первый end-to-end usable flow.

**Gate:**
- [ ] UI не polling full list
- [ ] Row identity/focus/scroll стабильны
- [ ] 100-row fixture
- [ ] Metadata/file list не блокирует MainActor
- [ ] Restart сохраняет flow
- [ ] Один torrent error не блокирует другие
- [ ] Untrusted source не может создать путь вне validated root

---

## WP-08 — Native UX completeness

**Track:** PRODUCT
**Goal:** Минимальный, но полноценный daily-use клиент.

**Gate:**
- [ ] Keyboard-only core flow
- [ ] VoiceOver audit
- [ ] Light/Dark/Increase Contrast/Reduce Motion
- [ ] Focus restoration после sheet/reconnect
- [ ] Zero missing String Catalog keys
- [ ] Russian long-string layout
- [ ] No routine modal alerts
- [ ] 100–500 row performance

---

## WP-09 — Fault recovery и resource control

**Track:** PRODUCT
**Goal:** Устранить причины долгосрочных зависаний.

**Gate:**
- [ ] Полная fault matrix зелёная
- [ ] Нет busy-loop
- [ ] Нет глобального stop из-за одной задачи
- [ ] Recovery actions понятны
- [ ] No unexpected folder creation for missing volume

---

## WP-10 — Safe file operations

**Track:** PRODUCT
**Goal:** Сделать move/remove/recheck безопасными.

**Gate:**
- [ ] Файл вне manifest невозможно удалить
- [ ] Keep-data не изменяет payload
- [ ] Failed Trash не удаляет record
- [ ] Partial Trash восстанавливается или guided recovery
- [ ] Crash во время move восстанавливается
- [ ] No permanent delete API

---

## WP-11 — Torrent Creator CPU reference

**Track:** PRODUCT
**Goal:** Production-correct v1/v2/hybrid creator.

**Gate:**
- [ ] v1/v2/hybrid проходят независимую проверку
- [ ] Source не изменяется
- [ ] Cancel не оставляет valid-looking partial output
- [ ] Все edge cases покрыты
- [ ] Creator usable без Metal
- [x] Fresh non-private Creator enables reviewed third-party tiers; visible opt-out removes only recommended tiers
- [x] Manual topology remains exact; private receives no recommendation and still fails closed when empty
- [x] Visible effective tiers equal inspect, commit and parsed `announce-list`; Domain and pinned libtorrent parse pass
- [x] Permanent EN/RU best-effort disclosure is visible; no managed service, guarantee, IPC, persistence or engine change


---

## WP-12 — Metal research

**Track:** RESEARCH
**Goal:** Принять measured ADOPT_METAL или REJECT_METAL.

**Gate:**
- [ ] Все критерии §12 плана выполнены
- [ ] Формальный ADR
- [ ] При REJECT — prototype удалён из release targets
- [ ] При ADOPT — default Automatic + CPU fallback

---

## WP-13 — Diagnostics, security, dependencies

**Track:** RELEASE
**Goal:** Завершить observability и повторно аудировать protections.

**Gate:**
- [ ] Diagnostic bundle не раскрывает приватные данные
- [ ] No secrets
- [ ] No Critical/High relevant CVE
- [ ] Entitlements минимальны
- [ ] Release build self-contained

---

## WP-14 — Performance qualification

**Track:** RELEASE
**Goal:** Измерить поведение под длительной нагрузкой.

**Gate:**
- [ ] SLO §11 выполнены
- [ ] Нет монотонной утечки
- [ ] Queues bounded, authoritative state не теряется
- [ ] Watchdog не делает false restart
- [ ] Report сохранён

---

## WP-15 — 168-hour stability gate

**Track:** RELEASE
**Goal:** Получить право назвать продукт стабильным.

**Gate:**
- [ ] 0 unexpected crashes
- [ ] 0 unrecovered hangs
- [ ] 0 corrupt payloads
- [ ] 0 lost records
- [ ] 100% reconnect/recovery
- [ ] 100% deterministic payloads pass final recheck
- [ ] No monotonic resource growth
- [ ] Diagnostic export работает под нагрузкой

---

## WP-16 — Signing, notarization и release

**Track:** RELEASE
**Goal:** Доставить проверяемый production DMG.

**Gate:**
- [ ] Полный release chain из §23 плана
- [ ] Notarization/stapling не меняют executable content
- [ ] Clean-machine install/update/uninstall пройдены

---

## WP-17 — Legacy retirement decision

**Track:** RELEASE
**Goal:** Отдельно решить судьбу Tauri-прототипа.

**Gate:**
- [ ] Никакого автоматического удаления legacy
- [ ] Решение зафиксировано в DECISIONS.md
