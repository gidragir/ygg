# Отчёт по реализации RFC-060: Live Single-Line Progress (`ygg`)

> **Дата:** 2026-11-17  
> **Спецификация:** [2026-11-16-ygg-live-progress-design.md](../../specs/2026-11-16-ygg-live-progress-design.md)  
> **План:** [2026-11-16-ygg-live-progress.md](../plans/2026-11-16-ygg-live-progress.md)

---

## 1. Обзор изменений

| Файл | Назначение |
| :--- | :--- |
| [src/progress.nu](../../../src/progress.nu) | Новый модуль: автоопределение TTY (`is-tty-progress`), чтение ~4 КБ хвоста с защитой UTF-8 и сплитом `[\r\n]+` до `ansi strip` (`read-last-log-line`, `read-progress-tail`), рендер с графемным подсчётом длины/обрезкой и clamp ширины `>= 20` (`format-progress-line`, `format-progress-done`), `progress-clear-line`, `progress-step`. |
| [src/mod.nu](../../../src/mod.nu) | Экспорт `progress.nu *`. |
| [src/pkg.nu](../../../src/pkg.nu) | `run-with-timeout` с `--label` и `--no-tty-progress` (потоковый `job spawn` с раздельными `o>`/`e>`, `try/catch`, явный `exit_code: 0` в `try`, пустой `spawn_err` при обычном `exit != 0`, exit code `127` при отсутствии бинарника, опрос каждые 250 мс, сохранение `stderr` + суффикс при таймауте, гарантированная очистка `ygg-proc-*.log` и `kill-job-tree`); `prepare-sudo-for-progress`; интеграция в `prepare-provider-environment`, `run-install-argv`, `install-packages`, `prune-unused-packages`. |
| [src/container.nu](../../../src/container.nu) | Поддержка `--label` в `run-compose`, передача меток из `run-container-step`, `upgrade-containers` (`pull`/`build`/`down`/`up`) и `down-module-stacks`, `progress-clear-line` в `run-container-step` и `container-warn-down`. |
| [src/git.nu](../../../src/git.nu) | Перевод `git clone --progress` (`stage-module` вне `--read-only` с `--label $"[git] clone ($source)"`), `git fetch --progress --all --tags` и `git pull --progress --rebase` (`checkout-module-ref`, `update-module`) на `run-with-timeout ... 0 --label ...`. |
| [src/sdk.nu](../../../src/sdk.nu) | Интеграция `--label` в `run-module-setup` (без дублирования `stdout` при `exit_code == 0`, fallback `stdout` при пустом `stderr`), `run-link-hooks`, `run-service-actions` (с `prepare-sudo-for-progress` для `systemd-system`). |
| [src/link.nu](../../../src/link.nu) | Вызов `progress-clear-line` в `backup-with-notice`. |
| [bin/ygg.nu](../../../bin/ygg.nu) | `progress-step` в фазах `apply-plan` (`preflight`, `links`, `finalize` строго вне `--dry-run`), `main add` (вне `--dry-run`), `main remove`, `main upgrade`, `main update`; `progress-clear-line` перед финальным выводом и в `catch`. |
| [tests/test_progress.nu](../../../tests/test_progress.nu) | Юнит-тесты `src/progress.nu` (включая UTF-8 графемы) и `run-with-timeout --label` (включая регрессию `test_run_with_timeout_label_after_caught_error` и изоляцию временного каталога через `TMPDIR`/`TEMP`/`TMP`). |
| [tests/test_pkg_git.nu](../../../tests/test_pkg_git.nu), [tests/test_container.nu](../../../tests/test_container.nu), [tests/test_sdk.nu](../../../tests/test_sdk.nu), [tests/test_cli_e2e.nu](../../../tests/test_cli_e2e.nu) | Регрессионные и E2E-тесты для `prepare-sudo-for-progress`, `run-compose --label`, `run-module-setup` (включая проверку текста `stdout-err-fallback`), тишины `diff`/`apply --dry-run`/`add --dry-run`/`status`/`doctor` и Plain-прогресса `apply`/`remove`. |
| [AGENTS.md](../../../AGENTS.md), [SKILL.md](../../../.agents/skills/nushell-ygg-dev/SKILL.md), [ygg-module-verification/SKILL.md](../../../.agents/skills/ygg-module-verification/SKILL.md), `.context-init/knowledge/**` | Обновление правил и паттернов Nushell 0.116+ (§§19–21, включая явный `exit_code: 0` при `o>`/`e>` в `try/catch`) и базы знаний `context-init`. |

---

## 2. Результаты верификации

| Команда | Результат |
| :--- | :--- |
| `rtk nu tests/run.nu --filter test_progress` | PASS (4/4) |
| `rtk nu tests/run.nu --filter test_run_with_timeout` | PASS (6/6) |
| `rtk nu tests/run.nu --filter test_container_run_compose_with_label` | PASS (1/1) |
| `rtk nu tests/run.nu --filter test_run_module_setup_no_stdout_leak_and_error_fallback` | PASS (1/1) |
| `rtk nu tests/run.nu --filter test_cli_progress_phases_and_readonly_silence` | PASS (1/1) |
| `rtk nu tests/run.nu` | PASS (313 passed, 0 failed; `test_phase2_modules.nu` пропущен без `YGG_RUN_HOST_E2E=1`) |
| `rtk context-init update . --compact --prune && rtk context-init check --compact` | `missing=[], untracked=[], format=[]` (`git_stale=true` до коммита) |
