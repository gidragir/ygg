---
directory: src/env.nu
source:
  kind: git
  blob_sha: 32aafb435a8433461b13f363bf5f3c97bb58c8e2
  commit_sha: 56685b11fa470aab9e4cc098f1d5e7cf0690667b
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

# Подсистема: Env (L1)

Модуль и компоненты директории `src/env` (1 файлов)

> **Идентификатор:** `src_env`
> **Теги:** Generic / Multi-language, src_env

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `src/env.nu` | Исходный код |

## 🔑 Ключевой контракт и экспорты
```text
export def format-windows-env-script [clean_env: record, path_entries: list<string>, user_home: string]: nothing -> string
def resolve-env-value [v: string, sb: string]: nothing -> string
def secret-keys [p: string]: nothing -> record
export def missing-secret-keys [template: string, secrets: string]: nothing -> list<string>
export def resolve-secret-value [raw: string]: nothing -> string
export def compile-environment [ ygg_home: string, plan: record, --dry-run, --force, --sandbox: string = "" ]: nothing -> nothing
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
