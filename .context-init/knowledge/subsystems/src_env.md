---
directory: src/env.nu
source:
  kind: git
  blob_sha: b5ff35ae6e721cc498abc0effafb1bda6653f6f9
  commit_sha: 307bca92930f2b3a263e6bf8abdf3df8ecd4e688
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
def quote-path-posix [v: string]: nothing -> string
def quote-path-fish [v: string]: nothing -> string
def secret-keys [p: string]: nothing -> record
export def missing-secret-keys [template: string, secrets: string]: nothing -> list<string>
export def classify-secret-value [raw: string]: nothing -> record<kind: string, ref: string>
export def load-secrets-env [ygg_home: string]: nothing -> record
export def validate-secret-providers [ygg_home: string]: nothing -> list<string>
export def secret-provider-argv [kind: string, ref: string]: nothing -> list<string>
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
