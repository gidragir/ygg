# Ygg Live Single-Line Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить потоковый однострочный живой прогресс в `stderr` для долгих операций `ygg` (`apply`, `upgrade`, `update`, `add`, `remove`) с сохранением раздельных потоков `stdout`/`stderr` и чистого вывода в non-TTY/`--dry-run`.

**Architecture:** Новый модуль `src/progress.nu` отвечает за автоопределение TTY (`is-terminal --stderr`, `TERM != "dumb"`, пустой `NO_COLOR`), безопасное чтение ~4 КБ хвоста логов с учётом UTF-8 и сплитом `[\r\n]+` до `ansi strip`, а также рендер/очистку однострочного статуса. `run-with-timeout` в `src/pkg.nu` при `--label != ""` запускает процесс в `job spawn` с `try/catch` и раздельными файлами `o> $out_log e> $err_log`, опрашивает `job recv` каждые 250 мс и гарантированно чистит дерево процессов и временные файлы при завершении, таймауте или прерывании.

**Tech Stack:** Nushell (`>= 0.116`), `std/assert` (`tests/helpers.nu`, `tests/run.nu`), `mktemp` (uutils built-in).

**Spec:** [docs/specs/2026-11-16-ygg-live-progress-design.md](../../specs/2026-11-16-ygg-live-progress-design.md)

## Global Constraints

* **Nushell `>= 0.116` без внешних зависимостей:** работает на Linux, macOS и Windows 11/Server (Non-Admin); все пути и `mktemp -t --suffix .log ygg-proc-XXXXXX` строго кроссплатформенные.
* **ZERO HOST MUTATION:** временные файлы прогресса создаются строго в системном tmp (`$nu.temp-dir`), никогда в `$HOME`, `$YGG_HOME` или модулях; все тесты работают внутри `with-temp-ygg`, без литеральных `/tmp/...`; при `YGG_MOCK_PKG_LOG` подпроцессы не запускаются и формат мок-логов не меняется.
* **Канал и режимы вывода:** весь прогресс строго в `stderr`; TTY-режим активен только при `(is-terminal --stderr) and (($env.TERM? | default "") != "dumb") and (($env.NO_COLOR? | default "") == "")`. В `--dry-run`, `ygg diff`, `ygg status`, `ygg doctor` прогресс полностью отключён.
* **Контракт `run-with-timeout`:** сохраняет `record<exit_code: int, stdout: string, stderr: string, timed_out: bool>` и независимость `stdout`/`stderr`; отсутствующий бинарник возвращает `exit_code: 127` с текстом ошибки в `stderr`; таймаут возвращает `exit_code: 124, timed_out: true`; `$label == ""` с `$timeout_sec <= 0` остаётся синхронным (`| complete`).
* **Прогресс `git` и защита `sudo`:** вызовы `git clone`/`fetch`/`pull` с `--label` передают `--progress`; при интерактивном `stdin` перед командами с `SUDO_MGRS`/`paru`/`systemd-system` выполняется прогрев `^sudo -v` или подавляется тикер (`--no-tty-progress`).

## Review Focus

1. **`\r`-перезаписи без `\n` (`git --progress`, `curl`) и `ansi strip`:** сплит по `[\r\n]+` обязан выполняться строго **до** `ansi strip`, иначе `ansi strip` удалит `\r`, склеит кадры, и обрезка покажет старый процент.
2. **Срез ~4 КБ на границе многобайтовых UTF-8 символов:** отбрасывание ведущих continuation-байтов (`0x80..0xBF`, до 3 байт) перед `decode utf-8` предотвращает ошибку декодирования.
3. **Сверх-узкий терминал (`width` меньше длины префикса + таймера):** clamp ширины (`[$width, 20] | math max`) и защита от отрицательной длины среза в `format-progress-line`.
4. **Ненулевой код выхода и отсутствующий бинарник внутри `job spawn`:** `o> ... e> ...` бросает исключение в Nu 0.116; `try/catch` внутри `job spawn` гарантирует `job send`, разделение `stdout`/`stderr` (важно для `WINGET_OK_CODES`) и маппинг отсутствующего бинарника на `127`.
5. **Прерывание/исключение в polling-цикле и утечка логов:** `try/catch` вокруг цикла гарантирует `kill-job-tree $jid`, `progress-clear-line` и `try { rm -f ... } catch {}` для обоих лог-файлов.

---

### Task 1: Модуль `src/progress.nu`, экспорт и юнит-тесты

**Files:**
- Create: `src/progress.nu`
- Modify: `src/mod.nu:1-12`
- Test: `tests/test_progress.nu`

**Interfaces:**
- Consumes: built-in `is-terminal`, `term size`, `ansi strip`, `open --raw`, `bytes at`
- Produces:
  - `is-tty-progress []: nothing -> bool`
  - `sanitize-log-line [line: string]: nothing -> string`
  - `read-last-log-line [path: string]: nothing -> string`
  - `read-progress-tail [err_path: string, out_path: string]: nothing -> string`
  - `progress-clear-line []: nothing -> nothing`
  - `format-progress-line [spinner: string, label: string, tail: string, elapsed_sec: int, width: int]: nothing -> string`
  - `format-progress-done [status: string, label: string, elapsed_sec: float]: nothing -> string`
  - `progress-step [phase: string, msg: string]: nothing -> nothing`

- [ ] **Step 1: Написать падающие юнит-тесты в `tests/test_progress.nu`**

Покрыть: `test_progress_sanitize_and_split` (`\r`-перезаписи без `\n`, `\t`, CSI `\x1b[2K`, `\x1b[32m`), `test_progress_read_last_log_line_edge_cases` (несуществующий/пустой файл, многострочный, `\r`-only поток, >5 КБ файл с кириллицей/эмодзи в начале 4 КБ хвоста), `test_progress_format_and_narrow_width` (`(14s)`, `(18.4s)`, обрезка под `width: 80` и `width: 15` без отрицательного среза), `test_progress_is_tty_env_guards` (`NO_COLOR=1`, `TERM=dumb`, non-TTY).

- [ ] **Step 2: Прогнать тесты и убедиться, что они падают**

Run: `rtk nu tests/run.nu --filter test_progress`
Expected: FAIL (модуль/команды `progress.nu` не найдены).

- [ ] **Step 3: Реализовать `src/progress.nu` и добавить `export use progress.nu *` в `src/mod.nu`**

Ключевые детали:
- `read-last-log-line`: при размере `bytes length > 4096` брать `bytes at (-4096)..`, пропустить до 3 ведущих байт в диапазоне `0x80..0xBF`, декодировать через `decode utf-8` (fallback на `into string`), затем `split row --regex '[\r\n]+'` **до** `sanitize-log-line`.
- `read-progress-tail`: сравнить наличие/mtime `$err_path` и `$out_path`; читать наиболее свежий непустой хвост (`$err_path` приоритетен при равенстве).
- `term-columns`: `try { [(term size).columns, 20] | math max } catch { 80 }`.
- `format-progress-line`: если `$tail` пуст — опустить `| `; иначе обрезать `$tail` до доступного остатка с `...` (при нехватке места обрезать и префикс).
- `progress-clear-line`: `if (is-tty-progress) { print -e -n "\r\x1b[2K" }`.
- `progress-step`: в `stderr` `$"[(phase)] ($msg)"` (предварительно `progress-clear-line`).

- [ ] **Step 4: Прогнать тесты и убедиться, что они проходят**

Run: `rtk nu tests/run.nu --filter test_progress`
Expected: PASS (все юнит-тесты `test_progress_*`).

- [ ] **Step 5: Зафиксировать изменения локальным коммитом (или отметить выполненным перед Task 2)**

```bash
rtk git add src/progress.nu src/mod.nu tests/test_progress.nu && rtk oco -y
```

---

### Task 2: Потоковый `run-with-timeout --label` в `src/pkg.nu`

**Files:**
- Modify: `src/pkg.nu:1-112`
- Test: `tests/test_progress.nu`

**Interfaces:**
- Consumes: `progress.nu` (`is-tty-progress`, `read-progress-tail`, `progress-clear-line`, `format-progress-line`, `format-progress-done`)
- Produces:
  - `run-with-timeout [argv: list<string>, timeout_sec: int, --label: string = "", --no-tty-progress]: nothing -> record<exit_code: int, stdout: string, stderr: string, timed_out: bool>`
  - `SPINNER_FRAMES = ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]` (внутренний спиннер цикла)

- [ ] **Step 1: Написать падающие тесты `run-with-timeout --label` в `tests/test_progress.nu`**

Покрыть:
- `test_run_with_timeout_label_streams_and_exit_codes`: раздельные `stdout` и `stderr` как при `exit_code == 0`, так и при ненулевом коде (имитация `WINGET_OK_CODES`).
- `test_run_with_timeout_label_missing_bin`: несуществующий бинарник возвращает `exit_code: 127`, непустой `stderr`, `timed_out: false`.
- `test_run_with_timeout_label_plain_and_no_color`: запуск `nu -c` с `NO_COLOR=1` проверяет в `stderr` `[label]...` и `[ok] label (...)` без `\r` и `\x1b[`.
- `test_run_with_timeout_label_cr_stream_and_no_timeout`: реальный `nu -c` пишет `\r`-строки в `stderr` и завершается при `$timeout_sec = 0` с `--label != ""`; сравнить с `$timeout_sec = 0` при `$label == ""`.
- `test_run_with_timeout_label_timeout_and_cleanup`: превышение таймаута возвращает `exit_code: 124`, `timed_out: true`, убивает дерево (`kill-job-tree`) и не оставляет `ygg-proc-*.log` в `$nu.temp-dir`.
- `test_run_with_timeout_label_interrupt_cleanup`: проверка очистки `kill-job-tree` + удаления обоих временных файлов при ошибке в цикле опроса.

- [ ] **Step 2: Прогнать тесты и убедиться, что они падают**

Run: `rtk nu tests/run.nu --filter test_run_with_timeout_label`
Expected: FAIL (`run-with-timeout` не принимает `--label` / `--no-tty-progress`).

- [ ] **Step 3: Реализовать `--label` и `--no-tty-progress` в `run-with-timeout` (`src/pkg.nu`)**

Подход строго по §4.3 и §6 спеки:
- При `$label == ""` сохранить текущий код без изменений (`timeout_sec <= 0` синхронно, `> 0` через `job spawn`).
- При `$label != ""`:
  - Создать `$out_log` и `$err_log` через `mktemp -t --suffix .log ygg-proc-XXXXXX`.
  - Внутри `job spawn` выставить `PYTHONUNBUFFERED` (`default "1"`) и `COMPOSE_PROGRESS` (`default "plain"`), выполнить `try { ^$bin ...$args o> $out_log e> $err_log; { exit_code: ($env.LAST_EXIT_CODE? | default 0), spawn_err: "" } } catch { |e| let missing = (which $bin | is-empty); { exit_code: (if $missing { 127 } else { $env.LAST_EXIT_CODE? | default 1 }), spawn_err: $e.msg } }`, отправить через `job send 0 --tag $tag`.
  - Polling-цикл `job recv --tag $tag --timeout 250ms` обернуть в `try { ... } catch { |e| kill-job-tree $jid; progress-clear-line; rm-cleanup; error make $e }`. Поддержать `$timeout_sec <= 0` без лимита времени.
  - После выхода прочитать `$out_log`/`$err_log` (при пустом `stderr` и непустом `spawn_err` подставить `spawn_err`), удалить оба файла в `try/catch`, зафиксировать `[ok]` / `[fail]` / `[timeout]` в `stderr`.

- [ ] **Step 4: Прогнать тесты Task 1, Task 2 и существующий `test_pkg_git`**

Run: `rtk nu tests/run.nu --filter test_progress && rtk nu tests/run.nu --filter test_run_with_timeout`
Expected: PASS.

- [ ] **Step 5: Зафиксировать изменения**

```bash
rtk git add src/pkg.nu tests/test_progress.nu && rtk oco -y
```

---

### Task 3: Интеграция в `src/pkg.nu` и `src/container.nu` + защита интерактивного `sudo`

**Files:**
- Modify: `src/pkg.nu` (`prepare-provider-environment`, `run-install-argv`, `install-packages`, `prune-unused-packages`, новый `prepare-sudo-for-progress`)
- Modify: `src/container.nu` (`run-compose`, `run-container-step`, `upgrade-containers`, `down-module-stacks`, `container-warn-down`)
- Test: `tests/test_pkg_git.nu`, `tests/test_container.nu`

**Interfaces:**
- Consumes: `run-with-timeout` (`--label`, `--no-tty-progress`), `progress-clear-line`
- Produces:
  - `prepare-sudo-for-progress [needs_sudo: bool, interactive_prompt_risk: bool]: nothing -> bool` (возвращает `true`, если нужно передать `--no-tty-progress`)
  - `run-compose [argv: list<string>, timeout: int, --dry-run, --sandbox: string = "", --label: string = ""]: nothing -> record<status: string, stderr: string>`

- [ ] **Step 1: Написать падающие тесты в `tests/test_pkg_git.nu` и `tests/test_container.nu`**

Покрыть:
- `prepare-sudo-for-progress` возвращает `true` (отключает тикер) при `interactive_prompt_risk = true` (например, `paru`) в не-мок режиме при наличии TTY и `YGG_NONINTERACTIVE != "1"`, и `false` при `YGG_MOCK_PKG_LOG` / `YGG_NONINTERACTIVE=1`.
- `run-compose --label "[containers] up m/p"` в `--dry-run` и с `YGG_MOCK_PKG_LOG` сохраняет прежний формат мок-лога и результат.

- [ ] **Step 2: Прогнать тесты и убедиться, что они падают**

Run: `rtk nu tests/run.nu --filter test_container`
Expected: FAIL (`run-compose` не принимает `--label` / `prepare-sudo-for-progress` не определён).

- [ ] **Step 3: Обновить `src/pkg.nu` и `src/container.nu`**

- В `src/pkg.nu`: добавить `prepare-sudo-for-progress` (при интерактивном `stdin` и неуспешном `^sudo -n true` выполняет `^sudo -v` до запуска прогресса; если пароль не закэширован или менеджер `paru`, возвращает `true` для `--no-tty-progress`); передать `--label` в `prepare-provider-environment`, `run-install-argv`/`install-packages`, `prune-unused-packages` (включая `mise unuse`); вызывать `progress-clear-line` перед `print -e` предупреждениями.
- В `src/container.nu`: добавить `--label: string = ""` в `run-compose`, передать `[containers] <action> <module>/<project>` из `run-container-step`, `upgrade-containers`, `down-module-stacks`; вызывать `progress-clear-line` в `container-warn-down`.

- [ ] **Step 4: Прогнать пакетные и контейнерные тесты**

Run: `rtk nu tests/run.nu --filter test_pkg && rtk nu tests/run.nu --filter test_container`
Expected: PASS.

- [ ] **Step 5: Зафиксировать изменения**

```bash
rtk git add src/pkg.nu src/container.nu tests/test_pkg_git.nu tests/test_container.nu && rtk oco -y
```

---

### Task 4: Интеграция в `src/git.nu` и `src/sdk.nu`

**Files:**
- Modify: `src/git.nu` (`stage-module`, `checkout-module-ref`, `update-module`)
- Modify: `src/sdk.nu` (`run-module-setup`, `run-link-hooks`, `run-service-actions`)
- Test: `tests/test_pkg_git.nu`, `tests/test_sdk.nu`

**Interfaces:**
- Consumes: `run-with-timeout`, `prepare-sudo-for-progress`, `progress-clear-line`
- Produces: прежние публичные сигнатуры `src/git.nu` и `src/sdk.nu` без ломки контрактов

- [ ] **Step 1: Написать/дополнить тесты в `tests/test_sdk.nu` и `tests/test_pkg_git.nu`**

Покрыть:
- `run-module-setup`: при успешном `setup.nu` (`exit_code == 0`, не `dry-run`) не дублирует сырой `stdout` в поток вывода процесса (тест через подпроцесс `nu -c`), а при ошибке (`exit_code != 0`) пробрасывает `error make` с текстом из `stderr` (или `stdout`, если `stderr` пуст).
- `stage-module` / `update-module`: локальный git-клон и `pull --rebase` продолжают работать с `--progress` (на локальном bare-репозитории без падений).

- [ ] **Step 2: Прогнать тесты и убедиться, что новый тест падает**

Run: `rtk nu tests/run.nu --filter test_sdk`
Expected: FAIL на проверке подавления дублирующего `stdout` при `exit_code == 0` / fallback `stdout` при пустом `stderr`.

- [ ] **Step 3: Обновить `src/git.nu` и `src/sdk.nu`**

- `src/git.nu`: перевести `git clone --progress` (`stage-module`), `git fetch --progress --all --tags` и `git pull --progress --rebase` (`checkout-module-ref`, `update-module`) на `run-with-timeout ... 0 --label ...`. Короткие `rev-parse`, `status --porcelain`, `show-ref`, `stash`, `checkout`, `rebase --abort`, `reset` оставить на `| complete`.
- `src/sdk.nu`:
  - `run-module-setup`: вызывать `run-with-timeout ["nu", "-I", $ygg_src_dir, $setup_script] 0 --label $"[hooks] ($mod_name) setup.nu"` (только при `not $dry_run`; при `$is_dry == "true"` без `--label`); на `exit_code == 0` не печатать `res.stdout` при активном `--label`; на `exit_code != 0` вывести непустой `stderr` (fallback `stdout`) и `error make`.
  - `run-link-hooks`: передать `--label $"[hooks] ($modules): ($keys | str join ', ')"`, вызывать `progress-clear-line` перед `print -e`.
  - `run-service-actions`: передать `--label $"[services] ($action) ($svc) \(($mgr)\)"`, для `systemd-system` учитывать `prepare-sudo-for-progress`, вызывать `progress-clear-line` перед `print -e`.

- [ ] **Step 4: Прогнать `test_sdk` и `test_pkg_git`**

Run: `rtk nu tests/run.nu --filter test_sdk && rtk nu tests/run.nu --filter test_pkg_git`
Expected: PASS.

- [ ] **Step 5: Зафиксировать изменения**

```bash
rtk git add src/git.nu src/sdk.nu tests/test_sdk.nu tests/test_pkg_git.nu && rtk oco -y
```

---

### Task 5: Оркестрация фаз в `src/link.nu`, `bin/ygg.nu`, E2E и аудит дрейфа

**Files:**
- Modify: `src/link.nu` (`backup-with-notice`)
- Modify: `bin/ygg.nu` (`main add`, `main remove`, `main upgrade`, `main update`, `apply-plan`)
- Test: `tests/test_cli_e2e.nu`

**Interfaces:**
- Consumes: `progress-step`, `progress-clear-line`

- [ ] **Step 1: Добавить E2E-тесты в `tests/test_cli_e2e.nu`**

Покрыть:
- `ygg diff`, `ygg apply --dry-run`, `ygg status --json`, `ygg doctor --json` не содержат строк прогресса (`[ok]`, `[links]`, `\x1b[`) ни в `stdout`, ни в `stderr`.
- `ygg apply` и `ygg remove` в песочнице с моками отрабатывают с чистым `stdout` (`Applied ...` / `Removed ...`) и читаемым Plain-прогрессом в `stderr`.

- [ ] **Step 2: Прогнать новый E2E-тест и убедиться, что он падает**

Run: `rtk nu tests/run.nu --filter test_cli_e2e`
Expected: FAIL на новых проверках `progress-step` в `stderr` для `apply` / `remove`.

- [ ] **Step 3: Обновить `src/link.nu` и `bin/ygg.nu`**

- В `src/link.nu` (`backup-with-notice`): вызов `progress-clear-line` перед `print`.
- В `bin/ygg.nu`: добавить `progress-step` для фаз `apply-plan` (`preflight`, `links`, `finalize` — **строго при `not $dry_run`**), а также в `main add` (`not $dry_run`), `main remove`, `main upgrade` (`not $dry_run`), `main update`; перед финальным выводом и обработкой ошибок вызывать `progress-clear-line`.

- [ ] **Step 4: Полный прогон всех тестов и аудит дрейфа `context-init`**

Run:
```bash
rtk nu tests/run.nu
rtk context-init update . --compact --prune
rtk context-init check --compact
```
Expected: все тесты `tests/run.nu` PASS (`0 failed`), `context-init check` без `missing`/`untracked` дрейфа.

- [ ] **Step 5: Зафиксировать изменения**

```bash
rtk git add src/link.nu bin/ygg.nu tests/test_cli_e2e.nu .context-init/ && rtk oco -y
```
