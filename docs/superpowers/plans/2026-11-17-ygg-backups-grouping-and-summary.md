# RFC-063: Группировка бэкапов запуска, сводка и отображение в `status` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Группировать все бэкапы одного запуска `add`/`apply`/`update`/`remove` (включая `setup.nu`) в единый каталог `.state/backups/<timestamp>/` с метафайлом `<timestamp>.json`, печатать сводку забэкапленных путей в конце прогона и показывать недавние бэкапы в `ygg status`.

**Architecture:** В начале мутирующего запуска генерируется один `YGG_BACKUP_ID` (`%Y%m%d_%H%M%S_%f`) и пробрасывается через `with-env` (в том числе в дочерний `^nu` внутри `run-module-setup`). `backup-existing` складывает файлы в `.state/backups/<id>/` (добавляя `.1`, `.2` при коллизии) и дописывает верхнеуровневую цель в соседний файл `.state/backups/<id>.json`. В конце `apply-plan` / `main remove` (и при ошибке после частичных мутаций) печатается компактная сводка, а `main status` без `--json` выводит блок `Recent backups`.

**Tech Stack:** Nushell (`nu >= 0.116`), JSON, `tests/run.nu`, `mise run test`.

**Spec:** `docs/specs/2026-11-17-ygg-backups-grouping-and-summary-design.md`

## Global Constraints

* Nushell `>= 0.116`, целевые ОС: Linux, Windows 11/Server Non-Admin, macOS.
* ZERO HOST MUTATION: все тесты выполняются строго внутри `with-temp-ygg` (`YGG_HOME`, `YGG_SANDBOX`); литеральных `/tmp/...` нет.
* `--dry-run`, `diff`, `doctor` не создают каталогов/индексов `.state/backups/` и не выводят сводку бэкапов.
* Сводка бэкапов и уведомление `backup-with-notice` пишутся в `stderr` (`print -e`); `ygg status --json` сохраняет формат JSON-массива модулей без примесей текста.
* Служебный индекс `<id>.json` хранится рядом с `<id>/` (`type == "file"`), а не внутри каталога бэкапа.
* DoD: регрессионные тесты с комментарием `# regression: #10` и коммит с футером `Fixes #10`.

## Review Focus

1. Повторный бэкап одного и того же пути внутри одного `YGG_BACKUP_ID` не затирает первый снимок, а создаёт суффикс `.1`, `.2` и фиксирует обе записи в `<id>.json` (Task 1).
2. Сбой на позднем шаге `apply` (после бэкапа части целей) всё равно выводит в `stderr` сводку уже созданных бэкапов из блока `catch` (Task 3).
3. Вызов `safe-link` из дочернего `setup.nu` наследует `YGG_BACKUP_ID` через `run-module-setup` и попадает в тот же `<id>/` и `<id>.json` (Task 3).
4. Осиротевший `<id>.json` (без каталога `<id>/`) удаляется при не-dry-run `rotate-backups` и игнорируется в `list-recent-backups`; legacy-каталог без `.json` показывается в `ygg status` с пометкой `(legacy)` (Task 1, Task 4).
5. `ygg status --json` остаётся валидным JSON-массивом модулей, а `--dry-run` не создаёт `.state/backups/<id>.json` (Task 3, Task 4).

---

### Task 1: Единый `YGG_BACKUP_ID`, индекс `<id>.json`, коллизии и ротация в `src/state.nu`

**Files:**
- Modify: `src/state.nu:282-302` (`backup-existing`), `src/state.nu:700-765` (`rotate-backups`)
- Test: `tests/test_state.nu`

**Interfaces:**
- Produces:
  - `new-backup-id []: nothing -> string`
  - `backup-existing [ygg_home: string, target_path: string, --backup-id: string = ""]: nothing -> string`
  - `read-backup-run [ygg_home: string, backup_id: string]: nothing -> record` (`{ id: string, dir: string, created_at: string, entries: list<record> }`)
  - `list-recent-backups [ygg_home: string, --limit: int = 5]: nothing -> list<record>` (`{ id: string, dir: string, created_at: string, targets: list<string>, legacy: bool }`)
  - `rotate-backups` удаляет парный `<id>.json` вместе с `<id>/` и подчищает осиротевшие `<id>.json` при не-dry-run.

- [ ] **Step 1: Write failing tests in `tests/test_state.nu` (`# regression: #10`)**

Добавить тесты:
- `test_backup_existing_groups_by_env_and_resolves_collisions`:
  - `with-env { YGG_BACKUP_ID: "20261117_120000_000001" }` для двух разных файлов `a.conf` и `b.conf` складывает оба в `$home/.state/backups/20261117_120000_000001/` и записывает 2 записи в `20261117_120000_000001.json`.
  - Повторное создание `a.conf` и вызов `backup-existing` с тем же `YGG_BACKUP_ID` сохраняет второй файл с суффиксом `.1`, не затирая первый снимок, и добавляет 3-ю запись в `.json`.
- `test_rotate_backups_removes_json_index_and_orphans`:
  - Создаёт 3 каталога бэкапов с `.json` индексами + 1 осиротевший `orphan.json` без каталога.
  - Вызов `rotate-backups $home --max-count=1 --max-age-days=0` удаляет 2 старых каталога, их `.json` и осиротевший `orphan.json`, возвращая список из 2 удалённых каталогов.
- `test_list_recent_backups_handles_indexed_legacy_and_orphan`:
  - Проверяет, что `list-recent-backups` возвращает индексированные бэкапы с `targets`, legacy-каталоги с `legacy: true` и игнорирует осиротевшие `.json`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `rtk nu tests/run.nu --filter test_state`
Expected: FAIL (отсутствуют `list-recent-backups`, `--backup-id`, `<id>.json`).

- [ ] **Step 3: Implement `new-backup-id`, update `backup-existing`, add `read-backup-run`, `list-recent-backups`, update `rotate-backups` in `src/state.nu`**

Реализовать:
- `export def new-backup-id []: nothing -> string` -> `date now | format date "%Y%m%d_%H%M%S_%f"`.
- `backup-existing`: приоритет `if ($backup_id != "") { $backup_id } else if (($env.YGG_BACKUP_ID? | default "") != "") { $env.YGG_BACKUP_ID } else { new-backup-id }`. При существовании `$dest_path` перебирать суффикс `.1`, `.2`, ... до свободного пути. После `mv` читать (если есть) и обновлять `$bkp_root/($bid).json` через `to json -i 2 | save -f`.
- `export def read-backup-run [ygg_home: string, backup_id: string]: nothing -> record`.
- `export def list-recent-backups [ygg_home: string, --limit: int = 5]: nothing -> list<record>`.
- В `rotate-backups`: при не-dry-run вместе с `rm -rf $dir` удалять `$"($dir).json"`, если существует; также удалять осиротевшие `*.json` в `$bkp_root`, если одноимённый каталог отсутствует.

- [ ] **Step 4: Run `test_state` to verify pass**

Run: `rtk nu tests/run.nu --filter test_state`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
rtk git add src/state.nu tests/test_state.nu
rtk git commit -m "feat(state): group backups by run id and track backup index"
```

---

### Task 2: Сводка бэкапов в `src/progress.nu` и `stderr` в `backup-with-notice` (`src/link.nu`)

**Files:**
- Modify: `src/progress.nu:143-168`, `src/link.nu:299-308`
- Test: `tests/test_progress.nu`

**Interfaces:**
- Consumes: `read-backup-run` record `{ id, dir, entries }` (Task 1)
- Produces: `format-backup-summary [run: record, --limit: int = 10]: nothing -> string`

- [ ] **Step 1: Write failing tests in `tests/test_progress.nu` (`# regression: #10`)**

Добавить тесты:
- `test_format_backup_summary_empty_and_under_limit`:
  - для пустого `entries` возвращает `""`;
  - для 2 записей возвращает `[ygg] Backed up 2 path(s) -> <dir>:` и строки `  - <target>`.
- `test_format_backup_summary_truncates_over_limit`:
  - для 12 записей при `--limit 10` выводит ровно 10 элементов и строку `  ... and 2 more`.

- [ ] **Step 2: Run `test_progress` to verify it fails**

Run: `rtk nu tests/run.nu --filter test_progress`
Expected: FAIL (`format-backup-summary` не найдена).

- [ ] **Step 3: Implement `format-backup-summary` in `src/progress.nu` and switch `backup-with-notice` in `src/link.nu` to `print -e`**

- В `src/progress.nu`: добавить `export def format-backup-summary [run: record, --limit: int = 10]: nothing -> string`.
- В `src/link.nu:304`: заменить `print` на `print -e`, чтобы построчное уведомление не смешивалось с `stdout` итоговой строки `Applied N module(s).`.

- [ ] **Step 4: Run `test_progress` and `test_link` to verify pass**

Run: `rtk nu tests/run.nu --filter test_progress && rtk nu tests/run.nu --filter test_link`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
rtk git add src/progress.nu src/link.nu tests/test_progress.nu
rtk git commit -m "feat(progress): add format-backup-summary and route backup notice to stderr"
```

---

### Task 3: Проброс `YGG_BACKUP_ID` через `add` / `apply` / `remove` / `setup.nu` и вывод сводки

**Files:**
- Modify: `src/sdk.nu:340-355` (`run-module-setup`), `bin/ygg.nu:98-260` (`main add`, `main remove`), `bin/ygg.nu:480-616` (`apply-plan`)
- Test: `tests/test_e2e_apply.nu`

**Interfaces:**
- Consumes: `new-backup-id`, `read-backup-run` (`src/state.nu`), `format-backup-summary` (`src/progress.nu`)
- Produces: единая папка бэкапов и сводка в `stderr` для `add`, `apply`, `update`, `remove` (включая ветку `catch` при частичном сбое).

- [ ] **Step 1: Write failing E2E tests in `tests/test_e2e_apply.nu` (`# regression: #10`)**

Добавить тесты:
- `test_apply_and_setup_group_backups_and_print_summary`:
  - модуль с 2 конфликтующими файлами в `[links]` и вызовом `safe-link` в `setup.nu` (для 3-го файла) при `ygg apply`:
    - создаёт ровно 1 каталог в `$home/.state/backups/` (и 1 `.json`);
    - в `stderr` выводит `Backed up 3 path(s) ->` и все 3 исходных пути.
- `test_apply_failure_still_prints_backup_summary`:
  - при ошибке после шага `links` (например, падающий `setup.nu` или `pkg`) `stderr` всё равно содержит сводку уже забэкапленных путей.
- `test_apply_dry_run_creates_no_backup_index`:
  - `ygg apply --dry-run` при наличии конфликтующих файлов не создаёт ни каталогов, ни `.json` в `.state/backups/`.

- [ ] **Step 2: Run `test_e2e_apply` to verify they fail**

Run: `rtk nu tests/run.nu --filter test_e2e_apply`
Expected: FAIL (создаётся несколько каталогов бэкапов, нет сводки).

- [ ] **Step 3: Wire `YGG_BACKUP_ID` and summary printing in `src/sdk.nu` and `bin/ygg.nu`**

- В `src/sdk.nu` (`run-module-setup`): добавить `YGG_BACKUP_ID: ($env.YGG_BACKUP_ID? | default "")` в `$env_vars`.
- В `bin/ygg.nu`:
  - Импортировать `new-backup-id`, `read-backup-run` из `state.nu` и `format-backup-summary` из `progress.nu`.
  - В `main add`: обернуть `register-staged-module` + `apply-plan` в `with-env { YGG_BACKUP_ID: (new-backup-id) }`.
  - В `apply-plan` (после ветки `if $dry_run`): вычислить `$run_backup_id = (if (($env.YGG_BACKUP_ID? | default "") != "") { $env.YGG_BACKUP_ID } else { new-backup-id })` и обернуть транзакцию в `with-env { YGG_BACKUP_ID: $run_backup_id }`. Печатать `format-backup-summary (read-backup-run $ygg_home $run_backup_id)` в `stderr` (если не пусто) как после `format-apply-summary`, так и в `catch` до `error make $e`.
  - В `main remove`: обернуть `unlink-module` в `with-env { YGG_BACKUP_ID: $run_backup_id }` и напечатать сводку в `stderr`, если были бэкапы (`dir_copy`).

- [ ] **Step 4: Run `test_e2e_apply` to verify pass**

Run: `rtk nu tests/run.nu --filter test_e2e_apply`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
rtk git add src/sdk.nu bin/ygg.nu tests/test_e2e_apply.nu
rtk git commit -m "feat(apply): group run backups via YGG_BACKUP_ID and print summary"
```

---

### Task 4: Отображение недавних бэкапов в `ygg status` и финальная верификация

**Files:**
- Modify: `bin/ygg.nu:769-780` (`main status`)
- Test: `tests/test_e2e_cli_core.nu`

**Interfaces:**
- Consumes: `list-recent-backups` (`src/state.nu`)
- Produces: человекочитаемый вывод `Recent backups` после таблицы модулей в `ygg status`, неизменный `--json`.

- [ ] **Step 1: Write failing tests in `tests/test_e2e_cli_core.nu` (`# regression: #10`)**

Добавить тесты:
- `test_status_shows_recent_backups_and_preserves_json`:
  - создаёт индексированный бэкап (через `backup-existing` / `ygg apply`) и legacy-каталог без `.json`;
  - `ygg status` (без `--json`) содержит таблицу модулей и секцию `Recent backups`, включая путь из индекса и `(legacy)`;
  - `ygg status --json` парсится через `from json` строго как список записей модулей без лишнего текста.

- [ ] **Step 2: Run `test_e2e_cli_core` to verify it fails**

Run: `rtk nu tests/run.nu --filter test_e2e_cli_core`
Expected: FAIL (`Recent backups` отсутствует в выводе `ygg status`).

- [ ] **Step 3: Implement `Recent backups` section in `main status` (`bin/ygg.nu`)**

В `main status`:
- при `--json`: `print ($rows | to json --raw)` (без изменений).
- без `--json`: `print ($rows | table)`; затем получить `let recent = (list-recent-backups $ygg_home --limit 5)`; если не пусто, вывести `Recent backups:` и строки формата `<id>  (<N> path(s)): <первые 3 пути + "+M more">` или `<id>  (legacy)`.

- [ ] **Step 4: Run full test suite and `context-init` check**

Run:
```bash
rtk mise run test
rtk context-init update . --compact --prune
rtk context-init check --compact
```
Expected: все тесты PASS, `context-init check` без ошибок дрейфа.

- [ ] **Step 5: Commit**

```bash
rtk git add bin/ygg.nu tests/test_e2e_cli_core.nu .context-init/
rtk git commit -m "feat(status): show recent backups in ygg status

Fixes #10"
```
