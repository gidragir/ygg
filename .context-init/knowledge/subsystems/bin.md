---
directory: bin/ygg.nu
source:
  kind: git
  blob_sha: 725aebb47a9543b4862f25c2cf7244768280d789
  commit_sha: 815458e5b6bc88a3a157c1c5138ac1e9e9d102aa
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

# Подсистема: Bin (L1)

Модуль и компоненты директории `bin` (1 файлов)

> **Идентификатор:** `bin`
> **Теги:** Generic / Multi-language, bin

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `bin/ygg.nu` | Исходный код |

## 🔑 Ключевой контракт и экспорты
```text
def "main version" []
def main [ --version (-v) # Print version ]
def "main init" [ name?: string, --os: string = "linux" # Comma-separated target OS list for the new module (default: linux) ]
def "main add" [ source: string, # Local directory or git URL of the module(...) --scope (-s): string = "", # Comma-separated scopes to activate for the module --dry-run (-n), # Show the plan without modifying anything --force (-f), # Overwrite conflicting files and links (wit...
def assert-pkg-flags [pkg: string, skip_packages: bool]
def "main remove" [ name: string, # Module name --no-lock # Do not take the host lock ]
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
