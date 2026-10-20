# TmuxPadCore

Слой Core приложения TmuxPad (спека `docs/tmuxpad-spec.md`, §5.2): всё, что собирается и
тестируется без Apple-фреймворков. SwiftPM-пакет, Swift 6, iOS 17+ / macOS 14+ / Linux. Ни UIKit,
ни SwiftUI, ни Keychain, ни файловых хранилищ: платформенное — за протоколами, реализации в приложении.

## Модули

| Каталог | Что внутри |
|---|---|
| `Models/` | модели §5.1 (`ServerConfig`, `SSHKeyInfo`, `ServerSnapshot`, `RemoteSession`, `RemoteProject`, `DoctorReport`), валидация имён сессий и проектов, подсказка имени `Validation.suggestedSessionName(from:)`; `SessionTree` — дерево сайдбара из снимка (проекты → сессии, `byActivity`); `OpenSessionsRoster` — открытые терминалы: порядок вкладок, вытеснение самого давно неактивного сверх 8, JSON |
| `Host/` | `HostCommand` (exec-строки с экранированием), `HostAPI` (подкоманды скрипта, коды выхода → `HostError`), парсеры `list` V1 и `doctor`, `HostBootstrap` (проверка версии и установка скрипта), `HostScript` (скрипт-ресурс) |
| `SSH/` | протоколы `SSHTransport` / `SSHConnection` / `PTYChannel` (§12), `CitadelTransport` на swift-nio-ssh, `SessionChannel` (exec, exec со stdin + EOF, PTY + exec), ключи Ed25519 (`SSHKeys`), `TOFUHostKeyValidator`, протоколы `KeyStore` / `HostKeyStore` с in-memory реализациями |
| `Pool/` | `ConnectionPool` и `ServerConnection`: одно соединение на сервер, 2 слота exec (`AsyncSemaphore`), до 8 PTY, exec-пинг `true`, бэкофф-реконнект, `ConnectionState`; интервалы — `PoolSettings`; `TreeRefresher` — опрос `list` серверов раз в 10 с, `ServerTreeState` (доступность, снимок, `BootstrapStatus`, `attention`) |
| `Terminal/` | `TerminalSurface` (протокол экрана, `copyModeSuspected`), `TerminalSession`: PTY `attach`, resize, `input(_:)` — мышиные отчёты мимо `copy-cancel`, ввод с `copy-cancel` перед первым нажатием после скролла, `cancelCopyMode()`, правило выбивания (§6.1), `TerminalState`; `MouseReport` — разбор исходящих байтов на SGR/X10-отчёты (`TerminalInput`) |
| `Diagnostics/` | `DiagnosticsLog`: кольцевой буфер событий без секретов и байтов терминала, `export()` для «Поделиться» (§3.6) |
| `Resources/` | `tmuxpad-host.sh` — копия `host/tmuxpad-host.sh` |

Каналы SSH ядро открывает через `NIOSSHHandler.createChannel` напрямую, а не через
`executeCommand`/`withPTY` Citadel; от Citadel берутся только разбор и экспорт OpenSSH-ключей.
`SSHTransport` — единственная точка контакта с сетью: пул и терминал тестируются на
`FakeTransport`.

## Что реализует приложение

- `KeyStore` — Keychain; ключ Secure Enclave P-256 заворачивается в
  `SSHPrivateKey(NIOSSHPrivateKey(secureEnclaveP256Key:))`, Ed25519 — через `SSHKeys`.
- `HostKeyStore` — доверенные отпечатки (TOFU, §8). Новый отпечаток ядро сохраняет само и
  подключается; при `ServerConnection.hostKeyFirstSeen == true` UI показывает «Доверять»,
  отказ → `disconnect()` + `reset(host:port:)`. При `SSHError.hostKeyChanged` — `reset(host:port:)`
  по подтверждению.
- `scenePhase → .active` → `ConnectionPool.reconnectAll()`, смена сети (`NWPathMonitor`) →
  `reconnectAll(force: true)`: рвёт и соединения, которые выглядят живыми.
- `TerminalSurface` — SwiftTerm (позже, возможно, libghostty); вызовы приходят не с main.
- Делегат SwiftTerm `send(source:data:)` зовёт `TerminalSession.input(_:)` по порядку прихода
  байтов; чип «Прокрутка ✕» показывается по `copyModeSuspected(true)` (колесо вверх, скролл) и
  прячется по `copyModeSuspected(false)`; тап по нему — `cancelCopyMode()`.
- `TreeModel` подписывается на `TreeRefresher.updates()`, `start()`/`stop()` — по `scenePhase`,
  серверы — `setServers(_:)`; после «Установить» — `markPrepared(_:)`, pull-to-refresh —
  `refresh(id, force: true)`. Сервер без `ServerConfig.hostKeyFingerprint` опрос не подключает
  (`.needsSetup("Connection not checked")`): после «Доверять» приложение пишет отпечаток в
  `ServerConfig` и передаёт обновлённый список в `setServers(_:)`. При `ServerTreeState.attention`
  (`authFailed`, `hostKeyChanged`) UI открывает проверку сервера, а не «Повторить».
- `OpenSessionsModel` держит `OpenSessionsRoster` (в UserDefaults) и делает
  `detach()` терминалам, которые вернул `open(_:)` как вытесненные.
- `deviceID` из Keychain и `ServerConfig` из JSON-хранилища приложения передаются в `ConnectionPool`.

## Скрипт-ресурс

`Sources/TmuxPadCore/Resources/tmuxpad-host.sh` — побайтная копия `host/tmuxpad-host.sh`.
После правки скрипта скопировать его сюда:

```
cp host/tmuxpad-host.sh TmuxPadCore/Sources/TmuxPadCore/Resources/tmuxpad-host.sh
```

Равенство проверяет `HostScriptResourceTests`. Версию (`VERSION=` в скрипте) `HostBootstrap`
читает из ресурса и сравнивает с `tmuxpad-host.sh version` на сервере.

## Сборка и тесты

Команды — из корня репозитория:

```
swift build --package-path TmuxPadCore --build-tests          # первая сборка ~12,5 мин на 2 vCPU, дальше минуты
swift test --package-path TmuxPadCore --skip IntegrationTests  # юнит-тесты, без Docker
TmuxPadCore/scripts/test.sh                                   # стенд + все тесты
TmuxPadCore/scripts/test.sh --filter HostAPIIntegrationTests  # один suite или тест (regex по имени)
shellcheck -s bash host/tests/bench.sh TmuxPadCore/scripts/test.sh
```

Тесты — Swift Testing. Юнит-тесты — `*Tests.swift`, интеграционные — `*IntegrationTests.swift`:
они ходят в Docker-стенд sshd + tmux из `host/tests/docker/` и гоняют настоящий скрипт. Без
переменных стенда они пропускаются, а не падают.

Стенд — `host/tests/bench.sh up|down`: тот же образ, что у `host/tests/run.sh`, состояние в
`host/tests/.bench/`. `up` идемпотентен и печатает `export TMUXPAD_BENCH_PORT=…
TMUXPAD_BENCH_KEY=… TMUXPAD_BENCH_USER=dev`; `scripts/test.sh` делает `up` → `swift test` →
`down`. `TMUXPAD_TEST_BASE=ubuntu:22.04` — стенд на tmux 3.2a.

На macOS оба скрипта идут системным bash 3.2; нужен Docker (Docker Desktop или OrbStack) и,
желательно, `brew install coreutils`: без `timeout`/`gtimeout` `bench.sh` предупреждает и ждёт
ssh без таймаута.
