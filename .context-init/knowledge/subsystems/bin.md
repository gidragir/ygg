---
directory: bin/ygg.nu
source:
  kind: git
  blob_sha: 44e5ec82c169af7404b5bddb814c10c10e140bcb
  commit_sha: 23db0a16cc70b05c766b715633609bf942d801bb
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
def main [--version (-v)]
def "main init" [ name?: string, --os: string = "linux" ]
def "main add" [ source: string, --scope (-s): string = "", --dry-run (-n), --force (-f), --skip-packages (-S), --pkg: string = "", --pkg-timeout: int = -1, --refresh-packages, --sandbox: string = "" ]
def assert-pkg-flags [pkg: string, skip_packages: bool]
def "main remove" [name: string]
def print-op-line [o: record]
def "main apply" [ --dry-run (-n), --force (-f), --all (-a), --skip-packages (-S), --pkg: string = "", --pkg-timeout: int = -1, --refresh-packages, --sandbox: string = "" ]
def apply-plan [ --dry-run,
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
