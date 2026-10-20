# tmuxpad-host.sh

Серверная половина TmuxPad. Скрипт лежит на сервере в `~/.local/bin/tmuxpad-host.sh`, вся
логика tmux живёт в нём; приложение вызывает подкоманды через ssh exec-каналы. Контракт —
§7 `docs/tmuxpad-spec.md`.

## Установка

Приложение ставит скрипт одной exec-командой, сам скрипт идёт в stdin, затем вызывает `setup`:

```
cat host/tmuxpad-host.sh | ssh HOST 'mkdir -p ~/.local/bin && cat > ~/.local/bin/tmuxpad-host.sh && chmod +x ~/.local/bin/tmuxpad-host.sh'
ssh HOST '~/.local/bin/tmuxpad-host.sh setup'
```

При каждом подключении приложение вызывает `version` и предлагает обновить скрипт, если
версия в бандле новее.

Форма вызова подкоманд (§5 спеки):

```
env TMUXPAD_CLIENT=<uuid> TMUXPAD_PROJECTS=<root> TMUXPAD_CMD=<cmd> "$HOME"/.local/bin/tmuxpad-host.sh <cmd> [args]
```

## Подкоманды и коды выхода

| Подкоманда | Что делает | Коды выхода |
|---|---|---|
| `version` | печатает `tmuxpad-host 1` | 0 |
| `list` | сессии и проекты, TSV `V 1` | 0; 2 — корня проектов нет |
| `new NAME PROJECT` | tmux-сессия в папке проекта, агент через `send-keys`; stdout пустой | 0; 2 — неверное имя, проект или окружение; 3 — сессия уже есть; 1 — ошибка tmux |
| `attach NAME` | выкидывает своих зависших клиентов, `exec tmux attach-session` без `-d` | 2 — неверное имя или нет `TMUXPAD_CLIENT`; 4 — сессии нет |
| `take NAME` | то же с `-d`: выкидывает всех (кнопка «Забрать») | как у `attach` |
| `copy-cancel NAME` | `send-keys -X cancel`, выход из copy-mode | 0, в том числе вне режима; 2 — неверное имя |
| `kill NAME` | убивает сессию и `NAME.claude` | 0, в том числе если сессии нет; 2 — неверное имя |
| `setup` | `~/.tmuxpad/`, корень проектов, блок в `~/.tmux.conf`; идемпотентно; в конце `doctor` | как у `doctor` |
| `doctor` | проверки сервера | 0; 1 — есть хоть один `fail` |
| `auth` | токен Claude из stdin в `~/.tmuxpad/env` (0600) | 0; 2 — нет годного токена |

Неизвестная подкоманда и плохой `TMUXPAD_CLIENT` — код 2.

Имена: сессия `^[A-Za-z0-9_-]{1,64}$`, проект `^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$`.

## Переменные

- `TMUXPAD_CLIENT` — UUID устройства. Обязателен для `attach` и `take`; для `list`
  необязателен, без него все клиенты считаются чужими.
- `TMUXPAD_PROJECTS` — корень проектов, по умолчанию `~/projects`. `~` и относительный
  путь считаются от `$HOME`, путь нормализуется `realpath`.
- `TMUXPAD_CMD` — команда агента, по умолчанию `claude`. Флаги `-n NAME`, `--session-id`,
  `--resume` добавляются, только если basename первого слова — `claude`; другая команда
  запускается как есть.

## Формат `list`

```
V	1
S	<name>	<others>	<project>	<activity_epoch>
P	<project>	<abs_path>
```

`S` — сессии, у которых `session_path` лежит прямо в корне проектов, отсортированы по
имени. `others` — число клиентов сессии без метки текущего `TMUXPAD_CLIENT`. `P` — каталоги
корня с валидным именем, по алфавиту.

## Формат `doctor`

TSV `ok|warn|fail<TAB>KEY<TAB>MESSAGE`, ключи по порядку: `tmux` (≥ 3.1), `claude` (в PATH
login-шелла), `claude_name` (поддержка `--name`, иначе `warn`), `projects`, `script`.

## Файлы состояния

- `~/.tmuxpad/env` — `export CLAUDE_CODE_OAUTH_TOKEN='…'`, 0600; пишет `auth`, сорсит
  шелл перед запуском агента.
- `~/.tmuxpad/clients/<pid>` — UUID устройства, к которому относится tmux-клиент с этим
  PID. Пишет `attach`; `list` и `attach` удаляют файлы ушедших клиентов.
- `~/.tmuxpad/NAME.claude` — `<uuid>\t<project>`, UUID разговора Claude для `--resume`
  после ребута; удаляет `kill`.

## Требования к серверу

Linux, bash, tmux ≥ 3.1 (`allow-passthrough` пишется в конфиг только от 3.3), coreutils
`realpath`, `infocmp` (без него `TERM` падает на `xterm-256color`), Claude Code в PATH
login-шелла.

## Тесты

Интеграционные, через ssh к контейнеру с sshd и tmux (`host/tests/docker/`), той же
exec-строкой, что у приложения. Нужны docker и shellcheck.

```
shellcheck -s bash host/tmuxpad-host.sh host/tests/run.sh host/tests/lib.sh host/tests/docker/entrypoint.sh host/tests/docker/claude host/tests/docker/claude-old host/tests/cases/*.sh
host/tests/run.sh                                  # ubuntu:24.04, tmux 3.4
TMUXPAD_TEST_BASE=ubuntu:22.04 host/tests/run.sh   # tmux 3.2a
host/tests/run.sh -k test_list_others              # один тест, по подстроке имени
```

## Атрибуция

Основа — `agt-remote-host.sh` из рецепта `remote-claude-session` проекта agterm
(MIT, https://github.com/umputun/agterm/tree/master/cookbook/remote-claude-session).
