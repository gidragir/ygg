---
directory: src/doctor.nu
source:
  kind: git
  blob_sha: 810a44a317f4067f834404246be59e0337c37bf8
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
def is-owned-link [p: string, state: record, roots: list<string>]: nothing -> bool
def check-orphan-links [state: record, targets: table, sb: string, roots: list<string>]: nothing -> list<record>
def check-state-orphans [state: record, host_modules: list<string>]: nothing -> list<record>
def check-sync [state: record]: nothing -> list<record>
export def is-windows-acl-insecure [acl_lines: string]: nothing -> bool
export def select-powershell [has_pwsh: bool, has_winps: bool]: nothing -> record<bin: string, hide_module_path: bool>
```

## 🧪 Запуск и тестирование
```bash
rtk mise run test
```
