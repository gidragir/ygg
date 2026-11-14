---
directory: src/sdk.nu
source:
  kind: git
  blob_sha: b2fc8172b203f12b55b57d237d30158983d137f6
  commit_sha: 815458e5b6bc88a3a157c1c5138ac1e9e9d102aa
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

# Подсистема: Sdk (L1)

Модуль и компоненты директории `src/sdk` (1 файлов)

> **Идентификатор:** `src_sdk`
> **Теги:** Generic / Multi-language, src_sdk

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `src/sdk.nu` | Исходный код |

## 🔑 Ключевой контракт и экспорты
```text
def is-path-absolute [p: string]: nothing -> bool
export def hash-watch-set [watch_globs: list<string>, base_dir: string]: nothing -> string
export def onchange [ key: string, watch_globs: list<string>, block: closure, --target: string = "" ]: nothing -> bool
export def merge-json [ src_fragment: string, dest_json: string, --mode: string = "0600" ]: nothing -> nothing
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
