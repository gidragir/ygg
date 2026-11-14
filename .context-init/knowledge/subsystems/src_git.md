---
directory: src/git.nu
source:
  kind: git
  blob_sha: 06ae7300f8e7c76565c4cfc6cbee5cd897056522
  commit_sha: e1466886272809a25ea67f71ff1481772a1c14a2
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

# Подсистема: Git (L1)

Модуль и компоненты директории `src/git` (1 файлов)

> **Идентификатор:** `src_git`
> **Теги:** Generic / Multi-language, src_git

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `src/git.nu` | Исходный код |

## 🔑 Ключевой контракт и экспорты
```text
def assert-module-clean [mod_dir: string, name: string, action: string]: nothing -> nothing
export def is-canonicalizable [path: string]: nothing -> bool
export def warn-if-not-canonicalizable [path: string]: nothing -> nothing
export def discard-staged-module [prep: record]: nothing -> nothing
def stage-module [ygg_home: string, source: string, scopes: list<string>, force: bool, read_only: bool]: nothing -> record
export def register-staged-module [ygg_home: string, prep: record, --force]: nothing -> record
export def add-module [ ygg_home: string, source: string, --scopes: list<string> = [], --dry-run, --force, --read-only # never write into YGG_HOME(...); implies --dry-run ]: nothing -> record<name: string, path: string, scopes: list<string>, tmp_clone: string>
export def remove-module [ygg_home: string, name: string]: nothing -> nothing
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
