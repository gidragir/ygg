# 🌳 Yggdrasil (`ygg`)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Nushell](https://img.shields.io/badge/Nushell->=_0.116-green.svg)](https://www.nushell.sh/)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20Windows%20%7C%20macOS-lightgrey.svg)](#)
[![Tests](https://img.shields.io/badge/Tests-124%20passed-success.svg)](#-testing--development)

> **Fast, declarative, multi-module dotfiles and configuration manager powered by [Nushell](https://www.nushell.sh/).**  
> *No template engines. First-class Windows Non-Admin support. 3-way GUI copy sync. Transactional safety.*

---

## 🌟 Why Yggdrasil?

Traditional dotfile managers either rely on complex templating engines (`.tmpl`, Jinja, Go templates) that break syntax highlighting in your editor, or struggle in corporate environments where Windows Administrator privileges and Developer Mode are restricted.

`ygg` takes a different approach:
* **Zero Template Complexity:** All declarations are flat, native `TOML` files (`links.toml`, `packages.toml`, etc.). Dotfile sources remain pure, unpolluted, syntax-valid files.
* **Modular Multi-Repo Architecture:** Split your configuration into modular Git repositories or local folders (e.g. `base`, `desktop`, `work-configs`, `ai-stack`) and combine them per machine.
* **First-Class Windows Non-Admin:** Works out-of-the-box on Windows 11 / Server without administrative rights or Developer Mode using NTFS Directory Junctions (`mklink /J`), 3-way hash copy synchronization, and user-space `.cmd` shims.
* **Bidirectional 3-Way GUI Sync (`ygg save`):** Automatically track host-side modifications made by external GUI applications (such as Windows Terminal, GlazeWM, VSCode) back into your module repositories without git conflicts.
* **Safe Preflight & Atomic Swapping:** Zero-data-loss architecture. All changes are verified upfront (`ygg diff`), existing files are safely backed up to `~/.ygg/.state/backups/`, and symlinks are swapped atomically (`mv -Tf`).
* **Built-in Host Audit (`ygg doctor`):** Instant read-only health checks for broken links, permission leaks, unmanaged duplicates, and pending saves.
* **Reactive Procedural SDK:** When procedural logic is needed, use standard Nushell hooks (`setup.nu`) with built-in primitives: `ygg onchange`, `ygg merge-json`, `ygg export-secrets`, and `ygg safe-link`.

---

## ⚡ Quick Start & Installation

### Unix / Linux / macOS
```bash
curl -fsSL https://raw.githubusercontent.com/gidragir/ygg/main/scripts/install.sh | bash
```

### Windows 11 / Server (Non-Admin PowerShell)
```powershell
irm https://raw.githubusercontent.com/gidragir/ygg/main/scripts/install.ps1 | iex
```

The bootstrapper automatically installs [mise](https://mise.jdx.dev) (user-space), Nushell (`nu`), clones the engine to `~/.ygg/.engine`, and sets up the `ygg` shim in `~/.local/bin`.

---

## 🏗 Architecture & Layout

`ygg` maintains a clean separation between declarative manifests, host state, and secret credentials:

```
~/.ygg/
├── host.toml            # Declares active modules, scopes, and local exclusions
├── secrets.toml         # Host-local secrets (mode 0600; never committed)
├── modules/             # Installed modules (Git repos or local symlinks)
│   ├── omni-dotfiles/
│   │   ├── ygg.toml     # Module manifest (or split .toml files)
│   │   └── setup.nu     # Optional procedural hook
│   └── work-profile/
└── .state/              # Runtime metadata, backup snapshots, hash caches
    ├── backups/         # Timestamped safety backups of displaced files
    ├── baseline/        # 3-way baseline hashes for GUI copy-sync
    └── hashes/          # Package and onchange idempotency caches
```

---

## 📖 CLI Reference

```bash
ygg <command> [options]
```

### Core Commands

| Command | Arguments / Flags | Description |
| :--- | :--- | :--- |
| **`init`** | `[name] [--os <list>]` | Initialize a new module in the current directory with `ygg.toml` and `.gitignore`. |
| **`add`** | `<source> [-s, --scope <scopes>] [--dry-run] [--force]` | Clone or link a module (`owner/repo`, Git URL, or local path) and apply it. Accepts inline scopes: `repo@work,pc`. |
| **`remove`** | `<name> [--force]` | Safely unlink managed files and remove module configuration, guarding against uncommitted work. |
| **`apply`** | `[-n, --dry-run] [-f, --force] [--sandbox <path>]` | Execute the full pipeline: install packages, deploy links, export environment, and run `setup.nu` hooks. |
| **`diff`** | `[--sandbox <path>]` | Dry-run preview of planned symlink and copy operations without modifying the filesystem. |
| **`doctor`** | `[-v, --verbose]` | Read-only host audit: checks broken links, orphan files, collisions, permission leaks, and uncommitted edits. Exits with code `1` on error. |
| **`update`** | | Fetch and rebase all Git modules. Safely aborts on conflict; auto-applies on success. |
| **`save`** | `[--sandbox <path>]` | Synchronize modified host files defined in `[save]` back to their source module repos. |
| **`status`** | `[--json]` | Display module status table (Git branch, dirty state, links, packages). Use `--json` for machine-readable output. |
| **`version`** | `[-v, --version]` | Output current `ygg` engine version and Git commit hash. |

### Procedural SDK Helpers (For `setup.nu` and Scripts)

* **`ygg onchange <key> <watch_globs> <command> [--target <path>] [--force]`**  
  Executes `<command>` only when files matching `<watch_globs>` change. Automatically self-heals if `<target>` was deleted.
* **`ygg merge-json <src_fragment> <dest_json> [--mode <mode>]`**  
  Deep-merges a JSON fragment into a target file without overwriting unrelated keys.
* **`ygg export-secrets <dest_dotenv> [--keys <comma_separated_keys>]`**  
  Exports requested secrets from `~/.ygg/secrets.toml` into a target `.env` file with strict shell escaping.
* **`ygg safe-link <src> <dest> [--mode <mode>]`**  
  Creates a link or junction, automatically backing up any preexisting real file or folder to safety backups.

---

## 📝 Manifest Specification

### 1. Host Configuration: `~/.ygg/host.toml`

Defines which modules are active on the current machine and configures their hardware/OS scopes:

```toml
modules = [
  { name = "omni-dotfiles" },
  { name = "work-tools", scopes = ["work", "pc"], exclude = ["heavy-ide"] },
  { name = "personal-vault", scopes = ["home"] }
]
```

### 2. Module Manifest: `ygg.toml`

Modules can define configurations within a single `ygg.toml` or split them into dedicated files (`links.toml`, `packages.toml`, `env.toml`, `aliases.toml`):

```toml
name = "omni-dotfiles"
description = "Universal developer setup"
os = ["linux", "windows", "macos"]

# Symlinks and directory links
[links]
"nvim" = "~/.config/nvim"
"git/.gitconfig" = "~/.gitconfig"
"bin/*" = "~/.local/bin/"

# 3-Way Hash Sync for GUI applications that write to their configs
[save]
"terminal/settings.json" = "~/AppData/Local/Packages/Microsoft.WindowsTerminal_*/LocalState/settings.json"

# Declarative multi-manager package lists
[packages]
pacman = ["neovim", "ripgrep", "bat", "fd"]
winget = ["Neovim.Neovim", "BurntSushi.ripgrep.MSVC"]
brew = ["neovim", "ripgrep"]

# Cross-shell environment variables
[env]
EDITOR = "nvim"
PAGER = "bat"

# Shell aliases
[aliases]
g = "git"
v = "nvim"

# Conditional scope overrides
[scope.work]
env = { WORK_ENV = "production", VAULT_ADDR = "https://vault.internal" }

[scope.windows]
links = { "powershell/profile.ps1" = "~/Documents/PowerShell/Microsoft.PowerShell_profile.ps1" }
```

---

## 🪟 Windows Non-Admin Mechanics

Running dotfile managers on corporate or restricted Windows setups usually fails because creating symbolic links requires elevated Administrator privileges or Windows Developer Mode.

`ygg` solves this completely:

```
Directory Link Request
       │
       ▼
Can we create NTFS Junction? (mklink /J)
  ├── Yes ──► Create Directory Junction (Zero Admin rights needed)
  └── No (cross-volume / remote target)
        ├── Try Directory Symlink (mklink /D)
        └── Fallback to recursive 3-way copy sync (dir_copy)
```

* **NTFS Directory Junctions:** Standard unprivileged users can link directories across NTFS volumes with zero permission prompts.
* **3-Way GUI Copy Sync:** For single configuration files that external Windows apps rewrite destructively (breaking symlinks), `ygg` maintains a 3-way content hash baseline (`.state/baseline/`) and seamlessly brings external GUI changes back to Git via `ygg save`.
* **Isolated `.cmd` Shims:** Any executable scripts placed into `~/.local/bin/` automatically receive Windows `.cmd` shim wrappers with `setlocal` environment isolation.

---

## 🧪 Testing & Development

`ygg` enforces a strict **Zero Host Mutation** invariant across its entire test suite: no test ever reads or touches real user configurations (`~/.ygg`, `~/.config`, `$HOME`). All tests execute inside isolated temporary sandboxes (`/tmp/ygg-test-*`).

Run the automated test suite:

```bash
# Using Nushell directly
nu tests/run.nu

# Or via justfile
just test
```

For Windows verification, run inside isolated Windows Sandbox:
```cmd
wsb tests\sandbox.wsb
```

### Releasing

`YGG_VERSION` in `bin/ygg.nu` is the single source of the version. To release:

1. Bump `YGG_VERSION` and merge the change into `main`.
2. Tag the merged commit and push the tag:

```bash
git tag v0.1.2 && git push origin v0.1.2
```

The `Release` workflow (`.github/workflows/release.yml`) checks that the tag is `v<semver>`, matches `YGG_VERSION` and points to a commit on `main` (`scripts/release.nu`), runs the full test matrix on Linux, Windows and macOS, and then publishes a GitHub Release with generated notes. A tag with a pre-release suffix (`v1.0.0-rc.1`) is published as a pre-release.

---

## 📄 License

Distributed under the MIT License. See [LICENSE](LICENSE) for more details.

Crafted with care by [gidragir](https://github.com/gidragir).
