# Executor Prompt: RFC-062 Module Lint (`ygg lint`) & Reusable CI Workflow (`module-check.yml`)

## Целевые скиллы
* `.agents/skills/nushell-ygg-dev/SKILL.md` (обязателен перед редактированием любых `.nu` файлов)
* `superpowers:test-driven-development`
* `superpowers:verification-before-completion`

## Обязательная директива навигации
Для исследования архитектуры и API используй `rtk context-init pack <subsystem_id> --compress`. Не вычитывай файлы директории целиком.

## Входные документы и границы файлов
* Спецификация: `docs/specs/2026-11-17-ygg-module-lint-and-ci-design.md`
* План: `docs/superpowers/plans/2026-11-19-ygg-module-lint-and-ci.md`
* Затрагиваемые файлы:
  * Create: `src/lint.nu`, `tests/test_lint.nu`, `.github/workflows/module-check.yml`, `tests/fixtures/module-sample/*`
  * Modify: `src/manifest.nu`, `src/pkg.nu`, `bin/ygg.nu`, `mise.toml`, `tests/run.nu`, `scripts/release.nu`, `tests/test_release.nu`, `.github/workflows/ci.yml`, `README.md`, `.agents/skills/ygg-module-verification/SKILL.md`
  * Delete: `tests/test_phase2_modules.nu`

## Ключевые инварианты реализации
1. `ygg lint` — строго read-only (`AGENTS.md` §2.1): без `ensure-ygg-dirs`, без `host.lock`, без записи вне `mktemp -d`, без прогресса в `stderr` и без `ygg-proc-*.log`. Временный каталог удаляется в `try/catch` при любом исходе.
2. `src/link.nu` и `src/state.nu` ради `lint` не меняются.
3. Формат находок идентичен `doctor --json` (`{check, severity, target, detail, fix}`); у L5 добавляются `{os, scopes, cross_os}`. Код выхода `1` только при `severity == "error"`.
4. `YGG_HOST_OS_OVERRIDE` и временный `YGG_MOCK_PKG_LOG` из L5 не должны протекать в L4 (`setup.nu`), L6 (`probe-packages`) и `compose`.
5. Путь `setup.nu` в L4 передавать через `with-env { YGG_LINT_SETUP: $setup_path }` и `^nu -I $src_dir -c 'nu-check $env.YGG_LINT_SETUP'` (безопасно для пробелов и Windows `\`).
6. Все тесты строго внутри `with-temp-ygg`, с комментариями `# regression: #23`, `# regression: #35`, `# regression: #38`; финальные коммиты с футерами `Fixes #23`, `Fixes #35`, `Fixes #38`.
7. После `gh pr create` обязательно проверить CI через `gh pr checks --watch` (в т.ч. `windows-latest` и `module-check`).

## Команды верификации
```bash
rtk nu tests/run.nu --filter test_lint
rtk nu tests/run.nu --filter test_release
rtk nu tests/run.nu --filter test_e2e_completions
rtk nu bin/ygg.nu lint tests/fixtures/module-sample
rtk mise run test
rtk context-init update . --compact --prune
rtk context-init check --compact
```
