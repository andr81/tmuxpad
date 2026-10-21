# Приложение, жизненный цикл и релиз: фон, смена сети, восстановление, онбординг, настройки терминала, Face ID, README

## Overview

Седьмой и последний план v1 по спеке `docs/tmuxpad-spec.md`, фазы 5 и 6. Исполняется на Mac.
Фаза 5: приложение переживает уход в фон, блокировку экрана, смену сети и перезапуск — при
возврате тихо переподключается ко всем открытым сессиям. Фаза 6: онбординг для первого запуска,
настройки терминала (шрифт, размер, тема, Option = Meta, звук), светлая и тёмная тема, Face ID
перед первым использованием ключа (опция), иконка, README с подготовкой сервера, UI-смоук.
TestFlight требует учётной записи Apple Developer и остаётся ручным шагом (Post-Completion).

Порядок: после планов 3–6. Большую часть фазы 5 уже делает ядро: `ConnectionPool.disconnectAll()`,
`reconnectAll(force:)`, бэкофф с остановкой в `failed`, а `TerminalSession` в `.offline` сама ждёт
`.connected` пула и переоткрывает `attach` (код 4 → `.ended`). Приложению остаётся вовремя
вызвать эти методы и сохранить, что было открыто.

### Решения, принятые в спеке (не переоткрывать)

- §6: `scenePhase → .background` — `beginBackgroundTask` (до ~30 с работы), затем соединения
  закрываются; вернулись раньше — ничего не рвём. `.active` — для каждого сервера с открытыми
  сессиями reconnect → `list` → новый PTY `attach` для каждой живой, исчезнувшие — «Сессия
  завершена»; плашка «Переподключение…» на время. Смена сети (`NWPathMonitor`) —
  `reconnectAll(force: true)`. Ключ не принят / хост-ключ сменился — сразу `failed`, без
  бэкоффа. После четырёх неудачных попыток пул в `failed` до явного запроса (возврат из фона,
  смена сети, «Повторить»).
- §6.1: возврат из фона, смена сети, перезапуск — переподключение ко всем открытым сессиям
  молча, независимо от `others`; Mac не выбивается.
- §11 фаза 5: восстановление открытых сессий после перезапуска — список имён в `UserDefaults`.
- §3.7: онбординг — создать ключ → публичный ключ и команда для сервера (копировать,
  поделиться) → добавить сервер → «Проверить подключение» (доверять отпечатку) → «Подготовить
  сервер» с чеклистом и числом найденных проектов.
- §3.6 «Терминал»: шрифт, размер, тема (светлая/тёмная/как система), Option = Meta, звук bell.
- §8: Face ID перед первым использованием ключа в сессии приложения — опция.
- §2: одно окно, только iPad; распространение — Xcode/TestFlight (§13, открытый вопрос 1 не
  решается этим планом).

### Решения исполнителя плана

1. **`LifecycleCoordinator`** (`App/State/LifecycleCoordinator.swift`, `@MainActor final
   class`) — единственное место, которое реагирует на `scenePhase` и сеть. `RootView`
   передаёт ему `scenePhase` через `onChange`.
   - `.background`: `UIApplication.shared.beginBackgroundTask(withName: "tmuxpad.close")`;
     через 25 с (запас до ~30 с системы) — `tree.stop()`, `pool.disconnectAll()`, конец
     фоновой задачи; обработчик истечения делает то же сразу. Возврат в `.active` до 25 с
     отменяет таймер и задачу: соединения не тронуты.
   - `.inactive` (шторка, переключатель приложений) — ничего не делает.
   - `.active` после разрыва: `pool.reconnectAll()`, `tree.start()` и `tree.refresh()`;
     терминалы переоткрываются сами (ядро), их плашка — «Переподключение…» по состоянию.
     После `.active` без разрыва — только `tree.start()`.
   - Первый `.active` после запуска — восстановление (решение 3).
2. **`NetworkMonitor`** (`App/Platform/NetworkMonitor.swift`): `NWPathMonitor` на своей
   очереди; событие «сеть сменилась» — изменение `status` на `.satisfied` или набора
   `availableInterfaces` (Wi-Fi ↔ сотовая) при `.satisfied`; первое срабатывание после старта
   игнорируется; дребезг 1 с. Событие → `pool.reconnectAll(force: true)` и `tree.refresh()`.
   Переход в `.unsatisfied` ничего не рвёт: keepalive и так похоронит соединение, а возврат
   сети придёт событием. В фоне монитор работает, но координатор игнорирует события, пока
   соединения закрыты.
3. **Восстановление открытых** (`App/State/OpenSessionsPersistence.swift`): `OpenSessionsRoster`
   (Codable, план 3) и `selection` пишутся в `UserDefaults` (`openSessions.roster`,
   `openSessions.selection`) при каждом изменении ростера. При первом `.active` после запуска
   ключи с неизвестным `serverID` отбрасываются, остальные открываются через
   `OpenSessionsModel.open` в порядке `tabs` без `take`; если сессии на сервере больше нет,
   ядро даст `.ended` — плашка «Сессия завершена», как в §6. Не восстанавливается, если
   приложение запущено с `-uitest-inmemory`.
4. **Онбординг** (`App/UI/Onboarding/`) — полноэкранный `fullScreenCover`, когда нет ни
   ключей, ни серверов (и флаг `onboarding.done` не выставлен). Шаги — `NavigationStack`:
   ключ (SE по умолчанию, если доступен, иначе Ed25519; переиспользует `KeyLibrary`), публичный
   ключ (переиспользует `KeyDetailView` в режиме «онбординг» — без удаления), сервер
   (`ServerEditView` в режиме создания), проверка (`ServerCheckView`), подготовка (чеклист
   `doctor` + «Проектов найдено: N» из `api.list()`), «Готово». «Пропустить» на каждом шаге
   выставляет флаг. Шаги — значения `enum OnboardingStep` с чистой функцией перехода
   (`next(after:context:)`) для тестов.
5. **Настройки терминала** (`App/UI/Settings/TerminalSettingsView.swift`, раздел «Терминал»):
   шрифт — `Picker` из «Системный моноширинный» (`UIFont.monospacedSystemFont`), «Menlo»,
   «Courier New» (есть в iPadOS; SF Mono в iOS-приложениях недоступен); размер — `Stepper`
   9…32 (тот же `TerminalAppearance` из плана 6, что и pinch); тема — «Как система» / «Светлая»
   / «Тёмная» (`preferredColorScheme` на корне и цвета терминала: две палитры
   `nativeForegroundColor`/`nativeBackgroundColor`/`caretColor` под светлую и тёмную;
   ANSI-палитра SwiftTerm по умолчанию); Option = Meta (`optionAsMetaKey`); звук — «Звук» /
   «Выключен» (`bellStyle`). Ключи: `terminal.fontName` (новый; значения `system`, `Menlo`,
   `Courier New`), `terminal.fontSize`, `terminal.theme` (новый; `system`, `light`, `dark`),
   `terminal.optionAsMeta`, `terminal.bell`. Все значения — в `AppEnvironment.defaults`
   (план 4: в тестах — отдельный `suiteName`), три из них план 6 уже
   читает, и применяются ко всем открытым терминалам сразу через `TerminalAppearance`.
6. **Face ID** (`App/Platform/KeyUnlocker.swift`): настройка «Требовать Face ID для ключей»
   (`security.requireBiometrics`, по умолчанию выключено). Где ставить проверку, решает то,
   как ядро держит ключ: `ServerConnection` хранит `SSHAuth`, полученный при создании, и
   `reconnectAll()` после фона переподключается с ним, не вызывая `auth(for:)`. Поэтому
   проверка в `auth(for:)` была бы декоративной. Решение:
   - `AppEnvironment.auth(for:)` кеширует `SSHAuth` по `keyID` (заодно `TreeRefresher` не
     читает Keychain/SE на каждом тике раз в 10 с); кеш очищается при уходе в фон, если
     настройка включена.
   - `KeyUnlocker.authenticate()` — `LAContext().evaluatePolicy(.deviceOwnerAuthentication,
     localizedReason: "Доступ к SSH-ключу")`, однопоточный: параллельные вызовы ждут одного
     запроса, а не показывают несколько. Успех действует до ухода в фон.
   - `LifecycleCoordinator` при включённой настройке на `.active` после фона сначала ждёт
     `authenticate()`, и только потом `reconnectAll()` и `tree.start()`; `auth(for:)` при
     пустом кеше тоже ждёт `authenticate()`. Отказ → `AppError.biometricsDenied` → «Доступ к
     ключу отменён», соединения не поднимаются, терминалы остаются с плашкой «Повторить»,
     которая снова зовёт `authenticate()`; автоповторов нет.
   Один механизм для обоих видов ключей вместо access control SE-ключа: SE-ключи, созданные
   раньше без флага, не придётся пересоздавать. `NSFaceIDUsageDescription` в `project.yml`.
7. **Иконка** — генерируется скриптом `scripts/make-icon.swift` (Core Graphics, без внешних
   инструментов): 1024×1024, тёмный фон, моноширинный глиф `❯_` и тонкая рамка-сплит, PNG в
   `App/Resources/Assets.xcassets/AppIcon.appiconset/` с `Contents.json` формата single-size
   (Xcode 14+). PNG коммитится; скрипт — для пересоздания.
8. **README** (`README.md` в корне, по-русски): что это; требования к серверу (§7: Linux, bash,
   tmux ≥ 3.1, claude в login PATH, вход по ключу `ecdsa-sha2-nistp256` или `ssh-ed25519`);
   подготовка сервера (из приложения и вручную: где лежит скрипт, `setup`, `auth`, что
   меняется в `~/.tmux.conf`); сборка (Xcode 26, `brew install xcodegen coreutils`,
   `xcodegen generate`, подпись для устройства через `DEVELOPMENT_TEAM=` или выбор команды в
   Xcode, бесплатный аккаунт — переустановка раз в 7 дней); тесты (Linux-хост: ядро и
   host-скрипт; Mac: `scripts/ios-test.sh`); раскладка репозитория одной таблицей; ссылка на
   спеку и атрибуция рецепта agterm (MIT).
9. **UI-смоук** — таргет `AppUITests` (`bundle.ui-testing`, добавить в `testTargets` схемы
   `TmuxPad`) с запуском `-uitest-inmemory`: каждый запуск получает чистые `UserDefaults` и
   хранилища (`AppEnvironment.inMemory()`, план 4), поэтому онбординг появляется всегда и
   пропускается; «Настройки» → «Ключи» → создать Ed25519 → публичный ключ начинается с
   `ssh-ed25519 ` (ключ создаётся первым: без ключей «Добавить сервер» ведёт на создание
   ключа); «Серверы» → новый сервер с пустым адресом не сохраняется (кнопка неактивна). Элементы находятся по
   `accessibilityIdentifier`, которые план добавляет к нужным контролам.
10. **Тесты жизненного цикла без устройства.** `LifecycleCoordinatorTests` — с
    подменёнными часами (интервал 25 с — параметр, в тесте 50 мс) и протоколом над пулом и
    деревом (`LifecycleTargets`: `disconnectAll`, `reconnectAll(force:)`, `startTree`,
    `stopTree`, `refreshTree`), который в приложении реализует адаптер над `ConnectionPool` и
    `TreeModel`: фон → через интервал `disconnectAll` и `stopTree`; возврат раньше — ни одного
    вызова; возврат позже — `reconnectAll(false)`, `startTree`, `refreshTree`. `NetworkMonitor`
    — логика решения «сменилась ли сеть» вынесена в чистую функцию над снимками пути
    (`status`, интерфейсы) и тестируется таблицей. `OpenSessionsPersistenceTests` — запись и
    чтение, отбрасывание неизвестных серверов. `OnboardingStepTests`. Интеграционные
    (`LifecycleBenchTests`, стенд): открыть терминал → `disconnectAll` → состояние терминала
    уходит из `.live` → `reconnectAll` → снова `.live`, на стенде у сессии ровно один клиент
    этого устройства (зомби нет); убить сессию на стенде, пока «в фоне», → после возврата
    `.ended`.

### Чего этот план не делает

- Не загружает сборку в TestFlight и не настраивает App Store Connect: нужен аккаунт
  пользователя (Post-Completion).
- Не делает статус агента, уведомления, iCloud, dashboard — бэклог §10 и фаза 7.
- Не меняет ядро и host-скрипт; нехватку — `⚠️` в progress-лог и остановка.
- Не решает открытый вопрос §13 про App Store: README описывает Xcode и TestFlight.

## Context

- Спека: §2, §3.6, §3.7, §6, §6.1, §8, §11 (фазы 5, 6), §13.
- Ядро: `Pool/ConnectionPool.swift` (`disconnectAll`, `reconnectAll(force:)`),
  `Pool/ServerConnection.swift` (`ConnectionState`, `reconnectNow`), `Terminal/
  TerminalSession.swift` (ожидание `.connected` в `.offline`, код 4 → `.ended`),
  `Models/OpenSessionsRoster.swift` (Codable).
- Приложение после плана 6: `App/AppEnvironment.swift` (`auth(for:)`, режим
  `-uitest-inmemory`), `App/State/{TreeModel,OpenSessionsModel,OpenTerminal,
  TerminalAppearance}.swift`, `App/UI/Root/RootView.swift` (там `scenePhase` пока вызывает
  только `tree.start/stop` — переезжает в координатор), `App/UI/Settings/*` (`KeyDetailView`,
  `ServerEditView`, `ServerCheckView` переиспользуются онбордингом), `App/Terminal/
  TmuxTerminalView.swift` (читает `terminal.*` из `UserDefaults`), `project.yml`,
  `scripts/ios-test.sh`.

## Validation Commands

```
xcodegen generate
scripts/ios-test.sh
scripts/ios-test.sh --no-bench
scripts/ios-test.sh -only-testing:AppUITests
swift test --package-path TmuxPadCore --skip IntegrationTests
shellcheck -s bash scripts/ios-test.sh
```

Сборка без предупреждений в коде приложения.

## Testing Strategy

- Решения 9 и 10: координатор, монитор сети, сохранение, шаги онбординга — юнит-тестами;
  переподключение и отсутствие зомби-клиентов — против стенда; онбординг и настройки — UI-смоуком.
- Сценарии фазы 5 на устройстве (блокировка на 5 мин, Wi-Fi → LTE, ребут сервера, работа
  вместе с Mac) — руками по чеклисту Post-Completion: симулятор не замораживает приложение и
  не рвёт сокеты, как iPadOS.

## Задачи

### Task 1: фон, возврат, смена сети

**Файлы:** `App/State/LifecycleCoordinator.swift`, `App/Platform/NetworkMonitor.swift` (create),
`App/UI/Root/RootView.swift`, `App/AppEnvironment.swift`,
`AppTests/{LifecycleCoordinatorTests,NetworkMonitorTests,LifecycleBenchTests}.swift` (create).

- [x] `LifecycleCoordinator` по решению 1 с протоколом `LifecycleTargets` и адаптером
      приложения (решение 10); `RootView` передаёт `scenePhase` координатору вместо прямых
      `tree.start/stop`.
- [x] `NetworkMonitor` по решению 2; чистая функция `networkChanged(from:to:) -> Bool` над
      `struct PathSnapshot { satisfied: Bool; interfaces: Set<String> }`.
- [x] Каждое событие координатора и монитора — в `DiagnosticsLog` (`kind: .reconnect`,
      «background close», «foreground reconnect», «network changed: wifi → cellular»).
- [x] Тесты из решения 10 для координатора, монитора и стенда.
- [x] `scripts/ios-test.sh` проходит.

### Task 2: восстановление открытых сессий

**Файлы:** `App/State/OpenSessionsPersistence.swift` (create), `App/State/OpenSessionsModel.swift`,
`App/State/LifecycleCoordinator.swift`, `AppTests/OpenSessionsPersistenceTests.swift` (create).

- [x] Сохранение и восстановление по решению 3; `OpenSessionsModel` сообщает об изменении
      ростера одной точкой (`onRosterChange`).
- [x] `OpenSessionsPersistenceTests` (тестовый `UserDefaults(suiteName:)`).
- [x] `scripts/ios-test.sh --no-bench` проходит.

### Task 3: настройки терминала, тема, Face ID

**Файлы:** `App/UI/Settings/TerminalSettingsView.swift`, `App/Platform/KeyUnlocker.swift`
(create), `App/UI/Settings/SettingsView.swift`, `App/State/TerminalAppearance.swift`,
`App/Terminal/TmuxTerminalView.swift`, `App/AppEnvironment.swift`, `App/TmuxPadApp.swift`,
`project.yml`, `AppTests/{TerminalSettingsTests,KeyUnlockerTests}.swift` (create).

- [x] Раздел «Терминал» по решению 5; `TerminalAppearance` хранит и рассылает все параметры
      (шрифт, размер, тема, Option = Meta, звук); `TmuxTerminalView` применяет их без
      пересоздания.
- [x] Тема приложения — `preferredColorScheme` на корне по настройке.
- [x] Face ID по решению 6: настройка в разделе «Ключи»; `KeyUnlocker` за протоколом
      (`authenticate() async throws`), в тестах — фейк; `KeyUnlockerTests` — второе
      обращение не спрашивает, после `.background` спрашивает снова, отказ → ошибка.
- [x] `TerminalSettingsTests` — смена каждого параметра доходит до открытого терминала.
- [x] `scripts/ios-test.sh --no-bench` проходит.

### Task 4: онбординг

**Файлы:** `App/UI/Onboarding/{OnboardingView,OnboardingStep}.swift` (create),
`App/UI/Root/RootView.swift`, `App/UI/Settings/{KeyDetailView,ServerEditView,
ServerCheckView}.swift` (режим онбординга), `AppTests/OnboardingStepTests.swift` (create).

- [x] Онбординг по решению 4; шаг подготовки показывает «Проектов найдено: N».
- [x] `OnboardingStepTests` — переходы при доступном и недоступном SE, «Пропустить», возврат
      на шаг ключа после удаления ключа.
- [x] `scripts/ios-test.sh --no-bench` проходит.

### Task 5: иконка, README, UI-смоук

**Файлы:** `scripts/make-icon.swift` (create), `App/Resources/Assets.xcassets/AppIcon.appiconset/*`,
`README.md` (create), `project.yml` (таргет `AppUITests`), `AppUITests/SmokeUITests.swift`
(create), контролы с `accessibilityIdentifier` в `App/UI/**`.

- [ ] Иконка по решению 7: `swift scripts/make-icon.swift App/Resources/Assets.xcassets/
      AppIcon.appiconset/icon-1024.png`; `Contents.json` single-size; сборка без
      предупреждений актива.
- [ ] `README.md` по решению 8.
- [ ] `AppUITests` по решению 9; `scripts/ios-test.sh -only-testing:AppUITests` проходит.

### Task 6: документация, полный прогон, завершение

**Файлы:** `CLAUDE.md`, `docs/tmuxpad-spec.md` (§11 — отметки фаз 5 и 6),
`docs/plans/20261020-app-lifecycle-release.md` (move).

- [ ] `CLAUDE.md`: раскладка `App/UI/Onboarding`, `AppUITests`, `scripts/make-icon.swift`;
      инвариант «на `scenePhase` и сеть реагирует только `LifecycleCoordinator`».
- [ ] Спека §11: отметить сделанное в фазах 5 и 6 (TestFlight — не отмечать); расхождения —
      правкой спеки.
- [ ] Полный прогон Validation Commands и `TmuxPadCore/scripts/test.sh`; в progress-лог —
      число тестов по таргетам.
- [ ] Move this plan to `docs/plans/completed/`; коммит.

## Post-Completion

Сценарии фазы 5 — на iPad против настоящего сервера с открытыми 2–3 сессиями:

- Блокировка экрана на 5 минут → разблокировка: все терминалы снова живые, ввод работает, на
  сервере у каждой сессии нет лишних клиентов этого iPad (`tmux list-clients`).
- Возврат меньше чем через 25 с — соединения не рвутся (в журнале нет «background close»).
- Wi-Fi → сотовая и обратно: переподключение без ожидания keepalive (в журнале «network
  changed»).
- Ребут сервера: сессии пропали → «Сессия завершена»; «Создать заново» с тем же именем →
  claude стартует с `--resume` (разговор на месте).
- Работа вместе с Mac: Mac подключился без `-d` — оба видят сессию, размер за тем, кто
  печатает; Mac `attach -d` — iPad один раз переподключается молча, второй раз за минуту —
  плашка; возврат iPad из фона не выбивает Mac.
- Перезапуск приложения (смахнуть из переключателя) — открытые сессии восстановлены, выделена
  та же.
- Сервер выключен: 4 попытки, затем `failed`; «Повторить» и возврат из фона пробуют снова.
- Фаза 0, exec-пинг: время ответа `true` на настоящем сервере (журнал диагностики) и через
  сколько после выключения Wi-Fi пул замечает обрыв (два пропущенных пинга по 5 с при
  keepalive 15 с — ожидается 30–40 с); если сильно дольше — записать в спеку §5.
- Фаза 0, целевой сервер: `claude -n test --session-id <uuid>` стартует с именем, `claude
  --resume <uuid>` возвращает тот же разговор с тем же именем (§7, §11).

Фаза 6:

- Онбординг на чистой установке до «Готово» с настоящим сервером.
- Face ID: включить, уйти в фон, вернуться — запрос перед первым подключением.
- TestFlight: Apple Developer Program, App Store Connect — запись приложения с bundle id,
  `xcodebuild archive` + загрузка через Xcode Organizer; установка на iPad через TestFlight.
- Решить открытый вопрос §13 (только для себя или App Store) и записать в спеку.
