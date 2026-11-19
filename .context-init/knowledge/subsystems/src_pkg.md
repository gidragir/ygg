---
directory: src/pkg.nu
source:
  kind: git
  blob_sha: 3d6e99c81b1de1aba9ba3a35cbaf64734ae79cc0
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

# Подсистема: Pkg (L1)

Модуль и компоненты директории `src/pkg` (1 файлов)

> **Идентификатор:** `src_pkg`
> **Теги:** Generic / Multi-language, src_pkg

## 📁 Точки входа и структура файлов

| Файл | Статус |
| :--- | :--- |
| `src/pkg.nu` | Исходный код |

## 🔑 Ключевой контракт и экспорты
```text
export def pkg-env [mgr: string]: nothing -> record
export const KNOWN_PKG_MANAGERS = ["winget", "scoop", "pacman", "paru", "apt", "dnf", "zypper", "brew", "mise", "cargo", "pnpm", "uv"] # Package managers probed via HTTP registry/RPC APIs across all platforms const HTTP_PROBE_MGRS = ["paru", "cargo", "pnpm", "uv"] # RFC-005 / ...
def argv-pkgs [mgr: string, argv: list<string>, pkgs: list<string>]: nothing -> list<string>
def default-pkg-timeout [mgr: string]: nothing -> int
def kill-job-tree [jid: int]: nothing -> nothing
export def run-with-timeout [ argv: list<string> timeout_sec: int --label: string = "" --no-tty-progress --soft-fail --ok-codes: list<int> = [0] ]: nothing -> record
```

## 🧪 Запуск и тестирование
```bash
rtk mise run test
```
