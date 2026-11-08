---
directory: src/state.nu
source:
  kind: git
  blob_sha: 123d4004f795b7f07162d369f8e860c9712c1725
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
export def backup-existing [ygg_home: string, target_path: string]: nothing -> string
export def to-win32-path [p: string]: nothing -> string
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
