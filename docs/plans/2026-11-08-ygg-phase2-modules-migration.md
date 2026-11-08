# Ygg Phase 2 — Modules Migration & Stage 2 Sandbox Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate all 4 existing configuration repositories (`omni-dotfiles`, `dotfiles`, `ai-dotfiles`, `win-dotfiles`) onto the flat, template-free `ygg` module architecture inside isolated Git worktrees (`feat/ygg-migration`) and prove 100% end-to-end composability via Stage 2 `--sandbox` automated tests without mutating the running host.

**Architecture:** Each target repository is checked out into an isolated Git worktree under `/data/projects/worktree/ygg-phase2/<repo>` on branch `feat/ygg-migration` so live Chezmoi and GNU Stow symlinks in `$HOME` remain completely undisturbed until Phase 4 Cutover. Inside each worktree, `home/dot_*`, `.chezmoi*`, `.tmpl`, `infra/stow/`, and user-space Ansible playbooks are replaced by declarative `ygg.toml` + split manifests (`packages.toml`, `links.toml`, `env.toml`, `aliases.toml`), static configs with native `local.*` includes, `[scope.<name>]` hardware/role slices (`pc`, `asus`, `work`, `notebook`), and sandbox-safe `setup.nu` scripts powered by `ygg`'s Nushell SDK (`onchange`, `merge-json`, `export-secrets`).

**Tech Stack:** Nushell 0.116+ (`nu`), `ygg` CLI engine (`/data/projects/ygg`), TOML manifests, Git worktrees, SQLite3 (for Hermes guard session verification), WinGet DSC v0.2 YAML (`windows.dsc.yaml`).

**Spec Reference:** `/data/projects/ygg/docs/specs/2026-11-07-modular-omni-architecture-design.md` (Sections 2–7; Phase 2 & Stage 2 of Section 7).

---

## Global Constraints

1. **100% Live Host & Primary Worktree Isolation:**
   - **NEVER** run `git checkout`, `git mv`, `git rm`, or edit files inside the primary working trees `/data/projects/{omni-dotfiles,dotfiles,ai-dotfiles,win-dotfiles}` — live `$HOME` symlinks point directly into them, and 3 of them hold uncommitted local theme/config edits.
   - Perform ALL Phase 2 file migrations strictly inside `/data/projects/worktree/ygg-phase2/<repo>` on branch `feat/ygg-migration`.
   - **NEVER** run `ygg` without both `YGG_HOME=/tmp/...` and `--sandbox /tmp/...` (or `YGG_SANDBOX=/tmp/...`) and `YGG_MOCK_PKG_LOG=/tmp/...`. Modifying real `~/.ygg`, `~/.config`, `~/.hermes`, `~/.gemini`, or system services is strictly prohibited.
2. **Repository Scope Boundary:**
   - Do **NOT** split the 4 existing repositories into smaller sub-repositories in Phase 2. Migrate the exact 4 modules: `omni-dotfiles`, `dotfiles`, `ai-dotfiles`, `win-dotfiles`.
   - Stop strictly at Phase 2 (`feat/ygg-migration` commits + Stage 2 sandbox E2E test suite). Do **NOT** execute Stage 3 (VMs), Stage 4 (laptop canary), or Phase 4 (`stow -D` / Chezmoi removal on host).
3. **Zero-Templates & Native Static Configs:**
   - Every migrated worktree MUST contain **zero** `*.tmpl` files, **zero** `.chezmoi*` files/folders, and **zero** `infra/stow/` wrappers.
   - Use `/*` unfolding in `links.toml` for shared or runtime-stateful directories (`~/.local/bin/*`, `~/.zsh/scripts/*`, `~/.config/systemd/user/*`, `~/.config/nushell/*`, `~/.config/git/*`, `~/.config/niri/*`, `~/.gemini/config/*`, `~/.hermes/plugins/*`, `~/.hermes/profiles/<p>/*`, `~/.config/glazewm/*`) so runtime files (`history.sqlite3`, `state.db`, `config.json`, `local.kdl`, `config.local`) never dirty Git trees or collide across modules.
4. **Nushell 0.116+ & Host Tooling Invariants:**
   - Prefix every shell command with `rtk`. Never invoke GNU `find` or `grep` (use `rtk fd` and `rtk rg`; never pass `-E` to `rg`).
   - Follow `/data/projects/ygg/.agents/skills/nushell-ygg-dev/SKILL.md` for all `.nu` code: never interpolate strings containing literal `[` via `$"..."` (use `+`), use `get -o` (never `get -i`), bind `where { |it| ... }`, use `^cmd | complete` (never `do -i`).
   - `expand-target-path` tokens in `ygg` are `$APPDATA`, `$LOCALAPPDATA`, `$DOCUMENTS`, and `~` (never `%LOCALAPPDATA%`).
5. **Context-Bomb Exclusion Rule (NEVER read full file contents):**
   - `/data/projects/worktree/ygg-phase2/ai-dotfiles/infra/stacks/**`, Python plugin sources, `superpowers` submodule
   - `/data/projects/worktree/ygg-phase2/win-dotfiles/**/sources/*.wh.cpp`
   - `/data/projects/worktree/ygg-phase2/dotfiles/**/noctalia/**`
   - `/data/projects/worktree/ygg-phase2/omni-dotfiles/**/{themes,theme,cable}/**`

---

## File Structure & Worktree Map

| Workspace / Worktree | Branch | Key Files Created / Migrated | Legacy Artifacts Removed |
| :--- | :--- | :--- | :--- |
| `/data/projects/ygg` | `main` | `tests/test_phase2_modules.nu`, `justfile` (`test-phase2` recipe) | None |
| `/data/projects/worktree/ygg-phase2/omni-dotfiles` | `feat/ygg-migration` | `ygg.toml`, `packages.toml`, `links.toml`, `env.toml`, `aliases.toml`, flattened `./{atuin,bat,btop,carapace,cargo,fzf,gh,ghostty,git,glab-cli,glow,k3d,k9s,mise,nushell,nvim,omni,powershell,rtk,sheldon,superfile,television,zellij,zsh,bin}`, `starship.toml`, updated `justfile` & `AGENTS.md` | `.chezmoiroot`, `home/.chezmoi*`, `home/.chezmoidata/*`, `home/.chezmoiscripts/*`, all `*.tmpl`, `dot_*` / `executable_*` prefixes |
| `/data/projects/worktree/ygg-phase2/dotfiles` | `feat/ygg-migration` | `ygg.toml`, `packages.toml`, `links.toml`, `setup.nu`, flattened `./{OpenRGB,hypr,niri,noctalia,rofi,systemd,wallpaper-engine,waypaper,wireplumber,zsh}`, `vivaldi-stable.conf`, `niri/displays/{pc,asus}.kdl`, `systemd/user-pc/openrgb*.service`, `zsh/{alias-pc,scripts-pc}/*`, `secrets.example.toml` (keep root `playbooks/setup_system.yml` & Day-0 playbooks) | `.chezmoiroot`, `home/.chezmoi*`, `linked/` wrapper, all `*.tmpl`, `playbooks/setup_user.yml` |
| `/data/projects/worktree/ygg-phase2/ai-dotfiles` | `feat/ygg-migration` | `ygg.toml`, `packages.toml`, `links.toml`, `setup.nu`, `antigravity/*` (with `plugins/superpowers`), `services/hermes/{config.yaml,plugins/*,profiles/*}`, `configs/{hermes-desktop,ollama,opencommit}`, `systemd/user/hermes-{dashboard,gateway}.service`, `environment.d/pythonpath.conf`, updated `AGENTS.md` | `infra/stow/**`, `infra/playbooks/**` |
| `/data/projects/worktree/ygg-phase2/win-dotfiles` | `feat/ygg-migration` | `ygg.toml`, `packages.toml`, `links.toml`, `env.toml`, `setup.nu`, `system/windows.dsc.yaml`, flattened `./{1c,ahk,ai,bin,glazewm,just,nushell,opencode,powershell,scoop,scripts,terminal,windhawk,zebar}`, `glazewm/workspaces/{pc,notebook}.yaml`, static `bin/git-ws-add.ps1`, `bin/git-pull-all.ps1`, `scripts/git-pull-all.ts`, `ai/{config.yaml,mcp-base.example.json}` | `.chezmoi.toml.tmpl`, `.chezmoidata.toml`, `.chezmoiignore`, `.chezmoiscripts/**`, `dot_config/` wrapper, all `*.tmpl`, redundant static `.cmd` wrappers |

---

## Task 1: Worktree Isolation Setup & Stage 2 Sandbox E2E Harness

**Files:**
- Create worktrees: `/data/projects/worktree/ygg-phase2/{omni-dotfiles,dotfiles,ai-dotfiles,win-dotfiles}` (branch `feat/ygg-migration`)
- Create: `/data/projects/ygg/tests/test_phase2_modules.nu`
- Modify: `/data/projects/ygg/justfile`

- [ ] **Step 1: Create isolated Git worktrees for all 4 repositories without touching primary trees**

Run from `/data/projects/ygg`:
```bash
rtk nu -c '
let base = "/data/projects/worktree/ygg-phase2"
mkdir $base
for repo in ["omni-dotfiles", "dotfiles", "ai-dotfiles", "win-dotfiles"] {
    let src = $"/data/projects/($repo)"
    let wt = $"($base)/($repo)"
    if not ($wt | path exists) {
        let has_branch = ((^git -C $src branch --list "feat/ygg-migration" | str trim) != "")
        if $has_branch {
            ^git -C $src worktree add $wt "feat/ygg-migration"
        } else {
            ^git -C $src worktree add -b "feat/ygg-migration" $wt HEAD
        }
    }
}
^git -C "/data/projects/worktree/ygg-phase2/ai-dotfiles" submodule update --init --recursive
'
```
Expected: All 4 directories exist under `/data/projects/worktree/ygg-phase2/`, each on branch `feat/ygg-migration`, and `rtk git -C /data/projects/omni-dotfiles branch --show-current` still prints `main`.

- [ ] **Step 2: Write the failing Stage 2 multi-module sandbox test suite in `/data/projects/ygg/tests/test_phase2_modules.nu`**

Create `/data/projects/ygg/tests/test_phase2_modules.nu`:
```nushell
#!/usr/bin/env nu
# Stage 2 End-to-End Sandbox Verification for Phase 2 Migrated Modules

use std/assert

const YGG_BIN = (path self | path dirname | path dirname | path join "bin" "ygg.nu")
const WT_ROOT = "/data/projects/worktree/ygg-phase2"

def make-sandbox [name: string]: nothing -> record<root: string, ygg_home: string, home: string, pkg_log: string> {
    let id = (random chars --length 6)
    let root = $"/tmp/ygg-stage2-($name)-($id)"
    let ygg_home = ($root | path join ".ygg")
    let home = ($root | path join "home")
    let pkg_log = ($root | path join "pkg.log")
    mkdir ($ygg_home | path join "modules")
    mkdir $home
    "" | save -f $pkg_log
    { root: $root, ygg_home: $ygg_home, home: $home, pkg_log: $pkg_log }
}

def link-wt-modules [ygg_home: string, names: list<string>] {
    for n in $names {
        let src = ($WT_ROOT | path join $n)
        let dst = ($ygg_home | path join "modules" $n)
        ^ln -sfn $src $dst
    }
}

def assert-no-broken-links [dir: string] {
    let broken = (^fd -H --type l . $dir | lines | where { |p| ($p != "") and not ($p | path exists) })
    if not ($broken | is-empty) {
        error make { msg: ("Broken symlinks detected in sandbox: " + ($broken | str join ", ")) }
    }
}

export def test-zero-legacy-artifacts [repo: string] {
    let wt = ($WT_ROOT | path join $repo)
    assert (($wt | path join "ygg.toml") | path exists) $"Missing ygg.toml in ($repo)"
    let tmpls = (^fd -H --glob "*.tmpl" $wt --exclude .git | lines | where { |x| $x != "" })
    assert ($tmpls | is-empty) $"Legacy .tmpl files remain in ($repo): ($tmpls | str join ', ')"
    let cz = (^fd -H "chezmoi" $wt --exclude .git --exclude AGENTS.md --exclude README.md --exclude docs --exclude .agents | lines | where { |x| $x != "" })
    assert ($cz | is-empty) $"Legacy chezmoi files remain in ($repo): ($cz | str join ', ')"
}

export def test-omni-standalone-linux [] {
    let sb = (make-sandbox "omni-linux")
    try {
        link-wt-modules $sb.ygg_home ["omni-dotfiles"]
        'profile = "test-omni"
modules = ["omni-dotfiles"]
' | save -f ($sb.ygg_home | path join "config.toml")
        '[env]
OPENAI_API_KEY = "sk-test$secret'\''val"
' | save -f ($sb.ygg_home | path join "secrets.toml")

        let res = (with-env {
            HOME: $sb.home,
            YGG_HOME: $sb.ygg_home,
            YGG_SANDBOX: $sb.home,
            YGG_HOST_OS_OVERRIDE: "cachyos",
            YGG_MOCK_PKG_LOG: $sb.pkg_log
        } { ^nu $YGG_BIN apply --sandbox $sb.home } | complete)
        assert ($res.exit_code == 0) $"omni apply failed: ($res.stderr)"

        # Move sandbox into $sb.home/.ygg so shell profiles find ~/.ygg/.state/env/*
        ^ln -sfn $sb.ygg_home ($sb.home | path join ".ygg")
        assert (($sb.home | path join ".config" "nushell" "config.nu") | path exists)
        assert (($sb.home | path join ".config" "git" "config") | path exists)
        assert (($sb.home | path join ".local" "bin" "omni") | path exists)
        assert (($sb.home | path join ".local" "bin" "omni.nu") | path exists)
        assert-no-broken-links $sb.home

        # Verify Nushell loads env.nu + config.nu + aliases cleanly with HOME=$sb.home
        let nu_chk = (with-env { HOME: $sb.home, YGG_HOME: ($sb.home | path join ".ygg") } {
            ^nu --env-config ($sb.home | path join ".config" "nushell" "env.nu") --config ($sb.home | path join ".config" "nushell" "config.nu") -c "$env.EDITOR + '|' + $env.OPENAI_API_KEY"
        } | complete)
        assert ($nu_chk.exit_code == 0) $"Nushell profile failed to parse/load: ($nu_chk.stderr)"
        assert (($nu_chk.stdout | str trim) == "nvim|sk-test$secret'val") $"Unexpected nu env output: ($nu_chk.stdout)"

        # Verify Zsh loads .zshenv + .zshrc + aliases without error
        let zsh_chk = (with-env { HOME: $sb.home, YGG_HOME: ($sb.home | path join ".ygg") } {
            ^zsh -c 'source "$HOME/.zshenv" && source "$HOME/.zshrc" && printf "%s|%s" "$EDITOR" "$OPENAI_API_KEY"'
        } | complete)
        assert ($zsh_chk.exit_code == 0) $"Zsh profile failed: ($zsh_chk.stderr)"
        assert (($zsh_chk.stdout | str trim) == "nvim|sk-test$secret'val") $"Unexpected zsh env output: ($zsh_chk.stdout)"
    } catch { |e|
        rm -rf $sb.root
        error make { msg: $e.msg }
    }
    rm -rf $sb.root
}

export def test-linux-pc-and-asus-scope-switch [] {
    let sb = (make-sandbox "linux-scopes")
    try {
        link-wt-modules $sb.ygg_home ["omni-dotfiles", "dotfiles", "ai-dotfiles"]
        'profile = "cachyos-pc"
modules = [
  "omni-dotfiles",
  "dotfiles@pc",
  "ai-dotfiles",
]
' | save -f ($sb.ygg_home | path join "config.toml")
        '[env]
GEMINI_API_KEY = "gem-test-key"
' | save -f ($sb.ygg_home | path join "secrets.toml")

        # Seed existing foreign runtime JSON in Antigravity config.json + symlink trap in claude/settings.json
        mkdir ($sb.home | path join ".gemini" "config")
        '{"runtimeWindow": {"zoom": 1.25}}' | save -f ($sb.home | path join ".gemini" "config" "config.json")
        mkdir ($sb.home | path join ".claude")
        let legacy_target = ($sb.root | path join "legacy_claude_settings.json")
        '{"legacyKey": true}' | save -f $legacy_target
        ^ln -sfn $legacy_target ($sb.home | path join ".claude" "settings.json")

        let res_pc = (with-env {
            HOME: $sb.home,
            YGG_HOME: $sb.ygg_home,
            YGG_SANDBOX: $sb.home,
            YGG_HOST_OS_OVERRIDE: "cachyos",
            YGG_MOCK_PKG_LOG: $sb.pkg_log
        } { ^nu $YGG_BIN apply --sandbox $sb.home } | complete)
        assert ($res_pc.exit_code == 0) $"PC stack apply failed: ($res_pc.stderr)"
        assert-no-broken-links $sb.home

        # Assert PC-only artifacts present, ASUS-only absent
        assert (($sb.home | path join ".config" "OpenRGB" "off.orp") | path exists)
        assert (($sb.home | path join ".config" "systemd" "user" "openrgb.service") | path exists)
        let disp_pc = (open --raw ($sb.home | path join ".config" "niri" "cfg" "display.kdl"))
        assert ($disp_pc | str contains "DP-2") "PC display.kdl must configure desktop DP-2 monitor"
        let pkgs_pc = (open --raw $sb.pkg_log)
        assert ($pkgs_pc | str contains "openrgb") "PC packages must include openrgb"
        assert (not ($pkgs_pc | str contains "asusctl")) "PC packages must NOT include asusctl"

        # Assert ai-dotfiles setup.nu invariants
        let agy_cfg = (open ($sb.home | path join ".gemini" "config" "config.json"))
        assert (($agy_cfg | get -o runtimeWindow.zoom) == 1.25) "merge-json must preserve host runtimeWindow"
        assert (($sb.home | path join ".claude" "settings.json" | path type) == "file") "claude settings.json symlink must be replaced with physical file"
        assert (($sb.home | path join ".hermes" ".env") | path exists) "export-secrets must generate ~/.hermes/.env"
        assert (($sb.home | path join ".hermes" "skills" ".no-bundled-skills") | path exists) "Hermes .no-bundled-skills marker missing"
        let guard_cnt = (^sqlite3 ($sb.home | path join ".hermes" "profiles" "coder" "state.db") "SELECT COUNT(*) FROM sessions;" | str trim | into int)
        assert ($guard_cnt >= 2) $"Hermes coder state.db must have >=2 guard sessions, got ($guard_cnt)"

        # Switch profile in-place from dotfiles@pc -> dotfiles@asus (Review Focus: Zero-Trash pruning)
        "" | save -f $sb.pkg_log
        'profile = "cachyos-asus"
modules = [
  "omni-dotfiles",
  "dotfiles@asus",
]
' | save -f ($sb.ygg_home | path join "config.toml")

        let res_asus = (with-env {
            HOME: $sb.home,
            YGG_HOME: $sb.ygg_home,
            YGG_SANDBOX: $sb.home,
            YGG_HOST_OS_OVERRIDE: "cachyos",
            YGG_MOCK_PKG_LOG: $sb.pkg_log
        } { ^nu $YGG_BIN apply --sandbox $sb.home } | complete)
        assert ($res_asus.exit_code == 0) $"ASUS switch apply failed: ($res_asus.stderr)"
        assert-no-broken-links $sb.home

        # Assert PC artifacts pruned & ASUS artifacts active
        assert (not (($sb.home | path join ".config" "OpenRGB" "off.orp") | path exists)) "OpenRGB config must be pruned on @asus"
        assert (not (($sb.home | path join ".config" "systemd" "user" "openrgb.service") | path exists)) "openrgb.service must be pruned on @asus"
        assert (not (($sb.home | path join ".zsh" "alias" "cooler.zsh") | path exists)) "cooler.zsh must be pruned on @asus"
        let disp_asus = (open --raw ($sb.home | path join ".config" "niri" "cfg" "display.kdl"))
        assert (not ($disp_asus | str contains "DP-2")) "ASUS display.kdl must not contain desktop DP-2 layout"
        let pkgs_asus = (open --raw $sb.pkg_log)
        assert ($pkgs_asus | str contains "asusctl") "ASUS packages must include asusctl"
        assert (not ($pkgs_asus | str contains "openrgb")) "ASUS packages must NOT include openrgb"
    } catch { |e|
        rm -rf $sb.root
        error make { msg: $e.msg }
    }
    rm -rf $sb.root
}

export def test-windows-work-and-save-roundtrip [] {
    let sb = (make-sandbox "win-work")
    try {
        link-wt-modules $sb.ygg_home ["omni-dotfiles", "win-dotfiles"]
        # Seed simulated Windows Terminal target file so [save] 3-way copy-sync & ygg save engage
        let wt_dir = ($sb.home | path join "AppData" "Local" "Packages" "Microsoft.WindowsTerminal_8wekyb3d8bbwe" "LocalState")
        mkdir $wt_dir
        let wt_settings = ($wt_dir | path join "settings.json")
        (open --raw ($WT_ROOT | path join "win-dotfiles" "terminal" "settings.json")) | save -f $wt_settings

        'profile = "win-workstation"
modules = [
  "omni-dotfiles",
  "win-dotfiles@work",
]
' | save -f ($sb.ygg_home | path join "config.toml")

        let res = (with-env {
            HOME: $sb.home,
            YGG_HOME: $sb.ygg_home,
            YGG_SANDBOX: $sb.home,
            YGG_HOST_OS_OVERRIDE: "windows",
            YGG_MOCK_PKG_LOG: $sb.pkg_log
        } { ^nu $YGG_BIN apply --sandbox $sb.home } | complete)
        assert ($res.exit_code == 0) $"Windows @work apply failed: ($res.stderr)"

        # Assert Windows paths ($APPDATA, $DOCUMENTS, $LOCALAPPDATA) and auto-generated .cmd shims
        assert (($sb.home | path join "Documents" "PowerShell" "Microsoft.PowerShell_profile.ps1") | path exists)
        assert (($sb.home | path join "AppData" "Roaming" "nushell" "config.nu") | path exists)
        assert (($sb.home | path join "AppData" "Roaming" "nushell" "config.local.nu") | path exists)
        assert (($sb.home | path join ".local" "bin" "omni.cmd") | path exists) "ygg must auto-generate omni.cmd on Windows"
        assert (($sb.home | path join ".local" "bin" "edt.cmd") | path exists) "ygg must auto-generate edt.cmd for @work"
        assert (($sb.home | path join ".local" "bin" "update-ib.cmd") | path exists) "ygg must auto-generate update-ib.cmd for @work"
        assert (($sb.home | path join ".config" "1c" "projects.example.json") | path exists)
        assert (($sb.home | path join ".config" "glazewm" "cfg" "workspaces.yaml") | path exists)

        # Assert [save] entry registered in state.copies
        let st = (open ($sb.ygg_home | path join ".state" "state.json"))
        assert ($wt_settings in ($st.copies | columns)) "Windows Terminal settings.json must be tracked in state.copies via [save]"

        # Assert Unix DevOps aliases were NOT emitted into Windows aliases.ps1
        let ps_aliases = (open --raw ($sb.ygg_home | path join ".state" "env" "aliases.ps1"))
        assert (not ($ps_aliases | str contains "function kubectl")) "Unix DevOps aliases leaked into Windows aliases.ps1"
        assert ($ps_aliases | str contains "function gst") "Core git aliases missing in Windows aliases.ps1"
    } catch { |e|
        rm -rf $sb.root
        error make { msg: $e.msg }
    }
    rm -rf $sb.root
}

def main [target: string = "all"] {
    if $target in ["all", "omni"] {
        test-zero-legacy-artifacts "omni-dotfiles"
        test-omni-standalone-linux
        print "[PASS] omni-dotfiles Stage 2 checks"
    }
    if $target in ["all", "dotfiles"] {
        test-zero-legacy-artifacts "dotfiles"
        print "[PASS] dotfiles legacy-free checks"
    }
    if $target in ["all", "ai"] {
        test-zero-legacy-artifacts "ai-dotfiles"
        print "[PASS] ai-dotfiles legacy-free checks"
    }
    if $target in ["all", "linux-e2e"] {
        test-linux-pc-and-asus-scope-switch
        print "[PASS] Linux @pc + @asus + ai-dotfiles E2E checks"
    }
    if $target in ["all", "win"] {
        test-zero-legacy-artifacts "win-dotfiles"
        test-windows-work-and-save-roundtrip
        print "[PASS] win-dotfiles @work Stage 2 checks"
    }
}
```

- [ ] **Step 3: Add `test-phase2` recipe to `/data/projects/ygg/justfile` and verify Red phase**

Append to `/data/projects/ygg/justfile`:
```just
# Run Stage 2 sandbox verification against migrated Phase 2 module worktrees
test-phase2 target="all":
    nu tests/test_phase2_modules.nu {{target}}
```
Run:
```bash
rtk just --justfile /data/projects/ygg/justfile test-phase2 omni
```
Expected: FAIL with `Missing ygg.toml in omni-dotfiles`.

---

## Task 2: Migrate `omni-dotfiles` to Flat `ygg` Module (`feat/ygg-migration`)

**Worktree:** `/data/projects/worktree/ygg-phase2/omni-dotfiles` (branch `feat/ygg-migration`)

**Files:**
- Move: `home/dot_config/*` -> `./*` (excluding `environment.d`), `home/Documents/PowerShell` -> `./powershell`, `home/dot_cargo` -> `./cargo`, `home/dot_local/bin/executable_omni` -> `./bin/omni`, `home/dot_local/bin/executable_omni.nu` -> `./bin/omni.nu`, `home/dot_local/share/omni` -> `./omni`, `home/dot_zshrc` -> `./zsh/zshrc`, `home/nvim/dot_neoconf.json` -> `./nvim/.neoconf.json`
- Convert `.tmpl` -> static: `nushell/carapace.nu`, `cargo/config.toml`, `mise/config.toml`, `git/{config,config-github,config-gitlab}`, `gh/hosts.yml`, `glab-cli/config.yml`, `zsh/zshenv`
- Delete: `.chezmoiroot`, `home/` (including `.chezmoi.toml.tmpl`, `.chezmoiignore`, `.chezmoidata/*`, `.chezmoiscripts/*`, `aliases.{nu,zsh,ps1}.tmpl`, `omni.cmd.tmpl`, `10-environment.conf.tmpl`)
- Create: `ygg.toml`, `packages.toml`, `links.toml`, `env.toml`, `aliases.toml`
- Modify: `nushell/env.nu`, `nushell/conf.d/integrations.nu`, `nushell/config.nu`, `zsh/zshrc`, `powershell/conf.d/01-env.ps1`, `powershell/Microsoft.PowerShell_profile.ps1`, `.gitignore`, `justfile`, `AGENTS.md`

- [ ] **Step 1: Flatten `home/` directory tree via `git mv` inside `/data/projects/worktree/ygg-phase2/omni-dotfiles`**

Run in `/data/projects/worktree/ygg-phase2/omni-dotfiles`:
```bash
rtk nu -c '
cd /data/projects/worktree/ygg-phase2/omni-dotfiles
mkdir bin
^git mv home/dot_local/bin/executable_omni bin/omni
^git mv home/dot_local/bin/executable_omni.nu bin/omni.nu
^git mv home/dot_local/share/omni omni
^git mv home/Documents/PowerShell powershell
^git mv home/dot_cargo cargo
for item in (ls home/dot_config | get name) {
    let base = ($item | path basename)
    if $base != "environment.d" {
        ^git mv $item $base
    }
}
^git mv nvim/dot_neoconf.json nvim/.neoconf.json
^git mv home/dot_zshrc zsh/zshrc
^chmod +x bin/omni bin/omni.nu
'
```

- [ ] **Step 2: Convert remaining `.tmpl` configs to static files with native `local.*` includes and remove Chezmoi artifacts**

1. `nushell/carapace.nu` (from `nushell/carapace.nu.tmpl`): replace `{{ .chezmoi.homeDir }}` with `~` (or `$nu.home-dir`), then `git rm nushell/carapace.nu.tmpl`.
2. `cargo/config.toml` (from `cargo/config.toml.tmpl`): keep static `[target.x86_64-unknown-linux-gnu]` section (Cargo ignores Linux target triples on Windows/macOS natively), then `git rm cargo/config.toml.tmpl`.
3. `mise/config.toml` (from `mise/config.toml.tmpl`): keep universal cross-platform `[tools]` (`node`, `bun`, `uv`, `just`, `usage`, `eza`, `fzf`, `jq`, `yq`, `fd`, `ripgrep`, `bat`, `zoxide`, `starship`, `atuin`, `carapace`, `television`, `gh`, `glab`, `glow`, `lazydocker`, `lazygit`, `delta`) and `[env] _.path = ["{{env.HOME}}/.local/bin"]` (native Mise Tera syntax, NOT Chezmoi); move Unix-only tools (`kubectl`, `k9s`, `sheldon`, `zellij`, `btop`, `superfile`, `sops`, `age`) to `packages.toml` `[scope.unix.packages]`; `git rm mise/config.toml.tmpl`.
4. `git/config`, `git/config-github`, `git/config-gitlab`: remove Chezmoi `{{ .name }}` / `{{ .email }}` templating; add at the end of `git/config`:
   ```ini
   [include]
       path = ~/.config/git/config.local
   ```
   Convert `gh/hosts.yml.tmpl` -> `gh/hosts.yml` and `glab-cli/config.yml.tmpl` -> `glab-cli/config.yml` without secret tokens (CLI auth lives in local keyring / `secrets.toml` `GH_TOKEN` / `GITLAB_TOKEN`).
5. Create static `zsh/zshenv`:
   ```zsh
   # Omni-Dotfiles Zsh Environment Bootstrap (managed by ygg)
   YGG_STATE_ENV="${YGG_HOME:-$HOME/.ygg}/.state/env/env.zsh"
   [[ -f "$YGG_STATE_ENV" ]] && source "$YGG_STATE_ENV"
   [[ -f "$HOME/.zshenv.local" ]] && source "$HOME/.zshenv.local"
   ```
6. Remove all remaining Chezmoi files:
   ```bash
   rtk git -C /data/projects/worktree/ygg-phase2/omni-dotfiles rm -rf .chezmoiroot home nushell/aliases.nu.tmpl zsh/aliases.zsh.tmpl powershell/aliases.ps1.tmpl
   ```

- [ ] **Step 3: Create `ygg.toml`, `packages.toml`, `links.toml`, `env.toml`, and `aliases.toml`**

1. `ygg.toml`:
   ```toml
   name = "omni-dotfiles"
   description = "Cross-platform shell, terminal & CLI core (Nushell, Zsh, PowerShell)"
   os = ["linux", "macos", "windows"]
   ```
2. `packages.toml`:
   ```toml
   [packages]
   mise = [
     "aqua:sharkdp/bat",
     "aqua:sharkdp/fd",
     "aqua:BurntSushi/ripgrep",
     "aqua:eza-community/eza",
     "aqua:junegunn/fzf",
     "aqua:ajeetdsouza/zoxide",
     "aqua:starship/starship",
     "aqua:atuinsh/atuin",
     "aqua:carapace-sh/carapace-bin",
     "aqua:alexpasmantier/television",
     "aqua:casey/just",
   ]

   [scope.unix.packages]
   mise = [
     "aqua:zellij-org/zellij",
     "aqua:rossmacarthur/sheldon",
     "aqua:yorukot/superfile",
     "aqua:getsops/sops",
     "aqua:FiloSottile/age",
     "aqua:derailed/k9s",
   ]

   [scope.windows.packages]
   winget = [
     "Microsoft.PowerShell",
     "nushell",
     "jdx.mise",
     "Neovim.Neovim",
     "Git.Git",
   ]
   ```
3. `links.toml` (using `/*` unfolding on shared directories `bin`, `git`, `nushell` so runtime history, local overrides, and sibling modules never collide):
   ```toml
   [links]
   "bin/*" = "~/.local/bin/*"
   "omni" = "~/.local/share/omni"
   "starship.toml" = "~/.config/starship.toml"
   "atuin" = "~/.config/atuin"
   "bat" = "~/.config/bat"
   "carapace" = "~/.config/carapace"
   "cargo/config.toml" = "~/.cargo/config.toml"
   "fzf" = "~/.config/fzf"
   "gh" = "~/.config/gh"
   "ghostty" = "~/.config/ghostty"
   "git/*" = "~/.config/git/*"
   "glab-cli" = "~/.config/glab-cli"
   "glow" = "~/.config/glow"
   "mise" = "~/.config/mise"
   "rtk" = "~/.config/rtk"
   "superfile" = "~/.config/superfile"
   "television" = "~/.config/television"

   [scope.unix.links]
   "nushell/*" = "~/.config/nushell/*"
   "nvim" = "~/.config/nvim"
   "btop" = "~/.config/btop"
   "k3d" = "~/.config/k3d"
   "k9s" = "~/.config/k9s"
   "sheldon" = "~/.config/sheldon"
   "zellij" = "~/.config/zellij"
   "zsh/zshenv" = "~/.zshenv"
   "zsh/zshrc" = "~/.zshrc"
   "zsh/01-env.zsh" = "~/.config/zsh/01-env.zsh"
   "zsh/02-history.zsh" = "~/.config/zsh/02-history.zsh"
   "zsh/03-completion.zsh" = "~/.config/zsh/03-completion.zsh"
   "zsh/04-binds.zsh" = "~/.config/zsh/04-binds.zsh"
   "zsh/05-tools.zsh" = "~/.config/zsh/05-tools.zsh"
   "powershell" = "~/.config/powershell"

   [scope.windows.links]
   "nushell/*" = "$APPDATA/nushell/*"
   "nvim" = "$LOCALAPPDATA/nvim"
   "powershell" = "$DOCUMENTS/PowerShell"
   ```
4. `env.toml` (migrated 1:1 from `home/.chezmoidata/env.yaml`):
   ```toml
   [env]
   XDG_CONFIG_HOME = "~/.config"
   XDG_DATA_HOME = "~/.local/share"
   XDG_CACHE_HOME = "~/.cache"
   XDG_STATE_HOME = "~/.local/state"
   EDITOR = "nvim"
   VISUAL = "nvim"
   PAGER = "bat"
   BAT_PAGER = "less -R"
   FZF_DEFAULT_OPTS = "--height 40% --layout=reverse --border --inline-info"
   KUBECONFIG = "~/.kube/config"
   PYTHONIOENCODING = "utf-8"
   PYTHONUTF8 = "1"

   [scope.linux.env]
   SHELL = "/usr/bin/zsh"
   PNPM_HOME = "/data/projects/.pnpm-store"
   SCCACHE_DIR = "/data/projects/.sccache"
   UV_CACHE_DIR = "/data/projects/.uv-cache"
   FZF_BASE = "/usr/share/fzf"
   PROJECTS_ROOT = "/data/projects"
   PROJECTS_WORKTREE_ROOT = "/data/projects/worktree"
   LANG = "en_US.UTF-8"
   LC_TIME = "en_US.UTF-8"
   LC_NUMERIC = "en_US.UTF-8"
   LC_MONETARY = "en_US.UTF-8"
   LC_PAPER = "en_US.UTF-8"
   LC_NAME = "en_US.UTF-8"
   LC_ADDRESS = "en_US.UTF-8"
   LC_TELEPHONE = "en_US.UTF-8"
   LC_MEASUREMENT = "en_US.UTF-8"
   LC_IDENTIFICATION = "en_US.UTF-8"
   ```
5. `aliases.toml` (migrated 1:1 from `home/.chezmoidata/aliases.yaml`, replacing `cz = "chezmoi"` with `y = "ygg"`, keeping DevOps aliases under `[scope.unix.aliases]`):
   ```toml
   [aliases]
   l = "eza --icons"
   ll = "eza -l --icons"
   la = "eza -la --icons"
   lt = "eza --tree --level=2 --icons"
   tree = "eza --tree --icons"
   g = "git"
   ga = "git add"
   gc = "git commit"
   gp = "git push"
   gl = "git pull"
   gst = "git status"
   gd = "git diff"
   gco = "git checkout"
   gb = "git branch"
   glog = "git log --oneline --graph --decorate"
   c = "clear"
   cat = "bat"
   j = "just"
   m = "mise"
   y = "ygg"
   bt = "btop"
   sp = "superfile"
   television = "tv"
   extract = "omni extract"
   x = "omni extract"
   spft = "omni spft"
   omni-health = "omni health"
   ai-ctx = "omni ai ctx"
   ai-tree = "omni ai tree"
   ls-ai = "omni ai ls"
   gpsup = "omni git push"
   gsync = "omni git sync"
   git-wt-add = "omni git wt-add"
   ws-list = "omni git wt-list"
   feature = "omni git feature"
   mr-dev = "omni git mr-dev"

   [scope.unix.aliases]
   tf = "terraform"
   playbook = "ansible-playbook"
   k = "kubectl"
   kns = "kubens"
   ktx = "kubectx"
   k8s-helper = "omni k8s"
   ```

- [ ] **Step 4: Wire Nushell, Zsh, and PowerShell profiles to `~/.ygg/.state/env/*`**

1. In `nushell/env.nu`: replace the legacy `~/.config/chezmoi/secrets.toml` block (lines 32–41) with compile-time safe `source` of `~/.ygg/.state/env/env.nu`:
   ```nushell
   # Load compiled ygg environment & secrets (~/.ygg/.state/env/env.nu)
   const ygg_env_path = ($nu.home-dir | path join ".ygg" ".state" "env" "env.nu")
   const ygg_env_file = if ($ygg_env_path | path exists) { $ygg_env_path } else { null }
   source $ygg_env_file
   ```
2. In `nushell/conf.d/integrations.nu`: update section 3 (`aliases.nu`) to point to `~/.ygg/.state/env/aliases.nu`:
   ```nushell
   # 3. Source SSOT aliases generated by ygg
   const aliases_path = ($nu.home-dir | path join ".ygg" ".state" "env" "aliases.nu")
   const aliases_file = if ($aliases_path | path exists) { $aliases_path } else { null }
   source $aliases_file
   ```
3. In `nushell/config.nu` (keep strictly `<50` lines): append `local.nu` sourcing right before `config.local.nu`:
   ```nushell
   const ygg_local_path = ($nu.home-dir | path join ".ygg" ".state" "env" "local.nu")
   const ygg_local_file = if ($ygg_local_path | path exists) { $ygg_local_path } else { null }
   source $ygg_local_file
   ```
4. In `zsh/zshrc`: replace section 4 (`$ZSH_CONFIG_DIR/aliases.zsh`) with:
   ```zsh
   # 4. Source SSOT Environment & Aliases generated by ygg
   YGG_STATE_DIR="${YGG_HOME:-$HOME/.ygg}/.state/env"
   [[ -f "$YGG_STATE_DIR/env.zsh" ]] && source "$YGG_STATE_DIR/env.zsh"
   [[ -f "$YGG_STATE_DIR/aliases.zsh" ]] && source "$YGG_STATE_DIR/aliases.zsh"
   ```
5. In `powershell/conf.d/01-env.ps1`: append:
   ```powershell
   $YggHome = if ($env:YGG_HOME) { $env:YGG_HOME } else { Join-Path $HOME ".ygg" }
   $YggEnvPath = Join-Path $YggHome ".state\env\env.ps1"
   if (Test-Path -LiteralPath $YggEnvPath) { . $YggEnvPath }
   ```
   And in `powershell/Microsoft.PowerShell_profile.ps1` (keep `<50` lines): replace `$ProfileDir\aliases.ps1` with:
   ```powershell
   $YggHome = if ($env:YGG_HOME) { $env:YGG_HOME } else { Join-Path $HOME ".ygg" }
   $AliasesPath = Join-Path $YggHome ".state\env\aliases.ps1"
   if (Test-Path -LiteralPath $AliasesPath) { . $AliasesPath }
   ```
6. Update `.gitignore` (ignore `**/local.*`, `**/*.local`, `**/history.sqlite3*`, `.worktrees/`), update `justfile` recipes (`apply` -> `ygg apply`, `status` -> `ygg status`, `doctor` -> `ygg doctor`), and update `AGENTS.md` inside the worktree to document the `ygg` module layout.

- [ ] **Step 5: Run Stage 2 verification for `omni-dotfiles` and commit on `feat/ygg-migration`**

Run:
```bash
rtk just --justfile /data/projects/ygg/justfile test-phase2 omni
```
Expected: `[PASS] omni-dotfiles Stage 2 checks` (exit code `0`).

Commit inside `/data/projects/worktree/ygg-phase2/omni-dotfiles`:
```bash
rtk git -C /data/projects/worktree/ygg-phase2/omni-dotfiles add -A && rtk git -C /data/projects/worktree/ygg-phase2/omni-dotfiles commit -m "feat(ygg): migrate omni-dotfiles to flat template-free ygg module"
```

---

## Task 3: Migrate `dotfiles` (CachyOS Desktop & Laptop Scopes) (`feat/ygg-migration`)

**Worktree:** `/data/projects/worktree/ygg-phase2/dotfiles` (branch `feat/ygg-migration`)

**Files:**
- Move: `home/dot_config/*` -> `./*` (excluding `chezmoi`, `environment.d`, `symlink_noctalia.tmpl`), `home/dot_config/chezmoi/secrets.example.toml` -> `./secrets.example.toml`, `home/dot_zsh` -> `./zsh`, `linked/noctalia` -> `./noctalia`
- Isolate PC-only hardware files: `systemd/user/openrgb.service.tmpl` -> `systemd/user-pc/openrgb.service`, `systemd/user/openrgb-profile.service.tmpl` -> `systemd/user-pc/openrgb-profile.service`, `zsh/alias/cooler.zsh` -> `zsh/alias-pc/cooler.zsh`, `zsh/scripts/cooler-toggle.sh` -> `zsh/scripts-pc/cooler-toggle.sh`
- Split Niri display profiles: `niri/cfg/display.kdl.tmpl` -> `niri/displays/pc.kdl` + `niri/displays/asus.kdl`
- Add static user units: `systemd/user/rclone-obsidian-sync.service`, `systemd/user/rclone-obsidian-sync.timer`
- Delete: `.chezmoiroot`, `home/`, `linked/`, `playbooks/setup_user.yml` (strictly KEEP `playbooks/setup_system.yml` and root OS Day-0 playbooks!)
- Create: `ygg.toml`, `packages.toml`, `links.toml`, `setup.nu`

- [ ] **Step 1: Flatten `home/` and `linked/` and isolate PC vs ASUS files in `/data/projects/worktree/ygg-phase2/dotfiles`**

Run in `/data/projects/worktree/ygg-phase2/dotfiles`:
```bash
rtk nu -c '
cd /data/projects/worktree/ygg-phase2/dotfiles
^git mv home/dot_config/chezmoi/secrets.example.toml secrets.example.toml
^git mv home/dot_zsh zsh
^git mv linked/noctalia noctalia
for item in (ls home/dot_config | get name) {
    let base = ($item | path basename)
    if $base not-in ["chezmoi", "environment.d", "symlink_noctalia.tmpl"] {
        ^git mv $item $base
    }
}
mkdir systemd/user-pc zsh/alias-pc zsh/scripts-pc niri/displays
^git mv systemd/user/openrgb.service.tmpl systemd/user-pc/openrgb.service
^git mv systemd/user/openrgb-profile.service.tmpl systemd/user-pc/openrgb-profile.service
^git mv zsh/alias/cooler.zsh zsh/alias-pc/cooler.zsh
^git mv zsh/scripts/cooler-toggle.sh zsh/scripts-pc/cooler-toggle.sh
^chmod +x ...(glob zsh/scripts/*) zsh/scripts-pc/cooler-toggle.sh
'
```

- [ ] **Step 2: Convert `.tmpl` files into static configs and create PC/ASUS display profiles + Rclone systemd units**

1. Split `niri/cfg/display.kdl.tmpl` into:
   - `niri/displays/pc.kdl`: desktop dual-monitor / `DP-2` layout from the `desktop` branch of `display.kdl.tmpl`, ending with `include optional=true "../local.kdl"`.
   - `niri/displays/asus.kdl`: ASUS laptop `eDP-1` layout from the `laptop` branch of `display.kdl.tmpl`, ending with `include optional=true "../local.kdl"`.
   - `git rm niri/cfg/display.kdl.tmpl`.
2. Convert `waypaper/config.ini.tmpl` -> `waypaper/config.ini` (`~` paths, no `{{ .chezmoi.homeDir }}`) and `wallpaper-engine/config.json.tmpl` -> `wallpaper-engine/config.json`; remove `.tmpl` originals.
3. Create static `systemd/user/rclone-obsidian-sync.service` and `systemd/user/rclone-obsidian-sync.timer` (migrated verbatim from `playbooks/setup_user.yml` lines 145–174 using `%h/.cache/rclone/obsidian-sync.log`).
4. Remove Chezmoi & user-space Ansible artifacts (preserving root `playbooks/setup_system.yml` & Day-0 system playbooks):
   ```bash
   rtk git -C /data/projects/worktree/ygg-phase2/dotfiles rm -rf .chezmoiroot home playbooks/setup_user.yml
   ```
   (If `.chezmoiroot` did not exist, remove remaining `home/` directory cleanly.)

- [ ] **Step 3: Create `ygg.toml`, `packages.toml`, `links.toml`, and `setup.nu`**

1. `ygg.toml`:
   ```toml
   name = "dotfiles"
   description = "CachyOS / Arch Wayland Desktop (Niri, Noctalia, Audio, Desktop & ASUS Laptop Hardware Scopes)"
   os = ["cachyos", "arch"]
   ```
2. `packages.toml` (migrated from `playbooks/vars/packages.yml`, strictly separating `[scope.pc.packages]` and `[scope.asus.packages]`, omitting legacy `chezmoi` and `stow`):
   ```toml
   [packages]
   pacman = [
     "rustup", "neovim", "jq", "chromium", "git", "ripgrep", "fd", "bat", "eza",
     "rofi", "piper", "libratbag", "obsidian", "imv", "ddcutil", "wlsunset", "mpv",
     "libsixel", "libxpresent", "mujs", "playerctl", "pear-desktop", "rclone",
     "cliphist", "wtype", "hypridle", "cargo-binstall",
   ]
   paru = [
     "vivaldi", "visual-studio-code-bin", "ferdium-bin", "tor-browser-bin",
     "ghostty", "mise", "noctalia-qs", "noctalia", "noctalia-shell",
   ]
   cargo = [
     "cargo-ramdisk", "cargo-nextest", "bacon", "cargo-machete",
   ]

   [scope.pc.packages]
   paru = [
     "openrgb",
     "coolercontrold-bin",
     "coolercontrol-bin",
   ]

   [scope.asus.packages]
   pacman = [
     "asusctl",
     "supergfxctl",
     "rog-control-center",
     "power-profiles-daemon",
     "brightnessctl",
   ]
   ```
3. `links.toml` (unfolding `niri/cfg/*` as a physical directory so linking `display.kdl` inside `~/.config/niri/cfg/` never writes back into the Git repository):
   ```toml
   [links]
   "hypr" = "~/.config/hypr"
   "niri/config.kdl" = "~/.config/niri/config.kdl"
   "niri/noctalia.kdl" = "~/.config/niri/noctalia.kdl"
   "niri/cfg/*" = "~/.config/niri/cfg/*"
   "noctalia" = "~/.config/noctalia"
   "rofi" = "~/.config/rofi"
   "systemd/user/*" = "~/.config/systemd/user/*"
   "vivaldi-stable.conf" = "~/.config/vivaldi-stable.conf"
   "wallpaper-engine" = "~/.config/wallpaper-engine"
   "waypaper" = "~/.config/waypaper"
   "wireplumber" = "~/.config/wireplumber"
   "zsh/alias/*" = "~/.zsh/alias/*"
   "zsh/scripts/*" = "~/.zsh/scripts/*"

   [scope.pc.links]
   "niri/displays/pc.kdl" = "~/.config/niri/cfg/display.kdl"
   "OpenRGB" = "~/.config/OpenRGB"
   "systemd/user-pc/*" = "~/.config/systemd/user/*"
   "zsh/alias-pc/cooler.zsh" = "~/.zsh/alias/cooler.zsh"
   "zsh/scripts-pc/cooler-toggle.sh" = "~/.zsh/scripts/cooler-toggle.sh"

   [scope.asus.links]
   "niri/displays/asus.kdl" = "~/.config/niri/cfg/display.kdl"
   ```
4. `setup.nu` (replaces `playbooks/setup_user.yml` user-space tasks with full sandbox safety):
   ```nushell
   #!/usr/bin/env nu
   use state.nu [expand-target-path]

   let is_dry = (($env.YGG_DRY_RUN? | default "false") == "true")
   let is_sandbox = (($env.YGG_SANDBOX? | default "") != "")
   let scopes = (($env.YGG_SCOPES? | default "[]") | from json)

   if not $is_dry {
       # 1. Ensure Rclone cache directory exists (~/.cache/rclone)
       mkdir (expand-target-path "~/.cache/rclone")

       # 2. Ensure Neovim default MIME associations in ~/.config/mimeapps.list
       let mime_path = (expand-target-path "~/.config/mimeapps.list")
       mkdir ($mime_path | path dirname)
       let header = "[Default Applications]"
       let entries = [
           "text/markdown=nvim.desktop",
           "text/plain=nvim.desktop",
           "text/x-markdown=nvim.desktop"
       ]
       let existing = if ($mime_path | path exists) { open --raw $mime_path } else { "" }
       mut updated = $existing
       if not ($updated | str contains $header) {
           $updated = (if ($updated == "") { $header + "\n" } else { $updated + "\n" + $header + "\n" })
       }
       for entry in $entries {
           if not ($updated | str contains $entry) {
               $updated = $updated + $entry + "\n"
           }
       }
       $updated | save -f $mime_path

       # 3. Live-host only actions (skipped in --sandbox)
       if not $is_sandbox {
           if ("/data/projects" | path exists) {
               mkdir "/data/projects/.cargo-cache/registry" "/data/projects/.cargo-cache/git"
               mkdir ("~/.cargo" | path expand)
               ^ln -sfn "/data/projects/.cargo-cache/registry" ("~/.cargo/registry" | path expand)
               ^ln -sfn "/data/projects/.cargo-cache/git" ("~/.cargo/git" | path expand)
           }

           ^systemctl --user daemon-reload | complete | ignore
           if (("~/.config/rclone/rclone.conf" | path expand) | path exists) {
               ^systemctl --user enable --now rclone-obsidian-sync.timer | complete | ignore
           }
           if ("pc" in $scopes) {
               ^systemctl --user enable --now openrgb.service openrgb-profile.service | complete | ignore
           }
       }
   }
   ```

- [ ] **Step 4: Verify `dotfiles` legacy check and commit on `feat/ygg-migration`**

Run:
```bash
rtk just --justfile /data/projects/ygg/justfile test-phase2 dotfiles
```
Expected: `[PASS] dotfiles legacy-free checks`.

Commit inside `/data/projects/worktree/ygg-phase2/dotfiles`:
```bash
rtk git -C /data/projects/worktree/ygg-phase2/dotfiles add -A && rtk git -C /data/projects/worktree/ygg-phase2/dotfiles commit -m "feat(ygg): migrate dotfiles to ygg module with @pc and @asus scopes"
```

---

## Task 4: Migrate `ai-dotfiles` (CachyOS AI Workstation Module) (`feat/ygg-migration`)

**Worktree:** `/data/projects/worktree/ygg-phase2/ai-dotfiles` (branch `feat/ygg-migration`)

**Files:**
- Move out of `infra/stow/` (preserving submodule & physical plugins):
  - `infra/stow/antigravity/.gemini/config` -> `antigravity`
  - `infra/stow/hermes/.hermes/config.yaml` -> `services/hermes/config.yaml`
  - `infra/stow/hermes/.hermes/plugins/{grill-tab,hindsight,rtk-rewrite,skill-retrieval}` -> `services/hermes/plugins/{grill-tab,hindsight,rtk-rewrite,skill-retrieval}`
  - `infra/stow/hermes-desktop/.config/Hermes` -> `configs/hermes-desktop`
  - `infra/stow/ollama/.config/ollama` -> `configs/ollama`
  - `infra/stow/opencommit` -> `configs/opencommit`
- Create static systemd & env units: `systemd/user/hermes-dashboard.service`, `systemd/user/hermes-gateway.service`, `environment.d/pythonpath.conf`
- Delete: `infra/stow/`, `infra/playbooks/`
- Create: `ygg.toml`, `packages.toml`, `links.toml`, `setup.nu`
- Modify: `AGENTS.md`, `antigravity/plugins/host-rules/rules/AGENTS.md`

- [ ] **Step 1: Relocate physical configs & submodule out of `infra/stow/` via `git mv` (without reading Context Bomb contents)**

Run in `/data/projects/worktree/ygg-phase2/ai-dotfiles`:
```bash
rtk nu -c '
cd /data/projects/worktree/ygg-phase2/ai-dotfiles
mkdir configs systemd/user environment.d
^git mv infra/stow/antigravity/.gemini/config antigravity
^git mv infra/stow/hermes/.hermes/config.yaml services/hermes/config.yaml
for p in ["grill-tab", "hindsight", "rtk-rewrite", "skill-retrieval"] {
    ^git mv $"infra/stow/hermes/.hermes/plugins/($p)" $"services/hermes/plugins/($p)"
}
^git mv infra/stow/hermes-desktop/.config/Hermes configs/hermes-desktop
^git mv infra/stow/ollama/.config/ollama configs/ollama
^git mv infra/stow/opencommit configs/opencommit
^git rm -rf infra/stow infra/playbooks
^chmod +x ...(glob scripts/*.sh) scripts/hermes-helper-mcp scripts/host-cli-mcp
^chmod +x services/hermes/profiles/idea-receiver/scripts/capture_idea.py services/hermes/profiles/idea-refiner/scripts/refine_helper.py
'
```

- [ ] **Step 2: Create static `systemd/user/hermes-{dashboard,gateway}.service` and `environment.d/pythonpath.conf`**

1. Create `systemd/user/hermes-dashboard.service` and `systemd/user/hermes-gateway.service` with the exact `[Unit]`, `[Service]`, and `[Install]` definitions from legacy `setup_hermes.yml` (using `%h` systemd specifier — zero Jinja templates!).
2. Create `environment.d/pythonpath.conf`:
   ```ini
   PYTHONPATH=%h/.local/lib/python3.14/site-packages
   PYTHONDONTWRITEBYTECODE=1
   ```

- [ ] **Step 3: Create `ygg.toml`, `packages.toml`, `links.toml`, and `setup.nu`**

1. `ygg.toml`:
   ```toml
   name = "ai-dotfiles"
   description = "CachyOS Local AI Infrastructure (Antigravity, Hermes, Ollama 64K, Hindsight, RTK)"
   os = ["cachyos"]
   ```
2. `packages.toml`:
   ```toml
   [packages]
   pacman = ["ollama", "ollama-cuda", "docker", "docker-compose", "sqlite"]
   paru = ["rtk-bin", "opencode", "opencommit"]
   mise = ["bun", "uv", "node"]
   ```
3. Create `bin/` in `ai-dotfiles` for extensionless `~/.local/bin/*` entrypoints (`mkdir bin && ln -s ../scripts/sync-knowledge.sh bin/sync-knowledge && ln -s ../scripts/gcai.sh bin/gcai && ln -s ../scripts/hermes-helper-mcp bin/hermes-helper-mcp && ln -s ../scripts/host-cli-mcp bin/host-cli-mcp`), then write `links.toml` (direct `/*` unfolding into `~/.gemini/config`, `~/.hermes/plugins`, `~/.hermes/profiles/<p>`, `~/.config/Hermes`, `~/.zsh/scripts`, `~/.local/bin`, `~/.config/systemd/user`):
   ```toml
   [links]
   "antigravity/*" = "~/.gemini/config/*"
   "bin/*" = "~/.local/bin/*"
   "services/hermes/config.yaml" = "~/.hermes/config.yaml"
   "services/hermes/plugins/*" = "~/.hermes/plugins/*"
   "services/hermes/profiles/coder/*" = "~/.hermes/profiles/coder/*"
   "services/hermes/profiles/gemini/*" = "~/.hermes/profiles/gemini/*"
   "services/hermes/profiles/thinker/*" = "~/.hermes/profiles/thinker/*"
   "services/hermes/profiles/sysops/*" = "~/.hermes/profiles/sysops/*"
   "services/hermes/profiles/formatter/*" = "~/.hermes/profiles/formatter/*"
   "services/hermes/profiles/idea-receiver/*" = "~/.hermes/profiles/idea-receiver/*"
   "services/hermes/profiles/idea-refiner/*" = "~/.hermes/profiles/idea-refiner/*"
   "configs/hermes-desktop/*" = "~/.config/Hermes/*"
   "configs/ollama" = "~/.config/ollama"
   "configs/opencommit/.opencommit" = "~/.opencommit"
   "configs/opencommit/.opencommit_migrations" = "~/.opencommit_migrations"
   "infra/claude/CLAUDE.md" = "~/.claude/CLAUDE.md"
   "systemd/user/*" = "~/.config/systemd/user/*"
   "environment.d/pythonpath.conf" = "~/.config/environment.d/pythonpath.conf"
   "scripts/ai-launcher.sh" = "~/.zsh/scripts/ai-launcher.sh"
   "scripts/ai-stack.sh" = "~/.zsh/scripts/ai-stack.sh"
   "scripts/ai-status.sh" = "~/.zsh/scripts/ai-status.sh"
   "scripts/anything-ctl.sh" = "~/.zsh/scripts/anything-ctl.sh"
   "scripts/anythingllm-assistant-toggle.sh" = "~/.zsh/scripts/anythingllm-assistant-toggle.sh"
   "scripts/gcai.sh" = "~/.zsh/scripts/gcai.sh"
   "scripts/hermes-bar-status.sh" = "~/.zsh/scripts/hermes-bar-status.sh"
   "scripts/hermes-capture-idea.sh" = "~/.zsh/scripts/hermes-capture-idea.sh"
   "scripts/hermes-desktop-toggle.sh" = "~/.zsh/scripts/hermes-desktop-toggle.sh"
   "scripts/kanban-relay.sh" = "~/.zsh/scripts/kanban-relay.sh"
   "scripts/khoj-ctl.sh" = "~/.zsh/scripts/khoj-ctl.sh"
   "scripts/khoj-tags.sh" = "~/.zsh/scripts/khoj-tags.sh"
   "scripts/khoj-toggle.sh" = "~/.zsh/scripts/khoj-toggle.sh"
   "scripts/manage-hindsight.sh" = "~/.zsh/scripts/manage-hindsight.sh"
   "scripts/rtk-worktree-hook.sh" = "~/.zsh/scripts/rtk-worktree-hook.sh"
   "scripts/sync-env.sh" = "~/.zsh/scripts/sync-env.sh"
   "scripts/sync-knowledge.sh" = "~/.zsh/scripts/sync-knowledge.sh"
   "scripts/sync-skills.sh" = "~/.zsh/scripts/sync-skills.sh"
   "scripts/vram-guard.sh" = "~/.zsh/scripts/vram-guard.sh"
   ```
4. Create `setup.nu` using `use sdk.nu [onchange, merge-json, export-secrets]` and `use state.nu [expand-target-path]`:
   ```nushell
   #!/usr/bin/env nu
   use sdk.nu [onchange, merge-json, export-secrets]
   use state.nu [expand-target-path]
   use link.nu [is-link-or-junction, remove-link-only]

   let is_dry = (($env.YGG_DRY_RUN? | default "false") == "true")
   let is_sandbox = (($env.YGG_SANDBOX? | default "") != "")
   let mod_dir = ($env.YGG_MODULE_DIR? | default ".")

   let profiles = ["idea-receiver", "idea-refiner", "gemini", "thinker", "sysops", "formatter", "coder"]

   if not $is_dry {
       # 1. Merge declarative JSON fragments into physical runtime files (0600, symlink-safe)
       merge-json "infra/antigravity/config.plugins.json" "~/.gemini/config/config.json" --mode "0600"
       merge-json "infra/claude/settings.env.json" "~/.claude/settings.json" --mode "0600"

       # 2. Export secrets from $YGG_HOME/secrets.toml -> ~/.hermes/.env (0600) + per-profile .env & plugins links
       export-secrets "~/.hermes/.env"
       for p in $profiles {
           let plug_link = (expand-target-path $"~/.hermes/profiles/($p)/plugins")
           mkdir ($plug_link | path dirname)
           ^ln -sfn "../../plugins" $plug_link
       }
       for p in ["coder", "gemini", "thinker"] {
           let env_link = (expand-target-path $"~/.hermes/profiles/($p)/.env")
           mkdir ($env_link | path dirname)
           ^ln -sfn "../../.env" $env_link
       }

       # 3. Physical skills directories & .no-bundled-skills marker (zero duplicate host skills)
       let hermes_skills = (expand-target-path "~/.hermes/skills")
       if (is-link-or-junction $hermes_skills) { remove-link-only $hermes_skills }
       mkdir $hermes_skills
       "" | save -f ($hermes_skills | path join ".no-bundled-skills")

       let gemini_skills = (expand-target-path "~/.gemini/skills")
       mkdir $gemini_skills
       for dup in ["context-init", "context-audit"] {
           let dup_path = ($gemini_skills | path join $dup)
           if (is-link-or-junction $dup_path) { remove-link-only $dup_path }
       }

       # 4. Physical Hindsight config.json files (0600)
       let hindsight_targets = [
           { dest: "~/.hermes/hindsight/config.json", bank: "hermes" },
           { dest: "~/.hermes/profiles/coder/hindsight/config.json", bank: "coder" },
           { dest: "~/.hermes/profiles/gemini/hindsight/config.json", bank: "coder" },
           { dest: "~/.hermes/profiles/idea-refiner/hindsight/config.json", bank: "idea-refiner" },
           { dest: "~/.hermes/profiles/idea-receiver/hindsight/config.json", bank: "idea-refiner" },
           { dest: "~/.hermes/profiles/thinker/hindsight/config.json", bank: "personal-thinker" },
           { dest: "~/.hindsight/config.json", bank: "coder" }
       ]
       for h in $hindsight_targets {
           let p = (expand-target-path $h.dest)
           mkdir ($p | path dirname)
           { bank_id: $h.bank, base_url: "http://127.0.0.1:8890", recall_types: "observation" }
               | to json --indent 2 | save -f $p
           ^chmod 0600 $p | complete | ignore
       }

       # 5. Seed SQLite state.db guard sessions (count >= 2 invariant) for all 7 Hermes profiles
       if not (which sqlite3 | is-empty) {
           let schema_sql = "CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, started_at TEXT, last_activity_at TEXT, source TEXT, model TEXT, title TEXT, system_prompt TEXT); CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT, content TEXT, created_at TEXT);"
           let seed_sql = "INSERT OR IGNORE INTO sessions (id, started_at, last_activity_at, source, model, title) VALUES ('init_guard_01', datetime('now', '-1 day'), datetime('now', '-1 day'), 'system', 'qwen2.5:14b-ctx64k', 'System Guard 1'), ('init_guard_02', datetime('now', '-2 hour'), datetime('now', '-2 hour'), 'system', 'qwen2.5:14b-ctx64k', 'System Guard 2');"
           for p in $profiles {
               let db = (expand-target-path $"~/.hermes/profiles/($p)/state.db")
               mkdir ($db | path dirname)
               ^sqlite3 $db $schema_sql | complete | ignore
               let cnt_res = (^sqlite3 $db "SELECT COUNT(*) FROM sessions;" | complete)
               let cnt = (try { $cnt_res.stdout | str trim | into int } catch { 0 })
               if $cnt < 2 {
                   ^sqlite3 $db $seed_sql | complete | ignore
               }
           }
       }

       # 6. Live-host runtime integrations (strictly skipped under --sandbox)
       if not $is_sandbox {
           if ("/usr/bin/chromium" | path exists) {
               let chrome_link = (expand-target-path "~/.local/bin/google-chrome")
               mkdir ($chrome_link | path dirname)
               ^ln -sfn "/usr/bin/chromium" $chrome_link
           }

           onchange "ollama-modelfiles" ["infra/modelfiles/*"] {
               if not (which ollama | is-empty) {
                   ^ollama create "qwen2.5:14b-ctx64k" -f ($mod_dir | path join "infra/modelfiles/Modelfile.qwen2.5-ctx64k") | complete | ignore
                   ^ollama create "deepseek-r1:14b-ctx64k" -f ($mod_dir | path join "infra/modelfiles/Modelfile.deepseek-r1-ctx64k") | complete | ignore
               }
           }

           if not (which rtk | is-empty) {
               ^rtk init -g --auto-patch | complete | ignore
               ^rtk init -g --opencode | complete | ignore
           }

           ^systemctl --user daemon-reload | complete | ignore
           ^systemctl --user enable --now hermes-dashboard.service | complete | ignore
       }
   }
   ```

- [ ] **Step 4: Update `AGENTS.md` & `antigravity/plugins/host-rules/rules/AGENTS.md` in worktree, verify E2E Linux stack, and commit**

1. Update `AGENTS.md` and `antigravity/plugins/host-rules/rules/AGENTS.md` inside `/data/projects/worktree/ygg-phase2/ai-dotfiles` to reflect deployment via `ygg` (`ygg.toml`, `links.toml`, `setup.nu`) instead of `infra/stow/` and Ansible.
2. Run both `ai` and `linux-e2e` Stage 2 sandbox checks:
   ```bash
   rtk just --justfile /data/projects/ygg/justfile test-phase2 ai && rtk just --justfile /data/projects/ygg/justfile test-phase2 linux-e2e
   ```
   Expected: `[PASS] ai-dotfiles legacy-free checks` and `[PASS] Linux @pc + @asus + ai-dotfiles E2E checks`.
3. Commit inside `/data/projects/worktree/ygg-phase2/ai-dotfiles`:
   ```bash
   rtk git -C /data/projects/worktree/ygg-phase2/ai-dotfiles add -A && rtk git -C /data/projects/worktree/ygg-phase2/ai-dotfiles commit -m "feat(ygg): migrate ai-dotfiles to ygg module and eliminate stow/ansible"
   ```

---

## Task 5: Migrate `win-dotfiles` (Windows 11 Desktop & `@work` Scope) (`feat/ygg-migration`)

**Worktree:** `/data/projects/worktree/ygg-phase2/win-dotfiles` (branch `feat/ygg-migration`)

**Files:**
- Move: `dot_config/*` -> `./*` (`1c`, `ahk`, `ai`, `bin`, `glazewm`, `just`, `nushell`, `opencode`, `powershell`, `scoop`, `scripts`, `terminal`, `windhawk`, `zebar`)
- Convert `.tmpl` -> static:
  - `glazewm/cfg/workspaces.yaml.tmpl` -> `glazewm/workspaces/pc.yaml` + `glazewm/workspaces/notebook.yaml`
  - `bin/git-ws-add.ps1.tmpl` -> `bin/git-ws-add.ps1`
  - `bin/executable_git-pull-all.cmd.tmpl` -> `bin/git-pull-all.ps1`
  - `scripts/git-pull-all.ts.tmpl` -> `scripts/git-pull-all.ts`
  - `ai/config.yaml.tmpl` -> `ai/config.yaml`
  - `ai/mcp-base.json.tmpl` -> `ai/mcp-base.example.json`
- Delete: `.chezmoi.toml.tmpl`, `.chezmoidata.toml`, `.chezmoiignore`, `.chezmoiscripts/`, `dot_config/`, redundant static `.cmd` wrappers in `bin/` (`edt.cmd`, `git-ws-add.cmd`, `git-ws-remove.cmd`, `host-save.cmd`, `update-ib.cmd` — auto-generated by `ygg` on Windows!)
- Create: `ygg.toml`, `packages.toml`, `links.toml`, `env.toml`, `setup.nu`, `system/windows.dsc.yaml`
- Modify: `bin/host-save.ps1`, `AGENTS.md`

- [ ] **Step 1: Flatten `dot_config/*` via `git mv` without reading `windhawk/sources/*.wh.cpp`**

Run in `/data/projects/worktree/ygg-phase2/win-dotfiles`:
```bash
rtk nu -c '
cd /data/projects/worktree/ygg-phase2/win-dotfiles
for item in (ls dot_config | get name) {
    let base = ($item | path basename)
    ^git mv $item $base
}
mkdir glazewm/workspaces
'
```

- [ ] **Step 2: Replace all `.tmpl` files with static runtime-aware equivalents and remove Chezmoi files**

1. `glazewm/workspaces/pc.yaml` (lines 13–30 of `workspaces.yaml.tmpl` with `bind_to_monitor`) and `glazewm/workspaces/notebook.yaml` (lines 3–11 without monitor binding), stored outside `glazewm/cfg/` so `"glazewm/cfg/*"` only links shared config parts; `git rm glazewm/cfg/workspaces.yaml.tmpl`.
2. `bin/git-ws-add.ps1`: replace lines 40–45 (`{{- $defaultBranch ... }}`) with:
   ```powershell
   $defaultRefBranch = if ($cfg1c -and $cfg1c.worktree -and $cfg1c.worktree.reference_branch) {
       $cfg1c.worktree.reference_branch
   } elseif ($env:GIT_DEFAULT_BRANCH) {
       $env:GIT_DEFAULT_BRANCH
   } else {
       "main"
   }
   ```
   `git rm bin/git-ws-add.ps1.tmpl`.
3. `scripts/git-pull-all.ts`: read project list dynamically from `~/.config/1c/projects.json` (`workProjects` array if present) with `process.env.PROJECTS_ROOT || "D:/projects/default"`; create `bin/git-pull-all.ps1` (`& bun run "$HOME\.config\scripts\git-pull-all.ts" @args`); `git rm scripts/git-pull-all.ts.tmpl bin/executable_git-pull-all.cmd.tmpl`.
4. `ai/config.yaml`: replace `{{ .aiDashboardUser }}` / `{{ .aiDashboardHash }}` with static `username: "admin"` and `password_hash: ""`; convert `ai/mcp-base.json.tmpl` -> `ai/mcp-base.example.json` with placeholder strings; `git rm ai/config.yaml.tmpl ai/mcp-base.json.tmpl`.
5. Update `bin/host-save.ps1`: replace section 5 (`& chezmoi re-add`) with `& ygg save`.
6. Remove Chezmoi metadata & redundant static `.cmd` shims (which `ygg` auto-generates for every `.nu`/`.ps1` linked into `bin/`):
   ```bash
   rtk git -C /data/projects/worktree/ygg-phase2/win-dotfiles rm -rf .chezmoi.toml.tmpl .chezmoidata.toml .chezmoiignore .chezmoiscripts bin/edt.cmd bin/git-ws-add.cmd bin/git-ws-remove.cmd bin/host-save.cmd bin/update-ib.cmd
   ```

- [ ] **Step 3: Create `system/windows.dsc.yaml`, `ygg.toml`, `packages.toml`, `links.toml`, `env.toml`, and `setup.nu`**

1. `system/windows.dsc.yaml` (Day-0 OS configuration via `winget configure -f system/windows.dsc.yaml`):
   ```yaml
   # yaml-language-server: $schema=https://aka.ms/configuration-dsc-schema/0.2
   properties:
     configurationVersion: 0.2.0
     resources:
       - resource: Microsoft.Windows.Developer/DeveloperMode
         directives:
           description: Enable Windows Developer Mode
           allowPrerelease: true
         settings:
           Ensure: Present
       - resource: Microsoft.Windows.Developer/WindowsExplorer
         directives:
           description: Show file extensions and hidden files in Explorer
           allowPrerelease: true
         settings:
           FileExtensions: Show
           HiddenFiles: Show
       - resource: Microsoft.Windows.Developer/Taskbar
         directives:
           description: Clean Windows 11 Taskbar layout
           allowPrerelease: true
         settings:
           Alignment: Left
           SearchBoxMode: Hide
           TaskViewButton: Hide
           WidgetsButton: Hide
   ```
2. `ygg.toml` (`[save]` MUST reside in `ygg.toml` so `load-module-manifest` populates `manifest.save` rather than treating `save` as a link key in `links.toml`):
   ```toml
   name = "win-dotfiles"
   description = "Windows 11 Desktop Overlay (GlazeWM, Zebar, Windhawk, AHK) & @work 1C/EDT Stack"
   os = ["windows"]

   [save]
   "terminal/settings.json" = "$LOCALAPPDATA/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json"
   ```
3. `packages.toml`:
   ```toml
   [packages]
   winget = [
     "glzr-io.glazewm",
     "glzr-io.zebar",
     "AutoHotkey.AutoHotkey",
     "Microsoft.WindowsTerminal",
   ]
   scoop = [
     "64gram",
     "ast-grep",
     "bitwarden",
     "delta",
     "gh",
     "herdr",
     "mise",
     "opencode",
     "tokei",
     "windhawk",
   ]

   [scope.work.packages]
   winget = [
     "Azul.Zulu.17.JDK",
   ]
   ```
4. `links.toml` (separating base desktop links, `[scope.notebook.links]`, and `[scope.work.links]` for 1C/EDT/corporate AI):
   ```toml
   [links]
   "ahk" = "~/.config/ahk"
   "glazewm/cfg/*" = "~/.config/glazewm/cfg/*"
   "glazewm/workspaces/pc.yaml" = "~/.config/glazewm/cfg/workspaces.yaml"
   "just" = "~/.config/just"
   "nushell/config.local.nu" = "$APPDATA/nushell/config.local.nu"
   "nushell/custom" = "$APPDATA/nushell/custom"
   "opencode" = "~/.config/opencode"
   "powershell/conf.d" = "~/.config/powershell/conf.d"
   "scoop/scoop-apps.json" = "~/.config/scoop/scoop-apps.json"
   "terminal" = "~/.config/terminal"
   "windhawk" = "~/.config/windhawk"
   "zebar" = "~/.config/zebar"
   "bin/host-save.ps1" = "~/.local/bin/host-save.ps1"
   "bin/wt.ps1" = "~/.local/bin/wt.ps1"

   [scope.notebook.links]
   "glazewm/workspaces/notebook.yaml" = "~/.config/glazewm/cfg/workspaces.yaml"

   [scope.work.links]
   "1c/projects.example.json" = "~/.config/1c/projects.example.json"
   "ai" = "~/.config/ai"
   "scripts" = "~/.config/scripts"
   "bin/edt.ps1" = "~/.local/bin/edt.ps1"
   "bin/git-pull-all.ps1" = "~/.local/bin/git-pull-all.ps1"
   "bin/git-ws-add.ps1" = "~/.local/bin/git-ws-add.ps1"
   "bin/git-ws-remove.ps1" = "~/.local/bin/git-ws-remove.ps1"
   "bin/update-ib.nu" = "~/.local/bin/update-ib.nu"
   ```
5. `env.toml`:
   ```toml
   [env]
   LANG = "ru_RU.UTF-8"
   LC_ALL = "ru_RU.UTF-8"
   POWERSHELL_UPDATECHECK = "Off"

   [scope.work.env]
   JAVA_HOME = "C:/Program Files/Zulu/zulu-17"
   PROJECTS_ROOT = "D:/projects/default"
   PROJECTS_WORKTREE_ROOT = "D:/projects/worktree"
   ```
6. `setup.nu`:
   ```nushell
   #!/usr/bin/env nu
   use sdk.nu [onchange]
   use state.nu [expand-target-path]

   let is_dry = (($env.YGG_DRY_RUN? | default "false") == "true")
   let is_sandbox = (($env.YGG_SANDBOX? | default "") != "")

   if (not $is_dry) and (not $is_sandbox) and ($nu.os-info.family == "windows") {
       onchange "glazewm-merge" ["glazewm/cfg/*.yaml"] {
           let merge_script = (expand-target-path "~/.config/glazewm/cfg/merge.ps1")
           if ($merge_script | path exists) {
               ^pwsh -NoProfile -ExecutionPolicy Bypass -File $merge_script | complete | ignore
           }
       } --target "~/.config/glazewm/config.yaml"

       onchange "windhawk-sync" ["windhawk/settings.ini", "windhawk/engine-settings.ini", "windhawk/mods/*.ini"] {
           let wh_persist = (expand-target-path "~/scoop/persist/windhawk/AppData")
           let repo_wh = (expand-target-path "~/.config/windhawk")
           if ($wh_persist | path exists) {
               cp -f ($repo_wh | path join "settings.ini") ($wh_persist | path join "settings.ini")
               cp -f ($repo_wh | path join "engine-settings.ini") ($wh_persist | path join "Engine" "settings.ini")
           }
       }
   }
   ```

- [ ] **Step 4: Run Stage 2 Windows + `@work` verification and commit on `feat/ygg-migration`**

Run:
```bash
rtk just --justfile /data/projects/ygg/justfile test-phase2 win
```
Expected: `[PASS] win-dotfiles @work Stage 2 checks`.

Commit inside `/data/projects/worktree/ygg-phase2/win-dotfiles`:
```bash
rtk git -C /data/projects/worktree/ygg-phase2/win-dotfiles add -A && rtk git -C /data/projects/worktree/ygg-phase2/win-dotfiles commit -m "feat(ygg): migrate win-dotfiles to ygg module with @work scope and WinGet DSC"
```

---

## Task 6: Full Stage 2 Multi-Module Gate & Host Integrity Verification

**Files:**
- Commit in `/data/projects/ygg`: `tests/test_phase2_modules.nu`, `justfile`

- [ ] **Step 1: Run complete Phase 1 + Phase 2 test suites in `/data/projects/ygg`**

Run:
```bash
rtk just --justfile /data/projects/ygg/justfile test && rtk just --justfile /data/projects/ygg/justfile test-phase2 all
```
Expected: Both Phase 1 unit/integration tests and all Phase 2 Stage 2 multi-module sandbox suites exit with code `0`.

- [ ] **Step 2: Verify clean Git worktrees on `feat/ygg-migration` and zero mutation of live host primary trees**

Run:
```bash
rtk nu -c '
for r in ["omni-dotfiles", "dotfiles", "ai-dotfiles", "win-dotfiles"] {
    let wt = $"/data/projects/worktree/ygg-phase2/($r)"
    let st = (^git -C $wt status --porcelain | str trim)
    if $st != "" {
        error make { msg: $"Dirty worktree ($wt):\n($st)" }
    }
    let br = (^git -C $"/data/projects/($r)" branch --show-current | str trim)
    if $br != "main" {
        error make { msg: $"Primary repo /data/projects/($r) switched away from main!" }
    }
}
print "[PASS] All 4 feat/ygg-migration worktrees clean; all 4 primary host repos untouched on main."
'
```
Expected: `[PASS] All 4 feat/ygg-migration worktrees clean; all 4 primary host repos untouched on main.`

- [ ] **Step 3: Commit Stage 2 test harness in `/data/projects/ygg`**

Run:
```bash
rtk git -C /data/projects/ygg add tests/test_phase2_modules.nu justfile && rtk git -C /data/projects/ygg commit -m "test(phase2): add Stage 2 multi-module sandbox E2E verification suite"
```
Expected: `rtk git -C /data/projects/ygg status` is clean (`0` uncommitted files).

---

## Review Focus (Mandatory Edge-Case Checks)

1. **Live Host Symlink Preservation:** Primary working trees `/data/projects/{omni-dotfiles,dotfiles,ai-dotfiles,win-dotfiles}` MUST remain on `main` with zero touched files so active Chezmoi and GNU Stow symlinks in `$HOME` do not break during Phase 2 (`Task 1 Step 1` + `Task 6 Step 2`).
2. **Nushell Parse-Time Profile Safety in `omni-dotfiles`:** `nushell/env.nu`, `nushell/conf.d/integrations.nu`, and `nushell/config.nu` MUST use compile-time `const ... = if ($path | path exists) { $path } else { null }; source $file` against `$nu.home-dir | path join ".ygg" ".state" "env"` and keep `config.nu` `<50` lines (`test-omni-standalone-linux` verifies real `nu` & `zsh` subprocess invocation with `$` and `'` in secrets).
3. **Zero-Trash Scope Switch (`dotfiles@pc` -> `dotfiles@asus`):** Switching `config.toml` from `dotfiles@pc` to `dotfiles@asus` in the same sandbox MUST prune `~/.config/OpenRGB`, `openrgb.service`, and `cooler.zsh`, replace `display.kdl` with the laptop profile, and never pass `openrgb` to the package installer (`test-linux-pc-and-asus-scope-switch`).
4. **`ai-dotfiles` Stow Elimination Without Data Loss:** Physical directories that previously lived only inside `infra/stow/` (`antigravity` + `superpowers` submodule, `grill-tab`, `hindsight`, `rtk-rewrite`, `skill-retrieval`, `hermes/config.yaml`, `hermes-desktop`, `ollama`, `opencommit`) MUST be `git mv`ed before `git rm -rf infra/stow`, and `setup.nu` MUST replace symlinks at `config.json` / `settings.json` via `merge-json` (`0600`), create `.no-bundled-skills`, and seed `>=2` SQLite guard sessions (`test-linux-pc-and-asus-scope-switch`).
5. **Windows Auto-Shim & DevOps Scope Isolation:** Under `YGG_HOST_OS_OVERRIDE=windows`, `omni-dotfiles` + `win-dotfiles@work` MUST auto-generate `.cmd` shims (`omni.cmd`, `edt.cmd`, `update-ib.cmd`), expand `$APPDATA` / `$DOCUMENTS` / `$LOCALAPPDATA`, and exclude `[scope.unix.aliases]` DevOps commands from `aliases.ps1` (`test-windows-work-and-save-roundtrip`).
