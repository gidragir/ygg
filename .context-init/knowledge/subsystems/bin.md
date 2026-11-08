---
directory: bin/ygg.nu
source:
  kind: git
  blob_sha: 44e5ec82c169af7404b5bddb814c10c10e140bcb
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

# Подсистема: Bin (L1)

Модуль и компоненты директории `bin` (1 файлов)

> **Идентификатор:** `bin`
> **Теги:** Generic / Multi-language, bin

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `bin/ygg.nu` | Исходный код |

## 🔑 Ключевой контракт и экспорты
```text
def "main version" []
def main [--version (-v)]
def "main init" [ name?: string, --os: string = "linux" ]
def "main add" [ source: string, --scope (-s): string = "", --dry-run (-n), --force (-f), --skip-packages (-S), --pkg: string = "", --pkg-timeout: int = -1, --refresh-packages, --sandbox: string = "" ]
def assert-pkg-flags [pkg: string, skip_packages: bool]
def "main remove" [name: string]
def print-op-line [o: record]
def "main apply" [ --dry-run (-n), --force (-f), --all (-a), --skip-packages (-S), --pkg: string = "", --pkg-timeout: int = -1, --refresh-packages, --sandbox: string = "" ]
def apply-plan [ --dry-run, --force, --all, --skip-packages, --pkg: string = "", --pkg-timeout: int = -1, --refresh-packages, --sandbox: string = "", --extra-modules: list<record> = [] ]
def "main diff" [ --all (-a), --skip-packages (-S), --pkg: string = "", --refresh-packages, --sandbox: string = "" ]
def "main update" []
def "main save" [ --sandbox: string = "", --force ]
def "main status" [--json]
def "main doctor" [--json, --sandbox: string = ""]
def "main onchange" [ key: string, watch: string, cmd: string, --target: string = "" ]
def "main merge-json" [ src_fragment: string, dest_json: string, --mode: string = "0600" ]
def "main export-secrets" [ dest_dotenv: string, --keys: string = "[REDACTED]"
def "main safe-link" [src: string, dest: string]
```

## 🧪 Запуск и тестирование
```bash
# Проверьте общие тесты проекта
```
