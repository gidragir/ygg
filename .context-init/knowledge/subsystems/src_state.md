---
directory: src/state.nu
source:
  kind: git
  blob_sha: 969fd58d36adb8269a89d50f29a7ea8230222549
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

# Подсистема: State (L1)

Модуль и компоненты директории `src/state` (1 файлов)

> **Идентификатор:** `src_state`
> **Теги:** Generic / Multi-language, src_state

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `src/state.nu` | Исходный код |

## 🔑 Ключевой контракт и экспорты
```text
export def get-ygg-home []: nothing -> string
export def assert-sandbox-home [sandbox: string]: nothing -> nothing
export def ensure-ygg-dirs [ygg_home: string]: nothing -> nothing
export def load-state [ygg_home: string]: nothing -> record
export def save-state [ygg_home: string, state: record]: nothing -> nothing
export def detect-host-os []: nothing -> record<os: string, distro: string, auto_scopes: list<string>>
export def expand-target-path [raw_path: string, --sandbox: string = ""]: nothing -> string
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
