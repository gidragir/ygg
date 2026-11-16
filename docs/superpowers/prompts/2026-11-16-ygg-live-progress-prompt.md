# Executor Prompt: RFC-060 Live Single-Line Progress (`ygg`)

## Целевые скиллы
* `.agents/skills/nushell-ygg-dev/SKILL.md` (обязателен перед редактированием любых `.nu` файлов)
* `superpowers:test-driven-development`
* `superpowers:verification-before-completion`

## Обязательная директива навигации
Для исследования архитектуры и API используй `rtk context-init pack <subsystem_id> --compress`. Не вычитывай файлы директории целиком.

## Входные документы и границы файлов
* Спецификация: `docs/specs/2026-11-16-ygg-live-progress-design.md`
* План: `docs/superpowers/plans/2026-11-16-ygg-live-progress.md`
* Затрагиваемые файлы:
  * Create: `src/progress.nu`, `tests/test_progress.nu`
  * Modify: `src/mod.nu`, `src/pkg.nu`, `src/container.nu`, `src/git.nu`, `src/sdk.nu`, `src/link.nu`, `bin/ygg.nu`, `tests/test_pkg_git.nu`, `tests/test_container.nu`, `tests/test_sdk.nu`, `tests/test_cli_e2e.nu`

## Ключевые инварианты реализации
1. В `job spawn` всегда оборачивать `^$bin ...$args o> $out_log e> $err_log` в `try/catch` (в Nu 0.116 ненулевой выход бросает исключение); при `which $bin | is-empty` возвращать `exit_code: 127`.
2. Сохранять независимость `stdout` и `stderr` (не сливать через `o+e>`).
3. В `read-last-log-line` выполнять `split row --regex '[\r\n]+'` строго **до** `ansi strip`, с защитой UTF-8 границ хвоста ~4 КБ и clamp ширины `(term size).columns`.
4. Для `git clone`/`fetch`/`pull` с `--label` передавать `--progress`; для интерактивного `sudo`/`paru` прогревать `^sudo -v` или передавать `--no-tty-progress`.
5. `--dry-run`, `diff`, `status`, `doctor` не выводят прогресс; `NO_COLOR` отключает ANSI; темп-файлы `mktemp -t --suffix .log ygg-proc-XXXXXX` удаляются при успехе, ошибке, таймауте и прерывании.

## Команды верификации
```bash
rtk nu tests/run.nu --filter test_progress
rtk nu tests/run.nu
rtk context-init update . --compact --prune
rtk context-init check --compact
```
