---
directory: src/manifest.nu
source:
  kind: git
  blob_sha: 791c6ef2299d4d262af47957b529270ce4a962ba
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

# Подсистема: Manifest (L1)

Модуль и компоненты директории `src/manifest` (1 файлов)

> **Идентификатор:** `src_manifest`
> **Теги:** Generic / Multi-language, src_manifest

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `src/manifest.nu` | Исходный код |

## 🔑 Ключевой контракт и экспорты
```text
export def load-host-config [ygg_home: string]: nothing -> record
export def save-host-config [ygg_home: string, cfg: record]: nothing -> nothing
export def validate-module-os [manifest: record, host_os: record]: nothing -> bool
export def load-module-manifest [mod_dir: string]: nothing -> record
def to-string-list [value: any]: nothing -> list<string>
def normalize-link-value [key: string, value: any]: nothing -> record<targets: list<string>, on_change: string, mode: string>
def merge-link-entries [base: table, scoped: table]: nothing -> table
def entries-with-rank [section: any, origin_rank: int]: nothing -> table
export def resolve-effective-plan [ ygg_home: string, --modules-filter: list<string> = [], --extra-modules: list<record> = [] ]: nothing -> record
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
