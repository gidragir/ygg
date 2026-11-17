---
directory: src/sdk.nu
source:
  kind: git
  blob_sha: 838e226257e422871d9f2141398f8658a1eaa0d1
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
rtk mise run test
```
