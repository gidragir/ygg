---
directory: tests/fixtures/module-sample
source:
  kind: git
  blob_sha: 7c459c02c1b3fb8e123b1e1448ac4817959a802d
  commit_sha: 46316c5ab09f957e0847a0c89ac011084ca5316a
generated_by:
  component: context-init
  role: update
  model: none
freshness:
  total_entries: 3
  sampled_entries: 3
  unsampled_entries: 0
  pending_child_changes: 0
---

# Подсистема: Tests Fixtures (L1)

Тесты для `tests`

> **Идентификатор:** `tests_fixtures`
> **Теги:** Generic / Multi-language, tests, tests_fixtures

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `tests/fixtures/module-sample/links.toml` | Исходный код |
| `tests/fixtures/module-sample/packages.toml` | Исходный код |
| `tests/fixtures/module-sample/ygg.toml` | Исходный код |

## 🧪 Запуск и тестирование
```bash
rtk mise run test
```
