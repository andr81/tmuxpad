# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Состояние репозитория

Спецификация `docs/tmuxpad-spec.md` — источник правды по требованиям, архитектуре и плану (фазы 0–7, §11). Готовы host-скрипт с его Docker-стендом и SwiftPM-пакет ядра `TmuxPadCore` (§5.2) вместе с логикой для State без view (план 3). Приложение `TmuxPad` (только на Mac) после планов 4 `app-foundation`, 5 `app-sidebar`, 6 `app-terminal` и 7 `app-lifecycle-release` умеет ключи, серверы, проверку и подготовку сервера, передачу токена, журнал диагностики, живое дерево сайдбара, мастера «Новая сессия» и «Подключиться», kill и живой терминал SwiftTerm: открытые терминалы с переключением `⌘1…⌘9`, скролл с чипом «Прокрутка ✕», плашки состояний, меню `[⋯]`, pinch-шрифт; уход в фон и переподключение при возврате и смене сети, восстановление открытых сессий после перезапуска, онбординг, настройки терминала и темы, Face ID для ключей, иконку и README. Вне кода остались TestFlight и проверка сценариев фазы 5 на iPad.

Раскладка `host/`:
- `host/tmuxpad-host.sh` — сам скрипт; `host/README.md` — подкоманды, коды выхода, форматы, файлы состояния;
- `host/tests/run.sh` — раннер (свой, без bats): поднимает контейнер с sshd + tmux, ставит скрипт как приложение, гоняет функции `test_*`; `host/tests/lib.sh` — ssh-хелперы и ассерты;
- `host/tests/cases/*.sh` — тесты по подкомандам; `host/tests/docker/` — образ, entrypoint и заглушки `claude`/`claude-old`.

Команды (нужны docker и shellcheck; прогон стенда — минуты на первом запуске, дальше кэш образа):

```
shellcheck -s bash host/tmuxpad-host.sh host/tests/run.sh host/tests/lib.sh host/tests/docker/entrypoint.sh host/tests/docker/claude host/tests/docker/claude-old host/tests/cases/*.sh
host/tests/run.sh                                  # ubuntu:24.04, tmux 3.4
TMUXPAD_TEST_BASE=ubuntu:22.04 host/tests/run.sh   # tmux 3.2a, нижняя граница
host/tests/run.sh -k test_list_others              # один тест, по подстроке имени
```

Раскладка `TmuxPadCore/` (подробнее — `TmuxPadCore/README.md`):
- `Sources/TmuxPadCore/` — `Models/` (в т. ч. `SessionTree`, `OpenSessionsRoster`), `Host/` (`HostAPI`, `HostBootstrap`, парсеры), `SSH/` (транспорт, ключи, TOFU), `Pool/` (`ConnectionPool`, `ServerConnection`, `TreeRefresher`), `Terminal/` (`TerminalSession`, `TerminalSurface`, `MouseReport`), `Diagnostics/`, `Resources/tmuxpad-host.sh`;
- `Tests/TmuxPadCoreTests/` — Swift Testing: `*Tests.swift` юнит (пул и терминал на `FakeTransport`), `*IntegrationTests.swift` против стенда, без стенда пропускаются;
- `scripts/test.sh` — `host/tests/bench.sh up` → `swift test` → `down`; `host/tests/bench.sh` — долгоживущий контейнер того же образа, состояние в `host/tests/.bench/`.

Скрипт-ресурс `TmuxPadCore/Sources/TmuxPadCore/Resources/tmuxpad-host.sh` — побайтная копия `host/tmuxpad-host.sh`: после правки скрипта скопируй его туда, равенство проверяет `HostScriptResourceTests`.

Команды ядра (Swift 6.1.3; первая сборка ~12,5 мин — запускай в фоне, дальше минуты; новые предупреждения компилятора — ошибка):

```
swift build --package-path TmuxPadCore --build-tests
swift test --package-path TmuxPadCore --skip IntegrationTests  # юнит-тесты, без Docker
TmuxPadCore/scripts/test.sh                                   # стенд + все тесты
TmuxPadCore/scripts/test.sh --filter HostAPIIntegrationTests  # один suite или тест (regex по имени)
shellcheck -s bash host/tests/bench.sh TmuxPadCore/scripts/test.sh
```

`host/tests/bench.sh` и `TmuxPadCore/scripts/test.sh` идут и под системным bash 3.2 macOS без GNU coreutils: без `mapfile`, `declare -A`, `${v,,}`, `readlink -f`, `stat -c`, `timeout` — только через `with_timeout`. `bash -n` из bash 5 этого не ловит, проверка — `docker run --rm -v "$PWD":/w -w /w bash:3.2 bash -n host/tests/bench.sh` (и то же для `test.sh`). `run.sh` и `lib.sh` — только Linux.

Раскладка приложения:
- `project.yml` — XcodeGen, единственный источник настроек проекта;
- `App/TmuxPadApp.swift` (`@main`), `App/AppEnvironment.swift` — composition root: пул, хранилища, журнал, модели;
- `App/Platform/` — Keychain (`Keychain.swift`), протокол `AppKeyStore` (создание и импорт ключей; `KeychainKeyStore` в приложении, `InMemoryKeyStore` в тестах), `KeychainKeyStore` (Secure Enclave P-256 и Ed25519), `KeychainHostKeyStore`, `JSONFileStore` (`servers.json`, `keys.json` в Application Support), `DeviceIdentity`, `NetworkMonitor` (`NWPathMonitor` с дребезгом, `networkChanged(from:to:)`), `KeyUnlocker` (Face ID перед первым использованием ключа; там же `SecurityPreferences` — переключатель `security.requireBiometrics`, и `KeyCache` — ключи по `keyID`);
- `App/State/` — `@MainActor @Observable` модели: `ServerStore`, `KeyLibrary`, `ServerCheckModel`, `DiagnosticsModel`, `TreeModel` (обёртка над `TreeRefresher` ядра), `OpenSessionsModel` (ростер, выделение и открытые терминалы), `OpenTerminal` (один открытый терминал: `TerminalSession` ядра, view, состояние, чип), `TerminalAppearance` (шрифт, размер, тема, Option = Meta, звук — на устройство), `LifecycleCoordinator` (`scenePhase` и сеть → пул и дерево через `LifecycleTargets`), `OpenSessionsPersistence` (ростер и выделение в `UserDefaults` между запусками), `AppNavigation` (листы мастеров и видимость сайдбара для шорткатов), `SessionActions` (open/take/detach/kill/new, `tmux attach` для копирования); машины шагов мастеров без SwiftUI — `NewSessionFlow`, `AttachFlow`;
- `App/Terminal/` — UIKit-обвязка SwiftTerm: `SwiftTermSurface` (`TerminalSurface` ядра), `TmuxTerminalView` (подкласс `TerminalView`: шрифт, Option = Meta, мышь, pinch), `TerminalDelegate` (OSC 52, ссылки, bell, resize), `InputPump` (очередь ввода в `TerminalSession.input`);
- `App/UI/` — SwiftUI: `Root/` (`RootView`, `SessionCommands` — меню «Сессии» с ⌘-шорткатами, `StartupErrorView`), `Terminal/` (`TerminalScreen`, `TerminalContainerView`, `TerminalHeader`, `TerminalOverlay` — плашки, `ScrollChip`, `TerminalMenu` — `[⋯]`), `Sidebar/` (`SidebarView`, строки сервера, проекта и сессии, подтверждения), `Wizards/` (`NewSessionWizard` с шагами `ServerPickStep`/`ProjectPickStep`/`NameStep`, `AttachWizard`), `Settings/` (ключи, серверы, проверка, токен, диагностика, `TerminalSettingsView`), `Onboarding/` (`OnboardingView`, машина шагов `OnboardingStep` без SwiftUI, флаг `onboarding.done`), `ErrorText.swift` (`userText(_:)`), `ErrorAlert.swift` (`errorAlert(_:message:)`), `DoctorText.swift`;
- `AppTests/` — Swift Testing в симуляторе, хост — приложение; `ServerCheckBenchTests`, `SidebarBenchTests`, `TerminalBenchTests` и `LifecycleBenchTests` против стенда, без него пропускаются; `AppTests/Support/` — хелперы;
- `AppUITests/` — XCTest UI-смоук (`SmokeUITests`: приложение с `-uitest-inmemory`, ключ, сервер), идёт в той же схеме;
- `scripts/ios-test.sh` — `xcodegen generate` → стенд → `xcodebuild test`; `scripts/make-icon.swift` — рисует `AppIcon.appiconset/icon-1024.png` (`swift scripts/make-icon.swift <путь>`).

Приложение собирается и тестируется только на Mac: Xcode 26, `brew install xcodegen coreutils`, Docker Desktop или OrbStack (для стенда), симулятор iPad с iOS 17+. `TmuxPad.xcodeproj` генерирует `xcodegen generate` из `project.yml` и не коммитится (он в `.gitignore`, как и `App/Info.plist`); правки проекта — только в `project.yml`. `scripts/ios-test.sh` сам вызывает `xcodegen generate`, выбирает симулятор (`TMUXPAD_SIM` — UDID или имя, иначе первый iPad), поднимает стенд, если не передан `--no-bench`, и передаёт лишние аргументы в `xcodebuild test`; результат — `build/TestResults.xcresult`. `AppTests` не зависит от `TmuxPadCore` напрямую (модуль виден через приложение-хост): прямая зависимость ломает линковку пакетных фреймворков.

```
xcodegen generate
xcodebuild build -project TmuxPad.xcodeproj -scheme TmuxPad -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation -quiet  # флаг — build-плагин SwiftTerm
scripts/ios-test.sh                                   # стенд + все AppTests в симуляторе
scripts/ios-test.sh --no-bench                        # только юнит, без Docker
scripts/ios-test.sh -only-testing:AppTests/ServerStoreTests
scripts/ios-test.sh -only-testing:AppUITests            # UI-смоук
shellcheck -s bash scripts/ios-test.sh
```

Стенд с Docker Desktop падает на `docker-credential-desktop: executable file not found`, если в `PATH` нет `/Applications/Docker.app/Contents/Resources/bin` (так бывает в неинтерактивном шелле): добавь его перед `ios-test.sh` и `bench.sh`.

`scripts/ios-test.sh` тоже идёт под bash 3.2 macOS (те же ограничения, что у `bench.sh`). Предупреждения сборки в коде приложения — ошибка; предупреждения внутри зависимостей (`… is missing a dependency on …` у NIO) не считаются.

`xcodebuild` переписывает `TmuxPadCore/Package.resolved` пинами графа приложения (SwiftTerm и его зависимости); ядру они не нужны — такие правки не коммить, верни файл `git checkout TmuxPadCore/Package.resolved`.

Решения, которые меняют поведение, сначала вносятся в спеку, потом в код.

## Что строим

TmuxPad — iPad-клиент (iPadOS 17+, Swift 6, SwiftUI) для работы с Claude Code в tmux-сессиях на удалённых Linux-серверах. Модель взята из рецепта `remote-claude-session` из agterm, но совместимость с ним не нужна: свои пути (`~/.tmuxpad/`, `~/.local/bin/tmuxpad-host.sh`) и свои форматы.

Две половины, которые меняются вместе:

- **Приложение**: SwiftTerm (терминал), Citadel поверх swift-nio-ssh (SSH), ключи в Secure Enclave P-256 или Ed25519 в Keychain. Слои — UI / State (`@Observable`) / Core, раскладка в §5 спеки. Core — отдельный SwiftPM-пакет `TmuxPadCore` без UIKit/SwiftUI, собирается и тестируется на Linux против Docker-стенда (§5.2); всё платформенное (Keychain, Secure Enclave, JSON-хранилища в Application Support, `NWPathMonitor`) — за протоколами, реализации в приложении.
- **Host-скрипт `tmuxpad-host.sh`** (bash, встроен в бандл, ставится на сервер через stdin). Вся логика tmux живёт в нём; приложение вызывает подкоманды (`version`, `list`, `new`, `attach`, `take`, `copy-cancel`, `kill`, `setup`, `doctor`, `auth`) через exec-каналы. Контракт — §7: формат `list` (TSV с заголовком `V 1`), коды выхода (`new` → 3, если сессия есть; `attach` → 4, если нет). Меняешь формат или коды — меняй парсер в `HostAPI` и версию скрипта.

## Инварианты, которые легко сломать

- **Одно SSH-соединение на сервер.** Внутри PTY-каналы терминалов и exec-каналы. sshd по умолчанию даёт 10 сессий на соединение (`MaxSessions`), поэтому не больше 8 PTY и 2 одновременных exec на сервер.
- **Keepalive — прикладной exec-пинг `true`.** В swift-nio-ssh/Citadel встроенного keepalive нет.
- **`attach` без `-d`.** Приложение выкидывает только собственных зависших клиентов (`detach-client` по файлам `~/.tmuxpad/clients/<pid>` с тем же `TMUXPAD_CLIENT`); чужих выкидывает только `take` по явной кнопке «Забрать» (§6.1). Размер окна решает `window-size latest`, отсюда порог tmux ≥ 3.1. `list` отдаёт число чужих (`others`), а не `session_attached`.
- **Ввод в copy-mode tmux глотается.** Перед первым вводом после скролла приложение вызывает `copy-cancel NAME` через exec и ждёт его (§3.5). Биндинги tmux и глобальный `mouse on` в `~/.tmux.conf` не трогаем: `mouse` ставится на сессию в `new`/`attach`.
- **Мышиные отчёты и focus-отчёты (`ESC [ I`/`ESC [ O`) SwiftTerm идут в PTY мимо `copy-cancel`** (`TerminalSession.input`, разбор — `MouseReport`), иначе второй шаг прокрутки выводит pane из copy-mode. Клавиатура и мышь приходят из SwiftTerm одним делегатным `send`.
- **Таргеты tmux в скрипте**: для pane/окна (`send-keys -X`, `set`/`show` любых опций, включая session-опцию `mouse`) — `=NAME:`, голый `=NAME` даёт `can't find pane` или `no such session`; для session-команд — `=NAME`.
- **Агент запускается через `send-keys` во внутренний шелл tmux-сессии**, а не как её команда: выход из claude не должен убивать сессию.
- **Имя Claude-сессии = имя tmux-сессии** (`claude -n NAME --session-id <uuid>`); после ребута сервера — `--resume <uuid>`, UUID в `~/.tmuxpad/NAME.claude`.
- **Валидация имён** и в приложении, и в скрипте: сессия `^[A-Za-z0-9_-]{1,64}$`, проект `^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$`. В exec-строки ничего не подставляется без экранирования. Токен Claude передаётся только через stdin.
- **Каналы SSH ядро открывает через NIOSSH напрямую** (`SessionChannel`, `NIOSSHHandler.createChannel`), не через `executeCommand`/`withPTY` Citadel: те теряют stderr, не дают stdin с EOF и открывают shell вместо exec.
- **`SSHTransport` — единственная точка контакта с сетью**; пул и терминал тестируются на фейке (`FakeTransport`).
- **Терминал — за протоколом `TerminalSurface`**, чтобы SwiftTerm можно было заменить на libghostty.
- **Ввод из SwiftTerm идёт в ядро только через `InputPump` → `TerminalSession.input`**, не через `send`: делегат зовётся на main синхронно, `Task` на каждый вызов перемешал бы байты, а `send` мимо `input` пропустил бы `copy-cancel` и разбор мышиных отчётов.
- **Один `TmuxTerminalView` на открытый терминал** (`OpenTerminal.view`), он не пересоздаётся при переключении: `TerminalContainerView` только снимает старый view и ставит текущий. Иначе теряется экран и переключение перестаёт быть мгновенным.
- **SwiftTerm закреплён точной версией** (`exactVersion` в `project.yml`): колесо от drag пальцем — часть контракта §3.5. При обновлении перепроверить, что SwiftTerm шлёт колесо в той форме, которую разбирает `MouseReport` ядра (`TerminalBenchTests.wheelUpEntersCopyModeAndTypingLeavesIt`).
- **Приложение не логирует токен Claude и приватные ключи**: ни в `DiagnosticsLog`, ни в `print`/`os_log`, ни в тексты ошибок.
- **Keychain — только через `App/Platform/Keychain.swift`** (`SecItem*` больше нигде): там `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` и сервисы `dev.tmuxpad.*`.
- **Вопрос «Доверять» — по несовпадению отпечатка с `ServerConfig.hostKeyFingerprint`, а не по `hostKeyFirstSeen`** (`ServerCheckModel.connectTrusted`): ядро пишет ключ в `HostKeyStore` до ответа пользователя. Без вопроса конфиг догоняет только копия сервера, у которой этот отпечаток уже подтверждён для того же `host:port`. Смена адреса в `ServerStore.update` очищает отпечаток. Несовпадение с непустым отпечатком в конфиге (у копии без своего — в конфиге другого сервера с тем же адресом) — не вопрос, а блокировка `hostKeyChanged` с возвратом подтверждённого отпечатка в `HostKeyStore`; поэтому «Сбросить» очищает отпечаток у всех серверов с этим адресом.
- **OpenSSH-текст Ed25519 пишет `SSHKeys.openSSHEd25519` ядра** (им пользуются `SSHKeys.generateEd25519` и `KeychainKeyStore`), не `makeSSHRepresentation` Citadel: при комментарии длиной 5 по модулю 8 тот даёт файл, который Citadel не читает (`invalidPadding`). Комментарий ключа (`KeychainKeyStore.comment(for:)`) — только `[A-Za-z0-9._-]`: он попадает в shell-команду `authorizedKeysCommand`.
- **Действия над сессией — только через `SessionActions`** (`App/State/SessionActions.swift`): контекст-меню, свайп, мастера, плашки и меню `[⋯]` над терминалом зовут одни и те же `open`/`take`/`detach`/`kill`/`create`, а не `HostAPI` или `OpenSessionsModel` напрямую; подтверждения — в UI. `take` — только из «Забрать».
- **Ошибки ядра показываются пользователю через `userText(_:)`** из `App/UI/ErrorText.swift`: у `SSHError`/`HostError` английские `description`, новый случай в ядре — новый русский текст и строка в `ErrorTextTests`.
- iPadOS рвёт сокеты в фоне; устойчивость даёт tmux, приложение переподключается по `scenePhase` и `NWPathMonitor` (§6).
- **Face ID — в `LifecycleCoordinator` и `OpenTerminal.retry`, а не только в `auth(for:)`**: пул переподключается с сохранённым `SSHAuth`, не вызывая `auth(for:)`. Ключи кеширует `KeyCache` в `AppEnvironment.auth(for:)`, кеш чистит `KeyUnlocker.lock()` при уходе в фон; опрос дерева в фоне останавливается сразу, иначе его тик после `lock()` спрашивал бы Face ID.
- **На `scenePhase` и смену сети реагирует только `LifecycleCoordinator`**: `RootView` передаёт ему фазу, `NetworkMonitor` — событие; пул (`disconnectAll`/`reconnectAll`) и опрос дерева (`tree.start/stop`) из view и других моделей по этим событиям не дёргаются, иначе двойной reconnect и закрытие соединений мимо фоновой задачи.

## Тесты

Ядро — Swift Testing, интеграционные — против Docker-контейнера с sshd + tmux (`bench.sh`); host-скрипт — свой раннер `host/tests/run.sh` и shellcheck. Приложение — `AppTests` (Swift Testing в симуляторе, `scripts/ios-test.sh`); в симуляторе Xcode 26 Secure Enclave доступен (`secureEnclaveUnavailableThrows` там пропускается), вход SE-ключом на настоящий сервер проверяется на устройстве.
