---
directory: docs
source:
  kind: git
  blob_sha: 9ec30a9f2c79f83122ac40d191dd9b8978bb3be8
  commit_sha: cbe6f55f9c93a1c852c25c768b190ed5077ae844
generated_by:
  component: context-init
  role: init
  model: none
freshness:
  total_entries: 6
  sampled_entries: 6
  unsampled_entries: 0
  pending_child_changes: 0
---

# Подсистема: Docs (L1)

Модуль и компоненты директории `docs` (6 файлов)

> **Идентификатор:** `docs`
> **Теги:** Generic / Multi-language, docs

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `docs/plans/2026-11-07-ygg-phase1-engine.md` | Исходный код |
| `docs/plans/2026-11-08-ygg-engine-improvements-and-hardening.md` | Исходный код |
| `docs/plans/2026-11-08-ygg-phase2-engine-fixes.md` | Исходный код |
| `docs/plans/2026-11-08-ygg-phase2-modules-migration.md` | Исходный код |
| `docs/specs/2026-11-07-modular-omni-architecture-design.md` | Исходный код |
| `docs/specs/2026-11-08-ygg-engine-improvements-and-hardening.md` | Исходный код |

## 🔑 Ключевой контракт и экспорты
```text
export def test_state_roundtrip_and_dirs []
export def test_expand_target_path_with_sandbox_and_tokens []
export def test_backup_moves_regular_file_outside_config []
export def test_scope_isolation_and_last_module_wins []
export def test_rejects_incompatible_os []
export def test_glob_shared_dir_and_ownership_conflict []
export def test_replaces_dangling_symlink_without_backup []
export def test_scope_switch_prunes_old_links_safely []
export def test_three_way_copy_sync_preserves_host_gui_edits []
export def test_onchange_skips_recovers_missing_target_and_rolls_back_on_error []
export def test_merge_json_missing_and_symlink_target []
export def test_env_special_chars_escaping []
export def test_mock_pkg_filters_by_host_os []
export def test_update_aborts_cleanly_on_conflict []
export def test_full_cli_lifecycle []
export def test_sdk_functions_respect_ygg_dry_run []
export def test_preflight_blocks_missing_link_source_before_packages []
export def preflight-check [ ygg_home: string, plan: record, resolved: record =
export def format-preflight-errors [problems: list<record>]: nothing -> string
export def test_onchange_wildcard_pattern_does_not_call_path_exists_on_glob []
export def test_to_win32_path_preserves_symlink_and_replaces_slashes []
export def test_ensure_executable_sets_mode_and_suppresses_stderr []
export def test_cli_version_flag_and_subcommand []
export def test_ygg_cmd_shim_search_paths_and_setlocal []
def ensure-executable [p: string]: nothing -> nothing
export def test_env_expands_leading_tilde_and_home_only []
export def test_missing_secret_keys_audit []
export def test_export_secrets_warns_on_missing_requested_keys []
export def test_missing_package_manager_warns_and_skips_without_failing []
def resolve-env-value [v: string, sb: string]: nothing -> string
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
