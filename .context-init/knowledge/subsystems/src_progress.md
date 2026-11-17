---
directory: src/progress.nu
source:
  kind: git
  blob_sha: 5b168b05996f988f1c47690a1f50c22ac90a196a
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

# Подсистема: Progress (L1)

Модуль и компоненты директории `src/progress` (1 файлов)

> **Идентификатор:** `src_progress`
> **Теги:** Generic / Multi-language, src_progress

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `src/progress.nu` | Исходный код |

## 🔑 Ключевой контракт и экспорты
```text
export def is-tty-progress []: nothing -> bool
export def term-columns []: nothing -> int
export def sanitize-log-line [line: string]: nothing -> string
export def read-last-log-line [path: string]: nothing -> string
export def read-progress-tail [err_path: string, out_path: string]: nothing -> string
export def progress-clear-line []: nothing -> nothing
export def format-progress-line [ spinner: string label: string tail: string elapsed_sec: int width: int ]: nothing -> string
export def format-progress-done [ status: string label: string elapsed_sec: float ]: nothing -> string
export def progress-step [phase: string, msg: string]: nothing -> nothing
export def hook-warnings [hooks: list<record>]: nothing -> list<record<source: string, module: string, item: string, message: string>>
```

## 🧪 Запуск и тестирование
```bash
rtk mise run test
```
