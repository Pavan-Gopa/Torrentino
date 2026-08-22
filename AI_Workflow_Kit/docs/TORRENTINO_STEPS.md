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
- [x] Diagnostic bundle не раскрывает приватные данные — release-integrity QA pass + structured password-free projection, escaped-secret-hardened redactor, behavioral parity test (FIX lane)
- [x] No secrets — source/bundle scans clean (RELEASE-INTEGRITY-QA-001); runtime-at-rest hardening SEC-1 routed to WP13-SEC-HARDEN-001
- [x] No Critical/High relevant CVE — WP13SecurityAuditor001: libtorrent 2.0.13/2.1.0, boost 1.91.0, openssl 3.5.7 verdict no_critical_high_relevant (SECURITY_FINDINGS.md 2026-08-22)
- [x] Entitlements минимальны — signed entitlements empty dicts, Hardened Runtime, ADR-008 compliant
- [x] Release build self-contained — arm64-only, minOS 13.0, zero Homebrew links, codesign strict valid

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

---

## WP-18 — Finder Services: «Create with Torrentino»

**Track:** FEATURE (Human-authorized 2026-08-22)
**Goal:** Правый клик по папке/файлу в Finder → Services → «Create with
Torrentino» — приложение открывает Create Torrent sheet с подставленным
источником; весь существующий inspect→commit конвейер без изменений.

**Gate:**
- [x] [WP18.D1] NSServices зарегистрирован в Info.plist
      (NSMenuItem default «Create with Torrentino», NSMessage createTorrent,
      NSSendFileTypes public.folder/public.item, контекст Finder)
- [x] [WP18.D2] AppDelegate: servicesProvider принимает file URLs из pasteboard,
      активирует главное окно и открывает CreateTorrentSheet с preset source;
      множественный выбор → первый элемент; cold-launch покрыт очередью
      pendingCreateSourcePath; auto-inspection по preset (delta-фикс)
- [x] [WP18.D3] XCTest: NSServices запись валидна; handler извлекает первый
      URL из синтетического pasteboard; WP18FinderServicesTests 2/2,
      полный TorrentinoAppTests 50/50 (Main-верификация независимым прогоном)
- [x] [WP18.J1] Reviewer approved (WP18ServiceReviewer001): 0 blockers,
      4 info-residual (coalescing повторных вызовов при открытом листе —
      задокументировано; hand-crafted UUIDs; stub-seam тест-таргета;
      опциональные доп. тесты)

---

## WP-19 — In-app updates: Sparkle 2 + GitHub Releases

**Track:** FEATURE (Human decisions 2026-08-22: GitHub Releases / Sparkle 2 / manual-only UX)
**Goal:** Кнопка «Check for Updates…» в меню приложения: проверка appcast на
GitHub Releases, EdDSA-верификация, диалог обновления. Без фонового поллинга.

**Gate:**
- [x] [WP19.D1] Sparkle 2 добавлен как запинненная зависимость
      (versions.lock + проект), версия зафиксирована
- [x] [WP19.D2] Меню «Check for Updates…» → SPUUpdater проверка вручную;
      SUFeedURL в одном конфигурируемом месте; без авто-проверок при старте;
      корректное поведение при отсутствии сети/404
- [x] [WP19.D3] XCTest: меню-действие вызывает updater; feed URL из единственного
      источника; suite зелёный
- [x] [WP19.J1] Reviewer: поверхность безопасности апдейта (подписи EdDSA
      обязательны, никакого downgrade-приёма, https-only), scope
- [ ] [WP19.H1] HUMAN: сгенерировать EdDSA-ключ (sign_update), опубликовать
      appcast + релиз; вписать боевой URL репозитория

---

## WP-20 — Add-sheet memory: last destination + start/paused choice

**Track:** FIX (Human request 2026-08-22)
**Goal:** AddTorrentSheet запоминает последнюю выбранную папку назначения
и последнее положение переключателя Start paused между запусками;
несуществующий путь не подсаживается (том мог быть отмонтирован).

**Gate:**
- [x] [WP20.D1] Персистентность UI-выбора: последний destination path и
      start-paused хранятся в UserDefaults (app-side), сидируются при
      открытии листа, сохраняются только при УСПЕШНОМ добавлении;
      magnet/URL-ветки не затирают запомненную папку
- [x] [WP20.D2] Stale-path защита: путь подсаживается только если существует
      на диске; иначе тихий фолбэк на текущее поведение
- [x] [WP20.D3] XCTest: правила сидирования/сохранения через изолированный
      UserDefaults suite; suite зелёный
- [x] [WP20.J1] Reviewer: scope, отсутствие записи в engine settings,
      согласованность с ADR «UI не источник правды» (память UI-преференций)

---

## WP-21 — Remove torrent and delete downloaded files

**Track:** FEATURE/FIX (Human request 2026-08-22)
**Goal:** Контекстное меню предлагает два честно различимых действия:
обычный Remove сохраняет данные; destructive «Remove and Delete Files…»
после явного подтверждения удаляет задачу и перемещает её данные в Trash,
используя существующий durable prepare→commit removal flow.

**Gate:**
- [x] [WP21.D1] Context menu: Remove (keep files) + destructive
      Remove and Delete Files…; target IDs берутся из context-menu selection
- [x] [WP21.D2] Confirmation объясняет необратимое действие для задачи,
      Trash-поведение и shared-file protection; Cancel не отправляет команд
- [x] [WP21.D3] ViewModel принимает explicit deleteFiles Bool и передаёт его
      в PrepareRemovalRequest; существующий false-путь не меняется
- [x] [WP21.D4] XCTest spy: false/true request wiring, confirm/cancel routing;
      полный suite зелёный
- [x] [WP21.J1] Reviewer: destructive UX, shared-file semantics, multi-select,
      durable retry/pending-removal поведение не сломано
