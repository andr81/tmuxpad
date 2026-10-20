# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Состояние репозитория

Кода пока нет: в репозитории только спецификация `docs/tmuxpad-spec.md`. Это источник правды по требованиям, архитектуре и плану (фазы 0–7, §11). Команд сборки, линта и тестов ещё нет. Когда появятся `project.yml` (XcodeGen), Xcode-проект и host-скрипт, добавь сюда реальные команды, в том числе запуск одного теста. Не выдумывай их заранее.

Решения, которые меняют поведение, сначала вносятся в спеку, потом в код.

## Что строим

TmuxPad — iPad-клиент (iPadOS 17+, Swift 6, SwiftUI) для работы с Claude Code в tmux-сессиях на удалённых Linux-серверах. Модель взята из рецепта `remote-claude-session` из agterm, но совместимость с ним не нужна: свои пути (`~/.tmuxpad/`, `~/.local/bin/tmuxpad-host.sh`) и свои форматы.

Две половины, которые меняются вместе:

- **Приложение**: SwiftTerm (терминал), Citadel поверх swift-nio-ssh (SSH), ключи в Secure Enclave P-256 или Ed25519 в Keychain. Слои — UI / State (`@Observable`) / Core, раскладка в §5 спеки. Core — отдельный SwiftPM-пакет `TmuxPadCore` без UIKit/SwiftUI, собирается и тестируется на Linux против Docker-стенда (§5.2); всё платформенное (Keychain, Secure Enclave, SwiftData, `NWPathMonitor`) — за протоколами, реализации в приложении.
- **Host-скрипт `tmuxpad-host.sh`** (bash, встроен в бандл, ставится на сервер через stdin). Вся логика tmux живёт в нём; приложение вызывает подкоманды (`version`, `list`, `new`, `attach`, `take`, `copy-cancel`, `kill`, `setup`, `doctor`, `auth`) через exec-каналы. Контракт — §7: формат `list` (TSV с заголовком `V 1`), коды выхода (`new` → 3, если сессия есть; `attach` → 4, если нет). Меняешь формат или коды — меняй парсер в `HostAPI` и версию скрипта.

## Инварианты, которые легко сломать

- **Одно SSH-соединение на сервер.** Внутри PTY-каналы терминалов и exec-каналы. sshd по умолчанию даёт 10 сессий на соединение (`MaxSessions`), поэтому не больше 8 PTY и 2 одновременных exec на сервер.
- **Keepalive — прикладной exec-пинг `true`.** В swift-nio-ssh/Citadel встроенного keepalive нет.
- **`attach` без `-d`.** Приложение выкидывает только собственных зависших клиентов (`detach-client` по файлам `~/.tmuxpad/clients/<pid>` с тем же `TMUXPAD_CLIENT`); чужих выкидывает только `take` по явной кнопке «Забрать» (§6.1). Размер окна решает `window-size latest`, отсюда порог tmux ≥ 3.1. `list` отдаёт число чужих (`others`), а не `session_attached`.
- **Ввод в copy-mode tmux глотается.** Перед первым вводом после скролла приложение вызывает `copy-cancel NAME` через exec и ждёт его (§3.5). Биндинги tmux и глобальный `mouse on` в `~/.tmux.conf` не трогаем: `mouse` ставится на сессию в `new`/`attach`.
- **Таргеты tmux в скрипте**: для pane/окна (`send-keys -X`, `set -w`) — `=NAME:`, голый `=NAME` даёт `can't find pane`; для session-команд — `=NAME`.
- **Агент запускается через `send-keys` во внутренний шелл tmux-сессии**, а не как её команда: выход из claude не должен убивать сессию.
- **Имя Claude-сессии = имя tmux-сессии** (`claude -n NAME --session-id <uuid>`); после ребута сервера — `--resume <uuid>`, UUID в `~/.tmuxpad/NAME.claude`.
- **Валидация имён** и в приложении, и в скрипте: сессия `^[A-Za-z0-9_-]{1,64}$`, проект `^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$`. В exec-строки ничего не подставляется без экранирования. Токен Claude передаётся только через stdin.
- **Терминал — за протоколом `TerminalSurface`**, чтобы SwiftTerm можно было заменить на libghostty.
- iPadOS рвёт сокеты в фоне; устойчивость даёт tmux, приложение переподключается по `scenePhase` и `NWPathMonitor` (§6).

## Тесты (план)

Swift Testing / XCTest; интеграционные — против Docker-контейнера с sshd + tmux; shellcheck на host-скрипт.
