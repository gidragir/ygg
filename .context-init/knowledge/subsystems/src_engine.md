---
directory: src/engine.nu
source:
  kind: git
  blob_sha: fd520e25db9d26b928af339ffbadb4a0adb2ce33
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

# Подсистема: Engine (L1)

Модуль и компоненты директории `src/engine` (1 файлов)

> **Идентификатор:** `src_engine`
> **Теги:** Generic / Multi-language, src_engine

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `src/engine.nu` | Исходный код |

## 🔑 Ключевой контракт и экспорты
```text
export def read-ygg-version [file: string]: nothing -> string
export def latest-stable-tag [tags: list<string>]: nothing -> string
export def parse-remote-tags [output: string]: nothing -> list<string>
def git-out [dir: string, ...args: string]: nothing -> record
def engine-version-or-unknown [engine_dir: string]: nothing -> string
def assert-engine-checkout [engine_dir: string]: nothing -> nothing
export def engine-check-update [engine_dir: string]: nothing -> record<current: string, latest: string, update_available: bool>
export def engine-self-update [ engine_dir: string, --channel: string = "stable" # stable: latest v<semver> tag; main: tip of origin/main ]: nothing -> record<status: string, channel: string, ref: string, from: string, to: string>
```

## 🧪 Запуск и тестирование
```bash
rtk mise run test
```
