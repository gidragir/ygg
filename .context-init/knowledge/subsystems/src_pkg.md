---
directory: src/pkg.nu
source:
  kind: git
  blob_sha: f37ed9fd44866a0393ff0ce6a528a433b700e622
  commit_sha: 0d651c252a9873883824d2d6820981622c9fede7
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
def pkg-argv-list [mgr: string, pkgs: list<string>]: nothing -> list<list<string>>
def argv-pkgs [mgr: string, argv: list<string>, pkgs: list<string>]: nothing -> list<string>
def default-pkg-timeout [mgr: string]: nothing -> int
def kill-job-tree [jid: int]: nothing -> nothing
export def run-with-timeout [argv: list<string>, timeout_sec: int]: nothing -> record
export def allowed-package-managers [host_os: record]: nothing -> list<string>
export def missing-package-managers [plan: record]: nothing -> list<string>
def is-mock-mode []: nothing -> bool
def csv-env [name: string]: nothing -> list<string>
def missing-native-pkgs [pkgs: list<string>]: nothing -> list<string>
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
