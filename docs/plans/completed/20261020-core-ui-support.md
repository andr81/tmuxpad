# Ядро для UI: мышь мимо `copy-cancel`, дерево сессий, открытые терминалы, опрос серверов

## Overview

Третий план по спеке `docs/tmuxpad-spec.md`. Он дописывает в пакет `TmuxPadCore` ту логику
слоя State, которую можно тестировать без Apple-фреймворков: приложение (планы 4–7 на Mac)
оборачивает её в `@Observable`-модели и рисует. Исполняется на Linux-хосте (Swift 6.1.3,
Docker-стенд из плана 1) или на Mac (Swift из Xcode 26, Docker Desktop или OrbStack).

Зачем отдельный план до приложения. При разборе SwiftTerm 1.99.0 выяснилось, что клавиатурный
ввод и мышиные отчёты (колесо от drag одним пальцем, тап) приходят из `TerminalView` одним
делегатным `send`. Текущий `TerminalSession.send` перед первым вводом после скролла делает
`copy-cancel`; если через него пустить и колесо, второй же шаг прокрутки выведет pane из
copy-mode, и листать историю станет невозможно. Разбор исходящих байтов — чистая логика, её место
в ядре с юнит-тестами. Туда же ложатся построение дерева сайдбара, подсказка имени сессии,
порядок и вытеснение открытых терминалов и опрос серверов раз в 10 с: всё это иначе пришлось бы
тестировать только в симуляторе.

Что входит: `MouseReport` и новый вход `TerminalSession.input(_:)`; уведомление экрана о
подозрении на copy-mode и действие `cancelCopyMode()` для чипа «Прокрутка ✕»;
`Validation.suggestedSessionName(from:)`; `SessionTree`; `OpenSessionsRoster`; `TreeRefresher`;
переносимость `host/tests/bench.sh` и `TmuxPadCore/scripts/test.sh` на macOS (bash 3.2, без
GNU `timeout`).

### Решения, принятые в спеке (не переоткрывать)

- §3.5: SwiftTerm от 1.99.0; отчёт колеса вверх включает чип, прочие мышиные отчёты идут в PTY
  мимо `copy-cancel`; всё остальное — ввод, и перед первым вводом после скролла идёт
  `copy-cancel` с ожиданием. Чип скрывается после ввода или тапа; тап по чипу сам делает
  `copy-cancel`.
- §3.1: проекты без сессий по умолчанию скрыты, переключатель «Показывать все проекты»;
  `●` — сессия открыта в приложении, `○` — есть на сервере; подпись `attached` при
  `otherClients > 0`; сервер недоступен — строка с `⚠`, последний снимок серым с временем (§9);
  автообновление каждые ~10 с, пока приложение активно, плюс pull-to-refresh.
- §3.3: имя предзаполнено именем проекта, пробелы → `-`, валидация вживую; конфликт имени —
  предложение подключиться.
- §3.4: мастер «Подключиться» показывает сессии сервера, сгруппированные по проектам, с пометкой
  `attached`; сортировка по `lastActivity` (§5.1).
- §5: лимит 8 открытых терминалов на всё приложение; самые давно неактивные отключаются
  (`detach`, на сервере ничего не теряется).
- §7: при каждом подключении `version`; скрипт старше бандла или его нет → сервер «Требуется
  подготовка» (§9), то есть `ServerReachability.needsSetup`.
- §5: если за интервал keepalive прошёл любой exec, пинг пропускается; `list` раз в 10 с поэтому
  заменяет пинг, ничего дополнительно делать не нужно.

### Решения исполнителя плана

1. **`MouseReport` — перечисление разобранного буфера, а не флаг.** `enum TerminalInput {
   case keyboard; case wheelUp; case otherMouse }` и `static func classify(_ bytes: Data) ->
   TerminalInput` в `Terminal/MouseReport.swift`. Буфер считается мышиным, только если он
   целиком состоит из одного или нескольких отчётов: SGR `ESC [ < Pb ; Px ; Py (M|m)` (`Pb`,
   `Px`, `Py` — десятичные, 1–4 цифры) или X10 `ESC [ M Cb Cx Cy` (ровно три байта после `M`,
   каждый ≥ 32; X10 при колонке > 223 в режиме 1005 (UTF-8) разберётся как `.keyboard` —
   допустимо, отметить в doc-комментарии). Код кнопки: SGR — `Pb`, X10 — `Cb − 32`. Модификаторы — биты 4 (shift), 8
   (meta), 16 (ctrl); после их снятия (`b & ~28`) 64 — колесо вверх, 65 — колесо вниз. Если в
   буфере есть хоть один отчёт колеса вверх — `.wheelUp`, иначе `.otherMouse`. Всё, что не
   разобралось целиком (включая `ESC [ <` без завершения, URXVT-форму `ESC [ Pb ; Px ; Py M`
   без `<`), — `.keyboard`: лучше лишний `copy-cancel`, чем проглоченный ввод. Причина
   «целиком»: клавиатурная последовательность, начинающаяся с `ESC [`, не должна случайно
   уйти мимо `copy-cancel`.
2. **Новый вход `TerminalSession.input(_ bytes: Data) async throws`**,
   прежний `send(_:)` остаётся для программного ввода и тестов. `input` классифицирует буфер:
   `.wheelUp` → флаг `needsCopyCancel = true`, уведомление экрана, байты в PTY без
   `copy-cancel`; `.otherMouse` → байты в PTY без `copy-cancel`, флаг не трогается; `.keyboard`
   → прежняя логика `send` (`copy-cancel` при поднятом флаге, затем байты), флаг сбрасывается,
   экран уведомляется. Все три ветки встают в ту же очередь `sendTail`, чтобы порядок байтов в
   PTY совпадал с порядком вызовов. Возвращает `Void`: чип UI показывает по
   `copyModeSuspected` (решение 3), второй канал для того же факта не нужен. Порядок вызовов
   `input` — забота вызывающего: делегат SwiftTerm синхронный, приложение кладёт байты в один
   последовательный `AsyncStream` (план 6); отдельные `Task { await input }` пришли бы в актор
   не по порядку, и `sendTail` бы не помог.
3. **Уведомление экрана — новый метод протокола с реализацией по умолчанию.** В
   `TerminalSurface` добавляется `func copyModeSuspected(_ suspected: Bool)` и расширение
   протокола с пустой реализацией, чтобы существующие реализации (`RecordingSurface` в тестах)
   не ломались. Ядро вызывает его только при смене значения: `true` после первого колеса
   вверх, `false` после ввода, тапа по чипу и `detach()`. При `reconnect()`, `take()` и новом
   канале флаг **сохраняется**: copy-mode — состояние pane на сервере, новый `attach` его не
   снимает, и без `copy-cancel` первый ввод после обрыва tmux проглотил бы. Сейчас `begin()`
   (`TerminalSession.swift`) флаг не трогает — так и остаётся.
4. **`cancelCopyMode() async`** — действие чипа: если флаг поднят, встаёт в очередь `sendTail`,
   выполняет `server.api.copyCancel(session:)` (ошибка — только в журнал, как в `send`),
   сбрасывает флаг и уведомляет экран. При опущенном флаге ничего не делает.
5. **`Validation.suggestedSessionName(from:) -> String`** в `Models/Validation.swift`:
   пробелы и `.` → `-`, прочие символы вне `[A-Za-z0-9_-]` удаляются, подряд идущие `-`
   схлопываются в один, `-` по краям обрезаются, затем обрезка до 64 символов и повторное
   срезание `-` по краям; пустой результат → `"session"`.
   Нужен потому, что имя проекта может содержать `.` (`^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$`), а
   имя сессии — нет, и мастер предзаполняет имя именем проекта (§3.3). Результат всегда
   проходит `isValidSessionName`.
6. **`SessionTree` — чистая функция над снимком.** `struct ProjectNode: Hashable, Sendable {
   name, path: String?, sessions: [SessionNode] }`, `struct SessionNode: Hashable, Sendable {
   session: RemoteSession, isOpen: Bool }`. `static func build(snapshot: ServerSnapshot,
   openSessions: Set<String>, showEmptyProjects: Bool) -> [ProjectNode]`: проекты по имени без
   учёта регистра (`localizedStandardCompare` недоступен на Linux без Foundation-локали —
   `lowercased()` + `<`, при равенстве — по исходному имени, чтобы `API` и `api` стояли
   детерминированно); сессии внутри проекта по имени; сессия, чей проект отсутствует в
   `snapshot.projects` (папку удалили, а tmux-сессия жива), попадает в узел с этим именем и
   `path == nil` — иначе её нельзя было бы ни открыть, ни убить; при `showEmptyProjects ==
   false` узлы без сессий выпадают. Вторая функция `byActivity(snapshot:) -> [ActivityGroup]` (`struct ActivityGroup:
   Hashable, Sendable { project: String; sessions: [RemoteSession] }` — кортежи не `Equatable`,
   тесты не смогли бы их сравнить) для мастера «Подключиться»: группы упорядочены по самой свежей
   активности в группе, сессии внутри — по `lastActivity` по убыванию.
7. **`OpenSessionsRoster` — значение, а не актор.** `struct OpenSessionKey: Hashable, Codable,
   Sendable { serverID: UUID; name: String }`; `struct OpenSessionsRoster: Codable, Sendable`
   с `limit` (по умолчанию 8), `tabs: [OpenSessionKey]` в порядке открытия (для `⌘1…⌘9` и
   восстановления после перезапуска) и `recency` (последняя активация). Методы: `mutating func
   open(_:) -> [OpenSessionKey]` — добавляет (или активирует уже открытый) и возвращает
   вытесненных: самые давно неактивные, кроме только что открытого, пока `tabs.count > limit`;
   `activate(_:)`; `close(_:)`; `close(serverID:)` (сервер удалили); `tab(at index: Int) ->
   OpenSessionKey?` (1-based для `⌘1…⌘9`); `next(after:)`/`previous(before:)` по кругу для
   `⌘]`/`⌘[`. `recency` хранится как монотонный счётчик, а не `Date`: тесты детерминированы,
   а `Codable` не тащит часы. `limit` в JSON не пишется (иначе сохранённое значение перебило
   бы новое умолчание); при декодировании `recency` для ключей вне `tabs` выбрасываются. Актор
   не нужен: модель приложения живёт на main и держит
   значение у себя.
8. **`TreeRefresher` — актор поверх `ConnectionPool`.** Конструктор: `pool: ConnectionPool`,
   `bootstrap: HostBootstrap`, `auth: @Sendable (ServerConfig) async throws -> SSHAuth`
   (приложение достаёт ключ из `KeyStore`), `interval: Duration = .seconds(10)`. Состояние по
   серверу: `struct ServerTreeState: Sendable, Equatable { reachability: ServerReachability;
   snapshot: ServerSnapshot?; bootstrap: BootstrapStatus?; refreshing: Bool; attention:
   SSHError? }` (`attention` — последняя фатальная ошибка подключения, `authFailed` или
   `hostKeyChanged`; сбрасывается при успешном подключении). Выход —
   `updates() -> AsyncStream<(UUID, ServerTreeState)>` (много подписчиков, как
   `ServerConnection.stateUpdates()`: текущее состояние каждого сервера и все следующие).
   Методы: `setServers(_ configs: [ServerConfig])` (добавленные — `.unknown`, удалённые —
   `pool.remove(id:)` и выпадают из выхода), `start()` (периодический цикл; на каждом тике
   `refresh` всех серверов параллельно, без ожидания медленных), `stop()` (уход в фон — дерево не опрашивается),
   `refresh(_ id: UUID? = nil, force: Bool = false) async` (тик — без `force`;
   pull-to-refresh и «Повторить» — с `force`, решение 9; все или один; ждёт завершения).
   Один `refresh` на сервер одновременно: второй вызов, пока первый идёт, ждёт его результата,
   а не запускает новый `list`. `markPrepared(_ id:)` (после `HostBootstrap.prepare`)
   сбрасывает кешированный `bootstrap`, **дожидается** идущего `refresh` и только потом
   запускает новый — иначе он получил бы результат, начатый до подготовки (`.needsSetup`).
9. **Как `refresh` вычисляет `reachability`.** `pool.connection(for:auth:)`, затем по
   `await connection.state`, **без безусловного `connect()`**: `connect()` при
   не-`.connected` начинает новую эпоху (`ServerConnection.swift`, `beginEpoch()`), то есть
   гасит бэкофф-цикл и сбрасывает счётчик попыток, повторял бы `authFailed`/`hostKeyChanged`
   каждые 10 с и обрывал бы чужую попытку подключения.
   - Сервер, которому пользователь ещё не подтвердил хост-ключ (`ServerConfig.
     hostKeyFingerprint == nil`), не подключается вовсе → `.needsSetup("Connection not
     checked")`: иначе опрос сохранил бы отпечаток молча, без «Доверять» (§8). Подтверждение —
     «Проверить подключение» в приложении, оно же пишет отпечаток в конфиг.
   - `.disconnected` → `connect()`; ошибка → `.offline(описание)`, а `SSHError.authFailed` и
     `.hostKeyChanged` дополнительно кладутся в `ServerTreeState.attention` (решение 8), чтобы
     UI открыл проверку сервера вместо «Повторить»; пул после них в `.failed`, тики не
     повторяют (§9: автоповторов нет).
   - `.connecting`, `.reconnecting(attempt:)` → `.offline("Reconnecting…")` без вызовов;
     `.failed(reason)` → `.offline(reason)` без вызовов. Пул сам дойдёт до `.connected` или
     `.failed`; явный повтор — `refresh(id, force: true)` (pull-to-refresh и «Повторить» в UI),
     который зовёт `connection.reconnectNow()`.
   - `.connected(since:)` → работа дальше. Снимок при любой ошибке остаётся прежним (§9:
     «последний снимок серым»).
   Эпоха: после выяснения, что соединение `.connected(since:)`, `since` сравнивается с
   запомненным для сервера; новое значение → `bootstrap.status(api:)` (подписки на
   `stateUpdates()` не нужны: синхронное чтение `state` после `connect()` не опаздывает).
   `.missing` → `.needsSetup("Host script is not installed")`, `.outdated` →
   `.needsSetup("Host script v\(installed) is older than v\(bundled)")`, `.unreachable` →
   `.offline`. В `.needsSetup` `list` не вызывается. Иначе `api.list()`: успех → `.online` +
   новый снимок; `HostError.projectsRootMissing` → `.needsSetup("Projects folder … does not
   exist")`; `HostError.scriptMissing` → `.needsSetup` (скрипт удалили между подключениями);
   прочие → `.offline`. Тексты — английские константы ядра; переводит UI (как
   `HostError.description`).
10. **Таймер через `Task.sleep(for:)` с инжектируемыми часами не нужен**: интервал — параметр
    конструктора, юнит-тесты задают 50 мс и ждут нужное число тиков через `updates()`.
11. **Переносимость стенда на macOS.** `bench.sh` и `test.sh` запускаются системным bash 3.2 и
    без GNU coreutils. `timeout` есть только в `bench.sh`, поэтому функция живёт там: вместо
    голого `timeout` — функция `with_timeout SECONDS CMD…`: `timeout`,
    если есть, иначе `gtimeout` (Homebrew coreutils), иначе запуск без ограничения с
    предупреждением в stderr. Прочие конструкции проверить на bash 3.2: нет `mapfile`,
    `declare -A`, `${var,,}`, `wait -n`, `sed -i` без суффикса, `readlink -f`, `stat -c`. Тесты
    host-скрипта (`host/tests/run.sh`, `lib.sh`) остаются Linux-only: на Mac их не гоняют.

### Чего этот план не делает

- Ни строки SwiftUI/UIKit, SwiftTerm, Keychain: это планы 4–7.
- Не меняет host-скрипт и его контракт §7.
- Не переносит в ядро `@Observable`-модели: `Observation` на Linux есть, но границу §5.2 —
  «модели State живут в приложении» — план не двигает; в ядре только логика под ними.
- Не делает восстановление открытых сессий целиком: `OpenSessionsRoster` только `Codable`;
  где хранить (UserDefaults) и когда восстанавливать — план 7.
- Не трогает keepalive: `TreeRefresher` не шлёт пинги и не знает про них.

## Context

- Спека: §3.1, §3.3, §3.4, §3.5 (новый пункт «Мышь и клавиатура идут одним путём»), §5
  («Лимит — 8 открытых на всё приложение»), §5.2 (строка «Linux и Mac» перечисляет новые типы),
  §7, §9, §13 (решения 2026-10-20 про SwiftTerm и State).
- Ядро после плана 2: `TmuxPadCore/README.md` — карта модулей и что реализует приложение.
  - `Sources/TmuxPadCore/Terminal/TerminalSession.swift` — `send(_:)` (очередь `sendTail`, флаг
    `needsCopyCancel`), `noteScrolledUp()`, `detach()`, `take()`, `reconnect()`; приватный
    `begin()` растит `generation`.
  - `Sources/TmuxPadCore/Terminal/TerminalSurface.swift` — протокол `feed`, `size`,
    `stateChanged`.
  - `Sources/TmuxPadCore/Pool/ConnectionPool.swift` — `connection(for:auth:)`, `remove(id:)`,
    `existing(id:)`; `Pool/ServerConnection.swift` — `connect()` (при не-`.connected` начинает
    новую эпоху через `beginEpoch()`), `reconnectNow(force:)`, `state`, `api`.
  - `Sources/TmuxPadCore/Host/HostBootstrap.swift` — `status(api:)`, `prepare(api:)`,
    `BootstrapStatus`.
  - `Sources/TmuxPadCore/Models/Validation.swift` — `isValidSessionName`,
    `isValidProjectName`.
  - Тесты: `Tests/TmuxPadCoreTests/Support/FakeTransport.swift` (очередь ответов exec, PTY,
    обрыв), `Support/RecordingSurface.swift`, `Support/Bench.swift`, `Support/Timeout.swift`;
    `TerminalSessionTests.swift`, `TerminalIntegrationTests.swift`.
- SwiftTerm 1.99.0, `Sources/SwiftTerm/iOS/iOSTerminalView.swift`: drag одним пальцем при
  `allowMouseReporting` и мыши в приложении уходит через `forwardWheelDrag` в
  `terminal.sendEvent`, дальше в `TerminalViewDelegate.send(source:data:)` — тот же путь, что у
  клавиатуры. tmux с `mouse on` включает SGR-режим 1006, поэтому основная форма — SGR; X10
  разбирается на случай, если SGR выключат.
- Linux-хост: Swift 6.1.3 в `~/.local/swift-6.1.3`, `swift` в PATH. Первая сборка пакета на
  2 vCPU около 12,5 мин, повторная — минуты; в инструментах Claude Code команды длиннее 10 мин
  запускать в фоне.
- `host/tests/bench.sh` вызывает `timeout 10 ssh …` (строка 23) — на macOS без coreutils упадёт.

## Validation Commands

```
swift build --package-path TmuxPadCore --build-tests
swift test --package-path TmuxPadCore --skip IntegrationTests
TmuxPadCore/scripts/test.sh
TmuxPadCore/scripts/test.sh --filter TreeRefresherIntegrationTests
shellcheck -s bash host/tests/bench.sh TmuxPadCore/scripts/test.sh
docker run --rm -v "$PWD":/w -w /w bash:3.2 bash -n host/tests/bench.sh
docker run --rm -v "$PWD":/w -w /w bash:3.2 bash -n TmuxPadCore/scripts/test.sh
```

Сборка в режиме Swift 6 без предупреждений; новое предупреждение — ошибка задачи.

## Testing Strategy

- `MouseReportTests` (юнит): SGR колесо вверх `ESC[<64;10;5M` → `.wheelUp`; с ctrl
  `ESC[<80;10;5M` → `.wheelUp`; вниз `ESC[<65;10;5M` → `.otherMouse`; клик `ESC[<0;3;4M` и
  отпускание `ESC[<0;3;4m` → `.otherMouse`; два отчёта подряд, один из них вверх → `.wheelUp`;
  X10 `ESC[M` + `[96, 40, 40]` → `.wheelUp`; X10 с байтом < 32 → `.keyboard`; стрелка
  `ESC[A`, `ESC[<` без конца, `ESC[<64;10;5` без `M`, URXVT `ESC[64;10;5M`, обычный текст,
  пустой буфер → `.keyboard`; отчёт, за которым идёт текст `ESC[<64;1;1Ma` → `.keyboard`.
- `TerminalSessionTests` (юнит, `FakeTransport`): `input` колеса вверх уходит в PTY без exec и
  поднимает флаг (`RecordingSurface` видит `copyModeSuspected(true)` ровно один раз за два
  колеса); второе колесо вверх и колесо вниз после него — тоже без `copy-cancel`; затем
  клавиатура → ровно один exec `copy-cancel` до байтов клавиатуры, `copyModeSuspected(false)`;
  `cancelCopyMode()` при поднятом флаге — один `copy-cancel`, при опущенном — ни одного;
  порядок байтов в PTY совпадает с порядком вызовов при смеси колеса и клавиатуры;
  после `reconnect()` и `take()` флаг сохраняется: первый ввод идёт с `copy-cancel`;
  `detach()` сбрасывает флаг с уведомлением.
- `ValidationTests`: `"my.project"` → `"my-project"`, `"a  b"` → `"a-b"`, `"..."` →
  `"session"`, 200 символов → 64, `"Проект"` → `"session"`, результат всегда валиден
  (параметризованный тест на наборе строк).
- `SessionTreeTests`: сортировка проектов и сессий; сессия с исчезнувшим проектом даёт узел с
  `path == nil`; `showEmptyProjects` скрывает и показывает пустые; `isOpen` по множеству имён;
  `byActivity` упорядочивает группы и сессии.
- `OpenSessionsRosterTests`: девятое открытие вытесняет самое давно неактивное; повторное
  открытие уже открытого — активация без вытеснения; только что открытый не вытесняется даже
  при `limit == 1`; `close(serverID:)`; `tab(at:)` 1-based; `next`/`previous` по кругу;
  кодирование и декодирование JSON сохраняет `tabs` и порядок вытеснения, `limit` в JSON не
  попадает, `recency` чужих ключей при декодировании отбрасывается.
- `TreeRefresherTests` (юнит, `FakeTransport`, интервал 50 мс): успешный `list` → `.online` и
  снимок; обрыв после успеха с запретом переподключения (`failNextConnects(n)` до
  `dropConnection()`, иначе фейк переподключится сам за секунду) → `.offline` с прежним
  снимком; пока пул в `.reconnecting`, тики `refresh` не вызывают `connect` (счётчик попыток
  фейка не растёт сверх бэкоффа); в `.failed` после `authFailed` тики не делают попыток, а
  `refresh(id, force: true)` делает ровно одну; `version` = 127 → `.needsSetup` и `list` не
  вызывается; скрипт старее бандла → `.needsSetup`; `list` с кодом 2 → `.needsSetup`; два
  одновременных `refresh` одного сервера → один exec `list`; `markPrepared` во время идущего
  `refresh` дожидается его и запускает новый, который перечитывает `version`; сервер без
  `hostKeyFingerprint` в конфиге → `.needsSetup`, ни одной попытки подключения;
  `authFailed` → `attention == .authFailed`, следующий тик попыток не делает; `stop()`
  останавливает тики; `setServers` без сервера → `pool.remove` и сервер пропадает из выхода.
- `TreeRefresherIntegrationTests` (стенд; конфиг стенда получает `hostKeyFingerprint` из
  предварительного `connect()` того же пула — так приложение делает «Доверять»): сервер со
  стендом → `.online` со снимком, где есть
  проекты стенда; после `new` через `api` следующий `refresh` видит сессию; тест с удалением
  скрипта целиком внутри изолирующего хелпера `Bench` (как остальные тесты, меняющие стенд):
  `rm ~/.local/bin/tmuxpad-host.sh` через exec → `refresh` даёт `.needsSetup` (`list` с кодом
  127); затем `prepare` + `markPrepared` → снова `.online`; в `defer`/при ошибке —
  `bootstrap.install`, чтобы стенд остался со скриптом для следующих тестов.
- `TerminalIntegrationTests`: добавить тест — tmux-сессия с длинным выводом (`seq 1 500`),
  `input` с SGR колесом вверх три раза → `tmux display -p -t =NAME: '#{pane_in_mode}'` = 1;
  ещё одно колесо вверх не выводит из copy-mode (по-прежнему 1); затем `input("x")` → сначала
  `pane_in_mode` = 0, потом `x` виден в `capture-pane`. Все проверки состояния tmux — через
  ожидание с опросом (`Bench.eventually` или аналог из `Support/`), не сразу после `input`:
  PTY асинхронен, мгновенная проверка плавает.

## Задачи

### Task 1: `MouseReport` и ввод терминала мимо `copy-cancel`

**Файлы:** `TmuxPadCore/Sources/TmuxPadCore/Terminal/MouseReport.swift` (create),
`.../Terminal/TerminalSession.swift`, `.../Terminal/TerminalSurface.swift`,
`TmuxPadCore/Tests/TmuxPadCoreTests/MouseReportTests.swift` (create),
`.../TerminalSessionTests.swift`, `.../TerminalIntegrationTests.swift`,
`.../Support/RecordingSurface.swift`.

- [x] `Terminal/MouseReport.swift`: `public enum TerminalInput: Sendable, Equatable { case
      keyboard, wheelUp, otherMouse }` и `public enum MouseReport { public static func
      classify(_ bytes: Data) -> TerminalInput }` по решению 1: последовательный разбор с
      позиции 0; каждый отчёт должен начинаться ровно с `0x1B 0x5B`; SGR — `0x3C`, три
      десятичных поля через `;` (1–4 цифры каждое), финальный `M` или `m`; X10 — `0x4D` и ровно
      три байта ≥ 32; любой остаток или несовпадение → `.keyboard`; пустой буфер → `.keyboard`.
      Код кнопки после снятия модификаторов `b & ~28`: 64 → колесо вверх.
- [x] `TerminalSurface.swift`: в протокол — `func copyModeSuspected(_ suspected: Bool)` с
      doc-комментарием «чип "Прокрутка ✕" (§3.5); вызывается только при смене значения, не с
      main»; `extension TerminalSurface { public func copyModeSuspected(_ suspected: Bool) {} }`.
- [x] `TerminalSession.swift`: приватный `setCopyModeSuspected(_ value: Bool)` меняет
      `needsCopyCancel` и вызывает `surface.copyModeSuspected` только при смене значения;
      `noteScrolledUp()` идёт через него. Новый `public func input(_ bytes: Data) async throws`
      по решению 2: общая постановка в очередь `sendTail` вынесена из `send` в
      приватный `enqueue(_ data: Data, cancelFirst: Bool)`, `send` и `input` его используют;
      `.wheelUp` — `setCopyModeSuspected(true)`, `enqueue(cancelFirst: false)`; `.otherMouse` —
      `enqueue(cancelFirst: false)`; `.keyboard` — то же, что `send`. `send` сбрасывает флаг
      через `setCopyModeSuspected(false)`.
- [x] `TerminalSession.swift`: `public func cancelCopyMode() async` по решению 4 (через
      `enqueue` с пустыми данными и `cancelFirst: true`, без записи пустого буфера в PTY);
      `detach()` зовёт `setCopyModeSuspected(false)`; `take()`, `reconnect()` и открытие
      нового канала флаг не трогают (решение 3).
- [x] `Support/RecordingSurface.swift`: запись вызовов `copyModeSuspected` в массив для
      проверок.
- [x] `MouseReportTests` и новые случаи `TerminalSessionTests` из Testing Strategy.
- [x] `TerminalIntegrationTests`: тест «колесо вверх входит в copy-mode, второе колесо не
      выходит, клавиатура выходит и печатает» из Testing Strategy. SGR-байты строятся хелпером
      `sgrWheel(up: Bool, col: Int, row: Int) -> Data` в тесте. Если tmux на стенде не входит в
      copy-mode от колеса (нужен `mouse on`, его ставит `attach`), тест сначала проверяет
      `#{mouse}` = `on`.
- [x] Сборка без предупреждений, `swift test --skip IntegrationTests`, `scripts/test.sh
      --filter Terminal`.

### Task 2: подсказка имени, `SessionTree`, `OpenSessionsRoster`

**Файлы:** `TmuxPadCore/Sources/TmuxPadCore/Models/Validation.swift`,
`.../Models/SessionTree.swift` (create), `.../Models/OpenSessionsRoster.swift` (create),
`TmuxPadCore/Tests/TmuxPadCoreTests/{ValidationTests,SessionTreeTests,OpenSessionsRosterTests}.swift`
(`ValidationTests` — modify, остальные create).

- [x] `Validation.suggestedSessionName(from:)` по решению 5; doc-комментарий со ссылкой на
      §3.3 и причиной (`.` допустима в проекте, но не в сессии).
- [x] `Models/SessionTree.swift`: `ProjectNode`, `SessionNode`, `enum SessionTree` с
      `build(snapshot:openSessions:showEmptyProjects:)` и `byActivity(snapshot:)` по решению 6.
      Все типы `public`, `Sendable`, `Hashable`; у `ProjectNode` и `SessionNode` есть `id`
      (`name`) для `ForEach`/`List` — `Identifiable`.
- [x] `Models/OpenSessionsRoster.swift`: `OpenSessionKey` и `OpenSessionsRoster` по решению 7;
      `limit` — параметр инициализатора (по умолчанию 8), декодирование проверяет `limit ≥ 1`
      и отбрасывает дубликаты в `tabs`.
- [x] Тесты из Testing Strategy для всех трёх.
- [x] Сборка без предупреждений, `swift test --skip IntegrationTests`.

### Task 3: `TreeRefresher` — опрос серверов для дерева

**Файлы:** `TmuxPadCore/Sources/TmuxPadCore/Pool/TreeRefresher.swift` (create),
`TmuxPadCore/Tests/TmuxPadCoreTests/TreeRefresherTests.swift` (create),
`.../TreeRefresherIntegrationTests.swift` (create), `.../Support/FakeTransport.swift` (если
фейку не хватает сценариев: падение `connect` по команде теста, счётчик вызовов `list`).

- [x] `Pool/TreeRefresher.swift`: `public struct ServerTreeState` и `public actor
      TreeRefresher` по решениям 8–9: `init(pool:bootstrap:auth:interval:)`,
      `setServers(_:)`, `start()`, `stop()`, `refresh(_:force:)`, `markPrepared(_:)`, `state(for:)
      -> ServerTreeState?`, `updates()` (как `ServerConnection.stateUpdates()`: `AsyncStream`
      с `.bufferingNewest(64)`, подписка снимается отменой, первым приходит состояние всех
      известных серверов). Дедупликация: словарь `inFlight: [UUID: Task<Void, Never>]`,
      второй `refresh` ждёт `inFlight[id]?.value`.
- [x] Эпохи и вызовы пула — по решению 9: `connect()` только из `.disconnected`,
      `reconnectNow()` только при `refresh(id, force: true)`; `since` из `.connected(since:)`
      сравнивается с запомненным после чтения `state`, новое значение сбрасывает кешированный
      `bootstrap`. Подписок на `stateUpdates()` и фоновых задач на сервер нет.
      `markPrepared` — по решению 8.
- [x] Ошибки и состояния — по решению 9; каждое изменение `reachability` пишется в
      `DiagnosticsLog` пула (`kind: .exec`, текст без секретов: метка сервера и новое
      состояние).
- [x] `TreeRefresherTests` и `TreeRefresherIntegrationTests` из Testing Strategy;
      интеграционный suite — `.serialized`, `.enabled(if: Bench.isAvailable)`, все ожидания
      через `withTimeout`.
- [x] Сборка без предупреждений, `swift test --skip IntegrationTests`, `scripts/test.sh
      --filter TreeRefresher`.

### Task 4: стенд на macOS

**Файлы:** `host/tests/bench.sh`, `TmuxPadCore/scripts/test.sh`.

- [x] В `bench.sh` — функция `with_timeout` по решению 11; все вызовы `timeout` заменить на
      неё (в `test.sh` их нет, функция там не нужна). Сообщение при отсутствии обоих: `warning: no timeout/gtimeout, running without a time
      limit (brew install coreutils)`.
- [x] Пройтись по обоим скриптам на bash 3.2: заменить `mapfile`/`readarray`, ассоциативные
      массивы, `${var,,}`/`${var^^}`, `wait -n`, `sed -i` без суффикса, `readlink -f`,
      `realpath`, `stat -c`, `date -d`, `grep -P`, если встречаются, на переносимые формы.
      Пути к каталогу скрипта — `cd "$(dirname "$0")" && pwd -P`.
- [x] Проверка на Linux: `shellcheck -s bash` обоих скриптов чист;
      `TmuxPadCore/scripts/test.sh --filter TransportIntegrationTests` проходит; синтаксис
      bash 3.2 — `docker run --rm -v "$PWD":/w -w /w bash:3.2 bash -n host/tests/bench.sh` и то
      же для `TmuxPadCore/scripts/test.sh` (`bash -n` хоста bash 5 конструкции 3.2 не ловит);
      ветка «нет ни `timeout`, ни `gtimeout`» — `fn=$(sed -n '/^with_timeout()/,/^}/p'
      host/tests/bench.sh); PATH=/nonexistent /bin/bash -c "$fn; with_timeout 5 echo ok"`
      печатает предупреждение и `ok` (`echo` встроенный, `PATH` пуст для внешних команд).
      Прогон на настоящем macOS — Post-Completion.

### Task 5: документация, полный прогон, завершение

**Файлы:** `TmuxPadCore/README.md`, `CLAUDE.md`, `docs/tmuxpad-spec.md` (только при
расхождении), `docs/plans/20261020-core-ui-support.md` (move).

- [x] `TmuxPadCore/README.md`: в таблицу модулей — `Terminal/MouseReport`, `Models/SessionTree`,
      `Models/OpenSessionsRoster`, `Pool/TreeRefresher`; в «Что реализует приложение» — делегат
      SwiftTerm `send(source:data:)` зовёт `TerminalSession.input(_:)` и показывает чип по
      результату и по `copyModeSuspected`; `TreeModel` подписывается на
      `TreeRefresher.updates()`; `OpenSessionsModel` держит `OpenSessionsRoster` и делает
      `detach()` вытесненным; стенд на macOS требует Docker и, желательно, `brew install
      coreutils`.
- [x] `CLAUDE.md`, «Инварианты»: «Мышиные отчёты SwiftTerm идут в PTY мимо `copy-cancel`
      (`TerminalSession.input`), иначе второй шаг прокрутки выводит pane из copy-mode».
- [x] Полный прогон Validation Commands; в progress-лог — число тестов по видам.
- [x] Move this plan to `docs/plans/completed/`; коммит.

## Post-Completion

- На Mac: `host/tests/bench.sh up` и `TmuxPadCore/scripts/test.sh` системным bash 3.2 с Docker
  Desktop или OrbStack, без coreutils (предупреждение, прогон проходит) и с ними.
- Проверка в приложении — в плане 6: drag одним пальцем в SwiftTerm 1.99.0 действительно
  приходит в `send` SGR-отчётами `64`/`65`, а не X10 (если X10 — разбор и так покрыт).
