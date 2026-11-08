---
directory: src/doctor.nu
source:
  kind: git
  blob_sha: 1b4558a7cf98b0ee3694c01244292f95abc87425
  commit_sha: b2b60cceff6830fd15d59eceaa74351c9a6c7049
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

# Подсистема: Doctor (L1)

Модуль и компоненты директории `src/doctor` (1 файлов)

> **Идентификатор:** `src_doctor`
> **Теги:** Generic / Multi-language, src_doctor

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `src/doctor.nu` | Исходный код |

## 🔑 Ключевой контракт и экспорты
```text
def finding [check: string, severity: string, target: string, detail: string, fix: string]: nothing -> record<check: string, severity: string, target: string, detail: string, fix: string>
def to-list [value: any]: nothing -> list<string>
def list-files-rel [root: string, prefix: string = ""]: nothing -> list<string>
def check-links [ops: table]: nothing -> list<record>
def check-orphan-links [state: record, targets: table, sb: string]: nothing -> list<record>
def check-state-orphans [state: record, host_modules: list<string>]: nothing -> list<record>
def check-sync [state: record]: nothing -> list<record>
def check-perms [ygg_home: string, plan: record, sb: string]: nothing -> list<record>
def check-tools [plan: record]: nothing -> list<record>
def check-collisions [resolved: record]: nothing -> list<record>
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
