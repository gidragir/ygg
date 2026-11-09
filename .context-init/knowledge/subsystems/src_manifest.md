---
directory: src/manifest.nu
source:
  kind: git
  blob_sha: 315cb96799c77a1de70cbd525b41cc81a2b75214
  commit_sha: 0b134bd0a74f2ac2d0f6d0f038ddf0c72ecb7175
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
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
