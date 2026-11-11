---
directory: src/env.nu
source:
  kind: git
  blob_sha: 1c6b86c3f5a72f5a1c328a70072f2214227f8418
  commit_sha: 97b3c640b64d17e6df2c67ff21522c87b98fb18e
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
export def classify-secret-value [raw: string]: nothing -> record<kind: string, ref: string>
export def load-secrets-env [ygg_home: string]: nothing -> record
export def validate-secret-providers [ygg_home: string]: nothing -> list<string>
export def secret-provider-argv [kind: string, ref: string]: nothing -> list<string>
def format-lazy-provider-cmd [shell: string, argv: list<string>]: nothing -> string
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
