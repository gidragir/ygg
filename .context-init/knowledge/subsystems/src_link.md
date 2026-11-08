---
directory: src/link.nu
source:
  kind: git
  blob_sha: 6606973e3ffbbea87ea85c1c9606c2884125c730
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

# Подсистема: Link (L1)

Модуль и компоненты директории `src/link` (1 файлов)

> **Идентификатор:** `src_link`
> **Теги:** Generic / Multi-language, src_link

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `src/link.nu` | Исходный код |

## 🔑 Ключевой контракт и экспорты
```text
def ensure-executable [p: string]: nothing -> nothing
export def is-link-or-junction [path: string]: nothing -> bool
export def remove-link-only [path: string]: nothing -> nothing
export def normalize-case [p: string]: nothing -> string
export def link-literal-target [dest: string]: nothing -> string
export def link-target-matches [dest: string, src: string]: nothing -> bool
export def swap-symlink-atomic [src: string, dest: string]: nothing -> nothing
export def create-windows-dir-link [src: string, dest: string]: nothing -> record<ok: bool, type: string, stderr: string>
export def resolve-link-targets [ plan: record, --sandbox: string = "" ]: nothing -> record<targets: table, save_targets: table, collisions: table, nesting_conflicts: list<record>>
export def backup-with-notice [ygg_home: string, target: string]: nothing -> string
def has-wildcard [p: string]: nothing -> bool
def file-hash [p: string]: nothing -> string
def plan-copy-sync [ state: record, module_name: string, src: string, dest: string, force: bool ]: nothing -> record<op: string, detail: string, copy_record: record>
def run-copy-sync [p: record]: nothing -> nothing
def warn-copy-conflict [dest: string]: nothing -> nothing
def write-cmd-shim [dest: string]: nothing -> string
def copy-prune-detail [dest: string, last_synced_hash: string]: nothing -> string
def prune-copy [ygg_home: string, dest: string, last_synced_hash: string]: nothing -> nothing
def link-prune-detail [state: record, dest: string, entry: record]: nothing -> string
export def report-collisions [resolved: record]: nothing -> nothing
def expand-save-targets [save_targets: list]: nothing -> list
export def compute-link-ops [ ygg_home: string, resolved: record, --force, --sandbox: string = "" ]: nothing -> table<op: string, dest: string, src: string, module: string, key: string, detail: string>
export def apply-links [ ygg_home: string, plan: record, --dry-run, --force, --sandbox: string = "" ]: nothing -> record<applied: list<string>, pruned: list<string>, copies: list<string>, failed: list<record<dest: string, src: string, module: string, stderr: string>>>
export def save-copied-files [ ygg_home: string, plan: record, --sandbox: string = "", --force ]: nothing -> list<string>
export def unlink-module [ygg_home: string, module_name: string]: nothing -> int
def relative-files [dir: string]: nothing -> list<string>
export def shadowed-files [dest: string, src: string]: nothing -> list<string>
export def preflight-check [ ygg_home: string, plan: record, resolved: record =
export def format-preflight-errors [problems: list<record>]: nothing -> string
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
