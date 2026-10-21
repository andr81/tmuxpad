# Приложение, фундамент: Xcode-проект, Keychain и Secure Enclave, ключи, серверы, проверка и подготовка сервера, диагностика

## Overview

Четвёртый план по спеке `docs/tmuxpad-spec.md` и первый, который исполняется **только на Mac**
(Xcode 26, симулятор iPad, Docker Desktop или OrbStack для стенда). Он создаёт приложение
`TmuxPad` поверх пакета `TmuxPadCore` и доводит его до цели фазы 1: «можно завести 2+ сервера и
проверить подключение к каждому», плюс части фаз 0 и 2, которые требуют приложения: ключи
Secure Enclave и Ed25519 в Keychain, UUID устройства, TOFU с алертами, «Подготовить сервер» с
отчётом `doctor`, «Передать токен Claude», экран журнала диагностики.

После этого плана у приложения есть настройки и всё, что нужно сайдбару (план 5) и терминалу
(план 6): `AppEnvironment` с пулом, хранилищами и журналом. Сайдбар в этом плане — заглушка со
списком серверов и кнопкой настроек.

Порядок исполнения: план 3 (`20261020-core-ui-support.md`) должен быть выполнен раньше: этот
план использует `Validation`, `TreeRefresher` ему не нужен, но планы 5–6 строятся поверх обоих.

### Решения, принятые в спеке (не переоткрывать)

- iPadOS 17+, Swift 6, SwiftUI, UIKit где нужно; XcodeGen (`project.yml`), как в agterm (§4).
- Ядро — пакет `TmuxPadCore` по локальному пути; всё платформенное — в приложении за
  протоколами ядра `KeyStore`, `HostKeyStore`, `TerminalSurface` (§5.2).
- Ключи: Secure Enclave P-256 (`ecdsa-sha2-nistp256`) и Ed25519 в Keychain; импорт OpenSSH
  Ed25519; публичный ключ — копировать, поделиться, QR (§3.6, §4). Keychain —
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; приватный ключ не логируется и не
  попадает в бэкапы (§8).
- Серверы и метаданные ключей — Codable JSON (`servers.json`, `keys.json` в Application
  Support), не SwiftData (§4, решение 2026-10-20).
- UUID устройства создаётся при первом запуске и хранится в Keychain (§5).
- TOFU: ядро само сохраняет новый отпечаток и подключается; UI при
  `ServerConnection.hostKeyFirstSeen == true` показывает «Доверять», отказ → `disconnect()` +
  `HostKeyStore.reset(host:port:)`; `SSHError.hostKeyChanged` — блокирующий алерт с обоими
  отпечатками, подключение только после «Сбросить» (§8, §9).
- Ключ не принят → «Сервер не принял ключ» + «Показать публичный ключ», без автоповторов (§9).
- Поля сервера и значения по умолчанию — таблица §3.6; валидация — `ServerConfig.
  validationIssues()` ядра.
- Кнопки сервера: «Проверить подключение», «Подготовить сервер» (установить скрипт + `setup`),
  «Передать токен Claude» (§3.6). Токен — только через stdin (`HostAPI.auth`), не логируется (§8).
- Журнал диагностики с «Поделиться», без секретов и содержимого терминала (§3.6).
- Одно окно: `UIApplicationSupportsMultipleScenes = false` (§5).

### Решения исполнителя плана

1. **Раскладка репозитория.**
   ```
   project.yml                      XcodeGen; TmuxPad.xcodeproj не коммитится
   App/
     TmuxPadApp.swift               @main, WindowGroup, AppEnvironment в environment
     AppEnvironment.swift           composition root
     Platform/                      Keychain, Secure Enclave, JSON-файлы, UUID устройства
     State/                         @MainActor @Observable модели
     UI/                            SwiftUI; UI/Settings/, UI/Root/
     Resources/Assets.xcassets
   AppTests/                        unit-тесты, хост — приложение (Keychain в симуляторе)
   scripts/ios-test.sh              xcodegen + стенд + xcodebuild test
   ```
   `TmuxPad.xcodeproj` в `.gitignore`: его генерирует `xcodegen generate`, а сгенерированный
   проект в гите — источник конфликтов. Все команды сборки начинаются с `xcodegen generate`.
2. **`project.yml`**: `name: TmuxPad`; `options.deploymentTarget.iOS: "17.0"`,
   `options.developmentLanguage: ru`; `settings.base`: `SWIFT_VERSION: "6.0"`,
   `TARGETED_DEVICE_FAMILY: "2"` (только iPad, §2 не-цели), `ENABLE_USER_SCRIPT_SANDBOXING:
   YES`, `CODE_SIGN_STYLE: Automatic`. Команда разработчика в `project.yml` не пишется: для
   симулятора подпись не нужна, а для устройства её передают снаружи —
   `xcodebuild … DEVELOPMENT_TEAM=XXXXXXXXXX` или выбором команды в Xcode после
   `xcodegen generate` (инструкция — README в плане 7). `packages`: `TmuxPadCore: { path: TmuxPadCore }`,
   `swift-nio-ssh: { url: https://github.com/Wellz26/swift-nio-ssh.git, from: 0.3.4 }` —
   приложению нужен `NIOSSH` напрямую для `NIOSSHPrivateKey(secureEnclaveP256Key:)`, и URL
   совпадает с тем, что тянет Citadel в ядре, поэтому SwiftPM разрешит его в одну копию.
   Таргет `TmuxPad` (`type: application`, `platform: iOS`, `sources: [App]`), `info:` с
   `path: App/Info.plist` (XcodeGen генерирует файл, он в `.gitignore`) и `properties:`
   `CFBundleDisplayName: TmuxPad`, `UIApplicationSceneManifest.
   UIApplicationSupportsMultipleScenes: false`, `UILaunchScreen: {}`,
   `UISupportedInterfaceOrientations~ipad` — все четыре, `UIRequiresFullScreen: false`
   (Split View и Stage Manager, §3.5). `PRODUCT_BUNDLE_IDENTIFIER: dev.tmuxpad.app` (поменять
   на свой — Post-Completion). Таргет `AppTests` (`type: bundle.unit-test`, `sources:
   [AppTests]`, зависимость и host — `TmuxPad`). Схема `TmuxPad` с `testTargets: [AppTests]`
   (план 7 добавит туда `AppUITests`, иначе `-only-testing:AppUITests` ничего не запустит).
3. **Язык интерфейса — русский строками в коде.** Строки SwiftUI пишутся по-русски прямо в
   `Text("…")`; String Catalog не заводится: локализация не цель v1, а каталог из одного языка —
   лишний файл. Тексты ошибок ядра (английские `description`) UI переводит в одном месте —
   `UI/ErrorText.swift`, функция `userText(_ error: Error) -> String` со `switch` по
   `SSHError`, `HostError`, `KeyError`, прочее — `String(describing:)`.
4. **Keychain — один тонкий слой.** `Platform/Keychain.swift`: `struct Keychain { let service:
   String }` с `read(account:) throws -> Data?`, `write(_:account:) throws` (add или update),
   `delete(account:) throws`, `accounts() throws -> [String]`; класс `kSecClassGenericPassword`,
   `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
   `kSecAttrSynchronizable = false`. Ошибки `OSStatus` → `KeychainError.status(OSStatus)`.
   Сервисы: `dev.tmuxpad.key` (приватные ключи, account — `UUID` ключа),
   `dev.tmuxpad.hostkey` (отпечатки, account — `host:port`), `dev.tmuxpad.device`
   (account `device-id`). Сервис — параметр, чтобы тесты работали в своём `dev.tmuxpad.test.*`
   и чистили его.
5. **`KeychainKeyStore: KeyStore`** (актор). Метаданные (`[SSHKeyInfo]`) — в `keys.json`
   через `JSONFileStore`, приватная часть — в Keychain:
   - Ed25519: account = `id`, данные = OpenSSH-текст (`openssh-key-v1` без шифра, как его
     отдаёт `SSHKeys.generateEd25519` и как его ждёт `InMemoryKeyStore`); `privateKey(for:)`
     → `SSHKeys.importOpenSSHEd25519`.
   - Secure Enclave: account = `id`, данные = `SecureEnclave.P256.Signing.PrivateKey.
     dataRepresentation` (зашифрованный блоб, годный только на этом устройстве);
     `privateKey(for:)` → `SSHPrivateKey(NIOSSHPrivateKey(secureEnclaveP256Key: try
     SecureEnclave.P256.Signing.PrivateKey(dataRepresentation:)))`.
   - Протокольный `save(_ info:, privateKeyOpenSSH:)` принимает только `.ed25519`; для SE —
     отдельные методы: `createEd25519(name:) -> SSHKeyInfo`, `createSecureEnclave(name:) throws
     -> SSHKeyInfo` (`SecureEnclave.isAvailable`, иначе `KeyStoreError.secureEnclaveUnavailable`;
     access control `[.privateKeyUsage]`, Face ID — план 7), `importEd25519(name:text:
     passphrase:) throws -> SSHKeyInfo` (импорт с паролем, сохраняется без шифра: Keychain уже
     защищает). Публичный ключ — `SSHKeys.publicKeyOpenSSH(_:comment:)`, комментарий — имя
     ключа без пробелов (`tmuxpad-<name>`).
   - `delete` удаляет Keychain-запись и метаданные.
6. **`KeychainHostKeyStore: HostKeyStore`** (актор) — account `host:port` (ключ
   `InMemoryHostKeyStore.key(host:port:)`), данные — UTF-8 отпечатка.
7. **`DeviceIdentity.load(keychain:) throws -> UUID`** — читает или создаёт и пишет UUID.
   Ошибка Keychain при первом запуске — фатальная для приложения (без UUID нельзя отличить
   своих клиентов, §6.1): `AppEnvironment` показывает экран ошибки, а не падает.
8. **`JSONFileStore<Value: Codable>`** — `load() throws -> Value?` и атомарная запись
   (`Data.write(options: .atomic)`), файл в `FileManager.default.urls(for:
   .applicationSupportDirectory)` + `TmuxPad/`, каталог создаётся; `FileProtectionType.
   completeUntilFirstUserAuthentication`; `isExcludedFromBackup` не ставится: конфиги серверов
   без секретов, их потеря при переносе на новый iPad хуже. Кодировщик с `.sortedKeys`,
   `.prettyPrinted` — файлы читаемы при диагностике.
9. **`AppEnvironment`** (`@MainActor final class`, не `@Observable` — неизменяемые
   зависимости): `deviceID`, `keyStore: KeychainKeyStore`, `hostKeys: KeychainHostKeyStore`,
   `defaults: UserDefaults` (все настройки приложения читаются только отсюда: `live()` —
   `.standard`, `inMemory()` — свежий `UserDefaults(suiteName: "dev.tmuxpad.test.<UUID>")`,
   иначе флаги вроде `onboarding.done` переживали бы прогоны тестов), `log: DiagnosticsLog`, `pool: ConnectionPool` (`CitadelTransport()`), `bootstrap:
   HostBootstrap`, модели `servers: ServerStore`, `keys: KeyLibrary`. Функция `auth(for config:
   ServerConfig) async throws -> SSHAuth` достаёт ключ из `keyStore` (нет ключа →
   `AppError.keyMissing`). Режим тестов: `AppEnvironment.inMemory()` — `InMemoryKeyStore`,
   `InMemoryHostKeyStore`, временный каталог для JSON; выбирается аргументом запуска
   `-uitest-inmemory` (UI-смоук в плане 7) и в `AppTests`. Под XCTest (в окружении есть
   `XCTestConfigurationFilePath`) приложение-хост `AppTests` поднимает пустой корень без
   окружения: иначе при каждом прогоне юнит-тестов в симуляторе запускалось бы живое
   приложение с Keychain, а позже опросом дерева и онбордингом. Тесты строят свои окружения
   через `inMemory()`.
10. **Модели State** — `@MainActor @Observable final class`:
    - `ServerStore`: `servers: [ServerConfig]` по `sortIndex`; `add`, `update`, `duplicate`
      (метка «<метка> копия», новый `id`, отпечаток не копируется), `delete` (плюс
      `pool.remove(id:)` и `hostKeys.reset`), `move(fromOffsets:toOffset:)`; сохранение в
      `servers.json` после каждой правки; `issues(for:) -> [String]` = `validationIssues()` +
      пустая метка + неизвестный `keyID`.
    - `KeyLibrary`: `keys: [SSHKeyInfo]`, `secureEnclaveAvailable: Bool`, `create(kind:name:)`,
      `importKey(name:text:passphrase:)`, `delete(_:)` — отказ, если ключ используется
      сервером (`KeyLibraryError.inUse([метки серверов])`).
    - `ServerCheckModel` (по экземпляру на открытый экран сервера): состояние `idle | running(
      шаг) | trustPrompt(fingerprint) | hostKeyChanged(expected, actual) | authFailed |
      done(BootstrapStatus, DoctorReport?) | failed(String)`; действия `check()`, `trust()`,
      `reject()`, `resetHostKey()`, `prepare()`, `sendToken(_:)`. Вопрос «Доверять»
      задаётся, когда `connection.hostKeyFirstSeen && config.hostKeyFingerprint !=
      connection.hostKeyFingerprint`: соединение остаётся в пуле подключённым, `connect()`
      возвращается сразу, и `hostKeyFirstSeen` того же `ServerConnection` остаётся `true` —
      без второго условия вопрос повторялся бы. `trust()` пишет отпечаток в `ServerConfig.
      hostKeyFingerprint` через `ServerStore`; это не только отображение: `TreeRefresher`
      (план 3) не опрашивает сервер, пока поле пустое. Источник правды для проверки ключа —
      по-прежнему `HostKeyStore`.
    - `DiagnosticsModel`: живёт в `AppEnvironment` всё время работы приложения; при создании
      берёт снимок `log.events()` и один раз подписывается на `log.updates`. У этого
      `AsyncStream` один потребитель: подписка на экран, отменяемая при уходе, завершила бы
      поток навсегда, и при повторном открытии живых событий не было бы. `exportText()`.
11. **UI этого плана.** `RootView`: `NavigationSplitView`; в сайдбаре — пока список серверов
    (метка и адрес) и кнопка «⚙ Настройки» внизу; деталь — «Выберите сессию». План 5 заменит
    сайдбар деревом. `SettingsView` — sheet с `NavigationStack`: разделы «Серверы», «Ключи»,
    «Диагностика» (раздел «Терминал» — план 7). Экраны: `KeysView` (список, «Создать» с
    выбором SE/Ed25519 — SE скрыт, если недоступен, «Импортировать» — `.fileImporter` для
    текстового файла и вставка текста, поле пароля), `KeyDetailView` (публичный ключ моноширинно
    с выделением, «Скопировать», `ShareLink`, QR из `CIFilter.qrCodeGenerator()`, готовая
    команда `SSHKeys.authorizedKeysCommand` с копированием, «Удалить» с подтверждением);
    `ServersView` (список с перестановкой, свайп «Удалить» с подтверждением, «Дублировать» в
    контекст-меню), `ServerEditView` (`Form` по таблице §3.6, порт и keepalive — числовые поля,
    ключ — `Picker`, отпечаток только для чтения с «Сбросить», ошибки валидации под полями,
    «Сохранить» недоступна при ошибках; внизу секция с тремя кнопками сервера);
    `ServerCheckView` (ход проверки, алерты TOFU, смены ключа и «Сервер не принял ключ» с
    «Показать публичный ключ» → `KeyDetailView`, итог: статус скрипта и чеклист `doctor`);
    `TokenView` (`SecureField`, «Передать», поле очищается после успеха и при уходе с экрана);
    `DiagnosticsView` (список событий: время, сервер, вид, текст; `ShareLink` с текстом
    `export()`; фильтр по серверу).
12. **Чеклист `doctor` по-русски.** `UI/DoctorText.swift`: заголовки по ключам `tmux` →
    «tmux ≥ 3.1», `claude` → «claude в login PATH», `claude_name` → «claude поддерживает
    --name», `projects` → «Корень проектов», `script` → «host-скрипт»; значок по уровню (✓ / ⚠
    / ✗), под ним сообщение сервера как есть. Неизвестный ключ показывается своим именем.
13. **Тесты приложения.** Swift Testing в `AppTests` (Xcode 26 его поддерживает). Юнит:
    `Keychain` и `KeychainKeyStore` (Ed25519 — полный цикл; SE — `.enabled(if:
    SecureEnclave.isAvailable)`, в симуляторе пропуск), `KeychainHostKeyStore`,
    `DeviceIdentity` (стабильность между вызовами), `JSONFileStore`, `ServerStore` и
    `KeyLibrary` (на `AppEnvironment.inMemory()`). Интеграционные — `*BenchTests`, против
    стенда из плана 1 (`host/tests/bench.sh`): `ServerCheckModel` проходит TOFU, ставит
    скрипт, получает `doctor` с `ok`, передаёт токен; второй `check()` не спрашивает
    доверие. Стенд в тест попадает так: `ios-test.sh` экспортирует
    `TEST_RUNNER_TMUXPAD_BENCH_PORT`, `TEST_RUNNER_TMUXPAD_BENCH_USER` и
    `TEST_RUNNER_TMUXPAD_BENCH_KEY_B64` (ключ base64-строкой: тест не зависит от того, видит ли
    процесс симулятора файлы хоста), `xcodebuild` срезает префикс `TEST_RUNNER_`, и тест читает
    `TMUXPAD_BENCH_PORT`, `TMUXPAD_BENCH_USER`, `TMUXPAD_BENCH_KEY_B64`; без них тесты
    пропускаются.
14. **`scripts/ios-test.sh`** (bash 3.2-совместимый, shellcheck): `xcodegen generate`;
    симулятор — `TMUXPAD_SIM` (UDID или имя) или первый доступный iPad из `xcrun simctl list
    devices available` (разбор текста `grep -E '^[[:space:]]+iPad'` и UDID в скобках); `--no-bench`
    пропускает стенд, и прогон, где все `-only-testing:` указывают на `AppUITests`, тоже
    стенд не поднимает; иначе `host/tests/bench.sh up`, `eval` его `export`-строк, экспорт
    `TEST_RUNNER_*`, `trap` на `bench.sh down`; затем `xcodebuild test -project
    TmuxPad.xcodeproj -scheme TmuxPad -destination "platform=iOS Simulator,id=$UDID"
    -resultBundlePath build/TestResults.xcresult -quiet`; лишние аргументы уходят в
    `xcodebuild` (`-only-testing:AppTests/ServerStoreTests`). Перед запуском удаляет старый
    `build/TestResults.xcresult`.

### Чего этот план не делает

- Не делает дерево сайдбара, мастера, kill (план 5), терминал и SwiftTerm (план 6),
  `scenePhase`, `NWPathMonitor`, онбординг, настройки терминала, Face ID, иконку, README,
  UI-тесты, TestFlight (план 7).
- Не меняет ядро. Если ядру чего-то не хватает — остановиться и записать в progress-лог с `⚠️`:
  правка ядра — отдельный план с прогоном его тестов.
- Не меняет host-скрипт и его контракт §7.
- Не настраивает подпись для устройства и App Store Connect.

## Context

- Спека: §3.6 (настройки, кнопки сервера, диагностика), §3.7 (команда для сервера), §4
  (технологии, хранение), §5 (UUID устройства, одно окно), §5.1, §5.2, §8, §9.
- Ядро: `TmuxPadCore/README.md` — «Что реализует приложение». Используемое API:
  - `Models/Models.swift` — `ServerConfig` (поля и значения по умолчанию §3.6), `SSHKeyInfo`
    (`Kind.secureEnclaveP256`, `.ed25519`), `DoctorReport`/`DoctorLine`;
    `Models/Validation.swift` — `ServerConfig.validationIssues()`.
  - `SSH/Stores.swift` — протоколы `KeyStore` (`list`, `save(_:privateKeyOpenSSH:)`,
    `privateKey(for:) -> SSHPrivateKey?`, `delete`), `HostKeyStore` (`fingerprint(for:port:)`,
    `save`, `reset(host:port:)`), `InMemoryKeyStore`, `InMemoryHostKeyStore` (`key(host:port:)`).
  - `SSH/Keys.swift` — `SSHKeys.generateEd25519(comment:)`, `importOpenSSHEd25519(_:
    passphrase:)`, `publicKeyOpenSSH(_:comment:)`, `fingerprint(_:)`,
    `authorizedKeysCommand(publicKey:)`.
  - `SSH/SSHTransport.swift` — `SSHPrivateKey(NIOSSHPrivateKey)`, `SSHAuth.privateKey(_:user:)`;
    `SSH/CitadelTransport.swift` — `CitadelTransport()`.
  - `Pool/ConnectionPool.swift` — `init(transport:hostKeys:deviceID:log:settings:)`,
    `connection(for:auth:)`, `remove(id:)`; `Pool/ServerConnection.swift` — `connect()`
    (бросает первую ошибку, `authFailed`/`hostKeyChanged` → сразу `.failed`),
    `hostKeyFingerprint`, `hostKeyFirstSeen`, `disconnect()`, `api`.
  - `Host/HostBootstrap.swift` — `init()` (скрипт из ресурса), `status(api:)`,
    `prepare(api:) -> DoctorReport`; `Host/HostAPI.swift` — `doctor()`, `auth(token:)`;
    `Host/HostError.swift` — `HostError`, `SSHError` с английскими `description`.
  - `Diagnostics/DiagnosticsLog.swift` — `events()`, `updates`, `export()`, `DiagnosticsEvent.
    Kind`.
- swift-nio-ssh (форк `Wellz26`, 0.3.7): `NIOSSHPrivateKey(secureEnclaveP256Key:)` под
  `#if canImport(Darwin)`; `String(openSSHPublicKey:)` даёт `ecdsa-sha2-nistp256 AAAA…`.
- Стенд: `host/tests/bench.sh up|down` печатает `export TMUXPAD_BENCH_PORT=… TMUXPAD_BENCH_KEY=…
  TMUXPAD_BENCH_USER=dev`; после плана 3 работает на macOS bash 3.2. На стенде есть проекты и
  заглушка `claude`; `doctor` после `setup` проходит.
- Mac для исполнения: Xcode 26 (нужен Swift 6.2 для SwiftTerm 1.99.0 в плане 6; здесь
  достаточно Xcode 16+, но ставить сразу 26), `brew install xcodegen coreutils`, Docker Desktop
  или OrbStack, ralphex с конфигом как на Linux-хосте (`~/.config/ralphex/`, модели
  `opus[1m]`). Симулятор iPad с iOS 17+ — любой доступный.
- В симуляторе `SecureEnclave.isAvailable == false`: SE проверяется только на устройстве
  (Post-Completion).

## Validation Commands

```
xcodegen generate
xcodebuild build -project TmuxPad.xcodeproj -scheme TmuxPad -destination 'generic/platform=iOS Simulator' -quiet
scripts/ios-test.sh                       # стенд + все AppTests в симуляторе
scripts/ios-test.sh --no-bench            # только юнит, без Docker
scripts/ios-test.sh -only-testing:AppTests/ServerStoreTests
swift test --package-path TmuxPadCore --skip IntegrationTests   # ядро не сломано
shellcheck -s bash scripts/ios-test.sh
```

Сборка в режиме Swift 6 без предупреждений в коде приложения (предупреждения внутри зависимостей
не считаются); новое предупреждение — ошибка задачи.

## Testing Strategy

- Юнит (`AppTests`, симулятор): `KeychainTests` (запись, перезапись, чтение, удаление,
  `accounts()` в тестовом сервисе; чистка в `init`/`deinit` suite), `KeychainKeyStoreTests`
  (Ed25519: создать → `list` → `privateKey` даёт ключ с тем же публичным → удалить;
  импорт файла с паролем; импорт мусора → `KeyError.invalidKey`; SE — только на устройстве),
  `KeychainHostKeyStoreTests`, `DeviceIdentityTests`, `JSONFileStoreTests` (атомарная запись,
  отсутствующий файл → `nil`, битый JSON → ошибка, а не потеря файла), `ServerStoreTests`
  (добавить, дублировать без отпечатка, удалить → сервер ушёл из пула, порядок после `move`,
  `issues` для пустой метки и неизвестного ключа), `KeyLibraryTests` (удаление используемого
  ключа → `inUse`), `ErrorTextTests` (у каждого случая `SSHError`/`HostError` русский текст).
- Интеграционные (`ServerCheckBenchTests`, стенд): первый `check()` → `trustPrompt` с
  отпечатком, совпадающим с `ssh-keyscan`-отпечатком стенда (тест берёт его из
  `ServerConnection.hostKeyFingerprint`, сверка с `ssh-keygen` — Post-Completion); `trust()` →
  `done(.missing или .ready)`; `prepare()` → `done(.ready, report.ok == true)`; второй
  `check()` после пересоздания модели — без `trustPrompt`; подмена отпечатка в
  `InMemoryHostKeyStore` → `hostKeyChanged`, `resetHostKey()` → снова `trustPrompt`; чужой ключ
  (сгенерированный в тесте) → `authFailed`; `sendToken("tok_123")` → на стенде `~/.tmuxpad/env`
  содержит токен (проверка через `exec` пула).
- Сборка всей схемы без предупреждений; ядро — `swift test` без интеграции (на Mac Docker есть,
  полный `TmuxPadCore/scripts/test.sh` — в последней задаче).

## Задачи

### Task 1: Xcode-проект, каркас приложения, тестовый скрипт

**Файлы:** `project.yml` (create), `App/TmuxPadApp.swift` (create), `App/UI/Root/RootView.swift`
(create), `App/Resources/Assets.xcassets` (create: `AccentColor`, пустой `AppIcon`),
`AppTests/SmokeTests.swift` (create), `scripts/ios-test.sh` (create), `.gitignore`, `CLAUDE.md`.

- [x] `project.yml` по решению 2. Проверка: `xcodegen generate` создаёт
      `TmuxPad.xcodeproj`, `xcodebuild build … -destination 'generic/platform=iOS Simulator'`
      проходит; `NIOSSH` разрешился в ту же версию, что в `TmuxPadCore/Package.resolved`
      (сверить `Package.resolved` внутри `TmuxPad.xcodeproj/project.xcworkspace/xcshareddata/
      swiftpm/`).
- [x] `App/TmuxPadApp.swift`: `@main struct TmuxPadApp: App` с одной `WindowGroup { RootView() }`;
      `App/UI/Root/RootView.swift`: `NavigationSplitView` с пустым сайдбаром «Серверы» и
      деталью «Выберите сессию».
- [x] `.gitignore`: `TmuxPad.xcodeproj/`, `App/Info.plist` (генерирует XcodeGen), `build/`,
      `DerivedData/`, `*.xcresult`.
- [x] `scripts/ios-test.sh` по решению 14, `chmod +x`; `shellcheck -s bash` чист.
- [x] `AppTests/SmokeTests.swift`: `@Test func appEnvironmentBuilds()` — пока проверяет, что
      `TmuxPadCore` импортируется и `HostScript.version >= 1` (ресурс пакета доступен из
      приложения).
- [x] `CLAUDE.md`, «Состояние репозитория»: появилось приложение; команды из Validation
      Commands; требования Mac (Xcode 26, xcodegen, coreutils, Docker); правило «проект
      генерируется, `TmuxPad.xcodeproj` не коммитить».
- [x] `scripts/ios-test.sh --no-bench` проходит.

### Task 2: Keychain, Secure Enclave, JSON-файлы, UUID устройства

**Файлы:** `App/Platform/Keychain.swift`, `App/Platform/KeychainKeyStore.swift`,
`App/Platform/KeychainHostKeyStore.swift`, `App/Platform/DeviceIdentity.swift`,
`App/Platform/JSONFileStore.swift` (все create), `AppTests/{KeychainTests,
KeychainKeyStoreTests,KeychainHostKeyStoreTests,DeviceIdentityTests,JSONFileStoreTests}.swift`
(create).

- [x] `Keychain.swift` по решению 4; `KeychainError: Error, Equatable` с `status(OSStatus)` и
      `unexpectedData`.
- [x] `JSONFileStore.swift` по решению 8; каталог задаётся в инициализаторе (по умолчанию
      Application Support/`TmuxPad`), тесты используют `FileManager.default.temporaryDirectory`
      + UUID.
- [x] `KeychainKeyStore.swift` по решению 5: `actor KeychainKeyStore: KeyStore` с
      `init(keychain: Keychain, metadata: JSONFileStore<[SSHKeyInfo]>)`; `KeyStoreError`
      (`secureEnclaveUnavailable`, `unsupportedKind`, `notFound`). `@preconcurrency import
      NIOSSH`; `import CryptoKit` для `SecureEnclave`.
- [x] `KeychainHostKeyStore.swift` по решению 6; `DeviceIdentity.swift` по решению 7.
- [x] Тесты из Testing Strategy для этих типов; каждый suite работает в собственном сервисе
      `dev.tmuxpad.test.<suite>.<UUID>` и удаляет его записи в конце.
- [x] `scripts/ios-test.sh --no-bench` проходит.
- Заметки исполнения: приложению добавлена прямая зависимость `Citadel` в `project.yml` (тот же
  URL, что в ядре): импорт с паролем пересохраняет ключ без шифра через
  `Curve25519.Signing.PrivateKey(sshEd25519:decryptionKey:)` и `makeSSHRepresentation`, а
  `NIOSSHPrivateKey` сырых байт не отдаёт. В симуляторе Xcode 26 `SecureEnclave.isAvailable ==
  true`, полный цикл SE-ключа прошёл и там.

### Task 3: `AppEnvironment`, `ServerStore`, `KeyLibrary`, тексты ошибок

**Файлы:** `App/AppEnvironment.swift`, `App/State/ServerStore.swift`,
`App/State/KeyLibrary.swift`, `App/UI/ErrorText.swift` (все create), `App/TmuxPadApp.swift`,
`AppTests/{ServerStoreTests,KeyLibraryTests,ErrorTextTests}.swift` (create).

- [x] `AppEnvironment.swift` по решению 9: `static func live() throws -> AppEnvironment` и
      `static func inMemory(directory: URL? = nil) -> AppEnvironment`; выбор в `TmuxPadApp` —
      `ProcessInfo.processInfo.arguments.contains("-uitest-inmemory")`; ошибка `live()` →
      `StartupErrorView` с текстом и без дальнейшей работы. `AppError.keyMissing(UUID)`.
- [x] `ServerStore.swift` и `KeyLibrary.swift` по решению 10; оба получают зависимости через
      инициализатор (не через синглтон), загружаются из JSON при создании.
- [x] `ErrorText.swift` по решению 3: русские тексты всех случаев `SSHError` («Не удалось
      подключиться: …», «Сервер не принял ключ», «Ключ сервера изменился», «Сервер отказал в
      новом канале», «Сервер не ответил вовремя», «Соединение потеряно»), `HostError` («На
      сервере нет host-скрипта», «Сервер отклонил запрос: …», «Сессия с таким именем уже
      есть», «Сессии больше нет», «Папки проектов нет на сервере», «Команда завершилась с
      кодом N: …», «Неожиданный ответ сервера: …»), `KeyError`, `KeyStoreError`,
      `KeyLibraryError`, `AppError`.
- [x] Окружение передаётся в SwiftUI через `.environment(...)` для `@Observable`-моделей и
      собственный `EnvironmentKey` для `AppEnvironment`.
- [x] Тесты из Testing Strategy; `scripts/ios-test.sh --no-bench` проходит.
- Заметки исполнения: `inMemory(directory:)` бросает, как и `live()`: `HostBootstrap()` и
  загрузка `servers.json` могут упасть, а `try!` в тестах прятал бы причину. Создание и импорт
  ключей вынесены в протокол `AppKeyStore: KeyStore` (`App/Platform/AppKeyStore.swift`), его
  реализуют `KeychainKeyStore` и `InMemoryKeyStore` (SE — `secureEnclaveUnavailable`);
  `AppEnvironment.keyStore` — `any AppKeyStore`, `KeychainKeyStore.list()` — `nonisolated`,
  чтобы `live()` загрузил ключи синхронно. `ServerStore.issues(for:keys:)` получает список ключей
  параметром (у `KeyLibrary` ссылка на `ServerStore`, обратная дала бы цикл) и отдаёт русские
  тексты (`serverIssueText` в `ErrorText.swift`). `delete` сбрасывает отпечаток `host:port`,
  только если других серверов с тем же адресом нет: запись в `HostKeyStore` общая у копий.
  Симулятор, который `ios-test.sh` выбирает первым, отказывал в запуске («Busy, Application
  failed preflight checks»), пока не был загружен вручную (`xcrun simctl boot`).

### Task 4: настройки — ключи и серверы

**Файлы:** `App/UI/Settings/{SettingsView,KeysView,KeyDetailView,NewKeyView,ImportKeyView,
ServersView,ServerEditView,QRCodeView}.swift` (create), `App/UI/Root/RootView.swift`.

- [ ] `SettingsView`: sheet с `NavigationStack`, разделы «Серверы», «Ключи», «Диагностика»
      (ссылка на экран из Task 6; до Task 6 — заглушка), кнопка «Готово». `RootView`: кнопка
      «⚙ Настройки» внизу сайдбара и `⌘,` открывают sheet; список серверов в сайдбаре — из
      `ServerStore`.
- [ ] `KeysView`, `NewKeyView`, `ImportKeyView`, `KeyDetailView`, `QRCodeView` по решению 11.
      Имя ключа по умолчанию — «iPad SE-key» или «iPad Ed25519»; QR — `CIImage` →
      `UIImage` с масштабом без сглаживания (`.interpolation(.none)`); копирование —
      `UIPasteboard.general.string`; удаление используемого ключа — алерт со списком серверов.
- [ ] `ServersView`, `ServerEditView` по решению 11: новые серверы получают первый ключ
      библиотеки; без ключей «Добавить сервер» ведёт на создание ключа. Поле «Отпечаток
      хост-ключа» показывает `ServerConfig.hostKeyFingerprint` или «ещё не подключались»;
      «Сбросить» — подтверждение, `hostKeys.reset` и очистка поля.
- [ ] Ручная проверка в симуляторе не требуется; сборка без предупреждений и `scripts/ios-
      test.sh --no-bench`.

### Task 5: проверка подключения, подготовка сервера, токен

**Файлы:** `App/State/ServerCheckModel.swift`, `App/UI/Settings/{ServerCheckView,TokenView}.swift`,
`App/UI/DoctorText.swift` (все create), `App/UI/Settings/ServerEditView.swift`,
`AppTests/Support/Bench.swift` (create), `AppTests/ServerCheckBenchTests.swift` (create).

- [ ] `ServerCheckModel` по решению 10. `check()`: `pool.connection(for:auth:)` с
      `environment.auth(for:)` → `connect()`; `SSHError.authFailed` → `.authFailed`;
      `.hostKeyChanged(expected, actual)` → `.hostKeyChanged`; прочие → `.failed(userText)`;
      успех с `hostKeyFirstSeen` → `.trustPrompt(fingerprint)` (дальше — только после
      `trust()`); затем `bootstrap.status(api:)` и, при `.ready`, `api.doctor()` → `.done`.
      `reject()` → `disconnect()` + `hostKeys.reset` + `.idle`. `resetHostKey()` → `reset` и
      повторный `check()`. `prepare()` → `bootstrap.prepare(api:)` → `.done(.ready, report)`.
      `sendToken(_:)` → `api.auth(token:)`; токен не попадает ни в журнал, ни в состояние
      модели.
- [ ] `ServerCheckView` и `TokenView` по решению 11; кнопки сервера в `ServerEditView` открывают
      их (кнопки недоступны для несохранённого сервера). `DoctorText.swift` по решению 12.
- [ ] `AppTests/Support/Bench.swift`: `Bench.isAvailable`, `Bench.config(keyID:)`, ключ из
      `TMUXPAD_BENCH_KEY_B64` в `InMemoryKeyStore`; `ServerCheckBenchTests` из Testing Strategy,
      `.serialized`, `.enabled(if: Bench.isAvailable)`; перед каждым тестом — сброс состояния
      стенда так же, как в `TmuxPadCore/Tests/TmuxPadCoreTests/Support/Bench.swift`.
- [ ] `scripts/ios-test.sh` (со стендом) проходит.

### Task 6: экран диагностики

**Файлы:** `App/State/DiagnosticsModel.swift`, `App/UI/Settings/DiagnosticsView.swift` (create),
`App/UI/Settings/SettingsView.swift`, `AppTests/DiagnosticsModelTests.swift` (create).

- [ ] `DiagnosticsModel` по решению 10: создаётся в `AppEnvironment`, одна подписка на
      `log.updates` на всё время жизни; не больше `DiagnosticsLog.defaultCapacity` событий в
      памяти модели.
- [ ] `DiagnosticsView` по решению 11: строки новые сверху, время `HH:mm:ss`, значок по
      `Kind`; фильтр по серверу (`Picker`, «Все»); `ShareLink(item: model.exportText())`;
      «Очистить» не делается (журнал кольцевой).
- [ ] `DiagnosticsModelTests`: событие, записанное в журнал после создания модели,
      появляется в ней; после закрытия и повторного открытия экрана новые события по-прежнему
      приходят.
- [ ] `scripts/ios-test.sh --no-bench` проходит.

### Task 7: документация, полный прогон, завершение

**Файлы:** `CLAUDE.md`, `docs/tmuxpad-spec.md` (§11 — отметки фаз 1–2; расхождения — если
были), `docs/plans/20261020-app-foundation.md` (move).

- [ ] `CLAUDE.md`: раскладка `App/`, `AppTests/`, `scripts/ios-test.sh`; инварианты
      «приложение не логирует токен и приватные ключи», «Keychain только через
      `Platform/Keychain.swift`», «ошибки ядра показываются пользователю через
      `ErrorText.userText`».
- [ ] Спека §11: отметить сделанные пункты фазы 1 (`KeyManager` без share-экстеншенов,
      `HostKeyStore` + алерт, `ServerStore` + настройки + «Проверить подключение», UUID
      устройства, экран журнала) и фазы 2 (`HostBootstrap` с отчётом в UI). Там же поправить
      устаревшие ссылки «— план 3» в фазах 1 и 2: экран журнала и отчёт `doctor` — план 4,
      `NWPathMonitor` — план 7.
- [ ] Полный прогон: Validation Commands и `TmuxPadCore/scripts/test.sh` (ядро на Mac со
      стендом); в progress-лог — число тестов и время.
- [ ] Move this plan to `docs/plans/completed/`; коммит.

## Post-Completion

- Для устройства: свой `PRODUCT_BUNDLE_IDENTIFIER` в `project.yml` (если `dev.tmuxpad.app`
  занят) и команда разработчика через `DEVELOPMENT_TEAM=…` или Xcode.
- На iPad (не в симуляторе): создать SE-ключ, положить публичный на настоящий сервер
  командой из `KeyDetailView`, «Проверить подключение» → «Доверять» → отпечаток совпадает с
  `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` на сервере; «Подготовить сервер» →
  чеклист зелёный; «Передать токен» → на сервере `~/.tmuxpad/env` с правами `0600`.
- Завести второй сервер (или тот же с другой меткой и портом стенда) — цель фазы 1.
- Проверить, что в журнале диагностики нет токена и приватного ключа после всех действий.
