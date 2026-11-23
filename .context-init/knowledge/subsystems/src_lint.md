---
directory: src/lint.nu
source:
  kind: git
  blob_sha: d1962918a51ed2cb61af8a65bd1f5be1289d5b98
  commit_sha: 6d584b36062a1a9c84120fdf8b06dbc230e95d09
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

# Подсистема: Lint (L1)

Модуль и компоненты директории `src/lint` (1 файлов)

> **Идентификатор:** `src_lint`
> **Теги:** Generic / Multi-language, src_lint

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `src/lint.nu` | Исходный код |

## 🔑 Ключевой контракт и экспорты
```text
def is-record [v: any]: nothing -> bool
def has-wildcard-chars [s: string]: nothing -> bool
def has-win32-invalid-chars [s: string]: nothing -> bool
def native-rel [rel: string]: nothing -> string
def to-str-list [v: any]: nothing -> list<string>
def safe-path-type [p: string]: nothing -> any
def safe-path-exists [p: string]: nothing -> bool
def safe-dir-exists [p: string]: nothing -> bool
def safe-file-exists [p: string]: nothing -> bool
export def lint-finding [ check: string, severity: string, target: string, detail: string, fix: string ]: nothing -> record<check: string, severity: string, target: string, detail: string, fix: string>
```

## 🧪 Запуск и тестирование
```bash
rtk mise run test
```
