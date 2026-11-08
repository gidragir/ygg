---
directory: src/pkg.nu
source:
  kind: git
  blob_sha: 399f42ea3f7f4caded78b4c058dde3c4a17ccd4e
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
def sudo-available []: nothing -> bool
def pkg-set-hash [pkgs: list<string>]: nothing -> string
def expand-argv [argv: list<string>]: nothing -> list<string>
def provider-prep-argvs [mgr: string, sandbox: string]: nothing -> list<list<string>>
def prepare-provider-environment [mgr: string, sandbox: string, timeout: int]: nothing -> list<string>
def run-install-argv [mgr: string, argv: list<string>, inv_pkgs: list<string>, timeout: int]: nothing -> record
export def install-packages [ home_or_plan: any, maybe_plan?: any, --dry-run, --skip-packages(...), --pkg: string = "", --pkg-timeout: int = -1, --refresh-packages, --sandbox: string = "" ]: nothing -> record<executed: list<string>, skipped: list<string>, failed: list<record<m...
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
