---
directory: src/container.nu
source:
  kind: git
  blob_sha: 57e7ab5136c48cdc0b981ec68dae67f7d848ef8d
  commit_sha: dadd7fbef08ba0f3acd485efe55cd76931159055
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

# Подсистема: Container (L1)

Модуль и компоненты директории `src/container` (1 файлов)

> **Идентификатор:** `src_container`
> **Теги:** Generic / Multi-language, src_container

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `src/container.nu` | Исходный код |

## 🔑 Ключевой контракт и экспорты
```text
export const CONTAINER_RUNTIMES = ["docker", "podman"] const COMPOSE_DEFAULT_NAMES = ["compose.yaml" "compose.yml" "docker-compose.yaml" "docker-compose.yml"] def native-rel-path [rel: string]: nothing -> string
export def normalize-project-name [raw: string]: nothing -> string
export def find-override-file [file: string]: nothing -> string
def read-compose-name [file: string]: nothing -> string
export def compose-project-name [module: string, mod_dir: string, file: string]: nothing -> string
export def discover-stacks [module: string, mod_dir: string, cfg: record, scope_files: list<string>]: nothing -> list<record>
export def check-container-stacks [plan: record]: nothing -> list<record<module: string, key: string, reason: string, detail: string>>
export def compose-version-ok [output: string]: nothing -> bool
def container-sandbox [sandbox: string]: nothing -> string
def probe-runtime [rt: string]: nothing -> record<runtime: string, status: string, detail: string>
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
