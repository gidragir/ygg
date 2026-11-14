---
directory: src/state.nu
source:
  kind: git
  blob_sha: 3f5f9ecb4112bb6d152ea51c168640f100d8f6a1
  commit_sha: 9fc2715e329857cec74b41adaa696d00a9284ca0
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
export def fs-windows []: nothing -> bool
export def detect-host-os []: nothing -> record<os: string, distro: string, auto_scopes: list<string>>
export def expand-target-path [raw_path: string, --sandbox: string = ""]: nothing -> string
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
