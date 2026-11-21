---
directory: src/manifest.nu
source:
  kind: git
  blob_sha: 7daecefb49b71d11d5bf1fe471561386f2d68a0c
  commit_sha: 46316c5ab09f957e0847a0c89ac011084ca5316a
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
export def merge-services-deep [base: any, overlay: any]: any -> any
export const YGG_MANIFEST_KEYS = ["name", "os", "depends_on", "description", "config", "packages", "links", "save", "services", "env", "aliases", "path", "scope", "doctor", "containers", "setup"] # Supported OS and distribution tokens for ygg.toml `os` field export const KNOWN...
```

## 🧪 Запуск и тестирование
```bash
rtk mise run test
```
