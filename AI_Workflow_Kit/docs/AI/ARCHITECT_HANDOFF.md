# Architect → Orchestrator handoff — WP-13 engine session lifecycle (escalation)

## Feature / Change

Это **один архитектурный пакет для WP-13** (эскалация Human 2026-08-09), не
новый WP. Цель: **при каждом запуске приложения движок стартует корректно и
остаётся корректным весь сеанс** — один устойчивый engine session lifecycle и
одна ownership-модель вместо цикла per-lane заплаток. Пакет закрывает шесть
задокументированных recurring failures (restore rebuilt 0 над verified=9,
health latch, idle limbo, мёртвый diagnostics sink, agent lifecycle churn,
`event_bus_unavailable`) через явную state machine, single-writer health,
единый admission, session-scoped shutdown и bootstrap-verified observability.
Все ранее принятые поведения (rounds 1–7, live-lanes) перечислены в
**Preserved behavioral contract** и обязательны к сохранению.

## Decision summary (ADR-019)

- **ADR-019 — Engine session lifecycle: explicit state machine, single-writer
  health, unified admission, session-scoped shutdown** (appended to
  `AI_Workflow_Kit/docs/DECISIONS.md`).
- Key decisions: (1) явная session state machine поверх уже замороженного IPC
  vocabulary `EngineLifecycleState` с fail-closed переходами и инвариантом R0
  («никогда не rebuilt 0 молча над непустым verified store»); (2) tolerant
  decode как дизайн-правило + единая admission-функция с постусловиями P1–P4;
  (3) единственный writer health/activity/rates — `TransferCoordinator` через
  чистый `HealthPolicy`; UI не пишет health; (4) launchd владеет процессом
  агента, UI владеет shutdown veto (session-scoped shutdown), event bus
  создаётся до resume listener'а; (5) diagnostics sink — bootstrap-verified
  service с обязательными marker-строками; (6) декомпозиция god-object'а
  отдельным lane'ом, минимальной последовательностью, без big-bang.
- Untrusted ENGINE-002 diff в дереве — **только evidence**. Coder оценивает
  каждый hunk против этого контракта в Step 0 имплементации; дизайн на нём
  не строится.

---

## 1. Session state machine (agent)

Машина состояний реализуется в агенте поверх **уже замороженного** vocabulary
`Native/TorrentinoIPC/State.swift:221` (`EngineLifecycleState`) и события
`EngineLifecycleChangedEvent` (`Native/TorrentinoIPC/Events.swift:11`),
которые сейчас объявлены, но не реализованы и не эмитятся. Никаких новых
wire-типов не требуется.

### States (mapping на frozen vocabulary)

| Phase | `EngineLifecycleState` | Meaning |
|---|---|---|
| Process bootstrap | `starting` | `AgentRuntime.init`: log sink self-test, engine dir, instance lock, advisory lock, crash guard, counter store. |
| Persistence open | `openingStore` (→ `migratingStore` при миграциях) | `persistence.open()` в background; listener уже принимает соединения. |
| Restore | `restoringSession` | coordinator wired, restore pipeline читает store, settings, journals. |
| Admission/reconcile | `reconcilingRecords` | restore summary зафиксирован, первый pump/admission pass. |
| Running | `ready` | pump активен, health live-derived, команды обслуживаются полностью. |
| Degraded | `degraded` (+ `degradedReason`) | Достигается из любой pre-ready фазы по fail-closed триггеру (см. ниже). |
| Shutdown | `checkpointing` → `stopping` → `stopped` | flush → clean close (WAL checkpoint, clean flag) → `exit(0)`. |

### Transitions и fail-closed семантика

| From → To | Trigger | Fail-closed semantics |
|---|---|---|
| `starting` → `openingStore` | init успешен | Любой lock/counter/IO fault → `exit(1)` (launchd restart throttled) или `exit(78)` downgrade; stderr + log до выхода. |
| `openingStore` → `restoringSession` | `open()` вернул report | `open()` failure → `degraded(persistenceUnavailable)`: hello/health/shutdown обслуживаются; библиотечные команды (fetchSnapshot/commitAdd/…) возвращают typed fault, **никогда** пустой успех. |
| `restoringSession` → `reconcilingRecords` | restore summary готов | **R0**: `stored>0 ∧ rebuilt==0` → `degraded(restoreAnomaly)` + error log; fetchSnapshot fault; пустой snapshot не публикуется. Частичные сбои допустимы: rebuilt+skipped summary обязан быть ненулевой консистентным. |
| `reconcilingRecords` → `ready` | первый pump scheduled | engine start failure не блокирует фазу: admission деферится с typed health (P3), pump ретраит с backoff. |
| `ready` ⇄ `degraded(reason)` | conditions/persistence fault | Деградация в `ready` (например, persistence write failure классом corruption) допустима только с loud event + typed reason; восстановление — через `restartEngineSafely` или relaunch. |
| any → `checkpointing` → `stopping` → `stopped` | authorized stop (session-scoped shutdown ∨ SIGTERM/SIGINT) | pump остановлен до clean-shutdown pipeline; ack до exit; `exit(0)`; неавторизованный shutdown отклоняется (см. §5). |

Каждый переход: (a) пишется в file sink + OSLog строкой
`lifecycle transition from=<a> to=<b> reason=<r>`; (b) эмитится как
`EngineLifecycleChangedEvent(from:to:degradedReason:revision:)` urgent-путём
event bus (bus существует с bootstrap, §5).

### Command gating по фазам

| Команда | `starting`–`restoringSession` | `ready` | `degraded` |
|---|---|---|---|
| `hello`, `health`, `shutdown` | всегда обслуживаются | да | да |
| `fetchSnapshot`, все library/transfer команды | typed `engineNotReady` fault (существующее поведение, сохранить) | да | typed fault с reason деградации (`persistenceUnavailable` / `restoreAnomaly`), **никогда** пустой успех |

UI retry-контракт покрывает boot-window: `EngineClient.call()` bounded
reconnect + `TorrentListViewModel.start()` 5×500 ms — сохранить без изменений.

### Инварианты фазовой машины

- **R0 (restore anomaly):** `rebuilt==0` при непустом verified store —
  громкая деградация, не молчаливая пустая библиотека.
- **R1 (phase monotonicity):** фаза только продвигается вперёд; повторный
  вход в `restoringSession` запрещён (restore идемпотентен в рамках одного
  прохода; повторный restore — только через новый процесс/`restartEngineSafely`).
- **R2 (no silent exit):** любой не-zero exit сопровождается stderr + log;
  clean exit всегда `0` (LIFECYCLE_CONTRACT.md §3 сохранён).

---

## 2. Ownership map (single-writer rule)

| Артефакт | Единственный writer | Запрещено писать | Механизм |
|---|---|---|---|
| `TransferRecord.health/activity/downloadBytesPerSec/uploadBytesPerSec/progress/peers` | `TransferCoordinator` (actor), только через `HealthPolicy`-проекции (§4) | `BridgeTransferEngine`, `StatusCache`, `TorrentListViewModel`, `InspectorView`, любой UI-код | Все 4 текущие проекции сводятся к одной: `StatusCache`/`BridgeTransferEngine` = telemetry-источник; UI = read-only presentation |
| `TorrentHealth`-классификация (правила mapping) | `HealthPolicy` (чистые функции; в L1 может жить inline в coordinator, в L2.1 извлекается в `Native/TorrentinoEngineAgent/Transfer/HealthPolicy.swift`) | Дублирование правил в UI (`projectHealth`), в `LibtorrentActivityMapper.health` как отдельном авторитете | `LibtorrentActivityMapper.health` остаётся telemetry-mapping'ом алертов; record-level правила — только в `HealthPolicy` |
| `records`/`recordRevisions`/`engineRevision`/delta publication | `TransferCoordinator` | все | существующий контракт («ONLY writer of records and revisions») сохраняется |
| Durable persistence (SQLite/generation files) | `PersistenceStore` через coordinator-вызовы | прямые записи из UI/bridge | без изменений |
| Agent process lifetime | launchd (plist frozen, ADR-004) | любой XPC-клиент, кроме session-scoped shutdown (§5) | connection registry + veto |
| Per-torrent fault triangles | `HealthPolicy.triangleClassification` | UI-эвристики | §4, triangle policy |
| Process-level health (`--cli health` payload) | `AgentHealthLane` | coordinator/UI | без изменений; дополняется plist-only ключами §1/§6 |
| Log file sink + OSLog | `TorrentinoLog` facade → `RedactedLogFileManager.shared` | прямой `Logger()` в product-путях (существующее WP-13 Reviewer-правило) | §6 |

**UI не имеет права писать health**: `TorrentListViewModel.projectHealth`
(семантический rewrite transient→healthy) **удаляется**; его правило переезжает
в `HealthPolicy.transientSuppression` (единственный владелец). UI остаётся
только mapping health → icon/text/tooltip/localization.

---

## 3. Restore/admission contract

### 3.1 Tolerant decode — дизайн-правило (не per-lane заплатка)

- **Strict** только core identity: `id` (valid UUID string), `infoHashV1/V2`
  hex, `name`, `state`, `addedAt`. Всё остальное — tolerant:
  `decodeIfPresent`-семантика с typed fallback; unknown/extra fields
  игнорируются; altered shapes от будущих/отклонённых lane'ов не роняют запись.
- Применяется ко всем persisted side-tables: `torrent_limits`,
  `torrent_location`, `TrackerTopologyEnvelope` (versioned JSON,
  ADR-017-совместимо), metainfo payload, settings JSON.
- Частичный сбой на запись ≠ пропуск записи: запись **rebuilt**, сбой
  классифицируется в typed `TorrentHealth` (например, metainfo integrity
  failure → `.recoverableError(.storeError)`, topology fallback →
  metainfo tiers + warning) и логируется redacted.
- `try?` не используется для сокрытия topology/decode ошибок в restore
  (ADR-017 правило сохранено): каждый fallback явно логируется.

### 3.2 Per-record classification + mandatory summary

Каждая запись получает один из исходов:
- `rebuilt` — видима, health по storage/conditions;
- `rebuiltWithWarning(typedHealth)` — видима, typed health за частичный сбой;
- `skipped(reason)` — не видима; только при невалидном core identity
  (invalid UUID); reason логируется redacted.

**Контракт summary (обязателен при каждом boot):**
- log line (file + OSLog): `restore summary rebuilt=N skipped=M engineRevision=K`;
- plist-only ключи в `health()` reply: `restoreRebuilt`, `restoreSkipped`,
  `sessionPhase` (backward-compatible: клиент игнорирует неизвестные ключи);
- `N==0 ∧ stored>0` ⇒ R0 (degraded), см. §1.

### 3.3 Единый admission (один путь, один набор инвариантов)

Все пути сходятся в **одну** функцию (имя для Coder'а, например
`admit(record, reason:) -> AdmissionOutcome`), reason ∈
`{commitAdd, restoreReadd, resume, pumpReadd, engineRestart}`. Текущие
разнесённые реализации (`handleCommitAdd` engine-add ветка, resume re-add
ветка `handlePauseResume`, re-add цикл `pumpOnce`, restore initial-activity)
заменяются вызовами этой функции; дублирование gate-логики устраняется.

**Gate order (fail-closed, первый отказ побеждает):**
1. `safeRecovery` → defer(`.recoverableError(.crashLoopSafeMode)`);
2. `desired == .paused` → admit paused (`engine.add(paused: true)`),
   `activity=idle`, `health=healthy` (paused-запись получает engine slot —
   resume мгновенный);
3. storage probe с **remaining bytes** (§4.3) → defer(typed storage health);
4. system conditions (sleeping / network / resource budget) → defer(typed
   environment health);
5. slot check (`canAdmitEngineWork`, существующая логика) →
   defer(`.recoverableError(.resourceConstrained)`);
6. `ensureEngineStarted` → defer(`.recoverableError(.engineNotReady)`);
7. `engine.add(specification)` → success: `engineID`, health `.healthy`;
   failure: typed `engineHealth` + backoff (существующий `readdBackoff`).

**Постусловия (assert + regression tests):**
- **P1:** `admitted ∧ desired==running` ⇒ `activity ∈ {fetchingMetadata,
  checking}` (bootstrap activity; первый pump заменяет engine-truth'ом).
  **Никогда не `idle`.**
- **P2:** `admitted ∧ desired==paused` ⇒ `activity==idle ∧ health==healthy`.
- **P3:** `deferred` ⇒ `health != .healthy` (typed reason) ∧ `activity==idle`.
- **P4 (no idle limbo):** не существует записи `desired==running ∧
  activity==idle ∧ health==healthy`. Pump на каждом проходе проверяет P4;
  нарушение = bug: loud warning log + принудительная re-admission попытка.

---

## 4. Health/truthfulness contract

### 4.1 Live-derived health и latch clearing

- Record health для записей с `engineID` **ре-деривируется на каждом pump**
  из telemetry: никакой cached fault не переживает здоровый live sample.
- One-shot error alert = evidence с **bounded TTL** (рекомендация 30 s,
  настраиваемо константой): `StatusCache` хранит `errorObservedAt`; sample
  старше TTL без повторного алерта декатирует в healthy. Это устраняет latch
  «один алерт → вечный треугольник на тихом seeding».
- **Transient suppression** (правило, ранее дублировавшееся в UI):
  `recoverableError(internalError|engineBusy|engineNotReady|operationTimeout|
  engineUnresponsive)` подавляется в `.healthy`, пока `activity ∈
  {fetchingMetadata, queued, checking, downloading, seeding}` — но теперь
  только в `HealthPolicy`, не в UI.

### 4.2 Truthful actionable faults — triangle policy

| Health | Presentation | Обоснование |
|---|---|---|
| `waitingForSpace`, `permissionDenied`, `waitingForVolume`, `fatalError(*)`, `recoverableError(storeError/corruptData-класс)` | **triangle** + localized actionable text (required/free bytes, volume, permissions) | пользователь может действовать |
| `waitingForNetwork`, `systemSleeping`, `resourceConstrained`, `engineNotReady` (transient) | status text, без triangle | транзиентные environment-состояния |
| `crashLoopSafeMode` | session-level banner | не per-record fault |

`waitingForSpace` обязан нести actionable данные (required/available) в
fault-контракте — существующий `storageFault` factory сохранён.

### 4.3 Storage probe: remaining bytes, не total

- Probe в pump/admission использует `requiredBytes = max(0, effectiveTotal −
  downloadedBytes)` (по текущей record-проекции). Для seeding
  (`downloaded == total`) required = 0 ⇒ probe проходит ⇒ latch
  `waitingForSpace` на рабочих торрентах устраняется.
- Restore-time probe (когда downloaded ещё неизвестен) — только admission
  gate; первый live status авторитетен и очищает/уточняет.

---

## 5. Agent lifecycle / keepalive contract

### 5.1 Кто владеет жизнью агента

- **Процессом владеет launchd** (frozen plist: `RunAtLoad`, on-demand Mach
  spawn, `KeepAlive.SuccessfulExit=false`, `ThrottleInterval=10` —
  LIFECYCLE_CONTRACT.md без изменений). Агент продолжает работать headless
  после выхода UI (seeding не останавливается) — существующее поведение.
- **Пока UI подключён, UI владеет shutdown veto.** `AgentRuntime.ListenerDelegate`
  ведёт счётчик активных UI-соединений (`shouldAcceptNewConnection` +1,
  interruption/invalidation −1, под `stateQueue`).
- **Session-scoped shutdown:** `AgentService.shutdown` обслуживается
  (ack `true` + stop) **только если активных соединений ≤ 1** (запрашивающий
  — последний). Иначе reply `false`, агент продолжает работать.
  - Следствие 1 (churn устранён): shutdown от умирающего старого инстанса UI
    не убивает свежезапущенный агент, у которого уже подключён новый UI
    (count ≥ 2 ⇒ отказ).
  - Следствие 2: `--cli shutdown` при живом UI отказан (`acknowledged=false`,
    CLI уже различает true/false); оркестраторский fresh-build gate сначала
    закрывает приложение — совместимо.
  - ADR-004 бюджеты сохранены: ack-first, exit ~250 ms, UI 5 s cap.
- `prepareForQuit` остаётся no-op ack (зарезервирован под будущий протокол).

### 5.2 Boot-order контракт для event bus

- `TransferEventBus` конструируется в `AgentRuntime.init` (до
  `beginServing()`), инжектится в `AgentService` при конструировании.
  **`subscribeEvents` не может быть отклонён по таймингу** — bus существует
  всегда; до wiring coordinator'а он просто пуст.
- `sendCommand` до wiring coordinator'а сохраняет typed `engineNotReady`
  fault (fail-closed, существующее поведение); client-side bounded retry
  покрывает boot window.
- `service.coordinator`/`service.eventBus` set-once wiring сохранён, но bus
  перестаёт быть nil-able.

---

## 6. Diagnostics bootstrap contract

- **Физическое расположение:** `RedactedLogFileManager` (actor,
  `Native/TorrentinoEngineAgent/Agent/RedactedLogFileManager.swift`) за
  facade `TorrentinoLog` (`DiagnosticsLogging.swift`). Единственный вход;
  прямой `Logger()` в product-путях запрещён (WP-13 Reviewer-правило).
- **Инициализация — первая строка `AgentMain.main()`:**
  `TorrentinoLog.bootstrap()` — синхронный self-test: создать каталог →
  открыть `engine_log_current.log` → записать marker → flush → прочитать
  последнюю строку. Failure ⇒ stderr FATAL + OSLog fault +
  `observability=degraded` в health payload; агент продолжает работать
  (OSLog жив), но деградация observability видна.
- **Обязательные marker-строки каждого boot'а** (fresh-build gate asserts
  наличие в file sink И в OSLog):
  1. `agent bootstrap start version=<v>`
  2. `log sink ready path=<redacted>` (или `log sink degraded reason=<r>`)
  3. `agent bootstrapped version=<v> pid=<p>`
  4. `persistence open ... verified=N quarantined=M`
  5. `restore summary rebuilt=N skipped=M engineRevision=K`
  6. `transfer lane wired and status pump started`
- Контракт делает sink «неубиваемым» при рефакторинге: lazy-инициализация
  запрещена; отсутствие marker-строк в fresh build = gate failure.

---

## 7. UI contract changes (truthfulness)

- `TorrentListViewModel.projectHealth` (semantic rewrite) **удаляется**;
  transient suppression живёт в агентском `HealthPolicy` (§4.1).
- Demo-fixture fallback сохраняется **только** для transport-level
  недоступности (bounded reconnect исчерпан). Если агент reachable, но
  возвращает typed fault/degraded — UI показывает degraded banner
  (существующий `connectionNote`-механизм + lifecycle event), не фиктивные
  торренты.
- `EngineLifecycleChangedEvent` начинает обрабатываться UI (сейчас `break`):
  banner для `degraded` с `degradedReason`, без изменения list-состояния.
- Существующие UI-поведения (connecting text при zero-rate, status text,
  tooltips, inspector) сохраняются; меняется только источник правды.

---

## 8. Acceptance matrix

| # | Invariant | Уровень теста | Наблюдаемое доказательство | Owning file |
|---|---|---|---|---|
| I1 | R0: rebuilt 0 над непустым verified store никогда не молчит | agent XCTest (injected decode/store failure) + disposable live | `sessionPhase=degraded(restoreAnomaly)` в health payload; fetchSnapshot typed fault; error log line; пустой snapshot не публикуется | `Transfer/TransferCoordinator.swift`, `Agent/AgentRuntime.swift` |
| I2 | Tolerant decode extra/old shapes | agent XCTest | `testRestoreToleratesExtraFieldsAndOldShape`: rebuilt==2, skipped==0 (сохранить/усилить) | `Persistence/PersistenceStore.swift`, `Transfer/TransferCoordinator.swift` |
| I3 | Rebuilt/skipped summary обязателен каждый boot | observability script + fresh-build gate | marker-строка 5 в file+OSLog; `restoreRebuilt/restoreSkipped` в `--cli health` | `Agent/AgentRuntime.swift` |
| I4 | Единый admission, P1–P4 (нет idle limbo) | agent XCTest по каждому reason (commitAdd/restoreReadd/resume/pumpReadd/engineRestart) + live snapshot sweep | нет записи `desired=running ∧ activity=idle ∧ health=healthy`; resume/commit/restart сходятся в `admit()` | `Transfer/TransferCoordinator.swift` |
| I5 | Live-derived health, latch clearing (TTL + transient suppression) | agent XCTest (one-shot alert → healthy sample → clear; TTL expiry) + live | `recoverableError(internalError)` очищается ≤ TTL при живой activity; нет вечных треугольников на рабочих торрентах | `Transfer/StatusCache.swift`, `Transfer/BridgeTransferEngine.swift` (telemetry), `Transfer/TransferCoordinator.swift` (records) |
| I6 | Triangle только для truthful actionable faults | `HealthPolicy` unit + live screenshot | space/permission/volume/fatal ⇒ triangle+action text; network/sleep/resource ⇒ text only | `Transfer/TransferCoordinator.swift` (→ `HealthPolicy.swift` в L2.1) |
| I7 | Session-scoped shutdown, нет churn | lifecycle live proof (disposable) | `--cli shutdown` при живом UI ⇒ `acknowledged=false`, агент жив; после quit UI ⇒ `true`, exit 0; нет `shutdown requested via xpc` сразу после bootstrap нового агента | `Agent/AgentService.swift`, `Agent/AgentRuntime.swift` |
| I8 | Event subscription не отклоняется по таймингу | agent XCTest (subscribe до wiring) + live log | `subscribeEvents=true` в boot window; нет `event_bus_unavailable` | `Agent/AgentRuntime.swift`, `Agent/AgentService.swift` |
| I9 | Diagnostics sink жив с первой строки bootstrap | fresh-build gate | marker-строки 1–6 в `engine_log_current.log` И в OSLog каждого fresh build | `Agent/AgentMain.swift`, `Agent/DiagnosticsLogging.swift`, `Agent/RedactedLogFileManager.swift` |
| I10 | UI не показывает fixture при reachable-агенте | app XCTest | typed fault ⇒ `connectionNote`/banner; fixture только при transport unavailability | `Features/TorrentListViewModel.swift` |
| I11 | Preserved behavioral contract (§10) | full XCTest + `test_wp07_file_selection.sh` + `test_wp10_removal_durable.sh` + observability script + live checklist | все перечисленные поведения PASS без регрессий | все target files |

---

## 9. Ordered Coder implementation sequence

### Lane L1 — «Engine session lifecycle» (один серийный owner, hot files bundled)

Поведенческий контракт-процесс (standing rule 2026-08-09): один lane, один
checkpoint, regression sweep по всем touched hot files.

- **Step 0 — оценка untrusted ENGINE-002 diff (до любого кода).** Coder
  проходит uncommitted diff по файлам и классифицирует каждый hunk против
  этого документа: keep (удовлетворяет контракту) / rewrite / remove.
  Решение фиксируется в DONE-checkpoint. Дизайн на diff не строится.
- **Step 1 — diagnostics bootstrap (§6).** `TorrentinoLog.bootstrap()` +
  self-test + markers; удаление дублирующих raw-`Logger` вызовов в
  product-путях (facade-only правило). *Файлы: AgentMain, DiagnosticsLogging,
  RedactedLogFileManager, AgentRuntime (log-вызовы).*
- **Step 2 — event bus boot order (§5.2).** Bus в `AgentRuntime.init`,
  non-optional в `AgentService`; subscribe никогда не отказан по таймингу.
  *Файлы: AgentRuntime, AgentService.* (Независим от Step 1; допустим
  параллельно при двух Coder'ах, иначе серийно.)
- **Step 3 — session state machine (§1).** Phase tracking, transition logs,
  `EngineLifecycleChangedEvent` publication, `sessionPhase`/observability
  ключи в health payload, fail-closed gating библиотечных команд в degraded.
  *Файлы: AgentRuntime, AgentService, TransferCoordinator (phase hooks).*
  Зависит от Steps 1–2.
- **Step 4 — restore contract (§3.1–3.2).** Tolerant-decode аудит всех
  side-tables, per-record classification, mandatory summary, R0. Зависит от
  Step 3 (нужен degraded). *Файлы: TransferCoordinator, PersistenceStore
  (только decode-аудит, без schema-изменений).*
- **Step 5 — unified admission (§3.3).** `admit(record, reason:)` + gates +
  постусловия P1–P4; конвергенция commitAdd/resume/pumpReadd/restoreReadd/
  engineRestart. Зависит от Step 4. *Файлы: TransferCoordinator.*
- **Step 6 — live-derived health (§4).** Fault TTL в `StatusCache`, transient
  suppression в единственном месте, remaining-bytes probe, triangle policy.
  Зависит от Step 5. *Файлы: StatusCache, BridgeTransferEngine,
  TransferCoordinator.*
- **Step 7 — session-scoped shutdown (§5.1).** Connection registry в
  ListenerDelegate + veto-правило в `AgentService.shutdown`. Независим от
  Steps 4–6 по логике, но серийно (общий AgentRuntime/AgentService).
- **Step 8 — UI truthfulness (§7).** Удаление `projectHealth`, fixture только
  при transport unavailability, degraded banner из lifecycle events. Зависит
  от Step 6. *Файлы: TorrentListViewModel (+ InspectorView presentation при
  необходимости, Localizable.xcstrings EN+RU для banner-ключей).*
- **Step 9 — regression sweep.** Full `xcodebuild test`, QA gates
  (`test_wp07_file_selection.sh`, `test_wp10_removal_durable.sh`,
  observability script), preserved-contract checklist (§10), disposable
  launchd/live proofs (I1, I7, I9) с guard'ом от Human state.

**Границы параллельности:** внутри L1 серийный порядок рекомендуется
(один lane = один Coder = один checkpoint). Единственная безопасная
параллель — Steps 1∥2 при двух исполнителях. Steps 4–6 строго последовательны
(общий hot file, поведенческий контракт).

### Lane L2 — декомпозиция god-object (после acceptance L1; каждый шаг — отдельный серийный sub-lane)

Каждый шаг behavior-preserving: full test suite + fresh-build gate; нулевой
observable delta (одинаковые snapshot-ответы на скриптованную сессию команд).

1. **L2.1 — extract `HealthPolicy`** (чистые функции: storage→health,
   engine-error→health, conditions→health, transient suppression, triangle
   classification) в `Transfer/HealthPolicy.swift`. Минимальный риск: чистые
   функции уже покрыты L1-тестами.
2. **L2.2 — extract `AdmissionController`** (gate order, backoff table,
   `ensureEngineStarted`, `canAdmitEngineWork`, `admit()`). Records остаются
   у coordinator'а; controller возвращает outcomes.
3. **L2.3 — extract `RestorePipeline`** (tolerant decode loop, per-record
   classification, summary, R0). Зависит от L2.1.
4. **L2.4 — extract `RecordLedger`** (records, recordRevisions, changeLog,
   publishDelta, snapshot construction). Механический перенос.
5. **L2.5 (опционально) — lane file splits:** removal/creator/settings/
   tracker/move handlers в отдельные файлы-extensions `TransferCoordinator`
   без изменения типов — чисто reviewability.

---

## 10. Preserved behavioral contract (обязателен к сохранению)

Дизайн обязан сохранить все ранее принятые поведения; regression sweep (Step 9)
проверяет каждое:

**Rounds 1–7 (WP-13 fixes):**
1. Single mode-driven `.fileImporter` (`AddTorrentPickerMode`) с
   security-scoped access и localized failures (BUG-008, round 3).
2. Raw Logger confined to facades; observability command-matrix (round 3).
3. Stale inspection generations rejected; localized add-failures + app-side
   client log sink (round 4).
4. Snapshot-authoritative list: event sink до первого `fetchSnapshot`,
   refresh после commitAdd/didBecomeActive/reconnect, revision-contiguous
   merge, stale events ignored, gap ⇒ full snapshot (round 5).
5. Add sheet держит faults видимыми (localized `insufficientSpace` с
   required/free + destination hint; dismiss только по успеху) (rounds 5–6).
6. Selection-aware preflight; alias resolution via resource values + statfs;
   envelope rejection logging с redacted reason/provenance/request-ID (round 6).
7. Backward-compatible `fileSelection` decoding; bulk Select All/Deselect All
   в Add sheet; readable localized state text/tooltips; connecting activity
   indication; terminal add-flow errors (round 7).

**WP gates:** WP-08 (inspector, sorting/search/multi-select, menus,
settings transaction, per-torrent limits, notifications, EN/RU catalog);
WP-09 storage-fault semantics; WP-10 (two-phase removal + Trash-only +
journals, move storage journal + recovery, pending-removal guided resume);
WP-11 Creator contract (ADR-016/ADR-017: option-bound commit, structured
tracker topology как lifecycle authority).

**Live-lanes (accepted):**
8. Torrent-row activation ⇒ reveal/open content folder в Finder.
9. File-row activation ⇒ open файла default-app'ом (reveal + localized note
   при недоступном файле).
10. Independent multi-checkbox file selection (merge, не replace).
11. Visible Select All / Deselect All в main files pane и Add sheet.
12. Dynamic selected/download size recalculation (`effectiveTotalBytes`).
13. Real rates/progress/peer projection через bridge DTO (`fill_progress_dto`,
    alert drain batch).
14. DnD `.torrent` в окно: container-level `.onDrop` (все 5 UTI, `.url`
    fallback), `TorrentDropRouting`, `recentImportURLs` dedup, preview route.
15. Finder double-click/open-document ⇒ Add sheet с inspection preview
    (Total/Selected, file tree, Destination row, Start paused default true).
16. Adaptive files pane: `FilesPaneSizing` min/ideal/max, per-window collapse,
    нативный draggable `VSplitView` divider (без static overlay).
17. Remove state machine (accepted part) + `error.duplicate_add` EN/RU.
18. `--cli` surface (status/hello/health/snapshot/register/unregister/
    shutdown) и LIFECYCLE_CONTRACT.md exit codes.

---

## 11. Product target files (Lane L1)

```yaml
target_files:
  - Native/TorrentinoEngineAgent/Agent/AgentMain.swift
  - Native/TorrentinoEngineAgent/Agent/AgentRuntime.swift
  - Native/TorrentinoEngineAgent/Agent/AgentService.swift
  - Native/TorrentinoEngineAgent/Agent/DiagnosticsLogging.swift
  - Native/TorrentinoEngineAgent/Agent/RedactedLogFileManager.swift
  - Native/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift
  - Native/TorrentinoEngineAgent/Transfer/BridgeTransferEngine.swift
  - Native/TorrentinoEngineAgent/Transfer/StatusCache.swift
  - Native/TorrentinoEngineAgent/Persistence/PersistenceStore.swift  # только tolerant-decode аудит, без schema-изменений
  - Native/TorrentinoApp/Features/TorrentListViewModel.swift
  - Native/TorrentinoApp/Features/InspectorView.swift                # только presentation mapping, если затронуто
  - Native/TorrentinoApp/App/AppDelegate.swift                       # только logging shutdown-refusal, если нужно
  - Native/TorrentinoApp/Resources/Localizable.xcstrings             # только новые degraded-banner ключи (EN+RU)
```

**Явно НЕ targets:** `Native/TorrentinoIPC/*` (vocabulary уже заморожен и
достаточен; plist-only ключи health reply не меняют wire-контракт),
`Native/TorrentinoEngineBridge/*` (C++/ObjC++ bridge не требует изменений —
telemetry уже несёт rates/errors), `Native/Config/*.plist` (frozen), Xcode
project files, QA-скрипты (кроме обновления observability-скрипта Tester'ом
после product-landa), `STATE.yaml`, `Legacy/` (HARD BAN).

## 12. Non-goals

- Metal, новый функционал вне engine lifecycle, tracker redesign, magnet
  capability expansion, persistence schema migration.
- Big-bang rewrite `TransferCoordinator` (только L2-последовательность после
  acceptance L1).
- Изменение frozen XPC v1 wire contract'а, launchd plist, exit codes,
  ADR-004 shutdown budget'ов.
- Logo/AppIcon, LaunchServices, `/Applications/Torrentino.app.stale-2217`,
  Human Engine state (`~/Library/...`, launchd job) — read-only инспекция
  максимум.
- Коммиты, пуши, теги, ветки; `Legacy/Tauri/` (HARD BAN, dirty — игнорировать).
- Построение дизайна на untrusted ENGINE-002 diff.

## 13. Disposition of the untrusted ENGINE-002 diff

Diff остаётся в дереве как evidence. Step 0 Lane L1: Coder классифицирует
каждый hunk (keep/rewrite/remove) против §1–§7 и фиксирует решение в
checkpoint. Ориентиры: tolerant decode + rebuilt/skipped summary + truthful
initial activity на admit/re-add соответствуют контракту; любые health-latch
артефакты и проекции health в UI — переписать или удалить по §4.

## 14. Open questions for Human

Нет блокирующих. Принятые Architect-решения, о которых Human стоит знать:
1. `--cli shutdown` при живом UI будет отказан (`acknowledged=false`) —
   оркестраторский gate сначала закрывает приложение, совместимо.
2. Demo-fixture остаётся только при transport-недоступности; reachable
   degraded агент показывается banner'ом, не фиктивными данными.
3. Агент продолжает seeding headless после выхода UI (существующее поведение,
   ADR-004); shutdown на quit остаётся best-effort с 5 s cap.

## Next human action

Вернись к оркестратору и скажи «статус» или «приступай». Оркестратор
проверяет ADR-019 и этот пакет, открывает ordered Coder Lane L1 и прогоняет
fresh-build gate после каждого lane'а.
