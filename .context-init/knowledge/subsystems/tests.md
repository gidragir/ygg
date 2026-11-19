---
directory: tests
source:
  kind: git
  blob_sha: 74b4293e966efe5d6566c69be1189e8c0897c483
  commit_sha: 46316c5ab09f957e0847a0c89ac011084ca5316a
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

# Подсистема: Tests (L1)

Тесты проекта

> **Идентификатор:** `tests`
> **Теги:** Generic / Multi-language, tests, tests

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `tests/test_container.nu` | Исходный код |
| `tests/test_doctor.nu` | Исходный код |
| `tests/test_e2e_apply.nu` | Исходный код |
| `tests/test_e2e_cli_core.nu` | Исходный код |
| `tests/test_e2e_completions.nu` | Исходный код |
| `tests/test_e2e_containers.nu` | Исходный код |
| `tests/test_e2e_modules.nu` | Исходный код |
| `tests/test_env.nu` | Исходный код |
| `tests/test_link.nu` | Исходный код |
| `tests/test_lint.nu` | Исходный код |
| `tests/test_manifest.nu` | Исходный код |
| `tests/test_pkg_git.nu` | Исходный код |
| `tests/test_progress.nu` | Исходный код |
| `tests/test_sdk.nu` | Исходный код |
| `tests/test_state.nu` | Исходный код |

## 🧪 Запуск и тестирование
```bash
rtk mise run test
```
