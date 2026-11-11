---
directory: bin/ygg.nu
source:
  kind: git
  blob_sha: b98eebb171552914b08dd8e57043bcf253cceca6
  commit_sha: a6965b2d3ab2d4c100462b64280c84382d4ed740
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
