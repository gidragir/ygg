---
directory: docs
source:
  kind: git
  blob_sha: e4c4b66aba182072d4edd1d04f2c925bdb39a9bd
  commit_sha: 23920184815ab8144336b355ca51148c6577d991
generated_by:
  component: context-init
  role: update
  model: none
freshness:
  total_entries: 15
  sampled_entries: 15
  unsampled_entries: 0
  pending_child_changes: 0
---

# Подсистема: Docs (L1)

Модуль и компоненты директории `docs` (15 файлов)

> **Идентификатор:** `docs`
> **Теги:** Generic / Multi-language, docs

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `docs/bugs/2026-11-12-phase4-open-defects.md` | Исходный код |
| `docs/plans/2026-11-07-ygg-phase1-engine.md` | Исходный код |
| `docs/plans/2026-11-08-ygg-engine-improvements-and-hardening.md` | Исходный код |
| `docs/plans/2026-11-08-ygg-phase2-engine-fixes.md` | Исходный код |
| `docs/plans/2026-11-08-ygg-phase2-modules-migration.md` | Исходный код |
| `docs/plans/2026-11-08-ygg-phase3-implementation-plan.md` | Исходный код |
| `docs/plans/2026-11-10-ygg-phase4-implementation-plan.md` | Исходный код |
| `docs/plans/2026-11-15-ygg-module-containers-plan.md` | Исходный код |
| `docs/specs/2026-11-07-modular-omni-architecture-design.md` | Исходный код |
| `docs/specs/2026-11-08-ygg-engine-improvements-and-hardening.md` | Исходный код |
| `docs/specs/2026-11-08-ygg-phase3-resilience-and-ecosystem.md` | Исходный код |
| `docs/specs/2026-11-10-ygg-phase4-correctness-and-security-hardening.md` | Исходный код |
| `docs/specs/2026-11-15-ygg-module-containers-design.md` | Исходный код |
| `docs/specs/2026-11-16-ygg-live-progress-design.md` | Исходный код |
| `docs/superpowers/plans/2026-11-16-ygg-live-progress.md` | Исходный код |

## 🔑 Ключевой контракт и экспорты
```text
export def test_state_roundtrip_and_dirs []
export def test_expand_target_path_with_sandbox_and_tokens []
export def test_backup_moves_regular_file_outside_config []
export def test_scope_isolation_and_last_module_wins []
export def test_rejects_incompatible_os []
export def test_sdk_functions_respect_ygg_dry_run []
export def test_preflight_blocks_missing_link_source_before_packages []
export def preflight-check [ ygg_home: string, plan: record, resolved: record =
export def format-preflight-errors [problems: list<record>]: nothing -> string
export def test_load_host_config_rejects_broken_toml []
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
