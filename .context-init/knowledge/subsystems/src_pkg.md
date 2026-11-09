---
directory: src/pkg.nu
source:
  kind: git
  blob_sha: a0ed4cc578a3f3913a7c89eb973bad22972b8725
  commit_sha: 0470f79d512e279002641040ba1b0c036d054848
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
