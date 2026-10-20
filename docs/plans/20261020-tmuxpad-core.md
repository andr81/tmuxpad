# Пакет ядра `TmuxPadCore`: транспорт SSH, `HostAPI`, пул соединений, терминальная сессия

## Overview

Второй план по спеке `docs/tmuxpad-spec.md`, §5.2: всё из слоя Core, что собирается и тестируется
без Apple-фреймворков, — SwiftPM-пакет `TmuxPadCore` в каталоге `TmuxPadCore/` репозитория.
Исполняется на этом Linux-хосте (aarch64, Swift 6.1.3 в `~/.local/swift-6.1.3`, `swift` в PATH
через `~/.local/bin`), тесты ходят в тот же Docker-стенд sshd + tmux, что и host-скрипт из
плана 1 (`host/tests/docker/`), и гоняют настоящий `host/tmuxpad-host.sh`. Приложение (SwiftUI,
SwiftTerm, Keychain, Secure Enclave, SwiftData, `NWPathMonitor`) — план 3 на Mac; оно подключит
этот пакет как зависимость и реализует его протоколы `KeyStore`, `HostKeyStore`,
`TerminalSurface`.

Что входит (§5.2, строка «Linux и Mac»): модели §5.1 и валидация имён; сборка exec-строк §5;
парсеры `list` V1 и `doctor`, коды выхода → типизированные ошибки (`HostAPI`); установка и
проверка версии скрипта (`HostBootstrap`) со скриптом-ресурсом пакета; транспорт SSH на Citadel
0.12.1 + swift-nio-ssh за протоколом `SSHTransport` (§12) с TOFU-валидатором хост-ключа и
Ed25519-ключами через swift-crypto; `ConnectionPool` — одно соединение на сервер, очередь exec на
2 слота, не больше 8 PTY, exec-пинг `true`, бэкофф-реконнект, автомат состояний; `TerminalSession`
без view — PTY-канал `attach`, resize, выход из copy-mode перед вводом, обнаружение «нас выбили»
и правило «один раз молча, второй раз за минуту — плашка» (§6, §6.1); журнал диагностики §3.6.

### Решения, принятые в спеке (не переоткрывать)

- Одно SSH-соединение на сервер; внутри не больше 8 PTY-каналов и 2 одновременных exec: sshd по
  умолчанию даёт 10 сессионных каналов на соединение (`MaxSessions`). Отказ открыть канал —
  ошибка сразу, без ожидания (§5).
- Keepalive — прикладной exec-пинг `true` раз в `keepaliveSeconds` с ответом за 5 с; если за
  интервал уже прошёл любой exec, пинг пропускается; два неответа подряд — соединение мёртвое (§5).
- Реконнект с бэкоффом 1 → 2 → 5 → 10 с; после четырёх неудачных попыток пул останавливается в
  `failed` и ждёт явного запроса (§6, решение 2026-10-20).
- `attach` без `-d`; канал закрылся с 0 и сессия жива → нас выбил чужой `attach -d`: один раз
  переподключаемся молча, повтор в течение минуты → состояние «Отключено другим клиентом» с
  действиями «Переподключить» / «Забрать» (`take`) / «Закрыть» (§6, §6.1).
- Ввод в copy-mode tmux глотается: перед первым вводом после скролла вверх — `copy-cancel NAME`
  через exec, дождаться, затем ввод в PTY (§3.5).
- Форма exec-строк: `env TMUXPAD_CLIENT='…' TMUXPAD_PROJECTS='…' TMUXPAD_CMD='…'
  "$HOME"/.local/bin/tmuxpad-host.sh <cmd> <args>`; значения — в одинарных кавычках после
  валидации, `'` в значениях запрещён (§5, §8). Токен Claude и сам скрипт идут только через stdin.
- PTY: `TERM=xterm-256color`, `LANG=en_US.UTF-8` через env-запрос канала (sshd примет, если
  `AcceptEnv`, иначе молча отбросит), размер — от view (§5).
- TOFU: отпечаток `SHA256:<base64 без '='>` от wire-формата ключа, как у OpenSSH; смена
  отпечатка — блокирующая ошибка, подключение только после явного сброса (§8).
- Каналы SSH ядро открывает через `NIOSSHHandler.createChannel` напрямую поверх соединения
  Citadel: в публичном API Citadel 0.12.1 нет PTY + exec и нет EOF для stdin (§4, §5.2).
- Host-скрипт — ресурс пакета `Sources/TmuxPadCore/Resources/tmuxpad-host.sh`, копия
  `host/tmuxpad-host.sh`; равенство проверяет тест (§5.2).

### Решения исполнителя плана

1. **Раскладка**: `TmuxPadCore/Package.swift` (`swift-tools-version:6.0`, `swiftLanguageModes:
   [.v6]`, `platforms: [.iOS(.v17), .macOS(.v14)]`), один библиотечный таргет `TmuxPadCore`
   в `Sources/TmuxPadCore/` с подкаталогами `Models/`, `Host/`, `SSH/`, `Pool/`, `Terminal/`,
   `Diagnostics/`, `Resources/`; один тестовый таргет `TmuxPadCoreTests` в
   `Tests/TmuxPadCoreTests/`. Юнит-тесты — файлы `*Tests.swift`, интеграционные — `*IntegrationTests.swift`
   с suite-трейтами `.serialized` и `.enabled(if: Bench.isAvailable)`: без стенда они пропускаются,
   а не падают. Фреймворк — Swift Testing (в тулчейне 6.1), не XCTest.
2. **Зависимости**: `Citadel` `from: "0.12.1"`; чтобы импортировать `NIOSSH`, `NIOCore`,
   `NIOPosix` и `Crypto` напрямую, те же пакеты объявляются явно с теми же URL, что у Citadel:
   `https://github.com/Wellz26/swift-nio-ssh.git` (`"0.3.4"..<"0.4.0"`, Citadel зависит от этого
   форка, а не от `apple/swift-nio-ssh`), `https://github.com/apple/swift-nio.git` (`from:
   "2.81.0"`), `https://github.com/apple/swift-crypto.git` (`from: "3.12.3"`). `Package.resolved`
   коммитится.
3. **Транспорт — два уровня.** Протокол `SSHTransport` (`connect(_ endpoint: SSHEndpoint, auth:
   SSHAuth, hostKeys: any HostKeyStore) async throws -> any SSHConnection`) и протокол
   `SSHConnection` (`exec(_ command: String, stdin: Data?, timeout: Duration) async throws ->
   ExecResult`, `openPTY(command:term:cols:rows:environment:) async throws -> any PTYChannel`,
   `onDisconnect: AsyncStream<Void>`, `isConnected`, `close()`). Реализация `CitadelTransport`:
   TCP-канал поднимается своим `ClientBootstrap`, Citadel вешает на него SSH через
   `SSHClient.connect(on: channel, settings:)`; так у ядра остаётся `Channel`, из которого
   `channel.pipeline.handler(type: NIOSSHHandler.self)` даёт `createChannel`. Все три вида каналов
   (exec, exec со stdin, PTY + exec) — один класс `SessionChannelHandler` (ChannelDuplexHandler):
   env-запросы → при PTY `PseudoTerminalRequest` → `ExecRequest(wantReply: true)`; stdout/stderr
   по `SSHChannelData.type`; выход из `SSHChannelRequestEvent.ExitStatus`; EOF stdin —
   `channel.close(mode: .output)` при `allowRemoteHalfClosure = true`. `executeCommandStream`
   Citadel не используется: он теряет stderr в `executeCommand`, не даёт stdin и жёстко ждёт
   канал 15 с.
4. **Ключи**: `SSHAuth` = `.privateKey(NIOSSHPrivateKey, user: String)`; ядро умеет Ed25519
   целиком (`Curve25519.Signing.PrivateKey` из swift-crypto: генерация, импорт OpenSSH-файла
   через `Curve25519.Signing.PrivateKey(sshEd25519:)` из Citadel, экспорт публичного ключа
   `String(openSSHPublicKey:)` + комментарий); Secure Enclave P-256 приложение завернёт в
   `NIOSSHPrivateKey(secureEnclaveP256Key:)` само. Протокол `KeyStore` (`list`, `save(SSHKeyInfo,
   privateKeyOpenSSH:)`, `privateKey(for: UUID) -> NIOSSHPrivateKey?`, `delete`) и `HostKeyStore`
   (`fingerprint(for host: String, port: Int) -> String?`, `save`, `reset`) — с in-memory
   реализациями в пакете (`InMemoryKeyStore`, `InMemoryHostKeyStore`): они нужны тестам и
   подойдут приложению как заглушки до Keychain.
5. **TOFU-валидатор** — `SSHHostKeyValidator.custom(TOFUHostKeyValidator)`: отпечатка нет →
   сохранить и пропустить (режим «первое подключение», ядро сообщает отпечаток через результат
   `connect` для показа «Доверять»); совпал → пропустить; не совпал → `SSHError.hostKeyChanged(
   expected:actual:)`, соединение не поднимается. Подтверждение пользователем в UI — план 3; ядро
   даёт `HostKeyStore.reset(host:port:)`.
6. **Ошибки** — один `enum HostError: Error, Equatable`: `.scriptMissing` (команда не найдена:
   код 127 или 126 от шелла), `.badRequest(String)` (код 2, текст stderr), `.sessionExists` (3),
   `.noSession` (4), `.projectsRootMissing` (код 2 у `list`), `.failed(code: Int, stderr: String)`
   (прочее), `.badOutput(String)` (парсер). `SSHError`: `.connectFailed(String)`,
   `.authFailed`, `.hostKeyChanged(expected:actual:)`, `.channelRefused` (сервер не открыл
   канал — предел `MaxSessions`), `.timeout`, `.disconnected`. Все `Sendable`.
7. **Пул**: `ConnectionPool` (actor) хранит `ServerConnection` (actor) по `ServerConfig.id`;
   `ServerConnection` владеет `SSHConnection`, семафором exec на 2 слота (`AsyncSemaphore`,
   свой, ~40 строк), счётчиком PTY (9-й → `SSHError.channelRefused` локально, не ходя на сервер),
   задачей keepalive и автоматом состояний `ConnectionState`: `.disconnected`, `.connecting`,
   `.connected(since:)`, `.reconnecting(attempt:)`, `.failed(String)`. Переходы и причины —
   событиями в `DiagnosticsLog` и в `AsyncStream<ConnectionState>` для UI. Интервалы — поля
   `PoolSettings` (`keepalive`, `pingTimeout = 5 с`, `backoff = [1, 2, 5, 10] с`,
   `connectTimeout = 15 с`) в `Duration`: юнит-тесты задают миллисекунды и фейковый транспорт,
   отдельных абстракций часов нет.
8. **`TerminalSession`** (actor) не знает про SwiftTerm: протокол `TerminalSurface` —
   `feed(_ bytes: Data)`, `size: (cols: Int, rows: Int)`, `stateChanged(TerminalState)`; сессия
   открывает PTY `attach NAME`, качает вывод в `feed`, принимает `send(Data)`, `resize`,
   `noteScrolledUp()` (чип «Прокрутка»), `detach()`, `take()`, `reconnect()`. Состояния
   `TerminalState`: `.connecting`, `.live`, `.reconnecting`, `.ended`, `.disconnectedByOther`,
   `.offline(String)`. Правило выбивания — внутри сессии: канал кончился кодом 0 без нашего
   `detach` → `list`; сессии нет → `.ended`; есть → если прошлый такой случай был меньше
   `kickWindow` (60 с) назад → `.disconnectedByOther`, иначе `attach` снова молча.
9. **Диагностика**: `DiagnosticsLog` (actor) — кольцевой буфер на 2000 `DiagnosticsEvent`
   (`date`, `server: String` метка, `kind`, `message`), `export() -> String` для «Поделиться»;
   без секретов и без байтов терминала. Пишут пул, транспорт (подключение, отпечаток, обрывы) и
   `HostAPI` (команда без значений переменных, код выхода, длительность).
10. **Стенд для Swift-тестов** — `host/tests/bench.sh up|down`: тот же образ и ключ, что в
    `run.sh`, состояние в `host/tests/.bench/` (gitignored: `key`, `key.pub`, `cid`, `port`);
    `up` идемпотентен и печатает на stdout строки `export TMUXPAD_BENCH_PORT=… TMUXPAD_BENCH_KEY=…
    TMUXPAD_BENCH_USER=dev` (лог — на stderr), чтобы вызывать `eval "$(host/tests/bench.sh up)"`.
    Обёртка `TmuxPadCore/scripts/test.sh [аргументы swift test]`: `up` → `swift test
    --package-path TmuxPadCore "$@"` → `down`, код — от `swift test`. Swift-тесты читают эти
    переменные в `Bench`; между тестами — сброс той же строкой, что `reset` в `host/tests/lib.sh`
    (`tmux kill-server; rm -rf ~/.tmuxpad ~/.claude …; mkdir -p ~/projects/{api,web,my.app}`),
    через `exec` того же соединения; скрипт ставится через `HostBootstrap` из ресурса.
11. **Время сборки**: первая сборка зависимостей на этом хосте (2 vCPU) — 747 с (12,5 мин,
    спайк 2026-10-20 нативно; в Docker было 6,5 мин без тестов). Это больше лимита 10 мин одного
    вызова инструмента, поэтому первую `swift build --build-tests` запускать в фоне
    (`run_in_background`) и дождаться уведомления, а не в foreground с таймаутом; дальше сборка
    инкрементальная и укладывается в минуты. В worktree ralphex `.build` пустой — первая задача
    это учитывает.

### Чего этот план не делает

- Ни строки UI, SwiftTerm, Keychain, Secure Enclave, SwiftData, `NWPathMonitor`, `scenePhase`:
  только протоколы и in-memory реализации; всё платформенное — план 3 на Mac.
- Не генерирует P-256 и не хранит приватные ключи на диске; `KeyStore` на диске — приложение.
- Не делает `TreeModel`/автообновление дерева, кэш открытых терминалов, лимит «8 открытых» на
  уровне UI (в ядре — только отказ открыть 9-й PTY-канал).
- Не трогает host-скрипт и его тесты, кроме нового `host/tests/bench.sh` и `.gitignore`;
  контракт §7 не меняется. Если ядру понадобится что-то от скрипта — отдельный план.
- Не оптимизирует: один `ClientBootstrap` на соединение, `MultiThreadedEventLoopGroup.singleton`.
- Не подключает Xcode-проект и `project.yml`.

## Context

- Спека: §4 (строка SSH), §5 («Ключевые решения»: лимит каналов, keepalive, UUID устройства,
  PTY, форма exec-строк, `TerminalSurface`), §5.1 (модели), §5.2 (граница пакета), §6 и §6.1
  (жизненный цикл, выбивание), §7 (контракт скрипта), §8 (TOFU, экранирование), §3.5 («Выход из
  copy-mode»), §3.6 («Диагностика»), §12 (`SSHTransport`). `CLAUDE.md` — инварианты.
- Контракт скрипта (план 1, `host/README.md`): `version` → `tmuxpad-host 1` (в скрипте строка
  `VERSION=1`); `list` → `V\t1`, `S\t<name>\t<others>\t<project>\t<activity_epoch>`,
  `P\t<project>\t<abs_path>`; коды: 2 — аргументы/имена/окружение (у `list` — нет корня
  проектов), 3 — `new` при существующей сессии, 4 — `attach`/`take` без сессии, `kill` и
  `copy-cancel` идемпотентны (0), прочее 1; `doctor` → `ok|warn|fail\t<key>\t<message>`, ключи
  `tmux`, `claude`, `claude_name`, `projects`, `script`, код 1 при `fail`; `new` без stdout;
  `auth` — токен одной строкой на stdin, `^[A-Za-z0-9_-]+$`, иначе 2; установка —
  `mkdir -p ~/.local/bin && cat > ~/.local/bin/tmuxpad-host.sh && chmod +x
  ~/.local/bin/tmuxpad-host.sh` со скриптом на stdin. `TMUXPAD_CLIENT` обязателен для
  `attach`/`take`, валидируется по regex UUID.
- Стенд (`host/tests/docker/`): пользователь `dev`, ключ через `AUTHORIZED_KEY`, sshd с
  `PasswordAuthentication no`, `AcceptEnv LANG LC_*`, `MaxSessions` по умолчанию 10;
  заглушки `/usr/local/bin/claude` (пишет `$PWD|$*|token=…` в `~/claude-args.log`, `--help` с
  `--name`) и `/opt/claude-old/bin/claude` (без `--name`). Образы `tmuxpad-test:ubuntu-24.04`
  и `-22.04` уже собраны. Фоновый клиент tmux с хоста — `ssh -tt -n` (см. `attach_bg` в
  `host/tests/lib.sh`), пригодится, чтобы изобразить «чужого» клиента.
- Citadel 0.12.1 (проверено по исходникам в `.build/checkouts`): `SSHClient.connect(host:port:
  authenticationMethod:hostKeyValidator:reconnect:algorithms:protocolOptions:group:
  channelHandlers:connectTimeout:)`, `connect(to: SSHClientSettings)`, `connect(on: Channel,
  settings:)`; `onDisconnect(perform:)`, `isConnected`, `eventLoop`, `close()`.
  `SSHAuthenticationMethod.ed25519(username:privateKey:)`, `.p256(...)`,
  `.custom(NIOSSHClientUserAuthenticationDelegate)`; `SSHHostKeyValidator.trustedKeys(Set<
  NIOSSHPublicKey>)`, `.acceptAnything`, `.custom(NIOSSHClientServerAuthenticationDelegate)`
  (делегат получает `NIOSSHPublicKey` и `EventLoopPromise<Void>`). `Curve25519.Signing.
  PrivateKey(sshEd25519: String|Data, decryptionKey: Data?)` читает `openssh-key-v1` без
  шифра и с bcrypt. `executeCommandStream` кидает `SSHClient.CommandFailed(exitCode:)` при
  ненулевом коде, `executeCommand` без `mergeStreams` выбрасывает stderr; `withPTY` после
  `PseudoTerminalRequest` шлёт `ShellRequest`, а не exec; `TTYStdinWriter` умеет только `write`
  и `changeSize`; создание канала ограничено 15 с → `CitadelError.channelCreationFailed`.
  `withPTY`/`withTTY`/`withExec` помечены `@available(macOS 15.0, *)`.
- swift-nio-ssh 0.3.7 (форк `Wellz26`): `NIOSSHHandler.createChannel(_ promise:
  EventLoopPromise<Channel>?, channelType: .session, _ initializer: ((Channel, SSHChannelType)
  -> EventLoopFuture<Void>)?)`; события канала `SSHChannelRequestEvent.PseudoTerminalRequest(
  wantReply:term:terminalCharacterWidth:terminalRowHeight:terminalPixelWidth:terminalPixelHeight:
  terminalModes: SSHTerminalModes([:]))`, `.EnvironmentRequest(wantReply:name:value:)`,
  `.ExecRequest(command:wantReply:)`, `.WindowChangeRequest(terminalCharacterWidth:
  terminalRowHeight:terminalPixelWidth:terminalPixelHeight:)`; входящие `ExitStatus.exitStatus`,
  `ExitSignal`, `ChannelSuccessEvent`/`ChannelFailureEvent`; данные — `SSHChannelData(type:
  .channel|.stdErr, data: .byteBuffer(…))`; половинное закрытие — опция канала
  `allowRemoteHalfClosure`. Ключи: `NIOSSHPrivateKey(ed25519Key:)`, `(p256Key:)`,
  `(secureEnclaveP256Key:)` (только Apple), `.publicKey`; `NIOSSHPublicKey(openSSHPublicKey:
  String)`, `write(to: inout ByteBuffer)` (wire-формат для отпечатка), `String(openSSHPublicKey:)`.
- Тулчейн: Swift 6.1.3 (`swift --version` → `Swift version 6.1.3 (swift-6.1.3-RELEASE)`,
  `aarch64-unknown-linux-gnu`), в PATH через `~/.local/bin`. Проверено нативно (спайк
  2026-10-20): пакет с зависимостью Citadel 0.12.1 в режиме Swift 6 собирается за 747 с, `swift
  test` с `import Testing` (Testing Library 6.1.3) находит и гоняет тесты, `.build` после сборки
  — 511 МБ; `NIOSSHPrivateKey(ed25519Key:).publicKey.write(to:)` даёт wire-формат для отпечатка.
  Хост: 2 vCPU, 7 ГБ RAM, Ubuntu 24.04. Есть
  `docker`, `shellcheck`, `ssh`, `ssh-keygen`. Нет Xcode, Mac.
- Команды длиннее 2 мин в инструментах Claude Code требуют явного `timeout` (до 10 мин), а
  длиннее 10 мин — запуска в фоне с ожиданием уведомления: первая `swift build` — второй случай,
  прогон `scripts/test.sh` после неё — первый.

## Validation Commands

```
swift build --package-path TmuxPadCore --build-tests          # первая сборка ~12,5 мин: в фоне; дальше минуты
swift test --package-path TmuxPadCore --skip IntegrationTests  # юнит-тесты, без Docker
TmuxPadCore/scripts/test.sh                                   # стенд + все тесты
TmuxPadCore/scripts/test.sh --filter HostAPIIntegrationTests  # один suite или тест (regex по имени)
shellcheck -s bash host/tests/bench.sh TmuxPadCore/scripts/test.sh
host/tests/run.sh                                             # стенд скрипта не должен сломаться
```

`swift build` в режиме Swift 6 должен проходить без предупреждений о конкурентности; новые
предупреждения компилятора считаются ошибкой задачи.

## Testing Strategy

- **Юнит-тесты** (без сети): парсеры `list`/`doctor`, сборка и экранирование exec-строк,
  валидация имён, отпечатки, `HostError` из кодов выхода, автомат пула и терминальной сессии на
  `FakeTransport` (управляемый из теста: отдаёт заранее заданные `ExecResult`, умеет «порвать»
  соединение и «закрыть PTY с кодом 0», считает открытые каналы) с интервалами в миллисекундах.
- **Интеграционные suite** `*IntegrationTests` — `.serialized`, `.enabled(if: Bench.isAvailable)`;
  один контейнер на прогон `scripts/test.sh`, сброс состояния перед каждым тестом через `exec`;
  каждое ожидание — с таймаутом (`withTimeout(.seconds(10))`-хелпер), чтобы зависший канал не
  вешал прогон. Против стенда проверяются: соединение и аутентификация Ed25519 ключом из файла
  стенда, TOFU (первое подключение, совпадение, подмена), exec с кодами выхода и stderr, stdin +
  EOF, PTY + exec с `tty` и `stty size`, предел каналов (11-й отказ), установка скрипта из
  ресурса и весь `HostAPI` на настоящем скрипте, обрыв соединения (`kill -9 $PPID` внутри exec
  убивает sshd-процесс сеанса) → реконнект пула, PTY `attach` к tmux-сессии с вводом и resize,
  выбивание через `take` вторым UUID.
- Тест синхронности ресурса: `Sources/TmuxPadCore/Resources/tmuxpad-host.sh` побайтно равен
  `host/tmuxpad-host.sh` (путь к корню репозитория — от `#filePath` теста).
- Пропуск без стенда — явный: при отсутствии `TMUXPAD_BENCH_PORT` интеграционные тесты
  помечаются skipped, юнит-тесты идут всегда.

## Задачи

### Task 1: каркас пакета, модели, валидация, exec-строки, парсеры, диагностика

**Файлы:** `TmuxPadCore/Package.swift` (create), `TmuxPadCore/Sources/TmuxPadCore/Models/Models.swift`
(create), `.../Models/Validation.swift` (create), `.../Host/HostCommand.swift` (create),
`.../Host/ListParser.swift` (create), `.../Host/DoctorParser.swift` (create),
`.../Host/HostError.swift` (create), `.../Diagnostics/DiagnosticsLog.swift` (create),
`TmuxPadCore/Tests/TmuxPadCoreTests/{ValidationTests,HostCommandTests,ListParserTests,DoctorParserTests,HostErrorTests,DiagnosticsLogTests}.swift`
(create), `.gitignore`.

- [ ] `TmuxPadCore/Package.swift`: `// swift-tools-version:6.0`, `name: "TmuxPadCore"`,
      `platforms: [.iOS(.v17), .macOS(.v14)]`, `products: [.library(name: "TmuxPadCore", targets:
      ["TmuxPadCore"])]`, зависимости из решения 2, таргет `TmuxPadCore` с `dependencies:
      [.product(name: "Citadel", package: "Citadel"), .product(name: "NIOSSH", package:
      "swift-nio-ssh"), .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix",
      package: "swift-nio"), .product(name: "Crypto", package: "swift-crypto")]` и `resources:
      [.copy("Resources/tmuxpad-host.sh")]`, тестовый таргет `TmuxPadCoreTests`;
      `swiftLanguageModes: [.v6]`. Положить копию `host/tmuxpad-host.sh` в
      `Sources/TmuxPadCore/Resources/tmuxpad-host.sh` (ресурс нужен уже сейчас, иначе манифест
      не соберётся). Первая сборка: `swift build --package-path TmuxPadCore --build-tests` в
      фоне (решение 11); зафиксировать в progress-логе время сборки и версии из `Package.resolved`
      (ожидаются Citadel 0.12.1, swift-nio-ssh 0.3.7, swift-nio 2.104.x, swift-crypto 3.15.x).
- [ ] `.gitignore`: добавить `TmuxPadCore/.build/`, `TmuxPadCore/.swiftpm/`, `host/tests/.bench/`.
- [ ] `Models/Models.swift` — типы §5.1 как `public struct … : Sendable, Codable, Hashable`:
      `ServerConfig` (`id: UUID`, `label`, `host`, `port = 22`, `user`, `keyID: UUID`,
      `projectsRoot = "projects"`, `startCommand = "claude"`, `keepaliveSeconds = 15`,
      `hostKeyFingerprint: String?`, `sortIndex: Int`), `SSHKeyInfo` (`id`, `name`, `kind:
      Kind` с `.secureEnclaveP256`/`.ed25519`, `publicKeyOpenSSH`, `createdAt`),
      `RemoteProject` (`name`, `path`), `RemoteSession` (`name`, `project`, `otherClients: Int`,
      `lastActivity: Date`), `ServerSnapshot` (`projects`, `sessions`, `fetchedAt`),
      `ServerReachability` (`.unknown`, `.online`, `.offline(String)`, `.needsSetup(String)` —
      `String` вместо `Error`, чтобы тип был `Equatable` и `Sendable`), `DoctorLine` (`level:
      .ok/.warn/.fail`, `key`, `message`), `DoctorReport` (`lines`, `ok: Bool` = нет `fail`).
- [ ] `Models/Validation.swift`: `public enum Validation` с `isValidSessionName(_:)` по regex
      `^[A-Za-z0-9_-]{1,64}$`, `isValidProjectName(_:)` по `^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$`
      (на `Regex` Swift, без `NSRegularExpression`), `isSafeShellValue(_:)` — не пусто, без `'`,
      без управляющих символов и переводов строки (для `projectsRoot`, `startCommand`);
      `ServerConfig.validationIssues() -> [String]` (хост не пуст, порт 1…65535, пользователь не
      пуст и без пробелов, `projectsRoot` и `startCommand` безопасны, `keepaliveSeconds` 5…300).
- [ ] `Host/HostCommand.swift`: `public struct HostEnvironment: Sendable` (`client: UUID`,
      `projectsRoot: String`, `startCommand: String`); `public enum HostCommand: Sendable`
      (`.version`, `.list`, `.new(session:project:)`, `.attach(session:)`, `.take(session:)`,
      `.copyCancel(session:)`, `.kill(session:)`, `.setup`, `.doctor`, `.auth`, `.install`);
      `func render(env: HostEnvironment) throws -> String` строит ровно строку §5:
      `env TMUXPAD_CLIENT='<uuid в нижнем регистре>' TMUXPAD_PROJECTS='…' TMUXPAD_CMD='…'
      "$HOME"/.local/bin/tmuxpad-host.sh <cmd> <args>`; аргументы в одинарных кавычках через
      `shellQuote(_:)` (`'` → `'\''`); имена сессий и проектов проходят `Validation`, иначе
      `HostError.badRequest`; `.install` рендерится в `mkdir -p ~/.local/bin && cat >
      ~/.local/bin/tmuxpad-host.sh && chmod +x ~/.local/bin/tmuxpad-host.sh` без `env`-префикса.
- [ ] `Host/ListParser.swift`: `ListParser.parse(_ text: String, fetchedAt: Date) throws ->
      ServerSnapshot`: первая строка `V\t1` (иная версия → `HostError.badOutput("unsupported list
      version N")`), `S`-строки → `RemoteSession` (`others` и `activity` — целые, `activity` →
      `Date(timeIntervalSince1970:)`), `P`-строки → `RemoteProject`; неизвестные префиксы
      пропускаются (вперёд-совместимость), пустые строки игнорируются, строка с неверным числом
      полей → `badOutput`. `Host/DoctorParser.swift`: `DoctorParser.parse(_:) throws ->
      DoctorReport` по TSV `ok|warn|fail\tKEY\tMESSAGE`; сообщение может содержать табуляцию —
      брать всё после второго `\t`.
- [ ] `Host/HostError.swift`: `enum HostError` по решению 6 и `static func from(command:
      HostCommand, exitCode: Int, stderr: String) -> HostError` (127/126 → `.scriptMissing`;
      2 → для `.list` `.projectsRootMissing`, иначе `.badRequest(stderr)`; 3 →
      `.sessionExists`; 4 → `.noSession`; иначе `.failed(code:stderr:)`), `SSHError` по
      решению 6; у обоих `CustomStringConvertible` с текстом для UI на английском
      (локализация — приложение).
- [ ] `Diagnostics/DiagnosticsLog.swift`: `public actor DiagnosticsLog` с `DiagnosticsEvent`
      (`date`, `server`, `kind: Kind` — `.connect`, `.disconnect`, `.reconnect`, `.ping`,
      `.exec`, `.terminal`, `.hostKey`, `.error`; `message`), `record(_:)`, `events() ->
      [DiagnosticsEvent]`, `export() -> String` (одна строка на событие: ISO-8601 время, сервер,
      вид, сообщение), ёмкость 2000 с вытеснением старых; `AsyncStream<DiagnosticsEvent>`
      `updates` для живого экрана.
- [ ] Юнит-тесты (Swift Testing): валидация — таблица валидных/невалидных имён (`a`, 64 символа,
      65 символов, `a b`, `.hidden` для проекта, `my.app` валиден как проект и невалиден как
      сессия); `HostCommand` — точная строка для `.list` и `.new(session: "api", project:
      "my.app")` с фиксированным UUID, экранирование `'` в `startCommand` отвергается
      `isSafeShellValue`, невалидное имя → `badRequest`, `.install` без `env`; `ListParser` —
      пример из `host/README.md` с двумя `S` и тремя `P`, пустой список (только `V\t1`),
      неверная версия, лишний неизвестный префикс `X\t…` игнорируется, кривая `S`-строка →
      `badOutput`; `DoctorParser` — пять строк из `doctor`, `ok` только без `fail`;
      `HostError.from` — вся таблица кодов, включая `list` + 2; `DiagnosticsLog` — вытеснение
      при 2001 событии, формат `export`.
- [ ] `swift build --package-path TmuxPadCore --build-tests` без предупреждений, `swift test
      --package-path TmuxPadCore` зелёный; коммит.

### Task 2: транспорт SSH на Citadel и NIOSSH, ключи, TOFU, стенд для Swift-тестов

**Файлы:** `TmuxPadCore/Sources/TmuxPadCore/SSH/SSHTransport.swift` (create),
`.../SSH/CitadelTransport.swift` (create), `.../SSH/SessionChannel.swift` (create),
`.../SSH/TOFUHostKeyValidator.swift` (create), `.../SSH/Keys.swift` (create),
`.../SSH/Stores.swift` (create), `host/tests/bench.sh` (create), `TmuxPadCore/scripts/test.sh`
(create), `TmuxPadCore/Tests/TmuxPadCoreTests/Support/{Bench,Timeout}.swift` (create),
`TmuxPadCore/Tests/TmuxPadCoreTests/{KeysTests,TOFUTests,TransportIntegrationTests}.swift` (create).

- [ ] `SSH/SSHTransport.swift`: протоколы `SSHTransport`, `SSHConnection`, `PTYChannel`
      (`output: AsyncThrowingStream<Data, Error>` — поток байтов до закрытия; `send(_ data:
      Data) async throws`; `resize(cols:rows:) async throws`; `close() async`; `exitCode: Int?`
      после закрытия) и типы `SSHEndpoint` (`host`, `port`, `connectTimeout: Duration`),
      `SSHAuth` (`.privateKey(NIOSSHPrivateKey, user: String)`), `ExecResult` (`exitCode`,
      `stdout: Data`, `stderr: Data`, `duration: Duration`), `ConnectOutcome` (`connection`,
      `hostKeyFingerprint`, `firstSeen: Bool`). Всё `Sendable`; `NIOSSHPrivateKey` оборачивается
      в `struct SSHPrivateKey: @unchecked Sendable` с комментарием почему (тип NIOSSH не помечен).
- [ ] `SSH/Keys.swift`: `enum SSHKeys` — `generateEd25519() -> (NIOSSHPrivateKey, publicKeyOpenSSH:
      String)`, `importOpenSSHEd25519(_ text: String, passphrase: String?) throws ->
      NIOSSHPrivateKey` через `Curve25519.Signing.PrivateKey(sshEd25519:decryptionKey:)`
      (ошибка разбора → свой `KeyError.invalidKey(String)`, ошибки Citadel наружу не выходят),
      `publicKeyOpenSSH(_ key: NIOSSHPrivateKey, comment: String) -> String` через
      `String(openSSHPublicKey:)`, `fingerprint(_ key: NIOSSHPublicKey) -> String` —
      `SHA256:` + base64 без `=` от `write(to:)`; `authorizedKeysCommand(publicKey:) -> String`
      — строка из §3.7 (`mkdir -p ~/.ssh && echo '<pub>' >> ~/.ssh/authorized_keys && chmod 600
      ~/.ssh/authorized_keys`).
- [ ] `SSH/Stores.swift`: протоколы `KeyStore` и `HostKeyStore` по решению 4 (методы `async
      throws`), `InMemoryKeyStore`, `InMemoryHostKeyStore` (actors).
- [ ] `SSH/TOFUHostKeyValidator.swift`: `final class TOFUHostKeyValidator:
      NIOSSHClientServerAuthenticationDelegate` — в `validateHostKey(hostKey:validationCompletePromise:)`
      считает отпечаток, сравнивает с `expected: String?` (снимок из `HostKeyStore`, читается до
      подключения), пишет результат в `NIOLockedValueBox` (`seen: String`, `firstSeen: Bool`);
      несовпадение → `promise.fail(SSHError.hostKeyChanged(expected:actual:))`. После успешного
      `connect` транспорт сохраняет новый отпечаток в `HostKeyStore`.
- [ ] `SSH/SessionChannel.swift`: `SessionChannelHandler` (ChannelDuplexHandler, `InboundIn =
      SSHChannelData`) и `final class SessionChannel` поверх `Channel`: `open(on: NIOSSHHandler,
      eventLoop:, command:, env: [(String, String)], pty: PTYRequest?) async throws` —
      `createChannel` с таймаутом из настроек (не 15 с Citadel, а `connectTimeout`), в
      инициализаторе `allowRemoteHalfClosure = true` и добавление хендлера, затем env-запросы,
      при `pty` — `PseudoTerminalRequest(wantReply: true, term:, cols, rows, 0, 0,
      SSHTerminalModes([:]))`, затем `ExecRequest(wantReply: true)`; `ChannelFailureEvent` или
      отказ сервера открыть канал → `SSHError.channelRefused`. Выход: `stdout`, `stderr` как
      `AsyncStream<Data>`, `exit: Int?` из `ExitStatus`, `closed` — continuation по
      `channelInactive`. `write(_:)`, `eof()` (`close(mode: .output)`), `resize` →
      `WindowChangeRequest`, `close()`.
- [ ] `SSH/CitadelTransport.swift`: `public final class CitadelTransport: SSHTransport` —
      `ClientBootstrap(group: .singleton).connectTimeout(…).channelOption(TCP_NODELAY)`,
      `connect(host:port:)`, затем `SSHClient.connect(on: channel, settings: SSHClientSettings(
      host:, port:, authenticationMethod: { .custom(KeyAuthDelegate(user:key:)) } или
      `.ed25519(username:privateKey:)` когда ключ Ed25519, hostKeyValidator: .custom(tofu)))`;
      `CitadelConnection: SSHConnection` хранит `SSHClient`, `Channel`, `NIOSSHHandler`;
      `exec` — `SessionChannel` без PTY, при `stdin != nil` пишет и шлёт `eof()`, собирает
      stdout/stderr до закрытия, ждёт `exit` с таймаутом (`SSHError.timeout`, канал закрывается);
      `openPTY` — `SessionChannel` с PTY, возвращает `PTYChannel`; `onDisconnect` —
      `client.onDisconnect(perform:)` → `AsyncStream`; `close()` — `client.close()`. Ошибки
      Citadel/NIO маппятся: `AuthenticationFailed` → `.authFailed`, `InvalidHostKey`/наш
      `hostKeyChanged` → как есть, `NIOConnectionError`/`ChannelError.connectTimeout` →
      `.connectFailed(описание)`.
- [ ] `host/tests/bench.sh` (bash, `set -u`, shellcheck-чистый): `up` — образ
      `tmuxpad-test:${BASE//[:\/]/-}` из `host/tests/docker` (`TMUXPAD_TEST_BASE`, по умолчанию
      `ubuntu:24.04`), `host/tests/.bench/` с `key`/`key.pub` (`ssh-keygen -q -t ed25519 -N ''`),
      контейнер `docker run -d --rm -p 127.0.0.1::22 -e AUTHORIZED_KEY=…`, `cid` и `port` в
      файлы, ожидание `ssh … true` до 30 с; если `cid` жив — переиспользовать; stdout — только
      `export TMUXPAD_BENCH_PORT=<port>`, `export TMUXPAD_BENCH_KEY=<abs path key>`, `export
      TMUXPAD_BENCH_USER=dev`; `down` — `docker rm -f`, `rm -rf host/tests/.bench`.
      `TmuxPadCore/scripts/test.sh`: `eval "$(host/tests/bench.sh up)"`, `swift test
      --package-path TmuxPadCore "$@"`, `down` в `trap`, код `swift test`.
- [ ] `Tests/Support/Bench.swift`: `enum Bench` — `isAvailable` (есть `TMUXPAD_BENCH_PORT`),
      `endpoint`, `auth()` (ключ из файла через `SSHKeys.importOpenSSHEd25519`), `connect()`
      → `CitadelConnection` с `InMemoryHostKeyStore` (первое подключение), `reset(_ conn)` —
      exec строки сброса из решения 10, `tmux(_ conn, _ args)` — `exec("tmux \(args)")` с
      возвратом stdout. `Timeout.swift`: `withTimeout(_ duration:, _ body:)` на `TaskGroup`.
- [ ] Юнит-тесты `KeysTests`: сгенерированный Ed25519 экспортируется в `ssh-ed25519 AAAA… comment`
      и парсится обратно `NIOSSHPublicKey(openSSHPublicKey:)`; отпечаток — 7 + 43 символа,
      детерминирован; `authorizedKeysCommand` содержит публичный ключ. Для импорта — ключ,
      сгенерированный `ssh-keygen` на лету в тесте (`Process` есть на Linux и macOS; на iOS тест
      не выполняется) либо фикстура в `Tests/Fixtures/ed25519_test` (без passphrase, сгенерирован
      для тестов, в коммите). `TOFUTests`: валидатор с `expected == nil` → `firstSeen`,
      совпадение → ok, другой ключ → `hostKeyChanged` с обоими отпечатками.
- [ ] `TransportIntegrationTests` (стенд): `connectAndEcho` (`exec("echo ok")` → `ok\n`, код 0);
      `exitCodeAndStderr` (`exec("echo err >&2; exit 3")` → код 3, stderr `err\n`, stdout пуст);
      `stdinWithEOF` (`exec("cat", stdin: 100 КБ)` возвращает те же байты — без EOF `cat` не
      завершился бы); `ptyExec` (`openPTY(command: "tty; stty size; sleep 0.2", cols: 100, rows:
      30)` → вывод содержит `/dev/pts/` и `30 100`, `exitCode == 0`); `ptyResize` (команда
      `trap 'stty size' WINCH; sleep 5` в PTY 80×24, `resize(cols: 120, rows: 40)` → в выводе
      `40 120`); `envRequestLang` (`exec` с env `LANG=en_US.UTF-8` → `echo $LANG` печатает его —
      стенд принимает `LANG` по `AcceptEnv`); `tofuFirstThenMismatch` (первый `connect` →
      `firstSeen == true`, отпечаток в стора; второй с подменённым отпечатком в
      `InMemoryHostKeyStore` → `SSHError.hostKeyChanged`); `wrongKeyFails` (свежий ключ →
      `.authFailed`); `maxSessions` (10 PTY `sleep 30` открываются, 11-й → `.channelRefused` за
      < 5 с; закрыть все); `disconnectIsObserved` (`exec("kill -9 $PPID")` → `onDisconnect`
      срабатывает ≤ 5 с, `isConnected == false`).
- [ ] shellcheck на `bench.sh` и `test.sh`; `swift test --skip IntegrationTests` зелёный;
      `TmuxPadCore/scripts/test.sh` зелёный; коммит.

### Task 3: `HostAPI` и `HostBootstrap` на настоящем скрипте

**Файлы:** `TmuxPadCore/Sources/TmuxPadCore/Host/HostAPI.swift` (create),
`.../Host/HostBootstrap.swift` (create), `.../Host/HostScript.swift` (create),
`TmuxPadCore/Tests/TmuxPadCoreTests/{HostScriptResourceTests,HostAPITests,HostAPIIntegrationTests,HostBootstrapIntegrationTests}.swift`
(create), `Tests/Support/FakeTransport.swift` (create).

- [ ] `Host/HostScript.swift`: `enum HostScript` — `data` из `Bundle.module.url(forResource:
      "tmuxpad-host", withExtension: "sh")`, `version: Int` парсингом строки `^VERSION=(\d+)$`
      (отсутствие → `fatalError` на старте тестов недопустимо: `throws`).
- [ ] `Host/HostAPI.swift`: протокол `ExecRunner: Sendable` (`exec(_ command: String, stdin: Data?,
      timeout: Duration) async throws -> ExecResult`) — ему соответствуют `SSHConnection` (Task 2) и
      `ServerConnection` (Task 4, через очередь на 2 слота); `public struct HostAPI: Sendable` поверх
      `any ExecRunner` +
      `HostEnvironment` + `DiagnosticsLog`; метод `run(_ command: HostCommand, stdin: Data? = nil)
      async throws -> ExecResult`: рендер, `exec` с таймаутом 20 с, при ненулевом коде —
      `HostError.from(...)` (stderr как UTF-8, обрезан до 500 символов), событие в журнал
      (команда без значений переменных окружения, код, длительность). Публичные методы:
      `version() -> Int` (парсинг `tmuxpad-host N`, иначе `badOutput`), `list() ->
      ServerSnapshot`, `new(session:project:)`, `kill(session:)`, `copyCancel(session:)`,
      `setup() -> DoctorReport` (ненулевой код `setup`/`doctor` с разобранным отчётом — не
      ошибка, а `DoctorReport` с `ok == false`; ошибка только если вывод не парсится),
      `doctor() -> DoctorReport`, `auth(token: String)` (валидация `^[A-Za-z0-9_-]+$` локально,
      stdin `token\n`), `attachCommand(session:) -> String` и `takeCommand(session:)` — готовые
      exec-строки для PTY-канала (их выполняет `TerminalSession`).
- [ ] `Host/HostBootstrap.swift`: `public struct HostBootstrap` — `status(api:) async ->
      BootstrapStatus` (`.missing`, `.outdated(installed:bundled:)`, `.ready(version:)`,
      `.unreachable(String)`): `version()` → `scriptMissing` → `.missing`, число < `HostScript.
      version` → `.outdated`; `install(connection:) async throws` — `exec(HostCommand.install.
      render…, stdin: HostScript.data)` и проверка `version()` после; `prepare(api:) async
      throws -> DoctorReport` — `install` при `.missing`/`.outdated`, затем `setup()`.
- [ ] `Tests/Support/FakeTransport.swift`: `FakeConnection: SSHConnection` с очередью ответов
      `exec` (`[(matches: (String) -> Bool, result: Result<ExecResult, Error>)]`), журналом
      вызванных команд и stdin, управлением `onDisconnect`; PTY-часть — в Task 5 (здесь `openPTY`
      кидает `unimplemented`). `HostAPITests` (юнит, на фейке): `list` рендерит точную
      exec-строку и парсит ответ; код 3 у `new` → `.sessionExists`; 127 → `.scriptMissing`;
      `auth` отвергает токен с пробелом до обращения к сети и шлёт `token\n` в stdin; `setup`
      с кодом 1 и валидным отчётом → `DoctorReport.ok == false` без ошибки.
- [ ] `HostScriptResourceTests`: ресурс побайтно равен `host/tmuxpad-host.sh` (корень репозитория
      — три уровня вверх от `#filePath`), `HostScript.version == 1`.
- [ ] `HostBootstrapIntegrationTests` (стенд, чистый контейнер без скрипта — `rm -f
      ~/.local/bin/tmuxpad-host.sh` в сбросе): `status` → `.missing`; `install` → файл есть,
      исполняемый, `status` → `.ready(1)`; подмена версии (`sed -i 's/^VERSION=1/VERSION=0/'
      ~/.local/bin/tmuxpad-host.sh`) → `.outdated(installed: 0, bundled: 1)`; `prepare` →
      переустановил, `DoctorReport` с `tmux` ok, `projects` ok, `script` ok и `ok == true`;
      `~/.tmux.conf` содержит `# tmuxpad: begin`.
- [ ] `HostAPIIntegrationTests` (стенд, скрипт установлен через `HostBootstrap` в начале suite):
      `listEmpty` (три проекта, ноль сессий); `newListKill` (`new("api","api")` → `list`
      содержит сессию `api` с `project == "api"`, `otherClients == 0`, `lastActivity` в пределах
      минуты от сейчас; `kill` → пусто; `TMUXPAD_CMD` для стенда — `sleep 1000`, чтобы заглушка
      claude не мешала); `newConflict` (второй `new` → `.sessionExists`); `badNames` (`new("a b",
      …)` → `.badRequest`; на стенде достаточно `#expect(throws:)`, а то, что ошибка не доходит до
      сервера, проверяет юнит-тест на фейке); `othersCountsForeignClient`
      (фоновый `ssh -tt -n … tmux attach -t =api` через `Process` с ключом стенда → `list` даёт
      `otherClients == 1`; завершить процесс); `projectsRootMissing` (окружение с
      `projectsRoot: "nope"` → `.projectsRootMissing`); `copyCancelIdempotent` (0 и вне режима);
      `authStoresToken` (`auth("tok_1")` → `cat ~/.tmuxpad/env` содержит `tok_1`, права 600).
- [ ] `swift test --skip IntegrationTests` и `scripts/test.sh` зелёные, сборка без
      предупреждений; коммит.

### Task 4: `ConnectionPool` — состояния, очередь exec, keepalive, реконнект

**Файлы:** `TmuxPadCore/Sources/TmuxPadCore/Pool/{PoolSettings,ConnectionState,AsyncSemaphore,ServerConnection,ConnectionPool}.swift`
(create), `TmuxPadCore/Tests/TmuxPadCoreTests/{AsyncSemaphoreTests,ServerConnectionTests,PoolIntegrationTests}.swift`
(create), `Tests/Support/FakeTransport.swift`.

- [ ] `Pool/PoolSettings.swift`: `keepalive: Duration` (из `ServerConfig.keepaliveSeconds`),
      `pingTimeout = .seconds(5)`, `backoff: [Duration] = [1, 2, 5, 10] с`, `connectTimeout =
      .seconds(15)`, `execSlots = 2`, `ptySlots = 8`, `execTimeout = .seconds(20)`.
      `Pool/ConnectionState.swift` — enum решения 7, `Equatable`, `Sendable`.
      `Pool/AsyncSemaphore.swift` — actor с `acquire()`/`release()` и `withSlot(_:)`, FIFO,
      поддержка отмены (`withTaskCancellationHandler`, снятие из очереди).
- [ ] `Pool/ServerConnection.swift`: `public actor ServerConnection` (`config: ServerConfig`,
      `deviceID: UUID`, `transport`, `auth: SSHAuth`, `hostKeys`, `settings`, `log`):
      `connect()` (`.connecting` → `.connected`; ошибка → `.failed(описание)`, `hostKeyChanged`
      не ретраится никогда), `disconnect()` (явно, без реконнекта), `reconnectNow()` (сброс
      счётчика бэкоффа и немедленная попытка — для `scenePhase`/сети/кнопки «Повторить»),
      `exec(_ command: String, stdin: Data?) async throws -> ExecResult` через семафор на 2 слота
      с отметкой `lastExecAt`, `openPTY(...)` с учётом `ptySlots` (превышение →
      `SSHError.channelRefused` локально; закрытие канала освобождает слот), `api: HostAPI`
      (готовый `HostAPI` на `self` как `ExecRunner`, с `HostEnvironment` из конфига и `deviceID`),
      `states: AsyncStream<ConnectionState>`,
      `state`. Keepalive-задача при `.connected`: каждый `keepalive` — если `lastExecAt` старше
      интервала, `exec("true")` с `pingTimeout`; неответ → `missedPings += 1`; второй подряд →
      `markDead("ping timeout x2")`; успешный пинг обнуляет счётчик. Подписка на
      `onDisconnect` → `markDead("transport disconnected")`. `markDead` → закрыть соединение →
      цикл реконнекта по `backoff`: `.reconnecting(attempt: n)`, ожидание `backoff[n-1]`,
      попытка; успех → `.connected`, провал после последней ступени → `.failed(причина)` и стоп
      до `reconnectNow()`. Все переходы — в `DiagnosticsLog` с причиной. Открытые PTY-каналы
      при смерти соединения закрываются транспортом сами; их переоткрытие — дело
      `TerminalSession` (Task 5), пул лишь публикует состояние.
- [ ] `Pool/ConnectionPool.swift`: `public actor ConnectionPool` — `connection(for config:
      ServerConfig, auth: SSHAuth) -> ServerConnection` (создаёт один раз по `config.id`, при
      изменившемся `host`/`port`/`user`/`keyID` пересоздаёт), `remove(id:)` с `disconnect`,
      `disconnectAll()` (уход в фон, §6), `reconnectAll()` (возврат из фона, смена сети),
      общий `DiagnosticsLog`.
- [ ] `FakeTransport`: `connect` считает попытки, по сценарию падает N раз подряд
      (`failNextConnects`), выдаёт `FakeConnection`, у которого `exec` можно задержать
      (`execDelay`) или зависнуть (`hangExec = true`), `dropConnection()` стреляет в
      `onDisconnect`, `openPTY` ведёт счёт открытых каналов и даёт `FakePTY` с ручным `emit(
      Data)` и `close(exitCode:)`.
- [ ] `AsyncSemaphoreTests`: при 2 слотах и 5 задачах одновременно внутри не больше 2 (счётчик
      с `Atomic`/actor), FIFO порядок выдачи, отменённая ждущая задача не получает слот.
      `ServerConnectionTests` (фейк, интервалы 20–50 мс): `connectPublishesStates`
      (`.connecting` → `.connected`); `execUsesTwoSlots` (3 параллельных `exec` с задержкой →
      максимум 2 одновременно); `ptyLimit` (8 открытий ок, 9-е → `channelRefused`, после `close`
      одного — снова ок); `pingSkippedAfterRecentExec` (после `exec` в журнале фейка нет `true`
      до истечения интервала); `twoMissedPingsReconnect` (`hangExec` → через ~2 интервала
      `.reconnecting(attempt: 1)`, затем `.connected`, в логе причина `ping timeout x2`);
      `disconnectEventReconnects` (`dropConnection()` → `.reconnecting` → `.connected`);
      `backoffThenFailed` (`failNextConnects = 10` → четыре попытки с ожиданиями из `backoff`,
      затем `.failed`, попыток ровно 5 = 1 начальная + 4; `reconnectNow()` → снова попытка);
      `explicitDisconnectDoesNotReconnect`; `hostKeyChangedIsFatal` (не ретраится).
- [ ] `PoolIntegrationTests` (стенд): `connectExecPing` (реальный `connect`, `exec("true")`,
      state `.connected`); `killSessionReconnects` (`exec("kill -9 $PPID")` → `.reconnecting` →
      `.connected` ≤ 10 с, затем `api.version()` работает); `disconnectAllAndReconnectAll`.
- [ ] `swift test --skip IntegrationTests` и `scripts/test.sh` зелёные, без предупреждений;
      коммит.

### Task 5: `TerminalSurface` и `TerminalSession`

**Файлы:** `TmuxPadCore/Sources/TmuxPadCore/Terminal/{TerminalSurface,TerminalState,TerminalSession}.swift`
(create), `TmuxPadCore/Tests/TmuxPadCoreTests/{TerminalSessionTests,TerminalIntegrationTests}.swift`
(create), `Tests/Support/{FakeTransport,RecordingSurface}.swift`.

- [ ] `Terminal/TerminalSurface.swift`: `public protocol TerminalSurface: AnyObject, Sendable` —
      `func feed(_ bytes: Data)`, `var size: (cols: Int, rows: Int) { get }`, `func stateChanged(
      _ state: TerminalState)`; вызовы приходят с произвольного исполнителя, прыжок на main —
      дело реализации (SwiftTerm в плане 3). `Terminal/TerminalState.swift` — enum решения 8.
- [ ] `Terminal/TerminalSession.swift`: `public actor TerminalSession` (`server:
      ServerConnection`, `name: String`, `surface`, `log`, `kickWindow = .seconds(60)`):
      `start()` — `.connecting`, `openPTY(command: api.attachCommand(session:), term:
      "xterm-256color", cols/rows из `surface.size`, env `LANG=en_US.UTF-8`)` → `.live`, задача
      чтения `output` → `surface.feed`; `send(_ data: Data)` — если `needsCopyCancel`, сначала
      `await api.copyCancel(session:)` (ошибки игнорируются, в журнал), сброс флага, затем
      `pty.send`; `noteScrolledUp()` ставит флаг (вызывает UI при wheel-up); `resize(cols:rows:)`;
      `detach()` — флаг `userDetached`, `pty.close()`, `.ended`; `take()` — закрыть PTY, открыть
      с `takeCommand`; `reconnect()` — для возврата из фона: закрыть старый канал, если жив,
      `.reconnecting` → `attach` → `.live`. Конец `output` без `userDetached`: код 0 → `list`
      (через `server.api`): сессии нет → `.ended`; есть → `lastKick` моложе `kickWindow` →
      `.disconnectedByOther`, иначе `lastKick = now`, `.reconnecting`, `attach` снова; код 4
      → `.ended`; транспорт мёртв (`SSHError.disconnected` или состояние сервера не `.connected`)
      → `.offline(причина)` и ожидание `states` сервера: при `.connected` — `reconnect()`.
      Все переходы — в `surface.stateChanged` и в журнал.
- [ ] `RecordingSurface` (тест): копит байты и состояния, `size` настраиваемый. `FakePTY`
      умеет `emit`, `close(exitCode:)`, фиксирует `sent` и `resizes`.
- [ ] `TerminalSessionTests` (фейк): `startFeedsOutput` (байты из `emit` доходят до `feed`,
      состояние `.connecting` → `.live`, команда PTY — exec-строка `attach api`); `copyCancelBeforeInput`
      (`noteScrolledUp`, `send("x")` → в журнале фейка exec `copy-cancel api` до того, как PTY
      получил `x`; второй `send` без `copy-cancel`); `resizeForwards`; `detachEnds` (`.ended`,
      `list` не вызывался); `endedWhenSessionGone` (PTY закрыт с 0, `list` без сессии →
      `.ended`); `kickedOnceReconnectsSilently` (PTY закрыт с 0, `list` с сессией → новый
      `openPTY`, `.reconnecting` → `.live`, `.disconnectedByOther` не было); `kickedTwiceWithinMinute`
      (повтор при `kickWindow` 500 мс → `.disconnectedByOther`); `takeUsesTakeCommand`;
      `offlineThenReconnect` (сервер `.reconnecting` → `.offline`, после `.connected` → новый
      PTY, `.live`).
- [ ] `TerminalIntegrationTests` (стенд, скрипт установлен, сессия `new("api","api")` с
      `startCommand: "bash"`, чтобы в pane был интерактивный шелл): `attachShowsTmux` (после
      `start` в `feed` за 5 с приходят байты, `tmux list-clients -t =api` даёт одного клиента,
      файл в `~/.tmuxpad/clients/` содержит `deviceID`); `typingReachesPane` (`send("echo
      hello-from-pty\n")` → `tmux capture-pane -p -t =api:` содержит `hello-from-pty` ≤ 5 с);
      `resizeChangesWindow` (`resize(cols: 132, rows: 43)` → `tmux display -p -t =api
      '#{client_width}x#{client_height}'` даёт `132x43`); `copyCancelLeavesCopyMode` (`tmux
      copy-mode -t =api:` → `pane_in_mode` 1; `noteScrolledUp()`, `send("echo after\n")` →
      `pane_in_mode` 0 и `after` в capture-pane); `takeKicksOther` (вторая `ServerConnection`
      с другим `deviceID` и своя `TerminalSession` на той же сессии → у первой `take()` → у
      второй состояние `.reconnecting` затем `.live` (один раз молча), повторный `take()` в
      пределах минуты → `.disconnectedByOther`); `detachLeavesSessionAlive` (`detach()` →
      клиентов 0, сессия в `list` есть).
- [ ] `swift test --skip IntegrationTests` и `scripts/test.sh` зелёные, без предупреждений;
      коммит.

### Task 6: документация, полный прогон и завершение

**Файлы:** `TmuxPadCore/README.md` (create), `CLAUDE.md`, `docs/tmuxpad-spec.md` (только если
контракт в коде разошёлся со спекой), `docs/plans/20261020-tmuxpad-core.md` (move).

- [ ] `TmuxPadCore/README.md` (коротко, по-русски): назначение пакета и граница §5.2, карта
      модулей (`Models`, `Host`, `SSH`, `Pool`, `Terminal`, `Diagnostics`), что приложение должно
      реализовать (`KeyStore`, `HostKeyStore`, `TerminalSurface`, завернуть Secure Enclave в
      `NIOSSHPrivateKey`), как обновлять скрипт-ресурс (скопировать `host/tmuxpad-host.sh`,
      тест синхронности), команды сборки и тестов, стенд `bench.sh`, типичное время первой сборки.
- [ ] `CLAUDE.md`: раздел «Состояние репозитория» — появился `TmuxPadCore`: команды из Validation
      Commands (сборка, юнит-тесты без Docker, `scripts/test.sh`, один suite через `--filter`,
      shellcheck на `bench.sh`/`test.sh`), раскладка `TmuxPadCore/`, правило «скрипт-ресурс —
      копия `host/tmuxpad-host.sh`, равенство проверяет тест»; убрать фразу «Swift-кода ещё
      нет». В «Инварианты» добавить: «Каналы SSH ядро открывает через NIOSSH напрямую
      (`SessionChannel`), не через `executeCommand`/`withPTY` Citadel» и «`SSHTransport` —
      единственная точка контакта с сетью; пул и терминал тестируются на фейке». Расхождения
      кода со спекой (если были уточнены интервалы, состояния, ошибки) — внести в спеку одной
      правкой со ссылкой на этот план.
- [ ] Полный прогон: `swift build --build-tests` без предупреждений, `swift test --skip
      IntegrationTests`, `TmuxPadCore/scripts/test.sh`, shellcheck, `host/tests/run.sh` (стенд
      скрипта не пострадал от `bench.sh`/`.gitignore`); в progress-лог — время прогона и число
      тестов по видам.
- [ ] Move this plan to `docs/plans/completed/`; коммит.

## Как проверить после выкатки

- Этот хост как настоящий сервер: небольшой исполняемый таргет не входит в план, но в
  `swift test` можно указать стенд вручную — `TMUXPAD_BENCH_PORT=22 TMUXPAD_BENCH_KEY=~/.ssh/<ключ>
  TMUXPAD_BENCH_USER=ubuntu swift test --package-path TmuxPadCore --filter
  TransportIntegrationTests` — чтобы убедиться, что транспорт работает против настоящего sshd и
  tmux 3.4 с настоящим Claude Code (сброс состояния в тестах удаляет `~/.tmuxpad` и
  `~/.claude`, поэтому только `Transport*`, не `HostAPI*`).
- Когда появится план 3: приложение подключает `TmuxPadCore` по локальному пути в `project.yml`,
  реализует `TerminalSurface` на SwiftTerm и `KeyStore`/`HostKeyStore` на Keychain, передаёт
  `deviceID` из Keychain и `ServerConfig` из SwiftData; всё остальное — вызовы `ConnectionPool`
  и `TerminalSession`.
