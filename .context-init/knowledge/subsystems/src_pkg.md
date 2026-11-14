---
directory: src/pkg.nu
source:
  kind: git
  blob_sha: 21ac7b96893d3aee9a9e19169666efadbcfcd6f4
  commit_sha: 3a5aee6c0c7b698e57f67e5dc4852017c70b0c56
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

# Подсистема: Pkg (L1)

Модуль и компоненты директории `src/pkg` (1 файлов)

> **Идентификатор:** `src_pkg`
> **Теги:** Generic / Multi-language, src_pkg

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `src/pkg.nu` | Исходный код |

## 🔑 Ключевой контракт и экспорты
```text
export def pkg-env [mgr: string]: nothing -> record
def pkg-argv-list [mgr: string, pkgs: list<string>]: nothing -> list<list<string>>
def argv-pkgs [mgr: string, argv: list<string>, pkgs: list<string>]: nothing -> list<string>
def default-pkg-timeout [mgr: string]: nothing -> int
def kill-job-tree [jid: int]: nothing -> nothing
export def run-with-timeout [argv: list<string>, timeout_sec: int]: nothing -> record
export def allowed-package-managers [host_os: record]: nothing -> list<string>
export def missing-package-managers [plan: record]: nothing -> list<string>
def is-mock-mode []: nothing -> bool
def csv-env [name: string]: nothing -> list<string>
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
