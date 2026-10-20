# Host-скрипт `tmuxpad-host.sh` и Docker-стенд интеграционных тестов

## Overview

Первый план по спеке `docs/tmuxpad-spec.md`. Из всего проекта только серверная половина
исполняется на этом Linux-хосте: Swift и Xcode здесь нет, зато есть docker 29.1.3 (aarch64),
shellcheck, tmux 3.4 и sshd. Поэтому план закрывает §7 спеки целиком — скрипт
`tmuxpad-host.sh` со всеми подкомандами — и Docker-стенд, на котором его контракт проверяется
так же, как его будет вызывать приложение: по ssh, exec-строкой вида
`env TMUXPAD_… "$HOME"/.local/bin/tmuxpad-host.sh <cmd>`, с PTY там, где нужен клиент tmux.
Следующий план — пакет ядра `TmuxPadCore` (§5.2 спеки), тоже на этом хосте, с тестами против
стенда из этого плана; приложение поверх ядра пойдёт планом на Mac. Оба опираются на контракт
отсюда: формат `list`, коды выхода, файлы состояния.

Основа — `agt-remote-host.sh` из рецепта `remote-claude-session` (MIT, umputun/agterm);
берём версию с GitHub (329 строк): локальная копия `~/.local/bin/agt-remote-host.sh` на этом
хосте старее (296 строк, без `realpath`-нормализации и без фильтра «path прямо в корне»).
Переносится стиль (`set -u`, функции-подкоманды, `case` в конце, `valid_name`/`valid_project`,
`auth`, идемпотентный блок `setup`), но не пути, не форматы и не `-d`.

### Решения, принятые в спеке 2026-10-20 (не переоткрывать)

- `attach` **без `-d`**: размер окна решает `window-size latest` (по умолчанию с tmux 3.1,
  проверено на 3.4); скрипт выкидывает только зависших клиентов этого же устройства, чужих
  выкидывает только `take` (§6.1).
- Ввод в copy-mode tmux глотается (проверено): подкоманда `copy-cancel NAME` делает
  `send-keys -X cancel`, биндинги tmux не трогаем (§3.5).
- Порог tmux **3.1**; `allow-passthrough` ставится только при версии ≥ 3.3.
- `mouse on` — session-опция, ставится в `new` и `attach` на конкретную сессию; глобальный
  `~/.tmux.conf` её не включает; `~/.profile` не трогаем.
- `~/.tmuxpad/NAME.claude` хранит `<uuid>\t<project>`; другой проект или отсутствие транскрипта
  → новый UUID.

### Решения исполнителя плана

1. **Раскладка**: `host/tmuxpad-host.sh`, тесты в `host/tests/`. Xcode-проект позже
   подключит скрипт в бандл через XcodeGen (`project.yml`), копировать его в `Resources/`
   сейчас некуда — проекта нет.
2. **Тест-раннер — свой на bash**, без bats (не установлен) и без `sudo apt`: один файл
   `host/tests/run.sh` и библиотека `host/tests/lib.sh` с функциями `test_*`, автообнаружение
   через `declare -F`. Около сорока проверок, зависимость ради них не нужна.
3. **Тесты ходят по настоящему sshd в контейнере**, а не через `docker exec`: семантика
   `~/.tmuxpad/clients/$$` держится на `exec` внутри сеанса с pty, а стенд должен повторять
   путь приложения (§5 «Форма exec-строк»). Клиент tmux в тестах — фоновый `ssh -tt -n`.
4. **Заглушка `claude`** в образе: `/usr/local/bin/claude` пишет `pwd`, аргументы и наличие
   `CLAUDE_CODE_OAUTH_TOKEN` в `~/claude-args.log` и делает `exec sleep infinity`;
   `--help` печатает строку с `--name`, `--version` → `2.1.0 (stub)`. Вторая заглушка
   `claude-old` — то же без `--name` в `--help`, для ветки «старый Claude Code»; в образе
   есть симлинк `/opt/claude-old/bin/claude` на неё, и тесты зовут её этим путём — по
   решению 5 basename должен быть `claude`, иначе флаги не добавляются.
5. **Флаги `-n`/`--session-id`/`--resume` добавляются, только если первое слово
   `TMUXPAD_CMD` — `claude`** (по basename). Иная команда запуска идёт как есть, файл
   `NAME.claude` не создаётся. Проверка поддержки `-n`: `bash -lc '<cmd> --help' | grep -q
   -- --name` при каждом `new`; `doctor` сообщает то же как `warn`.
6. **`TMUXPAD_CLIENT` обязателен для `attach` и `take`** (без него нельзя пометить клиента),
   для `list` необязателен: без него все клиенты считаются чужими.
7. **Детерминированный вывод**: `S`-строки `list` отсортированы по имени, `P` — по имени
   (порядок глоба). `doctor` — TSV `ok|warn|fail\t<key>\t<message>`, код выхода 1 при любом
   `fail`. `new` на stdout ничего не печатает: контракт — состояние на диске и код выхода.
8. **Коды выхода**: 2 — неверные аргументы/имена/окружение; 3 — `new`, сессия уже есть;
   4 — `attach`/`take`, сессии нет; `kill` несуществующей сессии и `copy-cancel` вне режима —
   0 (идемпотентность); прочие ошибки tmux — 1.
9. **Поиск транскрипта глобом** `"$HOME"/.claude/projects/*/"$uuid".jsonl`, как в рецепте:
   на 2.1.304 проверено, что `--resume <uuid>` находит транскрипт из любого каталога.
   Кодирование каталога (`/` и `.` → `-`) в скрипте не нужно, в тесте используется только
   чтобы положить файл туда, куда положил бы Claude Code.
10. **Матрица**: тесты гоняются на `ubuntu:24.04` (tmux 3.4) по умолчанию и на
    `ubuntu:22.04` (tmux 3.2a) через `TMUXPAD_TEST_BASE` — это нижняя граница по спеке
    (3.1) среди живых LTS, на ней `allow-passthrough` должен **не** попадать в конфиг.

### Чего этот план не делает

- Ни строки Swift: приложение, `HostAPI`, `HostBootstrap` — следующие планы на Mac.
- Нет `status`, хуков в `~/.claude/settings.json`, `clone`, `hooks`, `known_hosts`,
  проброса ssh-agent (§10 спеки, бэклог).
- Нет установки на реальный сервер — это Post-Completion.
- Не трогает `~/.profile`, не ставит глобальный `mouse on`, не меняет sshd.
- Не оптимизирует `list` под большое число сессий: один `list-sessions` и один
  `list-clients`, этого достаточно.

## Context

- Спека: `docs/tmuxpad-spec.md` §5 «Форма exec-строк» (строки ~206–208), §6.1 (~270–284),
  §7 целиком (~288–370): таблица подкоманд, шаги `attach`, формат `list` `V 1`, шаги `new`,
  таблица флагов claude, `setup`, требования к серверу. `CLAUDE.md` — инварианты.
- Рецепт: `https://raw.githubusercontent.com/umputun/agterm/master/cookbook/remote-claude-session/agt-remote-host.sh`
  (скачать в scratchpad, в репозиторий не класть). Что берём почти дословно: `valid_name`,
  `valid_project`, нормализация `PROJECTS` (`~`, относительный путь → `$HOME/`, срез `/`),
  `infocmp` fallback для `TERM`, `send-keys` с `sh -c '[ -f env ] && . env; exec …'`,
  `end_newline` и помеченный блок в `~/.tmux.conf`, `auth` целиком (umask 077, tmp + mv,
  regex токена `^[A-Za-z0-9_-]+$`). Атрибуция — комментарий в шапке скрипта.
- Проверено на этом хосте (tmux 3.4):
  - `tmux list-clients -t =NAME -F '#{client_pid}\t#{client_tty}'` отдаёт PID процесса
    клиента и его tty; после `exec tmux attach-session` PID клиента = `$$` скрипта;
    `tmux detach-client -t <tty>` выкидывает ровно этого клиента, второй остаётся.
  - `send-keys -t '=NAME:' -X cancel` выводит pane из copy-mode; с таргетом `=NAME` (без
    двоеточия) — `can't find pane`. Вне режима — stderr `not in a mode`, код 1.
  - `mouse` — session-опция (`tmux set -t =NAME: mouse on`; с `-t =NAME` без двоеточия — `no such session`, у `set` таргет — pane), `window-size` —
    window-опция, по умолчанию `latest`.
  - Нажатие печатной клавиши в copy-mode не выходит из него (`pane_in_mode` остаётся 1).
- Проверено на Claude Code 2.1.304: флаги `-n, --name <name>`, `--session-id <uuid>`,
  `-r, --resume [value]` есть; каталог транскриптов `~/.claude/projects/<путь с / и . → ->/`;
  `--resume <uuid>` из другого каталога работает; занятый `--session-id` ошибки не даёт.
- Инструменты хоста: `docker` 29.1.3 (aarch64, образы `ubuntu:*` мультиарх), `shellcheck`,
  `ssh`/`ssh-keygen`, `script`, `timeout`. Нет: `bats`, `swift`. `sudo` есть, но план им не
  пользуется.
- `tmux -V` печатает `tmux 3.4`, `tmux 3.2a`, бывает `tmux next-3.5`; парсить регулярным
  выражением `([0-9]+)\.([0-9]+)`.
- Репозиторий пустой: `CLAUDE.md`, `docs/tmuxpad-spec.md`, этот план. `.gitignore` нет.

## Validation Commands

```
shellcheck -s bash host/tmuxpad-host.sh host/tests/run.sh host/tests/lib.sh host/tests/docker/entrypoint.sh host/tests/docker/claude host/tests/docker/claude-old host/tests/cases/*.sh
host/tests/run.sh                                  # ubuntu:24.04, tmux 3.4
TMUXPAD_TEST_BASE=ubuntu:22.04 host/tests/run.sh   # tmux 3.2a
host/tests/run.sh -k test_list_others              # один тест (подстрока имени)
```

Прогон стенда — в foreground, `timeout: 600000`; первый прогон тянет образ и ставит пакеты
(минуты), дальше кэш. Контейнер убирается `trap` в `run.sh` даже при падении теста.

## Testing Strategy

- Все проверки — интеграционные, через ssh к контейнеру, той же exec-строкой, что у
  приложения; юнит-тестов для bash отдельно нет: функции валидации проверяются через коды
  выхода подкоманд.
- Перед каждым тестом `reset`: `tmux kill-server`, `rm -rf ~/.tmuxpad ~/.claude ~/claude-args.log
  ~/.tmux.conf`, пересоздание `~/projects/{api,web,my.app}` и файла-не-каталога
  `~/projects/README.md` (не должен стать проектом). Каждый тест независим.
- Фоновые клиенты tmux — `ssh -tt -n … attach NAME` с ожиданием через опрос
  `tmux list-clients` (до 5 с); все ssh-вызовы под `timeout 20`, фоновые клиенты
  убиваются в `reset` и в `trap`.
- Заглушка `claude` фиксирует аргументы — так проверяются ветки `-n`/`--session-id`/
  `--resume` и сорсинг `~/.tmuxpad/env` без настоящего Claude Code.
- Один и тот же набор тестов на двух базовых образах; различия (`allow-passthrough`)
  ветвятся по `tmux -V` внутри теста.

## Задачи

### Task 1: каркас скрипта, Docker-стенд и тест-раннер

**Файлы:** `host/tmuxpad-host.sh` (create), `host/tests/run.sh` (create),
`host/tests/lib.sh` (create), `host/tests/docker/Dockerfile` (create),
`host/tests/docker/entrypoint.sh` (create), `host/tests/docker/claude` (create),
`host/tests/docker/claude-old` (create), `host/tests/cases/basic.sh` (create),
`.gitignore` (create).

- [x] `host/tmuxpad-host.sh`: шапка с атрибуцией рецепта (MIT, ссылка), `set -u`,
      `VERSION=1`, разбор окружения: `STATE=$HOME/.tmuxpad`,
      `PROJECTS=${TMUXPAD_PROJECTS:-$HOME/projects}` с раскрытием `~`, относительного пути
      и `realpath -m` (симлинк в корне не должен ломать фильтр `list`),
      `CMD=${TMUXPAD_CMD:-claude}`, `CLIENT=${TMUXPAD_CLIENT:-}` с проверкой по regex UUID
      (`^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$`; непустой и невалидный →
      `exit 2` с сообщением на stderr). Функции `valid_name`, `valid_project`, `die MSG
      [CODE]`, `need_client` (пусто → `exit 2`). Диспетчер `case` со всеми подкомандами из
      §7 (`version list new attach take copy-cancel kill setup doctor auth`); не реализованные
      пока печатают `not implemented` и `exit 1`; `version` печатает `tmuxpad-host 1`; без
      аргументов или с неизвестной подкомандой — usage на stderr, `exit 2`.
- [x] `host/tests/docker/Dockerfile`: `ARG BASE=ubuntu:24.04`, `FROM $BASE`,
      `DEBIAN_FRONTEND=noninteractive`, пакеты `openssh-server tmux bash coreutils
      ncurses-bin` (нужен `infocmp`), `useradd -m -s /bin/bash dev`, `mkdir /run/sshd`,
      в `sshd_config`: `PasswordAuthentication no`, `PubkeyAuthentication yes`,
      `AcceptEnv LANG LC_*` (как у стандартного Ubuntu; `TMUXPAD_*` через `AcceptEnv` **не**
      пропускать — приложение передаёт их через `env`, и стенд должен это проверять).
      Заглушки копируются в `/usr/local/bin/claude` и `/usr/local/bin/claude-old` с `chmod
      755`. `EXPOSE 22`, `ENTRYPOINT ["/entrypoint.sh"]`.
- [x] `host/tests/docker/entrypoint.sh`: пишет `$AUTHORIZED_KEY` в
      `/home/dev/.ssh/authorized_keys` (`mkdir -p`, `chmod 700/600`, `chown -R dev:dev`),
      `exec /usr/sbin/sshd -D -e`. Ключ приходит через переменную окружения, а не монтирование:
      `StrictModes` sshd требует владельца `dev`, с bind-mount это ломается.
- [x] `host/tests/docker/claude` (bash): `--version` → `2.1.0 (stub)`; `--help` → многострочный
      текст, в котором есть `-n, --name <name>`, `--session-id <uuid>`, `-r, --resume [value]`;
      иначе — дописать в `$HOME/claude-args.log` строку
      `$PWD|$*|token=${CLAUDE_CODE_OAUTH_TOKEN:-none}` и `exec sleep infinity`.
      `host/tests/docker/claude-old` — то же, но в `--help` нет `--name`.
- [x] `host/tests/lib.sh`: переменные `PORT`, `KEY`, `CLIENT_A=11111111-1111-4111-8111-111111111111`,
      `CLIENT_B=22222222-…`; `SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
      -o ConnectTimeout=5 -o LogLevel=ERROR -i "$KEY" -p "$PORT")`; функции:
      `r CMD…` — `timeout 20 ssh "${SSH_OPTS[@]}" dev@127.0.0.1 -- "$*"` (сырая команда);
      `h SUB ARGS…` — exec-строка ровно как в §5:
      `env TMUXPAD_CLIENT='$CLIENT' TMUXPAD_PROJECTS='$PROJECTS' TMUXPAD_CMD='$CMD' "\$HOME"/.local/bin/tmuxpad-host.sh SUB ARGS`
      (переменные `CLIENT`, `PROJECTS`, `CMD` — глобальные для теста, по умолчанию
      `$CLIENT_A`, `projects`, `claude`; пустая переменная не передаётся);
      `attach_bg NAME` — `timeout 120 ssh -tt -n "${SSH_OPTS[@]}" dev@127.0.0.1 "<та же
      exec-строка> attach NAME" >/dev/null 2>&1 &`, PID в массив `BG_PIDS`, печатает PID;
      `wait_clients NAME N` — опрос `r tmux list-clients -t =NAME -F '#{client_pid}' | wc -l`
      до 5 с, иначе `fail`; `wait_log` — опрос `~/claude-args.log` до 5 с;
      `reset` — убить `BG_PIDS`, `r 'tmux kill-server 2>/dev/null; rm -rf ~/.tmuxpad ~/.claude
      ~/claude-args.log ~/.tmux.conf; mkdir -p ~/projects/api ~/projects/web ~/projects/my.app;
      touch ~/projects/README.md'`;
      ассерты `assert_eq EXP ACT MSG`, `assert_exit CODE CMD…` (выполняет, сравнивает `$?`),
      `assert_contains HAYSTACK NEEDLE`, `assert_not_contains`, `fail MSG` (пишет в `FAILED`,
      `return 1`). Функции-тесты именуются `test_<area>_<case>`.
- [x] `host/tests/run.sh`: `set -u`; `TMUXPAD_TEST_BASE=${TMUXPAD_TEST_BASE:-ubuntu:24.04}`;
      тег образа `tmuxpad-test:${BASE//[:\/]/-}`; `docker build --build-arg BASE=…`;
      `TMP=$(mktemp -d)`, `ssh-keygen -q -t ed25519 -N '' -f "$TMP/key"`;
      `CID=$(docker run -d --rm -p 127.0.0.1::22 -e AUTHORIZED_KEY="$(cat "$TMP/key.pub")" IMAGE)`,
      `PORT` из `docker port "$CID" 22`; `trap 'docker rm -f "$CID"; rm -rf "$TMP"' EXIT`;
      ожидание `r true` до 30 с; установка скрипта **так же, как приложение** (§7):
      `r 'mkdir -p ~/.local/bin && cat > ~/.local/bin/tmuxpad-host.sh && chmod +x
      ~/.local/bin/tmuxpad-host.sh' < host/tmuxpad-host.sh`; `source` всех
      `host/tests/cases/*.sh`; фильтр `-k SUBSTR`; для каждой `test_*`: `reset`, запуск в
      подоболочке, учёт PASS/FAIL, итог `N passed, M failed`, код выхода 1 при `M>0`.
      Печатать имя теста до запуска, чтобы зависание было видно.
- [x] `host/tests/cases/basic.sh`: `test_basic_version` (`h version` → `tmuxpad-host 1`,
      код 0); `test_basic_usage` (`h` без подкоманды → 2; `h bogus` → 2);
      `test_basic_bad_client` (`CLIENT=not-a-uuid h version` → 2 — валидация окружения идёт
      до диспетчера); `test_basic_install_path` (`r test -x ~/.local/bin/tmuxpad-host.sh`).
- [x] `.gitignore`: `.ralphex/`, `*.tmp`, `.DS_Store`. `shellcheck` чист по всем файлам из
      Validation Commands; `host/tests/run.sh` зелёный; коммит.

### Task 2: `setup`, `doctor`, `auth`

**Файлы:** `host/tmuxpad-host.sh`, `host/tests/cases/setup.sh` (create).

- [x] `tmux_version` → печатает `MAJOR.MINOR` из `tmux -V` по regex `([0-9]+)\.([0-9]+)`
      (для `next-3.5` → `3.5`); `version_ge A B` — сравнение по двум числам без `sort -V`
      (его нет в busybox-подобных окружениях, а bash-арифметики достаточно).
- [x] `doctor`: TSV-строки `ok|warn|fail\t<key>\t<message>`, ключи и правила:
      `tmux` — нет → fail, `< 3.1` → fail (`tmux 3.0a found, 3.1 required`), иначе ok с версией;
      `claude` — `bash -lc "command -v <первое слово CMD>"` (login-шелл, как у pane tmux;
      ssh-шелл для exec — не login) → fail если нет; `claude_name` — `bash -lc "<cmd> --help"
      | grep -q -- --name` → иначе warn `sessions will start unnamed`; `projects` — каталог
      `$PROJECTS` есть → ok с числом подкаталогов, прошедших `valid_project`, иначе fail;
      `script` — ok `tmuxpad-host 1`. Код выхода 1, если есть хотя бы один `fail`, иначе 0.
      Проверка `claude` пропускается (ok `custom command`), если первое слово CMD не
      `claude` (решение 5).
- [x] `setup`: `mkdir -p "$STATE" "$STATE/clients" "$PROJECTS"`; блок в `~/.tmux.conf` между
      маркерами `# tmuxpad: begin` … `# tmuxpad: end` (перенос `end_newline` из рецепта):
      `set -g set-clipboard on`, `set -g history-limit 50000`, и `set -g allow-passthrough on`
      **только** при `version_ge $(tmux_version) 3.3` — старый tmux на неизвестной опции
      прекращает читать конфиг. Повторный запуск блок не дублирует (проверка по маркеру).
      Никаких правок `~/.profile`, `~/.claude/settings.json`, `~/.ssh`. В конце — `doctor`,
      его код выхода становится кодом `setup`.
- [x] `auth` — перенос из рецепта один в один, с путём `$STATE/env`: `umask 077`, токен одной
      строкой со stdin, regex `^[A-Za-z0-9_-]+$` иначе `exit 2`, перезапись строки
      `export CLAUDE_CODE_OAUTH_TOKEN='…'` через `.tmp` + `mv`, `chmod 600`, сообщение
      `token stored in …`.
- [x] Тесты `setup.sh`: `test_setup_tmux_conf_block` (после двух `h setup` маркер `# tmuxpad:
      begin` встречается один раз; `set-clipboard on` и `history-limit 50000` есть;
      `allow-passthrough` есть тогда и только тогда, когда `r tmux -V` ≥ 3.3 — ветвление в
      тесте по версии); `test_setup_leaves_profile_alone` (`~/.profile` до и после `setup`
      побайтно одинаков, `~/.claude/settings.json` не создан); `test_setup_creates_dirs`
      (`~/.tmuxpad/clients`, `~/projects`); `test_doctor_ok` (все строки `ok`, код 0, строка
      `projects` содержит `3` — `README.md` не проект); `test_doctor_no_projects_root`
      (`PROJECTS=nope h doctor` → строка `fail\tprojects`, код 1);
      `test_doctor_old_claude` (`CMD=/opt/claude-old/bin/claude h doctor` → `warn\tclaude_name`, код 0);
      `test_doctor_custom_cmd` (`CMD='sleep 1000' h doctor` → `ok\tclaude\tcustom command`);
      `test_auth_stores_token` (`printf 'sk-abc_1\n' | h auth` → файл `~/.tmuxpad/env` с правами
      `600` и ровно одной строкой `export CLAUDE_CODE_OAUTH_TOKEN='sk-abc_1'`; второй `auth` с
      другим токеном заменяет строку, строк по-прежнему одна); `test_auth_rejects_garbage`
      (`printf 'bad token\n' | h auth` → 2, файла нет). Для stdin в `h` — передавать через
      пайп, ssh его пробрасывает.
- [x] shellcheck чист, оба прогона `run.sh` зелёные (24.04 и 22.04 — именно здесь ветка
      `allow-passthrough` расходится); коммит.

### Task 3: `list` и учёт клиентов

**Файлы:** `host/tmuxpad-host.sh`, `host/tests/cases/list.sh` (create).

- [x] `prune_clients`: удаляет файлы `$STATE/clients/<pid>`, для которых PID нет в выводе
      `tmux list-clients -F '#{client_pid}'` (tmux-сервер не запущен → список пуст → удалить
      все). Зовётся из `list`, `attach`, `take`. Файлы с именем не из цифр — удалять тоже.
      Не удаляется файл PID, который ещё исполняет скрипт до `exec` (`/proc/<pid>/cmdline`
      содержит `tmuxpad-host`) — гонка `list` с параллельным `attach`; внесено в §7 спеки.
- [x] `others_for NAME`: число клиентов сессии из `tmux list-clients -t =NAME -F
      '#{client_pid}'`, у которых **нет** файла `$STATE/clients/<pid>` с содержимым, равным
      `$CLIENT`; при пустом `CLIENT` — все клиенты чужие. Один общий `list-clients -F
      '#{session_name}\t#{client_pid}'` на весь `list`, а не по сессии.
- [x] `list`: печатает `V\t1`; затем для каждой строки `tmux list-sessions -F
      '#{session_name}\t#{session_path}\t#{session_activity}' 2>/dev/null` — `realpath -m`
      пути, фильтр «родитель пути == `$PROJECTS`» (как в рецепте: `path == "$PROJECTS"/* &&
      ${path#"$PROJECTS"/} != */*`), строка `S\t<name>\t<others>\t<project>\t<activity>`,
      где `project` — basename пути; `S`-строки отсортированы по имени. Затем `P\t<name>\t<abs
      path>` для подкаталогов `$PROJECTS`, имя которых проходит `valid_project` (файлы и
      скрытые каталоги пропускаются). Отсутствие tmux-сервера — не ошибка: только `V` и `P`,
      код 0. Отсутствие `$PROJECTS` — `exit 2` с сообщением (приложение покажет «нужна
      подготовка»).
- [x] Тесты `list.sh` (сессии создаются напрямую `r tmux new -d -s NAME -c DIR`, `new` ещё не
      нужен): `test_list_header_and_projects` (без tmux-сервера: первая строка `V\t1`, ровно
      три `P`-строки `api`, `my.app`, `web` с абсолютными путями `/home/dev/projects/...`,
      `README.md` нет); `test_list_filters_foreign_sessions` (сессия с `-c ~` и сессия с
      `-c ~/projects/api/sub` не попадают, `-c ~/projects/api` попадает с `project=api`);
      `test_list_activity_is_epoch` (пятое поле — число ≥ 1700000000);
      `test_list_symlinked_root` (`PROJECTS=/home/dev/proj-link` где `proj-link → projects`
      — сессия с `-c ~/projects/api` видна); `test_list_others` (сессия `api`; `attach_bg api`
      с `CLIENT_A`, `wait_clients api 1` → `CLIENT=$CLIENT_A h list` даёт `others=0`,
      `CLIENT=$CLIENT_B h list` даёт `1`, `CLIENT= h list` даёт `1`); `test_list_plain_tmux_client_is_other`
      (фоновый `ssh -tt -n … 'tmux attach -t =api'` без скрипта → `others=1` для любого
      CLIENT); `test_list_prunes_stale_client_files` (создать `~/.tmuxpad/clients/999999` и
      `~/.tmuxpad/clients/junk`, `h list` → оба файла исчезли, файл живого клиента остался);
      `test_list_no_projects_root` (`PROJECTS=nope h list` → 2).
      Для `attach_bg` в этой задаче нужен минимальный `attach`: временно реализовать в скрипте
      запись `$STATE/clients/$$` + `exec tmux attach-session -t =NAME` без остальных шагов
      (полная версия — Task 5); тест на это не писать, он придёт с Task 5.
- [x] shellcheck, `run.sh` зелёный на 24.04 (и на 22.04); коммит.

### Task 4: `new`

**Файлы:** `host/tmuxpad-host.sh`, `host/tests/cases/new.sh` (create).

- [x] `new NAME PROJECT` по §7: `valid_name`/`valid_project` иначе 2; `[[ -d $PROJECTS/$PROJECT ]]`
      иначе 2; `$CMD` и `$STATE` не содержат `'` иначе 2 (они попадают внутрь `sh -c '…'`);
      `tmux has-session -t =NAME` → `exit 3`; `pane=$(tmux new-session -d -P -F '#{pane_id}'
      -s NAME -c DIR)` иначе 1; `tmux set -t =NAME: mouse on`.
- [x] Ветка claude (первое слово `$CMD` по basename == `claude`): файл `$STATE/NAME.claude`
      формата `<uuid>\t<project>`; читать его, если есть: при совпадении `project` и наличии
      транскрипта по глобу `"$HOME"/.claude/projects/*/"$uuid".jsonl` — флаги `--resume
      <uuid>`; иначе (файла нет / проект другой / транскрипта нет) — новый UUID из
      `/proc/sys/kernel/random/uuid`, перезапись файла, флаги `--session-id <uuid>` плюс
      `-n NAME`, если `bash -lc "<cmd> --help" | grep -q -- --name`. Иная команда: флагов нет,
      файл не создаётся и существующий не трогается.
- [x] Запуск: `tmux send-keys -t "$pane" "sh -c '[ -f \"$STATE/env\" ] && . \"$STATE/env\";
      exec $CMD $flags'" Enter` (одним аргументом + `Enter`, как в рецепте; `-l` не нужен);
      при ошибке `send-keys` — `kill-session` и `exit 1`, чтобы не оставлять пустую сессию.
      Stdout пустой.
- [x] Тесты `new.sh` (после `new` ждать `wait_log`): `test_new_creates_session` (сессия есть,
      `#{session_path}` = `/home/dev/projects/api`, `mouse on` у сессии, `api.claude` =
      `<uuid>\tapi`, где uuid проходит regex; лог заглушки: `pwd=/home/dev/projects/api`,
      аргументы `-n api --session-id <тот же uuid>`, `token=none`); `test_new_conflict`
      (второй `new api api` → 3, лог не вырос); `test_new_bad_names` (`new 'a b' api` → 2,
      `new .hidden api` → 2, `new api nothere` → 2, сессий нет); `test_new_resume_after_reboot`
      (`new`, затем `r tmux kill-session -t =api` — имитация ребута, файл `api.claude`
      остаётся; создать `~/.claude/projects/-home-dev-projects-api/<uuid>.jsonl`; `new api api`
      → аргументы `--resume <uuid>`, файл не изменился); `test_new_fresh_uuid_without_transcript`
      (то же без транскрипта → новый uuid в файле и в `--session-id`);
      `test_new_other_project_gets_new_uuid` (`new x api`, `kill-session`, `new x web` → файл
      `<new uuid>\tweb`, флаг `--session-id`, даже если транскрипт старого uuid лежит);
      `test_new_old_claude_unnamed` (`CMD=/opt/claude-old/bin/claude` → аргументы без `-n`, с `--session-id`);
      `test_new_custom_cmd` (`CMD='sleep 1000'` → `#{pane_current_command}` = `sleep` в
      течение 5 с, файла `api.claude` нет, лога нет); `test_new_rejects_quote`
      (`CMD="it's" h new api api` → 2); `test_new_sources_env` (`printf 'tok_1\n' | h auth`,
      затем `new` → в логе `token=tok_1`); `test_new_exit_keeps_session` (`CMD='sleep 1000'`,
      `r tmux send-keys -t =api: C-c` → через 2 с сессия жива, pane — шелл: выход команды не
      убивает сессию, инвариант CLAUDE.md).
- [x] shellcheck, `run.sh` зелёный; коммит.

### Task 5: `attach`, `take`, `copy-cancel`, `kill`

**Файлы:** `host/tmuxpad-host.sh`, `host/tests/cases/attach.sh` (create).

- [x] `attach_impl NAME DETACH_ALL` по шагам §7: `valid_name` иначе 2; `need_client`;
      `tmux has-session -t =NAME` иначе `exit 4`; `prune_clients`; для строк `tmux list-clients
      -t =NAME -F '#{client_pid}\t#{client_tty}'` — если `$STATE/clients/<pid>` существует и
      равен `$CLIENT` → `tmux detach-client -t <tty>` (выкидываем только свои зомби);
      `tmux set -t =NAME: mouse on`; `tmux set -w -t '=NAME:' window-size latest`;
      `infocmp "${TERM:-}" || export TERM=xterm-256color` (из рецепта); `mkdir -p
      $STATE/clients`, `printf '%s\n' "$CLIENT" > "$STATE/clients/$$"`; `exec tmux
      attach-session ${DETACH_ALL:+-d} -t =NAME`. `attach` = `attach_impl NAME ""`,
      `take` = `attach_impl NAME 1`. Временную заглушку из Task 3 заменить.
- [x] `copy-cancel NAME`: `valid_name` иначе 2; `tmux send-keys -t "=NAME:" -X cancel
      2>/dev/null; exit 0` — вне режима tmux ругается `not in a mode`, это штатно.
- [x] `kill NAME`: `valid_name` иначе 2; `tmux kill-session -t =NAME 2>/dev/null || true`;
      `rm -f "$STATE/NAME.claude"`; `exit 0` всегда (идемпотентно, как в рецепте).
- [x] Тесты `attach.sh` (сессия через `h new api api`, `CMD='sleep 1000'` чтобы заглушка не
      мешала): `test_attach_missing_session` (`h attach nope` → 4, `h take nope` → 4);
      `test_attach_requires_client` (`CLIENT= h attach api` → 2); `test_attach_writes_client_file`
      (`attach_bg api`, `wait_clients api 1`; PID клиента из `list-clients` равен имени файла
      в `~/.tmuxpad/clients/`, содержимое — `CLIENT_A`); `test_attach_sets_options` (после
      attach `tmux show -t =api mouse` → `mouse on`, `tmux show -w -t =api: window-size` →
      `window-size latest`); `test_attach_detaches_own_zombie` (первый `attach_bg` с `CLIENT_A`,
      второй `attach_bg` с `CLIENT_A` → через ≤5 с клиентов ровно 1, первый ssh-процесс
      завершился (`kill -0` ложно), файл первого PID удалён следующим `list`);
      `test_attach_keeps_foreign_client` (`CLIENT=$CLIENT_B attach_bg api`, затем
      `CLIENT=$CLIENT_A attach_bg api` → клиентов 2, оба ssh живы; плюс «голый» `tmux attach`
      тоже остаётся); `test_take_detaches_everyone` (клиенты B и голый, затем
      `CLIENT=$CLIENT_A` `take` → клиентов 1, это новый); `test_copy_cancel`
      (`r tmux copy-mode -t =api:` → `pane_in_mode`=1; `h copy-cancel api` → 0 и
      `pane_in_mode`=0; повторный `copy-cancel` → 0; `h copy-cancel 'bad name'` → 2);
      `test_kill` (`h kill api` → 0, сессии нет, `api.claude` нет; второй `kill api` → 0;
      `kill 'bad name'` → 2); `test_detach_on_ssh_close` (`attach_bg api`, `kill <ssh pid>`
      → через ≤3 с клиентов 0: закрытие канала приложением = корректный detach, §6).
- [x] shellcheck, `run.sh` зелёный на 24.04 и 22.04; коммит.

### Task 6: документация, матрица и завершение

**Файлы:** `host/README.md` (create), `CLAUDE.md`, `docs/tmuxpad-spec.md` (только если
контракт в коде разошёлся со спекой), `docs/plans/20261020-host-script.md` (move).

- [x] `host/README.md` (коротко, по-русски): назначение, строка установки, как её делает
      приложение (`mkdir -p ~/.local/bin && cat > … && chmod +x …` со скриптом в stdin),
      таблица подкоманд с кодами выхода (решение 8), переменные `TMUXPAD_CLIENT`,
      `TMUXPAD_PROJECTS`, `TMUXPAD_CMD`, формат `list V 1` и `doctor`, файлы состояния в
      `~/.tmuxpad/` (`env`, `clients/<pid>`, `NAME.claude`), требования к серверу
      (Linux, bash, tmux ≥ 3.1, coreutils `realpath`, `infocmp`), как запускать тесты и один
      тест, атрибуция рецепта.
- [x] `CLAUDE.md`: раздел «Состояние репозитория» — появился код: команды из Validation
      Commands (shellcheck, оба прогона, один тест через `-k`), раскладка `host/`; убрать
      фразу «кода пока нет». Если при реализации что-то в §7 пришлось уточнить (формат
      `doctor`, код `list` без корня, правило «флаги только для claude») — внести в спеку
      одной правкой со ссылкой на этот план, не оставлять расхождений.
- [x] Полный прогон: shellcheck всех файлов, `host/tests/run.sh` на `ubuntu:24.04` и на
      `ubuntu:22.04` — оба зелёные; в progress-лог записать время прогона и число тестов.
- [x] Move this plan to `docs/plans/completed/`; коммит.

## Как проверить после выкатки

- Этот хост сам подходит как целевой сервер (tmux 3.4, настоящий Claude Code 2.1.304):
  `cat host/tmuxpad-host.sh | ssh <этот хост> 'mkdir -p ~/.local/bin && cat > ~/.local/bin/tmuxpad-host.sh && chmod +x ~/.local/bin/tmuxpad-host.sh'`,
  затем `tmuxpad-host.sh setup` — ожидать все `ok`, `allow-passthrough` в блоке есть.
- С Mac: `ssh -t host "env TMUXPAD_CLIENT=$(uuidgen) ~/.local/bin/tmuxpad-host.sh new demo tmuxpad && env TMUXPAD_CLIENT=… ~/.local/bin/tmuxpad-host.sh attach demo"` —
  в tmux стартует `claude -n demo --session-id …`, имя `demo` видно в промпте Claude.
  Второй терминал с тем же `TMUXPAD_CLIENT` → первый отваливается с `[detached]`, с другим
  UUID → оба подключены, размер следует за тем, кто печатает (`window-size latest`).
- `tmux kill-session -t =demo` и повторный `new demo tmuxpad` → `claude --resume <uuid>`,
  тот же разговор с тем же именем — это единственная проверка Phase 0 про Claude, которую
  Docker-стенд закрыть не может.
- Прокрутить вывод колесом (copy-mode), затем `tmuxpad-host.sh copy-cancel demo` из другого
  окна — экран возвращается к живому Claude.
