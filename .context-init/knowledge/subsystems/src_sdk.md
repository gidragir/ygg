---
directory: src/sdk.nu
source:
  kind: git
  blob_sha: ac17b9a179671db16244ec0b73d1a0fdc0eddaaa
  commit_sha: cbe6f55f9c93a1c852c25c768b190ed5077ae844
generated_by:
  component: context-init
  role: init
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
export def export-secrets [ dest_dotenv: string, --keys: list<string> = [] ]: nothing -> nothing
export def run-module-setup [ ygg_home: string, mod_plan: record, --dry-run, --force, --sandbox: string = "" ]: nothing -> nothing
export def safe-link [src: string, dest: string]: nothing -> nothing
def make-safe-dir-link [src: string, dest: string]: nothing -> nothing
export def run-link-hooks [ ygg_home: string, targets: table, ops: table, --dry-run, --force, --sandbox: string = "" ]: nothing -> list<record<module: string, keys: list<string>, cmd: string, status: string, stderr: string>>
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
