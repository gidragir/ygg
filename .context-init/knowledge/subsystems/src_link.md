---
directory: src/link.nu
source:
  kind: git
  blob_sha: 03d5a7dfcc5f6d215d2cccb4bb84254ce6dc7463
  commit_sha: 307bca92930f2b3a263e6bf8abdf3df8ecd4e688
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

# Подсистема: Link (L1)

Модуль и компоненты директории `src/link` (1 файлов)

> **Идентификатор:** `src_link`
> **Теги:** Generic / Multi-language, src_link

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `src/link.nu` | Исходный код |

## 🔑 Ключевой контракт и экспорты
```text
def ensure-executable [p: string]: nothing -> nothing
export def is-link-or-junction [path: string]: nothing -> bool
export def remove-link-only [path: string]: nothing -> nothing
export def normalize-case [p: string]: nothing -> string
export def link-literal-target [dest: string]: nothing -> string
export def link-target-matches [dest: string, src: string]: nothing -> bool
export def swap-symlink-atomic [src: string, dest: string]: nothing -> nothing
export def create-windows-dir-link [src: string, dest: string]: nothing -> record<ok: bool, type: string, stderr: string>
export def resolve-link-targets [ plan: record, --sandbox: string = "" ]: nothing -> record<targets: table, save_targets: table, collisions: table, nesting_conflicts: list<record>>
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
