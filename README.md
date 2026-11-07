# 🌳 Yggdrasil (`ygg`)

> **Minimalist, cross-platform modular dotfile and configuration manager powered by [Nushell](https://www.nushell.sh/).**

---

## 🌟 Overview

`ygg` is an independent, declarative module manager designed for high-performance configuration management across Linux (CachyOS/Arch, Ubuntu, Debian), Windows 11 (Non-Admin, without Developer Mode), and macOS.

### Key Features

* **Zero Template Complexity:** No template engines (`.tmpl`, Go text/template, Jinja). Manifests are flat, standard `TOML` files.
* **Direct Git Connectivity:** Modules are standalone Git repositories or local directories directly symlinked or junctioned to your targets.
* **Non-Admin Windows Support:** Works out of the box on Windows without administrative privileges or Developer Mode using NTFS Directory Junctions (`mklink /J`), 3-way hash copy synchronization for GUI apps, and `HKCU\Environment` persistence.
* **3-Way Copy Sync (`ygg save`):** Smooth bidirectional sync for external GUI applications (such as Windows Terminal or GlazeWM) that rewrite configuration files directly.
* **Hardware & OS Scoping:** Easily compose modules using hardware roles (`[scope.pc]`, `[scope.asus]`, `[scope.work]`) and automatic OS tags (`[scope.linux]`, `[scope.windows]`, `[scope.cachyos]`).
* **Built-in Reactive SDK:** Idempotent procedural hooks in `setup.nu` using `onchange`, `merge-json`, and secure `export-secrets`.

---

## 🚀 Quick Start & Installation

### Unix / Linux / macOS
```bash
curl -fsSL https://raw.githubusercontent.com/gidragir/ygg/main/scripts/install.sh | bash
```

### Windows 11 / Server (Non-Admin PowerShell)
```powershell
irm https://raw.githubusercontent.com/gidragir/ygg/main/scripts/install.ps1 | iex
```

The bootstrapper automatically installs `mise` (user-space), Nushell (`nu`), clones the engine to `~/.ygg/.engine`, and sets up the `ygg` shim in `~/.local/bin`.

---

## 📖 CLI Usage

```bash
ygg <command> [options]
```

| Command | Arguments / Flags | Description |
| :--- | :--- | :--- |
| **`init`** | `[name] [--os <os_list>]` | Initialize a new module in the current directory with `ygg.toml` and `.gitignore`. |
| **`add`** | `<source> [--scope (-s) <scopes>]` | Add a local directory or remote Git repo (`owner/repo` or URL) and immediately apply. Accepts inline scopes: `repo@work,laptop`. |
| **`remove`** | `<name>` | Safely unlink and remove a module, guarding against uncommitted changes. |
| **`apply`** | `[--dry-run (-n)] [--force (-f)] [--sandbox <path>]` | Execute the full pipeline: install packages, deploy links, compile shell environments, and run `setup.nu` hooks. |
| **`update`** | | Fetch and rebase all Git modules. Aborts cleanly on conflict and auto-applies on success. |
| **`save`** | `[--sandbox <path>]` | Reverse-copy modified host files defined in `[save]` back to their source modules. |
| **`status`** | | View a tabular status of installed modules, active branches, dirty states, and health. |

### SDK Subcommands (For procedural scripts)

These commands can be called from module `setup.nu` scripts or terminal:

* **`ygg onchange <key> <watch_globs> <command> [--target <path>]`**  
  Execute `<command>` only if files matching `<watch_globs>` have changed since the last run. Self-heals if `<target>` is deleted.
* **`ygg merge-json <src_fragment> <dest_json> [--mode <mode>]`**  
  Deep-merge a JSON fragment into a target JSON configuration file without touching unrelated keys.
* **`ygg export-secrets <dest_dotenv> [--keys <comma_separated_keys>]`**  
  Export selected secrets from `~/.ygg/secrets.toml` into a target dotenv (`.env`) file with strict shell-escaping.

---

## 📁 Manifest Specification

### `~/.ygg/host.toml` (Host Configuration)
Defines modules enabled on this machine and their active scopes:

```toml
modules = [
  { name = "omni-dotfiles" },
  { name = "private-dotfiles", scopes = ["work", "pc"] }
]
```

### Module `ygg.toml`
Defines module packages, links, environment variables, aliases, and scopes:

```toml
name = "my-module"
os = ["linux", "windows"]
description = "My common configuration"

[links]
"nvim" = "~/.config/nvim"
"git/.gitconfig" = "~/.gitconfig"

[save]
"terminal/settings.json" = "~/AppData/Local/Packages/Microsoft.WindowsTerminal_*/LocalState/settings.json"

[packages]
pacman = ["neovim", "ripgrep"]
winget = ["Neovim.Neovim", "BurntSushi.ripgrep.MSVC"]

[env]
EDITOR = "nvim"

[aliases]
g = "git"

[scope.work]
env = { WORK_ENV = "production" }
```

Modules can optionally split large configurations into dedicated files:
* `packages.toml`
* `links.toml`
* `env.toml`
* `aliases.toml`

---

## 🧪 Testing & Development

All tests run in strict isolation inside temporary directories without modifying host state (`ZERO HOST MUTATION`).

To run the test suite:

```bash
just test
# or
nu tests/run.nu
```

Windows Sandbox can be started directly via `tests/sandbox.wsb`.

---

## 📄 License

MIT © [gidragir](https://github.com/gidragir)
