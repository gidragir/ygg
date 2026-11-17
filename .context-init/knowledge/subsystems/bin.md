---
directory: bin/ygg.nu
source:
  kind: git
  blob_sha: 676c563c99167dc1303c8f39b46f547d73857553
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
```

## 🧪 Запуск и тестирование
```bash
rtk mise run test
```
