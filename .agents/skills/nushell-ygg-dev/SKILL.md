---
name: nushell-ygg-dev
description: Use when writing, reviewing or debugging Nushell (.nu) code of the ygg engine in src/, bin/ or tests/, or when hitting nu::parser / nu::shell errors (unclosed_delimiter, variable_not_found, invalid_filename, deprecated get -i or do -i), hangs in job spawn / job recv, broken symlinks or junctions, or mangled UTF-8 in progress output.
---

# Nushell 0.116+ в движке ygg

## Обзор

Идиомы проверены на `nu 0.116.1` и на трёх ОС (Linux, macOS, Windows 11 Non-Admin). Главная причина ошибок — перенос привычек из Bash и старых версий Nushell. Кроссплатформенные и тестовые инварианты задаёт [AGENTS.md](../../../AGENTS.md) §2, здесь их не дублируем.

## Быстрая справка

Ниже — правила, которые чаще всего нарушают даже опытные агенты. Подробности и код — в файлах из колонки «Где».

| Ситуация | Правило | Где |
|---|---|---|
| Внешняя команда может вернуть ≠ 0 | `^cmd ... \| complete` и проверка `exit_code`; `do -i` устарел | [processes](references/processes.md) §1 |
| Редирект `o>`/`e>` внутри `job spawn` | `try/catch`, явный `exit_code: 0` в `try`, 127 через `which`, иначе `job recv` виснет | [processes](references/processes.md) §5 |
| Утилиты, принимающие один пакет (winget, uv tool) | цикл по одному пакету, `which`-guard до вызова | [processes](references/processes.md) §2–3 |
| Убить job по таймауту | снять PID до `job kill` (`kill-job-tree`) | [processes](references/processes.md) §4 |
| Правка `run-with-timeout` | коды 127/124, раздельные потоки, уборка temp | [processes](references/processes.md) §7 |
| Лог подпроцесса, `\r`-прогресс, `mktemp` | сплит по `[\r\n]+` до `ansi strip`; `mktemp -t --suffix .log ygg-proc-XXXXXX` | [processes](references/processes.md) §6 |
| Есть ли путь / ссылка | `path type` (lstat), а не `path exists`: битая ссылка даёт `false` | [filesystem](references/filesystem.md) §1 |
| Путь может содержать `*` или `?` | проверить строку до `path exists`/`path type`: на Windows `invalid_filename` | [filesystem](references/filesystem.md) §3 |
| Win32-путь к ссылке | `path expand -n` (`to-win32-path`), иначе `rmdir`/`del` бьют по цели | [filesystem](references/filesystem.md) §5 |
| Junction на UNC / без reparse points | каскад `mklink /J` → `mklink /D` → `cp -r` через `complete` | [filesystem](references/filesystem.md) §4 |
| Скобки `[...]` в `$"..."` | конкатенация `+`, иначе `unclosed_delimiter` | [syntax](references/syntax.md) §2 |
| Необязательное поле | `get -o` или `$rec.field?`; `get -i` устарел | [syntax](references/syntax.md) §3 |
| `$it` в `where { }` | явный параметр `{ \|it\| ... }` | [syntax](references/syntax.md) §4 |
| Длина и срез строки для UI | `--grapheme-clusters`: по умолчанию счёт в байтах | [syntax](references/syntax.md) §5 |
| `use`/`source` по переменной | невозможно (parse-time); дочерний `^nu -I` | [syntax](references/syntax.md) §1 |
| Секрет в env.nu / zsh / ps1 / dotenv | экранирование под конкретный шелл | [data](references/data.md) §2 |
| Тест проверяет очистку temp-файлов | дочерний `^nu` с `TMPDIR`/`TEMP`/`TMP` внутри `with-temp-ygg` | [testing](references/testing.md) |

## Частые ошибки

- **«Это очевидно, справку читать не нужно».** Пункты из таблицы — именно те, что агенты ошибочно пишут по памяти (`do -i`, `path exists` для глоба, `LAST_EXIT_CODE` после `o>`). Перед правкой открой нужный файл из колонки «Где».
- **Новая грабля не записана.** Нашёл поведение `nu`, которого здесь нет, — добавь пункт в подходящий `references/*.md` и строку в таблицу.
