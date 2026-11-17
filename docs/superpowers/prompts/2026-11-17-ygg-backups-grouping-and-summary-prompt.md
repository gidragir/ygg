# Executor Prompt: RFC-063 Backups Grouping, Summary & `ygg status`

## Целевые скиллы
* `.agents/skills/nushell-ygg-dev/SKILL.md` (обязателен перед редактированием любых `.nu` файлов)
* `superpowers:test-driven-development`
* `superpowers:verification-before-completion`

## Обязательная директива навигации
Для исследования архитектуры и API используй `rtk context-init pack <subsystem_id> --compress`. Не вычитывай файлы директории целиком.

## Входные документы и границы файлов
* Спецификация: `docs/specs/2026-11-17-ygg-backups-grouping-and-summary-design.md`
* План: `docs/superpowers/plans/2026-11-17-ygg-backups-grouping-and-summary.md`
* Затрагиваемые файлы:
  * Modify: `src/state.nu`, `src/progress.nu`, `src/link.nu`, `src/sdk.nu`, `bin/ygg.nu`
  * Test: `tests/test_state.nu`, `tests/test_progress.nu`, `tests/test_e2e_apply.nu`, `tests/test_e2e_cli_core.nu`

## Ключевые инварианты реализации
1. Индекс `<id>.json` хранится **рядом** с `.state/backups/<id>/`, никогда внутри него (`check-shadow` в `src/doctor.nu` и `rotate-backups` ищут `type == "dir"`).
2. При коллизии внутри одного `YGG_BACKUP_ID` добавлять суффикс `.1`, `.2`, ... до `mv`, не затирая предыдущий снимок.
3. `run-module-setup` пробрасывает `YGG_BACKUP_ID` в `$env_vars` дочернего `^nu` (`safe-link`).
4. Сводка и `backup-with-notice` пишутся в `stderr`; в `apply-plan` сводка печатается и в `catch` (при ошибке после частичных мутаций). `--dry-run` не создаёт индексов и не печатает сводку.
5. `ygg status --json` остаётся массивом модулей; без `--json` явно печатать `print ($rows | table)` до блока `Recent backups:`.
6. Все тесты строго внутри `with-temp-ygg`, с комментарием `# regression: #10`; финальный коммит с футером `Fixes #10`.

## Команды верификации
```bash
rtk nu tests/run.nu --filter test_state
rtk nu tests/run.nu --filter test_progress
rtk nu tests/run.nu --filter test_e2e_apply
rtk nu tests/run.nu --filter test_e2e_cli_core
rtk mise run test
rtk context-init update . --compact --prune
rtk context-init check --compact
```
