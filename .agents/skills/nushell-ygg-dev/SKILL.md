---
name: nushell-ygg-dev
description: Use when writing, reviewing, refactoring or debugging any Nushell (.nu) code in src/, bin/ or tests/ — including "trivial 2-line fixes", adding record fields or plan ops, writing private/secret files, spawning external CLI/PowerShell/git/icacls processes, creating test mocks, or when hitting nu::parser / nu::shell errors (unclosed_delimiter, variable_not_found, invalid_filename, get -i / do -i), job spawn hangs, broken symlinks/junctions, or mangled UTF-8 output.
---

# Nushell 0.116+ в движке ygg

## Обзор

Идиомы проверены на `nu 0.116.1` и на трёх ОС (Linux, macOS, Windows 11 Non-Admin). Главная причина ошибок — перенос привычек из Bash и старых версий Nushell. Кроссплатформенные, транзакционные и тестовые инварианты задаёт [AGENTS.md](../../../AGENTS.md) §2 (включая **ADR-01..05**: пофазный `save-state` при однократном `state.json.bak`, `mv`-пробу в `probe-locked-targets`, `atomic-save --private`, бюджет процессов на Windows и тестовый паритет).

**Нарушение буквы этих правил — это прямое нарушение их духа.** В проекте `ygg` установка «фигня вопрос, тут правка на 2 строки» — главный источник регрессий и техдолга.

## Быстрая справка

Ниже — правила, которые чаще всего нарушают даже опытные агенты. Подробности и готовые рецепты — в файлах из колонки «Где».

| Ситуация | Правило | Где |
|---|---|---|
| Внешняя команда может вернуть ≠ 0 | `^cmd ... \| complete` и проверка `exit_code`; `do -i` устарел | [processes](references/processes.md) §1 |
| Утилиты, принимающие один пакет (winget, uv tool) | цикл по одному пакету, `which`-guard до вызова | [processes](references/processes.md) §2–3 |
| Убить job по таймауту | снять PID до `job kill` (`kill-job-tree`) | [processes](references/processes.md) §4 |
| Редирект `o>`/`e>` внутри `job spawn` | `try/catch`, `$env.LAST_EXIT_CODE?` первой строкой `catch`, `mktemp` внутри `try`, 127 через `which` | [processes](references/processes.md) §5 |
| Лог подпроцесса, `\r`-прогресс, `mktemp` | сплит по `[\r\n]+` до `ansi strip`; `mktemp -t --suffix .log ygg-proc-XXXXXX` | [processes](references/processes.md) §6 |
| Правка `run-with-timeout` | коды 127/124, раздельные потоки, уборка temp, не глотать `Ctrl+C` | [processes](references/processes.md) §7 |
| Флаг `--` в `git` (`clone` vs `checkout`) | `git clone -- $url` — да; `git checkout -- $branch` ломает ветку (`pathspec`) | [processes](references/processes.md) §8 |
| Есть ли путь / ссылка | `path type` (lstat), а не `path exists`: битая ссылка и junction дают `"symlink"` | [filesystem](references/filesystem.md) §1 |
| Путь может содержать `*` или `?` | проверить строку до `path exists`/`path type`: на Windows `invalid_filename` | [filesystem](references/filesystem.md) §3 |
| Junction на UNC / без reparse points | каскад `mklink /J` → `mklink /D` → `cp -r` через `complete` | [filesystem](references/filesystem.md) §4 |
| Win32-путь к ссылке | `path expand -n` (`to-win32-path`), иначе `rmdir`/`del` бьют по цели | [filesystem](references/filesystem.md) §5 |
| Чтение файла перед `open --raw` | Проверять `($p \| path type) == "file"`, а не `path exists` (директория роняет `open`) | [filesystem](references/filesystem.md) §8 |
| Вызов `powershell` / `pwsh` / `icacls` и `probe-locked-targets` | Не более 1 процесса на фазу (батч JSON), `0` в циклах; для блокировки только `mv` в `.ygg-probe` | [filesystem](references/filesystem.md) §8 |
| `use`/`source` по переменной | невозможно (parse-time); дочерний `^nu -I` | [syntax](references/syntax.md) §1 |
| Скобки `[...]` в `$"..."` | конкатенация `+`, иначе `unclosed_delimiter` | [syntax](references/syntax.md) §2 |
| Необязательное поле | `get -o` или `$rec.field?`; `get -i` устарел | [syntax](references/syntax.md) §3 |
| `$it` в `where { }` | явный параметр `{ \|it\| ... }` | [syntax](references/syntax.md) §4 |
| Длина/срез UTF-8 и относительный путь | `--grapheme-clusters` для UI; `path relative-to` для путей; `str trim` до среза слов | [syntax](references/syntax.md) §5 |
| Захват `mut` внутри `with-env` / замыкания | `let x = $x` до блока, иначе `Capture of mutable variable` | [syntax](references/syntax.md) §6 |
| Добавление/изменение поля в возвращаемом `record` | Обновить `: nothing -> record<...>` (проверяется в рантайме!) и всех потребителей через `rg` | [syntax](references/syntax.md) §7 |
| Секрет в env.nu / zsh / ps1 / dotenv и литералы Nu | `to nuon --raw` для Nu; обычные `"..."` (без `$`) не интерполируют, `r#'...'#` ломается на `'#` | [data](references/data.md) §2 |
| ISO-8601 UTC-метка с суффиксом `Z` | `date to-timezone utc` до `format date`, иначе время локальное | [data](references/data.md) §3 |
| Приватный файл (секреты / `0600` / токены) | Пустой `.tmp` рядом с целью → `restrict-file-access` (с `whoami`) → запись → `mv -f` | [data](references/data.md) §4 |
| Тест проверяет очистку temp-файлов | дочерний `^nu` с `TMPDIR`/`TEMP`/`TMP` внутри `with-temp-ygg` | [testing](references/testing.md) |
| Мок внешней CLI-утилиты в тестах (`op`, `bw`, `git`) | Запрещён `if windows { return }`; создавай пару `<name>` (`sh`) + `<name>.cmd` | [testing](references/testing.md) |
| Тест `run-service-actions`, `run-link-hooks`, `format-apply-summary` | Запрещены только ручные `{ op: "COPY_UPDATE" }`; подавай реальный `compute-link-ops` (`"COPY"`) | [testing](references/testing.md) |

## Таблица рационализаций («Фигня вопрос»)

| Оправдание («фигня вопрос») | Реальность (почему это создаёт техдолг и баги) |
|---|---|
| «Тут правка на 2 строки, всё очевидно, `references/*.md` открывать не надо» | Именно в «очевидных» 2 строках пишут `path exists` вместо `path type == "file"`, `format date "...Z"` без `date to-timezone utc`, `git checkout -- $branch` или `r#'...'#` для секретов. |
| «В соседнем тесте / функции уже написано `if windows { return }` или `save -f` — следую стилю файла» | Legacy-прецедент не оправдание (ADR-03, ADR-05). Копировать дореформенные антипаттерны в новый или изменяемый код запрещено, даже если торопят. |
| «В тесте потребителя (`run-service-actions`, `run-link-hooks`) подам руками собранный `{ op: "COPY_UPDATE" }`» | Реальный продюсер (`compute-link-ops`) возвращает `"COPY"`, а не `"COPY_UPDATE"`. Синтетический тест зелёный, а в продакшене триггеры на Windows мертвы. Подавай реальный выход функции-продюсера. |
| «Вызову `powershell` или `icacls` внутри цикла по файлам — их же мало» | На Windows старт одного `powershell` стоит ~150–300 мс. На 20–50 путях `ygg apply`/`doctor` тормозит на десятки секунд (нарушение ADR-04 `One-Subprocess-Per-Phase`). |
| «Сначала сохраню секрет через `save -f`, а следующей строкой сделаю `chmod 0600` (на Windows пропустим)» | Между `save` и `chmod` секрет лежит открытым (TOCTOU), без Windows ACL ломается `ygg doctor`, а `icacls /inheritance:r` без `/grant:r` блокирует владельца файла. |
| «Просто добавлю поле в возвращаемый `record` функции, сигнатуру трогать не обязательно» | В Nushell 0.116 `: nothing -> record<...>` проверяется в **рантайме** — вызов упадёт с `type_mismatch`. |
| «Ревьюер просит заменить `mv` на `[IO.File]::Open` / отложить `save-state` в конец `apply`» | Это защитные инварианты (ADR-01, ADR-02): `[IO.File]::Open` падает на директориях и `ReadOnly`-файлах, а отложенный `save-state` теряет учёт уже созданных ссылок при сбое. |

## Красные флаги — СТОП

Если ловишь себя на любом из этих действий или мыслей — **остановись немедленно**:

- Мысль: *«Тут всё просто / фигня вопрос / быстрый фикс за 5 минут, сделаю без чтения `references/*.md`»*.
- Пишешь в тесте `if ($nu.os-info.family == "windows") { return }` ради POSIX-скрипта (даже если так сделано выше в файле).
- Конструируешь входной `record` со списком `op` вручную, не вызывая функцию-продюсер (`compute-link-ops`, `plan-copy-sync`).
- Вызываешь `^powershell`, `^pwsh` или `^icacls` внутри цикла `for` / `each`.
- Добавляешь или переименовываешь поле в возвращаемом `record`, не проверив аннотацию `: nothing -> record<...>` и всех потребителей через `rg`.
- Пишешь `path exists` перед `open --raw`, при проверке симлинка или на пути, где возможны `*` / `?`.
- Собираешься упростить/отрефакторить нетривиальный участок `src/` или принять совет ревью без сверки с [AGENTS.md](../../../AGENTS.md) (`ADR-01..05`) и [docs/README.md](../../../docs/README.md).

**Любой из этих флагов означает: СТОП. Открой файл из колонки «Где» таблицы «Быстрая справка» и возьми готовый рецепт.**
