---
directory: src/link.nu
source:
  kind: git
  blob_sha: 524053abb2169211aa43299ac65d3dfbd2b112c8
  commit_sha: e1466886272809a25ea67f71ff1481772a1c14a2
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
