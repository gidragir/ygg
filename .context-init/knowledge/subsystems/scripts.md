---
directory: scripts
source:
  kind: git
  blob_sha: e1527c3d037ae58f809e94dbc4b25dcf1461f05e
  commit_sha: b269cb6d37622578ea87359c014f11e40cae0830
generated_by:
  component: context-init
  role: update
  model: none
freshness:
  total_entries: 3
  sampled_entries: 3
  unsampled_entries: 0
  pending_child_changes: 0
---

# Подсистема: Scripts (L1)

Модуль и компоненты директории `scripts` (3 файлов)

> **Идентификатор:** `scripts`
> **Теги:** Generic / Multi-language, scripts

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `scripts/install.ps1` | Исходный код |
| `scripts/install.sh` | Исходный код |
| `scripts/release.nu` | Исходный код |

## 🔑 Ключевой контракт и экспорты
```text
export PATH="$HOME/.local/bin:$PATH" # 2. Check or install mise(...) if ! command -v mise >/dev/null 2>&1; then echo "==> mise not found, installing mise (user-space)..." curl -fsSL https://mise.run | sh fi # Activate mise shims in current subshell if command -v mise >/dev/nul...
export use ../src/engine.nu [read-ygg-version] const SEMVER = '^(...)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?$' # "" when `tag` is a v<semver> tag for `version`, otherwise the reason it is not export def release-tag-error [tag: string, version: string]: nothing -> string
export def is-prerelease [tag: string]: nothing -> bool
export def normalize-version [raw: string]: nothing -> string
export def set-ygg-version [content: string, version: string]: nothing -> string
def repo-root []: nothing -> string
def git [root: string, ...args: string]: nothing -> record
def git-ok [root: string, ...args: string]: nothing -> string
def fail [msg: string]
def assert-clean [root: string]
```

## 🧪 Запуск и тестирование
```bash
rtk mise run test
```
