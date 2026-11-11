---
directory: docs
source:
  kind: git
  blob_sha: bc7b01622e6c9396ec77aaf7db69d124fddc0cc6
  commit_sha: ac486e880edb2f0a1fc2abdaa8a24e77bb9f471d
generated_by:
  component: context-init
  role: update
  model: none
freshness:
  total_entries: 10
  sampled_entries: 10
  unsampled_entries: 0
  pending_child_changes: 0
---

# Подсистема: Docs (L1)

Модуль и компоненты директории `docs` (10 файлов)

> **Идентификатор:** `docs`
> **Теги:** Generic / Multi-language, docs

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `docs/plans/2026-11-07-ygg-phase1-engine.md` | Исходный код |
| `docs/plans/2026-11-08-ygg-engine-improvements-and-hardening.md` | Исходный код |
| `docs/plans/2026-11-08-ygg-phase2-engine-fixes.md` | Исходный код |
| `docs/plans/2026-11-08-ygg-phase2-modules-migration.md` | Исходный код |
| `docs/plans/2026-11-08-ygg-phase3-implementation-plan.md` | Исходный код |
| `docs/plans/2026-11-10-ygg-phase4-implementation-plan.md` | Исходный код |
| `docs/specs/2026-11-07-modular-omni-architecture-design.md` | Исходный код |
| `docs/specs/2026-11-08-ygg-engine-improvements-and-hardening.md` | Исходный код |
| `docs/specs/2026-11-08-ygg-phase3-resilience-and-ecosystem.md` | Исходный код |
| `docs/specs/2026-11-10-ygg-phase4-correctness-and-security-hardening.md` | Исходный код |

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
