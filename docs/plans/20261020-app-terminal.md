# Приложение, терминал: SwiftTerm, открытые терминалы, клавиатура, скролл и чип, плашки

## Overview

Шестой план по спеке `docs/tmuxpad-spec.md`, фаза 4. Исполняется на Mac. Цель фазы: «в claude
внутри tmux комфортно работать час подряд с аппаратной и экранной клавиатурой». После плана
тап по сессии открывает в детали живой терминал SwiftTerm поверх `TerminalSession` ядра;
открытые терминалы держатся в памяти и переключаются мгновенно (`⌘1…⌘9`, `⌘[`/`⌘]`), девятый
вытесняет самый давно неактивный; скролл пальцем листает историю tmux, ввод после скролла
сначала выводит pane из copy-mode; плашки «Переподключение…», «Сессия завершена», «Отключено
другим клиентом» и офлайн; меню `[⋯]`; pinch меняет шрифт во всех терминалах; OSC 52 кладёт
текст в буфер обмена iPad.

Порядок: после планов 3 (`TerminalSession.input`, `cancelCopyMode`, `copyModeSuspected`,
`OpenSessionsRoster`), 4 и 5 (`OpenSessionsModel` с `open(_:take:)`, `SessionActions`,
заглушка детали). Сюда же входит спайк фазы 0 «SwiftTerm `TerminalView` в
`UIViewRepresentable`, локальный эхо-тест» — первым же тестом задачи 1.

### Решения, принятые в спеке (не переоткрывать)

- SwiftTerm от 1.99.0: drag одним пальцем при `allowMouseReporting = true` и `mouse on` в
  сессии уходит как колесо; двумя пальцами — локальный буфер SwiftTerm (§3.5, §4).
- Мышиные отчёты идут в PTY мимо `copy-cancel`; колесо вверх включает чип «Прокрутка ✕»; ввод
  после скролла — сначала `copy-cancel` с ожиданием; тап по чипу — `copy-cancel` (§3.5).
  В ядре это `TerminalSession.input(_:)`, `cancelCopyMode()` и
  `TerminalSurface.copyModeSuspected(_:)`.
- Экранная панель — встроенный `TerminalAccessory` SwiftTerm (Esc, Ctrl, Tab, стрелки,
  `~ | / -`); своя не нужна (§3.5).
- Аппаратная клавиатура: полный ввод, Esc, Ctrl, Option как Meta (настройка, по умолчанию
  включено); `⌘`-шорткаты приложения перехватываются, остальное — в терминал (§3.5).
- Pinch — размер шрифта, одно значение на устройство (`UserDefaults`), меняется сразу во всех
  открытых терминалах (§3.5).
- Поворот, Split View, Stage Manager → `window-change` (§3.5).
- Плашки и кнопки: «Сессия завершена» — «Создать заново» / «Закрыть»; обрыв — полупрозрачная
  «Переподключение…» поверх последнего экрана, ввод блокируется; «Отключено другим клиентом» —
  «Переподключить» / «Забрать» / «Закрыть»; офлайн — «Повторить» (§3.5, §6, §6.1). Автомат
  состояний уже в ядре: `TerminalState` (`connecting`, `live`, `reconnecting`, `ended`,
  `disconnectedByOther`, `offline(String)`).
- `[⋯]` над терминалом: Отключиться · Забрать · Завершить · Переподключить · Размер шрифта (§3.2).
- `⌘1…⌘9`, `⌘[`/`⌘]` — переключение открытых (§3.2); лимит 8 на приложение, вытесненным —
  `detach` (§5).
- Протокол `TerminalSurface` — граница для замены на libghostty (§5).

### Решения исполнителя плана

1. **`SwiftTermSurface: TerminalSurface`** (`App/Terminal/SwiftTermSurface.swift`,
   `final class`, `@unchecked Sendable`): держит `weak var view: TerminalView?` и замыкания
   для состояния и чипа. Вызовы ядра приходят не с main, и в SwiftTerm 1.99.0 это не
   проблема: `feed(byteArray:)` и `terminalDimensions` объявлены `nonisolated` и рассчитаны на
   вызов из фонового потока («this can be invoked from a background thread»). Поэтому `feed`
   зовёт `view.feed(byteArray:)` напрямую, без прыжка на main, а `size` возвращает
   `view.terminalDimensions` (`cols`, `rows`; если `view` уже `nil` — `(80, 24)`). Ни своей
   очереди, ни кеша размера под замком не нужно. `stateChanged` и `copyModeSuspected` — на
   main в `OpenTerminal` (решение 3).
2. **Порядок ввода.** Делегат SwiftTerm `send(source:data:)` вызывается на main синхронно;
   если на каждый вызов создавать `Task`, порядок байтов не гарантирован. Поэтому у каждого
   терминала один `AsyncStream<Data>` (`bufferingPolicy: .unbounded`) и одна задача-потребитель,
   которая по очереди делает `try await session.input(bytes)`; чип поднимает и опускает только
   `copyModeSuspected` поверхности (решение 1), `input` ничего не возвращает. Ошибки ввода (`SSHError.disconnected`) — в журнал, не в UI: плашку покажет
   состояние сессии.
3. **`OpenTerminal`** (`@MainActor @Observable final class`, `App/State/OpenTerminal.swift`):
   `key`, `project`, `session: TerminalSession`, `view: TmuxTerminalView` (создаётся один раз и
   живёт, пока терминал открыт — так переключение мгновенное, §5), `state: TerminalState`,
   `showsScrollChip: Bool`, `lastActive`. Методы `start()`, `close()` (`detach()` + отмена
   задачи ввода), `reconnect()`, `take()`, `cancelCopyMode()`, `recreate()` для «Создать
   заново» (`api.new(session:project:)` с тем же именем и проектом из снимка, затем
   `session.reconnect()` — без него терминал остался бы в `.ended`; если проекта в снимке нет —
   алерт «Проект `P` не найден на сервере»).
4. **`OpenSessionsModel` из плана 5 получает терминалы**: `terminals: [OpenSessionKey:
   OpenTerminal]`; `open(_:take:)` — если терминала нет: `pool.connection(for:auth:)` →
   `connect()` (ошибка не мешает: сессия сама уйдёт в `.offline` и переоткроется, когда пул
   подключится) → `TerminalSession(server:name:surface:)` → `start()` или, при `take`,
   `take()`; если есть — только выделение и активация, а при `take` — `take()`. Вытесненным
   ростером — `close()`. `close(_:)` — `close()` и удаление. `select(index:)` (`⌘1…⌘9`),
   `selectNext()`/`selectPrevious()` (`⌘]`/`⌘[`) — через `OpenSessionsRoster.tab(at:)`,
   `next(after:)`, `previous(before:)`.
5. **`TmuxTerminalView: TerminalView`** (`App/Terminal/TmuxTerminalView.swift`): настройка
   один раз в `init`: `optionAsMetaKey` из настройки (`UserDefaults` `terminal.optionAsMeta`,
   по умолчанию `true`; экран настройки — план 7), шрифт `UIFont.monospacedSystemFont(ofSize:
   weight: .regular)` размера `terminal.fontSize` (по умолчанию 14, диапазон 9…32),
   `allowMouseReporting = true`, `TerminalAccessory` по умолчанию остаётся,
   `UIPinchGestureRecognizer` (решение 7). ⌘-клавиши SwiftTerm 1.99.0 в `pressesBegan`
   пропускает (`continue` при `.command`), поэтому шорткаты SwiftUI работают без своего
   `pressesBegan`. Проверить это в симуляторе нельзя: команды SwiftUI `.commands` на iPad
   попадают в `UIMenuSystem`, а не в `keyCommands` ответчиков, и тест их не увидит. Проверка —
   руками на iPad с клавиатурой (Post-Completion).
6. **Делегат** (`App/Terminal/TerminalDelegate.swift`, `TerminalViewDelegate`): `send` →
   поток ввода (решение 2); `sizeChanged` → кеш размера + `Task { try? await
   session.resize(cols:rows:) }` (последовательность не важна: значение последнего вызова
   побеждает на стороне tmux); `clipboardCopy` → `UIPasteboard.general.setData(content,
   forPasteboardType: UTType.utf8PlainText.identifier)`, если `content` — UTF-8, иначе игнор;
   `clipboardRead` → `nil` (чтение буфера iPad сервером не разрешаем — §8 по духу); `bell` →
   по настройке `terminal.bell` (`sound` по умолчанию, `off`; SwiftTerm `bellStyle`);
   `requestOpenLink` → `UIApplication.shared.open` для `http`/`https`, иначе игнор;
   `setTerminalTitle`, `hostCurrentDirectoryUpdate`, `scrolled`, `rangeChanged`,
   `iTermContent`, kitty-буфер и `programStatusChanged` — пустые реализации (у части есть
   реализации по умолчанию в SwiftTerm — использовать их, если есть).
7. **Pinch и шрифт.** Pinch меняет размер с шагом 1 pt по накопленному масштабу (порог 0.12),
   новое значение пишется в `UserDefaults` и рассылается всем `OpenTerminal` через
   `TerminalAppearance` (`@MainActor @Observable`, одно на приложение): каждый
   `TmuxTerminalView` выставляет `font`, SwiftTerm пересчитывает сетку и вызывает
   `sizeChanged` → `resize`. Меню `[⋯]` → «Размер шрифта» — `Stepper` в popover с тем же
   эффектом.
8. **`TerminalScreen`** (`App/UI/Terminal/TerminalScreen.swift`): `UIViewRepresentable` вокруг
   контейнера `TerminalContainerView: UIView`, который при смене выделения снимает старый
   `TmuxTerminalView` и ставит текущий (`addSubview` с автоматическими констрейнтами по краям)
   и делает его first responder. Сам `TerminalView` не пересоздаётся. Над ним — SwiftUI:
   заголовок «server › project › session» и `[⋯]`; поверх — плашки (решение 9) и чип
   «Прокрутка ✕» по `showsScrollChip` (тап → `cancelCopyMode()`).
9. **Плашки** — `TerminalOverlay` по `TerminalState`: `.connecting`, `.reconnecting` —
   «Переподключение…» с индикатором на `.ultraThinMaterial`, `allowsHitTesting(true)` поверх
   терминала и `view.resignFirstResponder()` — ввод заблокирован; `.ended` — «Сессия
   завершена» + «Создать заново» / «Закрыть»; `.disconnectedByOther` — «Отключено другим
   клиентом» + «Переподключить» / «Забрать» (с подтверждением, как в сайдбаре) / «Закрыть»;
   `.offline(text)` — «Нет связи с сервером» + текст + «Повторить» (`reconnect()` и
   `server.reconnectNow()`); `.live` — без плашки, first responder возвращается.
10. **Меню `[⋯]`** — пункты §3.2 через `SessionActions` (план 5) и `OpenTerminal`:
    «Отключиться» (`SessionActions.detach`, инвариант плана 5), «Забрать» (подтверждение),
    «Завершить»
    (подтверждение, `SessionActions.kill`), «Переподключить» (`reconnect()`), «Размер шрифта».
11. **Шорткаты.** `⌘1…⌘9`, `⌘[`, `⌘]` — `.commands { CommandMenu("Сессии") { … } }` в
    `TmuxPadApp` (на iPad видны по удержанию ⌘ и работают при фокусе в терминале), вызывают
    `OpenSessionsModel`. `⌘N`, `⌘O`, `⌘0` из плана 5 переносятся туда же, чтобы работать и при
    фокусе в терминале и при скрытом сайдбаре; `.keyboardShortcut` с кнопок тулбара при этом
    снимается, чтобы одна комбинация не была объявлена дважды.
12. **Тесты.** Юнит в симуляторе: `SwiftTermSurfaceTests` (байты, отданные `feed` не с main,
    появляются на экране `TerminalView` в исходном порядке — читать через
    `view.visibleRowsText(0..<rows)` (в 1.99.0 нет `getTerminal()`, он убран при переходе к 2.0,
    см. `Documentation.docc/MigratingFrom1To2.md` SwiftTerm), с ожиданием-опросом, потому что
    `feed` обрабатывается асинхронно; `size` совпадает с `terminalDimensions` после смены
    кадра view); `InputPumpTests` (сотня
    вызовов делегата `send` подряд доходят до фейкового приёмника в том же порядке);
    `OpenSessionsModelTests` дополняются: девятый `open` вызывает `close` у вытесненного,
    `select(index:)`, `selectNext` по кругу. Эхо-тест фазы 0 (`EchoTests`): `TerminalView`
    вне экрана, делегат замыкает `send` на `feed` — набранное `insertText("hello")` видно в
    буфере. Интеграционные (`TerminalBenchTests`, стенд): открыть сессию через
    `OpenSessionsModel` → состояние `.live` и в буфере появляется приглашение шелла; ввод
    `echo hi\r` через делегат → в буфере `hi`; SGR колесо вверх через делегат → `#{pane_in_mode}`
    = 1 на стенде (через `exec`), чип поднят; ввод `x` → `pane_in_mode` = 0, чип опущен;
    `kill` извне (`tmux kill-session` через exec) → `.ended`; `take` вторым UUID устройства
    (отдельный пул с другим `deviceID`) дважды за минуту → `.disconnectedByOther`.

### Чего этот план не делает

- Не обрабатывает фон, смену сети, восстановление открытых терминалов после перезапуска (план 7).
- Не делает экран настроек терминала (шрифт, тема, Option = Meta, bell): значения читаются из
  `UserDefaults` с умолчаниями, экран — план 7.
- Не делает своей панели над клавиатурой и своих биндингов: `TerminalAccessory` SwiftTerm.
- Не меняет ядро. Если окажется, что SwiftTerm шлёт колесо не так, как разбирает
  `MouseReport` (например, в URXVT-форме), — остановиться с `⚠️` в progress-логе: правка ядра —
  отдельный план.
- Не трогает libghostty.

## Context

- Спека: §3.2, §3.5, §5 (кэш открытых, лимит, `TerminalSurface`), §6, §6.1.
- Ядро после плана 3: `Terminal/TerminalSession.swift` (`start`, `input(_:)`,
  `send`, `cancelCopyMode`, `resize`, `detach`, `take`, `reconnect`, `state`),
  `Terminal/TerminalSurface.swift` (`feed`, `size`, `stateChanged`, `copyModeSuspected`),
  `Terminal/TerminalState.swift`, `Terminal/MouseReport.swift`, `Models/OpenSessionsRoster.swift`.
  Сигнатуры сверять с кодом: план 3 мог их уточнить
  (`docs/plans/completed/20261020-core-ui-support.md`).
- Приложение после плана 5: `App/State/OpenSessionsModel.swift` (`roster`, `selection`,
  `open(_:take:)`, `close`), `App/State/SessionActions.swift`,
  `App/UI/Root/RootView.swift` и `SessionPlaceholderView.swift` (заменяется на
  `TerminalScreen`), `App/State/TreeModel.swift` (снимок — проект сессии для «Создать заново»).
- SwiftTerm 1.99.0 (2026-10-08, манифест `swift-tools-version:6.2` → Xcode 26):
  `Sources/SwiftTerm/iOS/iOSTerminalView.swift` — `open class TerminalView: UIScrollView`,
  `init(frame:font:)`, `terminalDelegate`, `allowMouseReporting`, `optionAsMetaKey`, `font`,
  `inputAccessoryView` (по умолчанию `TerminalAccessory`), `bellStyle`;
  `Sources/SwiftTerm/Apple/AppleTerminalView.swift` — `nonisolated` `feed(byteArray:)`,
  `terminalDimensions` (`TerminalDimensions { cols, rows }`), `visibleRowsText(_:)`,
  `terminalStateSnapshot()`, `getBufferAsData()`; `getTerminal()` в 1.99.0 нет;
  `pressesBegan` пропускает клавиши с `.command`;
  `Sources/SwiftTerm/Apple/TerminalViewDelegate.swift` — `sizeChanged`, `setTerminalTitle`,
  `hostCurrentDirectoryUpdate`, `send`, `scrolled`, `requestOpenLink`, `bell`,
  `clipboardCopy`, `clipboardRead`, kitty-буфер, `iTermContent`, `rangeChanged`,
  `programStatusChanged`. Колесо пальцем — `forwardWheelDrag` → `terminal.sendEvent` →
  делегат `send`.
- Стенд: `host/tests/docker/` — sshd + tmux 3.4, заглушка `claude` (печатает аргументы и ждёт),
  `mouse on` ставит `attach`.

## Validation Commands

```
xcodegen generate
scripts/ios-test.sh
scripts/ios-test.sh --no-bench
scripts/ios-test.sh -only-testing:AppTests/TerminalBenchTests
swift test --package-path TmuxPadCore --skip IntegrationTests
```

Сборка без предупреждений в коде приложения.

## Testing Strategy

- Всё, что не требует глаз, — тестами решения 12: порядок байтов, размер, состояние,
  copy-mode на настоящем tmux, вытеснение, выбивание.
- Вёрстка, жесты, аппаратная клавиатура и ощущение «час подряд» проверяются руками
  (Post-Completion): симулятор не воспроизводит клавиатуру iPad и Stage Manager честно.

## Задачи

### Task 1: SwiftTerm в проекте, поверхность, эхо-тест

**Файлы:** `project.yml`, `App/Terminal/{SwiftTermSurface,TmuxTerminalView,TerminalDelegate,
InputPump}.swift` (create), `AppTests/{EchoTests,SwiftTermSurfaceTests,InputPumpTests}.swift`
(create).

- [x] `project.yml`: пакет `SwiftTerm` — `url: https://github.com/migueldeicaza/SwiftTerm`,
      `exactVersion: 1.99.0` (точная версия: поведение колеса — часть контракта §3.5, его не
      должно менять обновление); зависимость таргета `TmuxPad`. Сборка проходит.
- [x] `SwiftTermSurface` по решению 1, `InputPump` (поток ввода и потребитель) по решению 2,
      `TmuxTerminalView` по решению 5, `TerminalDelegate` по решению 6.
- [x] `EchoTests`, `SwiftTermSurfaceTests`, `InputPumpTests` по решению 12.
- [x] `scripts/ios-test.sh --no-bench` проходит.

### Task 2: открытые терминалы и экран терминала

**Файлы:** `App/State/OpenTerminal.swift` (create), `App/State/OpenSessionsModel.swift`,
`App/UI/Terminal/{TerminalScreen,TerminalContainerView,TerminalHeader}.swift` (create),
`App/UI/Root/RootView.swift`, `App/UI/Root/SessionPlaceholderView.swift` (delete),
`AppTests/OpenSessionsModelTests.swift`, `AppTests/TerminalBenchTests.swift` (create).

- [x] `OpenTerminal` по решению 3; `OpenSessionsModel` по решению 4.
- [x] `TerminalScreen`, `TerminalContainerView`, `TerminalHeader` по решению 8; `RootView`
      показывает `TerminalScreen` для выделения.
- [x] Тесты вытеснения в `OpenSessionsModelTests`; в `TerminalBenchTests` — «открытие даёт
      `.live` и приглашение», «ввод `echo hi`».
- [x] `scripts/ios-test.sh` проходит.

### Task 3: скролл, чип, плашки, меню, шорткаты, шрифт

**Файлы:** `App/UI/Terminal/{TerminalOverlay,ScrollChip,TerminalMenu}.swift` (create),
`App/State/TerminalAppearance.swift` (create), `App/Terminal/TmuxTerminalView.swift`,
`App/UI/Terminal/TerminalScreen.swift`, `App/TmuxPadApp.swift`,
`AppTests/TerminalBenchTests.swift`, `AppTests/TerminalAppearanceTests.swift` (create).

- [ ] Чип «Прокрутка ✕» по решению 8 и плашки по решению 9; блокировка ввода при плашке.
- [ ] Меню `[⋯]` по решению 10; «Создать заново» — `OpenTerminal.recreate()`.
- [ ] `TerminalAppearance` и pinch по решению 7; `TerminalAppearanceTests` — изменение размера
      доходит до всех открытых `TmuxTerminalView` и сохраняется в `UserDefaults` (тестовый
      `suiteName`).
- [ ] Шорткаты по решению 11 (без автотеста: проверка — Post-Completion).
- [ ] В `TerminalBenchTests` — колесо и чип, `kill` извне → `.ended`, двойной `take` чужим
      UUID → `.disconnectedByOther`.
- [ ] `scripts/ios-test.sh` проходит.

### Task 4: документация, полный прогон, завершение

**Файлы:** `CLAUDE.md`, `docs/tmuxpad-spec.md` (§11 — отметки фаз 0 и 4), `docs/plans/
20261020-app-terminal.md` (move).

- [ ] `CLAUDE.md`: раскладка `App/Terminal`, `App/UI/Terminal`; инварианты «ввод из SwiftTerm
      идёт в ядро только через `InputPump` → `TerminalSession.input`, не через `send`», «один
      `TmuxTerminalView` на открытый терминал, не пересоздаётся при переключении», «SwiftTerm
      закреплён точной версией: при обновлении перепроверить колесо и `MouseReport`».
- [ ] Спека §11: фаза 4 — отметить сделанное; фаза 0 — эхо-тест и PTY с `tmux attach` к
      тестовой сессии с resize. Расхождения со спекой — правкой спеки.
- [ ] Полный прогон Validation Commands; в progress-лог — число тестов.
- [ ] Move this plan to `docs/plans/completed/`; коммит.

## Post-Completion

Фаза 0 и «Готово» фазы 4 проверяются на iPad руками, против настоящего сервера с claude:

- Аппаратная клавиатура: Esc, Ctrl-комбинации (`Ctrl-C`, `Ctrl-R` в шелле), Option как Meta
  (`Option-B`/`Option-F` в шелле), `⌘N`/`⌘O`/`⌘1…9`/`⌘0` при фокусе в терминале не уходят в
  терминал.
- Экранная клавиатура и `TerminalAccessory`: Esc, залипающий Ctrl, Tab, стрелки.
- Скролл одним пальцем листает историю tmux; ввод после скролла печатается сразу и не
  теряется; измерить задержку первого символа после скролла (`copy-cancel` через exec) —
  записать в спеку §3.5, если больше ~150 мс.
- Выделение и копирование текста; `printf '\e]52;c;%s\a' "$(printf hi | base64)"` на сервере
  кладёт `hi` в буфер iPad.
- Поворот, Split View, Stage Manager — tmux перерисовывается под новый размер.
- Два клиента: Mac `tmux attach -t =NAME` и iPad — размер следует за тем, кто печатает; Mac
  `tmux attach -d -t =NAME` выбивает iPad — один раз переподключение молча, второй раз за
  минуту — плашка «Отключено другим клиентом».
- Фаза 0, зависший клиент: убить приложение на iPad с открытой сессией (сокет висит на
  сервере), печатать с Mac — размер окна не возвращается к iPad; открыть приложение снова —
  `attach` выкидывает только зависшего клиента этого iPad (`tmux list-clients` до и после),
  Mac остаётся подключён.
- Час работы в claude с аппаратной и экранной клавиатурой без помех — «Готово» фазы 4.
