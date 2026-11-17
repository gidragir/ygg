---
directory: src/mod.nu
source:
  kind: git
  blob_sha: a14f866d4e6e92c9609cdbde1610bdfd2ec0ad0b
  commit_sha: b269cb6d37622578ea87359c014f11e40cae0830
generated_by:
  component: context-init
  role: update
  model: none
freshness:
  total_entries: 1
  sampled_entries: 1
  unsampled_entries: 0
  pending_child_changes: 0
---

# Подсистема: Mod (L1)

Модуль и компоненты директории `src/mod` (1 файлов)

> **Идентификатор:** `src_mod`
> **Теги:** Generic / Multi-language, src_mod

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `src/mod.nu` | Исходный код |

## 🔑 Ключевой контракт и экспорты
```text
export use state.nu * export use manifest.nu * export use link.nu * export use sdk.nu * export use env.nu * export use pkg.nu * export use git.nu * export use doctor.nu * export use container.nu * export use progress.nu * export use engine.nu *
```

## 🧪 Запуск и тестирование
```bash
rtk mise run test
```
