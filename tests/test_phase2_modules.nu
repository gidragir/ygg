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

# Tools launched by shell profiles (atuin, sheldon) may still be writing: retry removal once
def cleanup-sandbox [root: string] {
    try {
        rm -rf $root
    } catch {
        sleep 2sec
        try {
            rm -rf $root
        } catch { }
    }
    if ($root | path exists) {
        print -e $"Warning: sandbox root could not be removed: ($root)"
    }
}

def resolve-module-path [name: string]: nothing -> string {
    let wt = ($WT_ROOT | path join $name)
    if ($wt | path exists) {
        $wt
    } else {
        $"/data/projects/($name)"
    }
}

def link-wt-modules [ygg_home: string, names: list<string>] {
    for n in $names {
        let src = (resolve-module-path $n)
        let dst = ($ygg_home | path join "modules" $n)
        ^ln -sfn $src $dst
    }
}

def assert-no-broken-links [dir: string] {
    let broken = (^fd -H -I --type l . $dir | lines | where { |p| ($p != "") and not ($p | path exists) })
    if not ($broken | is-empty) {
        error make { msg: ("Broken symlinks detected in sandbox: " + ($broken | str join ", ")) }
    }
}

export def test-zero-legacy-artifacts [repo: string] {
    let wt = (resolve-module-path $repo)
    assert (($wt | path join "ygg.toml") | path exists) $"Missing ygg.toml in ($repo)"
    assert (not (($wt | path join "infra" "stow") | path exists)) $"Legacy infra/stow found in ($repo)"
    let tmpls = (^fd -H --glob "*.tmpl" $wt --exclude .git | lines | where { |x| $x != "" })
    assert ($tmpls | is-empty) $"Legacy .tmpl files remain in ($repo): ($tmpls | str join ', ')"
    let cz = (^fd -H "chezmoi" $wt --exclude .git --exclude AGENTS.md --exclude README.md --exclude docs --exclude .agents | lines | where { |x| $x != "" })
    assert ($cz | is-empty) $"Legacy chezmoi files remain in ($repo): ($cz | str join ', ')"
    let tracked = (^git -C $wt ls-files | lines | where { |x| $x != "" })
    let bad_legacy = ($tracked | where { |p|
        let parts = ($p | path split)
        $parts | any { |part| ($part starts-with "dot_") or ($part starts-with "executable_") }
    })
    assert ($bad_legacy | is-empty) $"Legacy dot_* or executable_* files tracked in git in ($repo): ($bad_legacy | str join ', ')"
}

export def test-omni-standalone-linux [] {
    let sb = (make-sandbox "omni-linux")
    try {
        link-wt-modules $sb.ygg_home ["omni-dotfiles"]
        '[[modules]]
name = "omni-dotfiles"
' | save -f ($sb.ygg_home | path join "host.toml")
        r#'[env]
OPENAI_API_KEY = "sk-test$secret'val"
'# | save -f ($sb.ygg_home | path join "secrets.toml")

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
        let nu_chk = (with-env { HOME: $sb.home, YGG_HOME: ($sb.home | path join ".ygg"), XDG_CONFIG_HOME: ($sb.home | path join ".config"), XDG_DATA_HOME: ($sb.home | path join ".local" "share"), XDG_CACHE_HOME: ($sb.home | path join ".cache"), XDG_STATE_HOME: ($sb.home | path join ".local" "state") } {
            ^nu --env-config ($sb.home | path join ".config" "nushell" "env.nu") --config ($sb.home | path join ".config" "nushell" "config.nu") -c "$env.EDITOR + '|' + $env.OPENAI_API_KEY"
        } | complete)
        assert ($nu_chk.exit_code == 0) $"Nushell profile failed to parse/load: ($nu_chk.stderr)"
        assert (($nu_chk.stdout | str trim) == "nvim|sk-test$secret'val") $"Unexpected nu env output: ($nu_chk.stdout)"

        # Second launch of nu with same profile files, but HOME and YGG_HOME without .ygg -> exit 0
        let no_ygg_home = ($sb.root | path join "home_no_ygg")
        mkdir $no_ygg_home
        let nu_chk_no_ygg = (with-env {
            HOME: $no_ygg_home,
            YGG_HOME: ($no_ygg_home | path join ".ygg"),
            XDG_CONFIG_HOME: ($sb.home | path join ".config"),
            XDG_DATA_HOME: ($no_ygg_home | path join ".local" "share"),
            XDG_CACHE_HOME: ($no_ygg_home | path join ".cache"),
            XDG_STATE_HOME: ($no_ygg_home | path join ".local" "state")
        } {
            ^nu --env-config ($sb.home | path join ".config" "nushell" "env.nu") --config ($sb.home | path join ".config" "nushell" "config.nu") -c "$env.EDITOR"
        } | complete)
        assert ($nu_chk_no_ygg.exit_code == 0) $"Nushell profile without .ygg failed: ($nu_chk_no_ygg.stderr)"
        assert (($nu_chk_no_ygg.stdout | str trim) == "nvim")

        # config.nu < 50 lines; env.nu, conf.d/integrations.nu, config.nu contain 'else { null }'
        let cfg_content = (open --raw ($sb.home | path join ".config" "nushell" "config.nu"))
        let cfg_lines = ($cfg_content | lines | length)
        assert ($cfg_lines < 50) $"config.nu must be < 50 lines, got ($cfg_lines)"

        let env_content = (open --raw ($sb.home | path join ".config" "nushell" "env.nu"))
        let int_content = (open --raw ($sb.home | path join ".config" "nushell" "conf.d" "integrations.nu"))
        assert ($env_content | str contains "else { null }") "env.nu must contain 'else { null }'"
        assert ($int_content | str contains "else { null }") "conf.d/integrations.nu must contain 'else { null }'"
        assert ($cfg_content | str contains "else { null }") "config.nu must contain 'else { null }'"

        # Verify Zsh loads .zshenv + .zshrc + aliases without error
        let zsh_chk = (with-env {
            HOME: $sb.home,
            YGG_HOME: ($sb.home | path join ".ygg"),
            XDG_CONFIG_HOME: ($sb.home | path join ".config"),
            XDG_DATA_HOME: ($sb.home | path join ".local" "share"),
            XDG_CACHE_HOME: ($sb.home | path join ".cache"),
            XDG_STATE_HOME: ($sb.home | path join ".local" "state"),
            MISE_OFFLINE: "true",
            MISE_DISABLE_UPDATE_CHECKS: "true"
        } {
            ^zsh -c 'source "$HOME/.zshenv" && source "$HOME/.zshrc" && printf "%s|%s" "$EDITOR" "$OPENAI_API_KEY"'
        } | complete)
        assert ($zsh_chk.exit_code == 0) $"Zsh profile failed: ($zsh_chk.stderr)"
        assert (($zsh_chk.stdout | str trim) == "nvim|sk-test$secret'val") $"Unexpected zsh env output: ($zsh_chk.stdout)"
    } catch { |e|
        cleanup-sandbox $sb.root
        error make { msg: $e.msg }
    }
    cleanup-sandbox $sb.root
}

export def test-linux-pc-and-asus-scope-switch [] {
    let sb = (make-sandbox "linux-scopes")
    try {
        link-wt-modules $sb.ygg_home ["omni-dotfiles", "dotfiles", "ai-dotfiles"]
        '[[modules]]
name = "omni-dotfiles"
[[modules]]
name = "dotfiles"
scopes = ["pc"]
[[modules]]
name = "ai-dotfiles"
' | save -f ($sb.ygg_home | path join "host.toml")
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

        # Repeat apply on @pc
        "" | save -f $sb.pkg_log
        let res_pc2 = (with-env {
            HOME: $sb.home,
            YGG_HOME: $sb.ygg_home,
            YGG_SANDBOX: $sb.home,
            YGG_HOST_OS_OVERRIDE: "cachyos",
            YGG_MOCK_PKG_LOG: $sb.pkg_log
        } { ^nu $YGG_BIN apply --sandbox $sb.home } | complete)
        assert ($res_pc2.exit_code == 0) $"PC stack repeat apply failed: ($res_pc2.stderr)"
        assert-no-broken-links $sb.home

        # Assert PC-only artifacts present, ASUS-only absent
        assert (($sb.home | path join ".config" "OpenRGB" "off.orp") | path exists)
        assert (($sb.home | path join ".config" "systemd" "user" "openrgb.service") | path exists)
        assert (($sb.home | path join ".zsh" "alias" "cooler.zsh") | path exists) "cooler.zsh must exist on @pc"
        let disp_pc = (open --raw ($sb.home | path join ".config" "niri" "cfg" "display.kdl"))
        assert ($disp_pc | str contains "DP-2") "PC display.kdl must configure desktop DP-2 monitor"
        let pkgs_pc = (open --raw $sb.pkg_log)
        assert ($pkgs_pc | str contains "openrgb") "PC packages must include openrgb"
        assert (not ($pkgs_pc | str contains "asusctl")) "PC packages must NOT include asusctl"

        # Assert ai-dotfiles setup.nu invariants
        let agy_cfg = (open ($sb.home | path join ".gemini" "config" "config.json"))
        assert (($agy_cfg | get -o runtimeWindow.zoom) == 1.25) "merge-json must preserve host runtimeWindow"
        assert ("plugins" in ($agy_cfg | columns)) "config.json must have plugins key"
        assert equal (ls -l ($sb.home | path join ".gemini" "config" "config.json") | get 0.mode) "rw-------"

        assert equal (($sb.home | path join ".claude" "settings.json" | path type)) "file"
        assert equal (ls -l ($sb.home | path join ".claude" "settings.json") | get 0.mode) "rw-------"

        assert (($sb.home | path join ".hermes" ".env") | path exists) "export-secrets must generate ~/.hermes/.env"
        assert equal (ls -l ($sb.home | path join ".hermes" ".env") | get 0.mode) "rw-------"
        let hermes_env = (open --raw ($sb.home | path join ".hermes" ".env"))
        assert ($hermes_env | str contains "GEMINI_API_KEY") "Hermes .env must contain GEMINI_API_KEY"

        assert (($sb.home | path join ".hermes" "skills" ".no-bundled-skills") | path exists) "Hermes .no-bundled-skills marker missing"
        assert (($sb.home | path join ".gemini" "config" "plugins" "superpowers") | path exists) "superpowers plugin missing"
        assert (($sb.home | path join ".hermes" "config.yaml") | path exists) "Hermes config.yaml missing"
        for p in ["grill-tab", "hindsight", "rtk-rewrite", "skill-retrieval"] {
            assert (($sb.home | path join ".hermes" "plugins" $p) | path exists) $"Hermes plugin ($p) missing"
        }
        assert (($sb.home | path join ".config" "Hermes") | path exists) "Hermes desktop config missing"
        assert (($sb.home | path join ".config" "ollama") | path exists) "ollama config missing"
        assert (($sb.home | path join ".opencommit") | path exists) "opencommit config missing"

        for prof in ["idea-receiver", "idea-refiner", "gemini", "thinker", "sysops", "formatter", "coder"] {
            let db = ($sb.home | path join ".hermes" "profiles" $prof "state.db")
            assert ($db | path exists) $"Hermes profile ($prof) state.db missing"
            let guard_cnt = (^sqlite3 $db "SELECT COUNT(*) FROM sessions;" | str trim | into int)
            assert ($guard_cnt >= 2) $"Hermes ($prof) state.db must have >=2 guard sessions, got ($guard_cnt)"
        }

        # Switch profile in-place from dotfiles@pc -> dotfiles@asus (Review Focus: Zero-Trash pruning)
        "" | save -f $sb.pkg_log
        '[[modules]]
name = "omni-dotfiles"
[[modules]]
name = "dotfiles"
scopes = ["asus"]
' | save -f ($sb.ygg_home | path join "host.toml")

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
        assert ($disp_asus | str contains "eDP-1") "ASUS display.kdl must contain eDP-1 monitor"
        let pkgs_asus = (open --raw $sb.pkg_log)
        assert ($pkgs_asus | str contains "asusctl") "ASUS packages must include asusctl"
        assert (not ($pkgs_asus | str contains "openrgb")) "ASUS packages must NOT include openrgb"
    } catch { |e|
        cleanup-sandbox $sb.root
        error make { msg: $e.msg }
    }
    cleanup-sandbox $sb.root
}

export def test-linux-asus-clean [] {
    let sb_asus = (make-sandbox "linux-asus-clean")
    let sb_pc = (make-sandbox "linux-pc-clean")
    try {
        link-wt-modules $sb_asus.ygg_home ["omni-dotfiles", "dotfiles", "ai-dotfiles"]
        '[[modules]]
name = "omni-dotfiles"
[[modules]]
name = "dotfiles"
scopes = ["asus"]
[[modules]]
name = "ai-dotfiles"
' | save -f ($sb_asus.ygg_home | path join "host.toml")
        '[env]
GEMINI_API_KEY = "gem-test-key"
' | save -f ($sb_asus.ygg_home | path join "secrets.toml")

        link-wt-modules $sb_pc.ygg_home ["omni-dotfiles", "dotfiles", "ai-dotfiles"]
        '[[modules]]
name = "omni-dotfiles"
[[modules]]
name = "dotfiles"
scopes = ["pc"]
[[modules]]
name = "ai-dotfiles"
' | save -f ($sb_pc.ygg_home | path join "host.toml")
        '[env]
GEMINI_API_KEY = "gem-test-key"
' | save -f ($sb_pc.ygg_home | path join "secrets.toml")

        let res_asus = (with-env {
            HOME: $sb_asus.home,
            YGG_HOME: $sb_asus.ygg_home,
            YGG_SANDBOX: $sb_asus.home,
            YGG_HOST_OS_OVERRIDE: "cachyos",
            YGG_MOCK_PKG_LOG: $sb_asus.pkg_log
        } { ^nu $YGG_BIN apply --sandbox $sb_asus.home } | complete)
        assert ($res_asus.exit_code == 0) $"ASUS clean apply failed: ($res_asus.stderr)"
        assert-no-broken-links $sb_asus.home

        let res_pc = (with-env {
            HOME: $sb_pc.home,
            YGG_HOME: $sb_pc.ygg_home,
            YGG_SANDBOX: $sb_pc.home,
            YGG_HOST_OS_OVERRIDE: "cachyos",
            YGG_MOCK_PKG_LOG: $sb_pc.pkg_log
        } { ^nu $YGG_BIN apply --sandbox $sb_pc.home } | complete)
        assert ($res_pc.exit_code == 0) $"PC clean apply failed: ($res_pc.stderr)"
        assert-no-broken-links $sb_pc.home

        # Assert ASUS clean properties
        assert (not (($sb_asus.home | path join ".config" "OpenRGB") | path exists)) "OpenRGB must not exist on clean @asus"
        assert (not (($sb_asus.home | path join ".config" "OpenRGB" "off.orp") | path exists)) "OpenRGB config must not exist on clean @asus"
        assert (not (($sb_asus.home | path join ".config" "systemd" "user" "openrgb.service") | path exists)) "openrgb.service must not exist on clean @asus"
        assert (not (($sb_asus.home | path join ".zsh" "alias" "cooler.zsh") | path exists)) "cooler.zsh must not exist on clean @asus"
        let disp_asus = (open --raw ($sb_asus.home | path join ".config" "niri" "cfg" "display.kdl"))
        assert ($disp_asus | str contains "eDP-1") "clean ASUS display.kdl must contain eDP-1"
        assert (not ($disp_asus | str contains "DP-2")) "clean ASUS display.kdl must not contain DP-2"

        # Scope-only targets check in state.links
        let st_pc = (open ($sb_pc.ygg_home | path join ".state" "state.json"))
        let st_asus = (open ($sb_asus.ygg_home | path join ".state" "state.json"))
        let links_pc = ($st_pc.links | columns)
        let links_asus = ($st_asus.links | columns)

        let pc_only_paths = [
            ($sb_pc.home | path join ".config" "OpenRGB"),
            ($sb_pc.home | path join ".zsh" "alias" "cooler.zsh"),
            ($sb_pc.home | path join ".zsh" "scripts" "cooler-toggle.sh"),
            ($sb_pc.home | path join ".config" "systemd" "user" "openrgb.service")
        ]
        let asus_counterparts = [
            ($sb_asus.home | path join ".config" "OpenRGB"),
            ($sb_asus.home | path join ".zsh" "alias" "cooler.zsh"),
            ($sb_asus.home | path join ".zsh" "scripts" "cooler-toggle.sh"),
            ($sb_asus.home | path join ".config" "systemd" "user" "openrgb.service")
        ]

        for p in $pc_only_paths {
            assert ($p in $links_pc) $"PC target ($p) missing from @pc state.links"
        }
        for p in $asus_counterparts {
            assert (not ($p in $links_asus)) $"PC target ($p) leaked into @asus state.links"
        }

        let disp_dest_asus = ($sb_asus.home | path join ".config" "niri" "cfg" "display.kdl")
        let disp_dest_pc = ($sb_pc.home | path join ".config" "niri" "cfg" "display.kdl")
        assert (($st_asus.links | get $disp_dest_asus | get src) ends-with "asus.kdl") "ASUS display.kdl src must be asus.kdl"
        assert (($st_pc.links | get $disp_dest_pc | get src) ends-with "pc.kdl") "PC display.kdl src must be pc.kdl"

        let pkgs_asus = (open --raw $sb_asus.pkg_log)
        assert ($pkgs_asus | str contains "asusctl") "ASUS packages must include asusctl"
        assert (not ($pkgs_asus | str contains "openrgb")) "ASUS packages must NOT include openrgb"

        let pkgs_pc = (open --raw $sb_pc.pkg_log)
        assert ($pkgs_pc | str contains "openrgb") "PC packages must include openrgb"
        assert (not ($pkgs_pc | str contains "asusctl")) "PC packages must NOT include asusctl"
    } catch { |e|
        cleanup-sandbox $sb_asus.root
        cleanup-sandbox $sb_pc.root
        error make { msg: $e.msg }
    }
    cleanup-sandbox $sb_asus.root
    cleanup-sandbox $sb_pc.root
}

export def test-windows-work-repeat-apply [] {
    let sb = (make-sandbox "win-work")
    try {
        link-wt-modules $sb.ygg_home ["omni-dotfiles", "win-dotfiles"]
        # Seed simulated Windows Terminal target file so [save] 3-way copy-sync & ygg save engage
        let wt_dir = ($sb.home | path join "AppData" "Local" "Packages" "Microsoft.WindowsTerminal_8wekyb3d8bbwe" "LocalState")
        mkdir $wt_dir
        let wt_settings = ($wt_dir | path join "settings.json")
        (open --raw ($WT_ROOT | path join "win-dotfiles" "terminal" "settings.json")) | save -f $wt_settings

        '[[modules]]
name = "omni-dotfiles"
[[modules]]
name = "win-dotfiles"
scopes = ["work"]
' | save -f ($sb.ygg_home | path join "host.toml")

        let res = (with-env {
            HOME: $sb.home,
            YGG_HOME: $sb.ygg_home,
            YGG_SANDBOX: $sb.home,
            YGG_HOST_OS_OVERRIDE: "windows",
            YGG_MOCK_PKG_LOG: $sb.pkg_log
        } { ^nu $YGG_BIN apply --sandbox $sb.home } | complete)
        assert ($res.exit_code == 0) $"Windows @work apply failed: ($res.stderr)"
        assert-no-broken-links $sb.home

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
        assert (not ($ps_aliases | str contains "function k {")) "Unix DevOps aliases leaked"
        assert (not ($ps_aliases | str contains "function tf {"))
        assert ($ps_aliases | str contains "function gst") "Core git aliases missing in Windows aliases.ps1"

        # Repeat apply with the same environment
        "" | save -f $sb.pkg_log
        let res2 = (with-env {
            HOME: $sb.home,
            YGG_HOME: $sb.ygg_home,
            YGG_SANDBOX: $sb.home,
            YGG_HOST_OS_OVERRIDE: "windows",
            YGG_MOCK_PKG_LOG: $sb.pkg_log
        } { ^nu $YGG_BIN apply --sandbox $sb.home } | complete)
        assert ($res2.exit_code == 0) $"second apply failed: ($res2.stderr)"
        assert equal (($sb.home | path join ".config" "git" "config") | path type) "file"
        assert equal (($sb.home | path join ".config" "glazewm" "cfg" "general.yaml") | path type) "file"
        assert-no-broken-links $sb.home
    } catch { |e|
        cleanup-sandbox $sb.root
        error make { msg: $e.msg }
    }
    cleanup-sandbox $sb.root
}

def main [target: string = "all"] {
    let valid_targets = ["all", "omni", "dotfiles", "ai", "linux-e2e", "linux-asus-clean", "win"]
    if not ($target in $valid_targets) {
        error make { msg: $"Unknown test target: ($target). Valid targets: ($valid_targets | str join ', ')" }
    }

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
        test-linux-asus-clean
        print "[PASS] Linux @pc + @asus + ai-dotfiles E2E checks"
    }
    if $target == "linux-asus-clean" {
        test-linux-asus-clean
        print "[PASS] Linux @asus clean E2E checks"
    }
    if $target in ["all", "win"] {
        test-zero-legacy-artifacts "win-dotfiles"
        test-windows-work-repeat-apply
        print "[PASS] win-dotfiles @work Stage 2 checks"
    }
    if $target == "all" {
        for repo in ["omni-dotfiles", "dotfiles", "ai-dotfiles", "win-dotfiles"] {
            let wt = (resolve-module-path $repo)
            let st = (^git -C $wt status --porcelain | str trim)
            if ($st != "") {
                error make { msg: $"Worktree ($repo) is dirty after tests:\n($st)" }
            }
        }
    }
}
