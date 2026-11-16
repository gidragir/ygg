---
directory: src/pkg.nu
source:
  kind: git
  blob_sha: 5d7ea276ebe0f8017685ed2bcedfb82e9f4db2c5
  commit_sha: 23920184815ab8144336b355ca51148c6577d991
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
export def run-with-timeout [ argv: list<string> timeout_sec: int --label: string = "" --no-tty-progress ]: nothing -> record
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
