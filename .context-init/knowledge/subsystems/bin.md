---
directory: bin/ygg.nu
source:
  kind: git
  blob_sha: b391f66ea31c2893581293c0df03578e4b03a290
  commit_sha: 0aca436558fb4c31003aa79ad7586966277a79d9
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
def "main add" [ source: string, --scope (-s): string = "", --dry-run (-n), --force (-f), --skip-packages (-S), --pkg: string = "", --pkg-timeout: int = -1, --refresh-packages, --sandbox: string = "", --no-lock ]
def assert-pkg-flags [pkg: string, skip_packages: bool]
def "main remove" [ name: string, --no-lock ]
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
