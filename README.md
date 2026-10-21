# TmuxPad

iPad-клиент для Claude Code в tmux-сессиях на удалённых Linux-серверах. Приложение держит одно
SSH-соединение на сервер, показывает в сайдбаре дерево «сервер → проект → сессия» и открывает
сессии в терминале SwiftTerm. Агент живёт в tmux на сервере, поэтому сворачивание приложения,
блокировка экрана и смена сети его не прерывают: при возврате приложение тихо подключается
обратно. С той же сессией можно параллельно работать с Mac. Открытые сессии восстанавливаются
после перезапуска приложения.

В «Настройках» раздел «Терминал» задаёт шрифт, размер, тему, Option = Meta и звук. В разделе
«Ключи» есть переключатель «Требовать Face ID для ключей»: Face ID спрашивается перед первым
подключением после запуска и после возврата из фона.

Требования, архитектура и план — в спеке [`docs/tmuxpad-spec.md`](docs/tmuxpad-spec.md).

## Что нужно на сервере

- Linux и bash;
- tmux 3.1 или новее (`allow-passthrough` пишется в конфиг, только если tmux 3.3+);
- `claude` в PATH login-шелла: агент запускается в login-шелле tmux-сессии;
- coreutils `realpath`; `infocmp` желателен, без него `TERM` будет `xterm-256color`;
- вход по ключу `ecdsa-sha2-nistp256` (ключ из Secure Enclave) или `ssh-ed25519`.

## Подготовка сервера

### Из приложения

1. «Настройки» → «Ключи» → «Добавить» → «Создать». Ключ в Secure Enclave не покидает iPad; Ed25519 хранится
   в Keychain и не попадает в бэкапы.
2. На экране ключа нажмите «Скопировать команду» и выполните её на сервере: она добавит
   публичный ключ в `~/.ssh/authorized_keys`.
3. «Серверы» → «Добавить сервер»: адрес, пользователь, ключ, папка проектов (по умолчанию
   `~/projects`).
4. «Проверить подключение» один раз спросит, доверять ли отпечатку ключа сервера. Если ключ
   сервера потом сменится, подключение блокируется до «Сбросить отпечаток».
5. «Подготовить сервер» ставит host-скрипт, вызывает `setup` и показывает чеклист `doctor`.
6. «Передать токен Claude» записывает токен в `~/.tmuxpad/env` (права 0600). Токен уходит
   только через stdin и нигде не логируется.

При первом запуске онбординг проводит по тем же шагам.

### Вручную

Скрипт лежит в репозитории как [`host/tmuxpad-host.sh`](host/tmuxpad-host.sh), в приложение
встроена его копия. Установка:

```
cat host/tmuxpad-host.sh | ssh HOST 'mkdir -p ~/.local/bin && cat > ~/.local/bin/tmuxpad-host.sh && chmod +x ~/.local/bin/tmuxpad-host.sh'
ssh HOST '~/.local/bin/tmuxpad-host.sh setup'
```

Токен Claude, если не передавать его из приложения:

```
printf '%s\n' "$CLAUDE_CODE_OAUTH_TOKEN" | ssh HOST '~/.local/bin/tmuxpad-host.sh auth'
```

Что меняет `setup`:

- создаёт `~/.tmuxpad/` и папку проектов;
- добавляет в `~/.tmux.conf` помеченный блок с `set-clipboard on`, `history-limit 50000` и,
  начиная с tmux 3.3, `allow-passthrough on`; повторный запуск блок не дублирует. Если tmux-сервер
  уже запущен, эти опции ставятся ему сразу;
- глобальный `mouse` не включает: приложение ставит `mouse on` только своим сессиям, выделение
  мышью в остальных сессиях на Mac не ломается. `~/.profile`, `~/.claude/` и `known_hosts`
  не трогает.

Подкоманды скрипта, коды выхода и файлы состояния описаны в [`host/README.md`](host/README.md).

## Сборка

Нужны Mac, Xcode 26 и симулятор iPad с iOS 17+ (или iPad).

```
brew install xcodegen coreutils
xcodegen generate
open TmuxPad.xcodeproj
```

Настройки проекта задаёт `project.yml`. `TmuxPad.xcodeproj` генерируется из него и в git не
лежит, поэтому правьте `project.yml`, а не проект в Xcode. При первой сборке Xcode попросит
разрешить build-плагин SwiftTerm.

Чтобы поставить приложение на iPad, выберите команду подписи в Xcode (Signing & Capabilities)
или передайте её при сборке из командной строки:

```
xcodebuild build -project TmuxPad.xcodeproj -scheme TmuxPad -destination 'generic/platform=iOS' -skipPackagePluginValidation DEVELOPMENT_TEAM=<TEAM_ID>
```

С бесплатным Apple ID подпись действует 7 дней, потом приложение нужно переустановить из Xcode.
С Apple Developer Program сборку можно раздавать через TestFlight.

## Тесты

Ядро `TmuxPadCore` и host-скрипт тестируются и на Linux, и на Mac; приложение тестируется
только на Mac. Интеграционные тесты идут против Docker-контейнера с sshd и tmux, для них нужен
Docker (на Mac — Docker Desktop или OrbStack).

```
# host-скрипт
shellcheck -s bash host/tmuxpad-host.sh
host/tests/run.sh                                  # ubuntu:24.04, tmux 3.4
TMUXPAD_TEST_BASE=ubuntu:22.04 host/tests/run.sh   # tmux 3.2a

# ядро
swift test --package-path TmuxPadCore --skip IntegrationTests  # без Docker
TmuxPadCore/scripts/test.sh                                   # с контейнером

# приложение, в симуляторе iPad
scripts/ios-test.sh                          # все тесты, с контейнером
scripts/ios-test.sh --no-bench               # без Docker
scripts/ios-test.sh -only-testing:AppUITests # UI-смоук
```

`scripts/ios-test.sh` берёт первый доступный симулятор iPad; другой задаётся через
`TMUXPAD_SIM` (UDID или имя). Результаты — в `build/TestResults.xcresult`.

## Раскладка репозитория

| Путь | Что там |
|---|---|
| `App/` | приложение: `State/` (модели `@Observable`), `UI/` (SwiftUI), `Terminal/` (обвязка SwiftTerm), `Platform/` (Keychain, Secure Enclave, сеть) |
| `AppTests/`, `AppUITests/` | юнит- и интеграционные тесты приложения, UI-смоук |
| `TmuxPadCore/` | SwiftPM-пакет ядра без UIKit: SSH, пул соединений, `HostAPI`, терминальная сессия; см. [`TmuxPadCore/README.md`](TmuxPadCore/README.md) |
| `host/` | `tmuxpad-host.sh`, его тесты и Docker-стенд |
| `scripts/` | `ios-test.sh`, `make-icon.swift` (пересоздаёт иконку) |
| `docs/` | спека и планы разработки |
| `project.yml` | настройки Xcode-проекта для XcodeGen |

## Атрибуция

Модель работы и основа host-скрипта взяты из рецепта
[`remote-claude-session`](https://github.com/umputun/agterm/tree/master/cookbook/remote-claude-session)
проекта [agterm](https://github.com/umputun/agterm) (MIT). Совместимости с рецептом нет: у
TmuxPad свои пути (`~/.tmuxpad/`, `~/.local/bin/tmuxpad-host.sh`) и свои форматы.
