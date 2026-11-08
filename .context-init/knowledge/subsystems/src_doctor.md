---
directory: src/doctor.nu
source:
  kind: git
  blob_sha: 3024b7d4e93aacb5bcdc0065f430fde80dda94b4
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
def check-shadow [ygg_home: string, targets: table]: nothing -> list<record>
def check-secrets [ygg_home: string, plan: record]: nothing -> list<record>
def check-canonical [plan: record, targets: table]: nothing -> list<record>
export def run-doctor [ ygg_home: string, --sandbox: string = "" ]: nothing -> table<check: string, severity: string, target: string, detail: string, fix: string>
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
