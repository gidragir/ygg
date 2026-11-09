---
directory: src/sdk.nu
source:
  kind: git
  blob_sha: 10547f36de99485a54e8ef3b3a5ad65f0fbebf10
  commit_sha: 0775557ef269ea7b6de4d26868502c068c22759b
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
