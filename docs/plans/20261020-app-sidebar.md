# Приложение, сайдбар: дерево Сервер → Проект → Сессия, мастера «Новая сессия» и «Подключиться», завершение

## Overview

Пятый план по спеке `docs/tmuxpad-spec.md`, фаза 3. Исполняется на Mac. Цель фазы: «весь
сценарий из запроса работает до момента "открыть терминал"». После плана сайдбар показывает
живое дерево всех серверов, мастера создают и выбирают сессии, kill работает с подтверждением,
а «открыть сессию» записывает её в `OpenSessionsModel` и выделяет; сам терминал в детали — план 6
(до него деталь показывает заглушку с именем сессии и состоянием).

Порядок: после планов 3 (`TreeRefresher`, `SessionTree`, `OpenSessionsRoster`,
`Validation.suggestedSessionName` в ядре) и 4 (`AppEnvironment`, `ServerStore`, настройки,
`ServerCheckView`).

### Решения, принятые в спеке (не переоткрывать)

- §3.1: `NavigationSplitView`, сайдбар скрывается (`⌘0`); `●` — открыта в приложении, `○` —
  существует; подпись `attached` при `otherClients > 0` — информационная; проекты без сессий
  скрыты, переключатель «Показывать все проекты» в меню сайдбара; недоступный сервер — строка
  с `⚠`, остальные работают; pull-to-refresh и автообновление ~10 с, пока приложение активно.
- §3.2: `[+]`/`⌘N` — мастер «Новая сессия»; `[⇄]`/`⌘O` — «Подключиться»; тап по сессии —
  открыть; контекст-меню проекта — «Новая сессия здесь»; контекст-меню сессии — Открыть ·
  Отключиться · Забрать (только при `attached`, с подтверждением) · Завершить (с
  подтверждением) · Скопировать `tmux attach`; свайп — Завершить с подтверждением.
- §3.3: сервер (пропуск при одном сервере или из контекст-меню) → проект (поиск) → имя
  (предзаполнено, пробелы → `-`, валидация вживую, конфликт → предложить подключиться) →
  `new NAME PROJECT` → открыть терминал.
- §3.4: сервер (если >1) → сессии, сгруппированные по проектам, с `attached` → тап → attach.
- §9: «Требуется подготовка» → кнопка «Подготовить»; «Нет проектов» → «В `<корень>` нет
  папок»; «Имя занято» → «Сессия `X` уже есть» [Подключиться] [Другое имя]; «Неверное имя» —
  подсветка и допустимые символы; офлайн — `⚠` и последний снимок серым со временем.
- §6.1: тап и мастер «Подключиться» делают обычный `attach`; «Забрать» — единственный путь к
  `take`.
- §5: лимит 8 открытых на приложение, вытесняются самые давно неактивные (`OpenSessionsRoster`).

### Решения исполнителя плана

1. **`TreeModel`** (`@MainActor @Observable final class`, `App/State/TreeModel.swift`) — тонкая
   обёртка над `TreeRefresher` ядра: `states: [UUID: ServerTreeState]`, `showEmptyProjects`
   (`AppEnvironment.defaults`, ключ `sidebar.showEmptyProjects`, по умолчанию `false`), `nodes(for
   serverID:) -> [ProjectNode]` через `SessionTree.build` с множеством открытых имён этого
   сервера из `OpenSessionsModel`. Подписка на `refresher.updates()` — одна `Task` на жизнь
   модели. `start()`/`stop()` вызывает `RootView` по `scenePhase == .active`/иное (полная
   обработка фона — план 7, здесь только опрос). `setServers` — при каждом изменении
   `ServerStore.servers` (`withObservationTracking` или `onChange` в `RootView`).
   `refresh(serverID:force:)`: pull-to-refresh и «Повторить» у офлайн-сервера — с `force: true`
   (ядро тогда зовёт `reconnectNow()`; тики опроса пул не дёргают, план 3, решение 9), после
   действий (new, kill) — без `force`.
2. **`OpenSessionsModel`** (`App/State/OpenSessionsModel.swift`) появляется в этом плане без
   терминала: `roster: OpenSessionsRoster`, `selection: OpenSessionKey?`, `open(_ key:, take:
   Bool = false)` (добавляет в ростер, выделяет; вытесненных просто убирает — в плане 6 они
   получат `detach()`), `close(_:)`, `isOpen(_:)`, `openNames(serverID:) -> Set<String>`.
   Параметр `take` в этом плане ведёт себя как обычное открытие: выполнять его нечем, пока нет
   терминала. План 6 меняет только внутренности `open`/`close`, а не вызывающих.
3. **Сайдбар — `List` с `Section` на сервер и `DisclosureGroup` на проект.** `OutlineGroup` не
   подходит: у узлов трёх уровней разные строки и меню. Раскрытость проектов — `@SceneStorage`
   по ключу `serverID/project`, по умолчанию раскрыты. Выделение — `List(selection:)` по
   `OpenSessionKey`; выбор строки сессии вызывает `open`. Строка сервера: метка, `⚠` и текст
   при `.offline` и кнопка «Повторить» (`refresh(serverID:force: true)`); при `.needsSetup` —
   причина («Требуется подготовка», «Подключение не проверено») и кнопка «Проверить»; при
   `ServerTreeState.attention` (`authFailed`, `hostKeyChanged`) — «Сервер не принял ключ» или
   «Ключ сервера изменился» и та же кнопка вместо «Повторить»: повтор тут не поможет (§9).
   «Проверить» открывает `ServerCheckView` из плана 4 sheet-ом (там «Доверять», сброс
   отпечатка, «Подготовить»); после закрытия sheet — `refresher.markPrepared(serverID)`, чтобы
   дерево перечитало сервер. Индикатор при `refreshing`; при офлайне и наличии снимка проекты
   и сессии рисуются `.foregroundStyle(.secondary)` с подписью «по состоянию на HH:mm».
   Строка сессии: `●`/`○`, имя, справа подпись `attached` (если `otherClients > 0`) и
   «N мин назад» (`RelativeDateTimeFormatter`, `.abbreviated`, русская локаль).
4. **Действия над сессией — `SessionActions`** (`App/State/SessionActions.swift`,
   `@MainActor`), чтобы контекст-меню, свайп и (в плане 6) меню `[⋯]` над терминалом вызывали
   одно и то же: `open(key)`, `take(key)` (подтверждение — в UI, здесь `open(key, take:
   true)`), `kill(key) async throws` (`connection.api.kill`, затем `openSessions.close(key)`,
   `tree.refresh(serverID:)`), `detach(key)` (`openSessions.close`), `attachCommand(key) ->
   String` для копирования: `tmux attach -t '=NAME'` — для ручного входа с Mac, без `-d`.
5. **Мастера — sheet с `NavigationStack(path:)`** и чистой машиной шагов, которую можно
   тестировать без UI: `NewSessionFlow` (`struct`, `App/State/NewSessionFlow.swift`): поля
   `serverID?`, `project?`, `name`; `steps` вычисляются из числа серверов и предзаполнения;
   `nameIssue: NameIssue?` (`.empty`, `.invalid`, `.exists`) по `Validation.isValidSessionName`
   и снимку сервера; `canCreate`. Имя предзаполняется `Validation.suggestedSessionName(from:
   project)` при выборе проекта, если пользователь ещё не правил поле. Ввод пробела в поле
   сразу заменяется на `-` (`onChange`). `AttachFlow` — аналогично: `serverID?`, группы из
   `SessionTree.byActivity`.
6. **Создание сессии.** «Создать» → `api.new(session:project:)`: успех → `tree.refresh`,
   `openSessions.open(key)`, sheet закрывается; `HostError.sessionExists` (гонка: снимок
   устарел) → тот же экран конфликта, что при проверке по снимку: «Сессия `X` уже есть» с
   кнопками «Подключиться» (открыть существующую) и «Другое имя» (фокус на поле);
   `HostError.badRequest` → текст под полем; прочие ошибки — алерт с `ErrorText.userText`.
   Пока запрос идёт, кнопка заменена индикатором, повторное нажатие невозможно.
7. **Пустые состояния.** Нет серверов — сайдбар показывает «Добавьте сервер в настройках» с
   кнопкой. Сервер без проектов — в мастере «В `<projectsRoot>` нет папок» (из
   `ServerConfig.projectsRoot`). Сервер в `.needsSetup` или `.offline` в мастерах показывается
   недоступным с причиной.
8. **Горячие клавиши** — `.keyboardShortcut` на кнопках тулбара (`⌘N`, `⌘O`); `⌘0` —
   переключение `columnVisibility` (`.all` ↔ `.detailOnly`) кнопкой тулбара с этим шорткатом.
   `⌘1…⌘9` и `⌘[`/`⌘]` — план 6 (переключение открытых терминалов).
9. **Деталь до плана 6** — `SessionPlaceholderView`: «server › project › session» и строка
   «Терминал появится в плане 6»; это позволяет проверить выделение и открытие руками.
10. **Тесты.** Юнит (симулятор, без стенда): `NewSessionFlowTests` (шаги при одном и двух
    серверах, предзаполнение из контекст-меню, подсказка имени из проекта с точкой, пробел →
    `-`, `nameIssue` для пустого, неверного и занятого имени), `AttachFlowTests`,
    `OpenSessionsModelTests` (открытие девятой вытесняет, `openNames`), `SessionActionsTests`
    (`attachCommand`). Интеграционные (`SidebarBenchTests`, стенд): `TreeModel` получает
    `.online` и проекты стенда; `NewSessionFlow` + создание → сессия видна в `nodes` после
    `refresh`; повторное создание того же имени → конфликт; `kill` → сессия пропадает; сервер
    с неверным портом → `.offline`, второй (стенд) остаётся `.online`.

### Чего этот план не делает

- Не открывает PTY и не рисует терминал; `take` только помечается (план 6).
- Не обрабатывает фон, смену сети, восстановление открытых сессий (план 7).
- Не меняет ядро и host-скрипт. Нехватку в ядре — `⚠️` в progress-лог и остановка.
- Не делает сортировку «нуждается во внимании» и статусы агента (фаза 7, v1.1).

## Context

- Спека: §3.1–§3.4, §5 (`TreeModel`, `OpenSessionsModel`), §6.1, §9.
- Ядро после плана 3: `Pool/TreeRefresher.swift` (`init(pool:bootstrap:auth:interval:)`,
  `setServers`, `start`, `stop`, `refresh(_:force:)`, `markPrepared`, `updates()`, `ServerTreeState`),
  `Models/SessionTree.swift` (`build`, `byActivity`, `ProjectNode`, `SessionNode`),
  `Models/OpenSessionsRoster.swift`, `Models/Validation.swift` (`suggestedSessionName`,
  `isValidSessionName`), `Host/HostAPI.swift` (`new`, `kill`), `Host/HostError.swift`.
  Точные сигнатуры — по коду: план 3 мог их уточнить, его решения записаны в
  `docs/plans/completed/20261020-core-ui-support.md`.
- Приложение после плана 4: `App/AppEnvironment.swift` (`pool`, `bootstrap`, `auth(for:)`,
  `log`), `App/State/ServerStore.swift`, `App/UI/Root/RootView.swift` (сайдбар-заглушка),
  `App/UI/Settings/ServerCheckView.swift`, `App/UI/ErrorText.swift`, `AppTests/Support/
  Bench.swift`, `scripts/ios-test.sh`.
- Стенд: проекты и заглушка `claude` на стенде есть (`host/tests/docker/`); сессии,
  созданные тестами, убиваются сбросом состояния перед каждым тестом.

## Validation Commands

```
xcodegen generate
scripts/ios-test.sh
scripts/ios-test.sh --no-bench
scripts/ios-test.sh -only-testing:AppTests/SidebarBenchTests
swift test --package-path TmuxPadCore --skip IntegrationTests
```

Сборка без предупреждений в коде приложения.

## Testing Strategy

- Логика мастеров и действий — в `struct`/`@MainActor`-классах без SwiftUI, тесты без UI
  (решение 10). Вёрстка проверяется сборкой и ручным проходом (Post-Completion); UI-смоук — в
  плане 7.
- Интеграционные тесты против стенда используют настоящий `TreeRefresher` и `ConnectionPool`
  с интервалом опроса 200 мс, все ожидания — с таймаутом 10 с.

## Задачи

### Task 1: `TreeModel` и `OpenSessionsModel`

**Файлы:** `App/State/TreeModel.swift`, `App/State/OpenSessionsModel.swift` (create),
`App/AppEnvironment.swift`, `App/UI/Root/RootView.swift`,
`AppTests/{OpenSessionsModelTests,SidebarBenchTests}.swift` (create).

- [x] `AppEnvironment`: `refresher: TreeRefresher` (`auth` — `environment.auth(for:)`,
      `bootstrap` — тот же `HostBootstrap`), модели `tree: TreeModel`, `openSessions:
      OpenSessionsModel`.
- [x] `TreeModel` по решению 1; `OpenSessionsModel` по решению 2.
- [x] `RootView`: `start()`/`stop()` по `scenePhase`; `setServers` при изменении списка
      серверов.
- [x] `OpenSessionsModelTests`; в `SidebarBenchTests` — тесты «стенд онлайн с проектами» и
      «неверный порт офлайн, стенд онлайн».
- [x] `scripts/ios-test.sh` проходит.

### Task 2: сайдбар

**Файлы:** `App/UI/Sidebar/{SidebarView,ServerRow,ProjectRow,SessionRow}.swift` (create),
`App/State/SessionActions.swift` (create), `App/UI/Root/RootView.swift`,
`App/UI/Root/SessionPlaceholderView.swift` (create), `AppTests/SessionActionsTests.swift`
(create).

- [ ] `SidebarView` по решению 3: секции серверов в порядке `ServerStore`, `.refreshable` →
      `tree.refresh(force: true)` всех; меню сайдбара (кнопка `…` в тулбаре) с `Toggle` «Показывать все
      проекты»; пустое состояние по решению 7.
- [ ] `ServerRow`, `ProjectRow`, `SessionRow` по решению 3; контекст-меню проекта — «Новая
      сессия здесь»; контекст-меню сессии — по §3.2 через `SessionActions` (решение 4);
      `.swipeActions` — «Завершить» с `role: .destructive`; подтверждения — `
      .confirmationDialog` с именем сессии («Завершить сессию `X`? Процессы в ней будут
      убиты.», «Забрать сессию `X`? Другие клиенты будут отключены.»).
- [ ] `SessionActions` по решению 4; «Скопировать `tmux attach`» кладёт строку в
      `UIPasteboard`.
- [ ] `RootView`: деталь — `SessionPlaceholderView` для `openSessions.selection` (решение 9),
      иначе «Выберите сессию»; кнопка `⌘0` по решению 8.
- [ ] `SessionActionsTests`; тест `kill` в `SidebarBenchTests`.
- [ ] `scripts/ios-test.sh` проходит.

### Task 3: мастер «Новая сессия»

**Файлы:** `App/State/NewSessionFlow.swift` (create), `App/UI/Wizards/{NewSessionWizard,
ServerPickStep,ProjectPickStep,NameStep}.swift` (create), `App/UI/Sidebar/SidebarView.swift`,
`AppTests/NewSessionFlowTests.swift` (create), `AppTests/SidebarBenchTests.swift`.

- [ ] `NewSessionFlow` по решению 5; создание и обработка ошибок — по решению 6 (метод
      `create(using:) async -> CreateOutcome` с `.created(OpenSessionKey)`, `.conflict`,
      `.invalid(String)`, `.failed(String)`).
- [ ] Шаги мастера: сервер (список с состоянием доступности, недоступные — неактивны с
      причиной), проект (`.searchable`, пустое состояние по решению 7), имя (`TextField` с
      автофокусом, без автокоррекции и автозаглавных, подсказка «Допустимы латинские буквы,
      цифры, `_` и `-`, до 64 символов» под полем при `invalid`, экран конфликта по решению 6).
- [ ] Вызовы: `[+]` и `⌘N` в тулбаре сайдбара; «Новая сессия здесь» — с предзаполненными
      сервером и проектом (шаги пропускаются).
- [ ] `NewSessionFlowTests`; в `SidebarBenchTests` — «создание видно в дереве» и «повторное
      имя — конфликт».
- [ ] `scripts/ios-test.sh` проходит.

### Task 4: мастер «Подключиться»

**Файлы:** `App/State/AttachFlow.swift` (create), `App/UI/Wizards/AttachWizard.swift` (create),
`App/UI/Sidebar/SidebarView.swift`, `AppTests/AttachFlowTests.swift` (create).

- [ ] `AttachFlow` по решению 5; шаг сервера пропускается при одном сервере.
- [ ] `AttachWizard`: секции по проектам в порядке `byActivity`, строка — имя, `attached`,
      «N мин назад»; тап → `openSessions.open(key)` и закрытие sheet. Пусто — «На сервере нет
      сессий» с кнопкой «Создать» (переход в мастер «Новая сессия» с выбранным сервером).
- [ ] Вызовы: `[⇄]` и `⌘O`.
- [ ] `AttachFlowTests`; `scripts/ios-test.sh` проходит.

### Task 5: документация, полный прогон, завершение

**Файлы:** `CLAUDE.md`, `docs/tmuxpad-spec.md` (§11 — отметки фазы 3), `docs/plans/
20261020-app-sidebar.md` (move).

- [ ] `CLAUDE.md`: раскладка `App/UI/Sidebar`, `App/UI/Wizards`, `App/State`; инвариант
      «действия над сессией — только через `SessionActions`».
- [ ] Спека §11: отметить пункты фазы 3; расхождения поведения со спекой (если были) — правкой
      спеки в этом же коммите.
- [ ] Полный прогон Validation Commands; в progress-лог — число тестов.
- [ ] Move this plan to `docs/plans/completed/`; коммит.

## Post-Completion

- В симуляторе против стенда (`host/tests/bench.sh up`, сервер `127.0.0.1:<порт>`, ключ стенда
  импортировать через «Импортировать»): создать сессию мастером, увидеть её в дереве, открыть
  (заглушка), завершить свайпом, «Показывать все проекты» показывает пустые проекты.
- Остановить контейнер стенда — сервер становится `⚠` с последним снимком серым, второй сервер
  работает; запустить — через ~10 с снова онлайн.
- На iPad против настоящего сервера — то же, плюс `attached` появляется, когда к сессии
  подключён `tmux attach` с Mac.
