# src/pkg.nu
# Yggdrasil configuration manager — Package providers driver

use state.nu [detect-host-os]

# Formulate package installation command for a specific provider
def format-pkg-command [mgr: string, pkgs: list<string>]: nothing -> string {
    let pkg_args = ($pkgs | str join " ")
    match $mgr {
        "pacman" => $"sudo pacman -S --needed --noconfirm ($pkg_args)",
        "paru" => $"paru -S --needed --noconfirm ($pkg_args)",
        "mise" => $"try { mise trust -y ~/.config/mise/config.toml } catch { }; mise use --path ~/.config/mise/config.local.toml ($pkg_args)",
        "cargo" => $"cargo install ($pkg_args)",
        "winget" => $"winget install --exact --accept-source-agreements --accept-package-agreements ($pkg_args)",
        "scoop" => $"scoop install ($pkg_args)",
        "pnpm" => $"pnpm add -g ($pkg_args)",
        "uv" => $"uv tool install ($pkg_args)",
        _ => $"($mgr) install ($pkg_args)"
    }
}

# Install packages according to the resolved effective plan
export def install-packages [
    plan: record,
    --dry-run,
    --skip-packages (-S),
    --sandbox: string = ""
]: nothing -> record<executed: list<string>, failed: list<record<mgr: string, stderr: string>>> {
    if $skip_packages {
        return { executed: [], failed: [] }
    }
    # Skip package installation when inside a sandbox or sandbox path is passed
    # In sandbox without mock logging, protect host package managers from execution
    let env_sb = ($env.YGG_SANDBOX? | default "")
    let mock_log = ($env.YGG_MOCK_PKG_LOG? | default "")
    if ($mock_log == "") and (($sandbox != "") or ($env_sb != "")) {
        return { executed: [], failed: [] }
    }

    let pkgs_record = ($plan.packages? | default {})
    if ($pkgs_record | columns | is-empty) {
        return { executed: [], failed: [] }
    }

    let host_os = (detect-host-os)
    let allowed_mgrs = if ($host_os.os == "windows") {
        ["winget", "scoop", "mise", "cargo", "pnpm", "uv"]
    } else if ($host_os.os == "linux") {
        if ($host_os.distro in ["cachyos", "arch"]) or ("arch" in $host_os.auto_scopes) {
            ["pacman", "paru", "mise", "cargo", "pnpm", "uv"]
        } else {
            ["mise", "cargo", "pnpm", "uv", "pacman", "paru"]
        }
    } else if ($host_os.os == "macos") {
        ["mise", "cargo", "pnpm", "uv"]
    } else {
        ["mise", "cargo", "pnpm", "uv"]
    }

    mut executed: list<string> = []
    mut failed: list<record<mgr: string, stderr: string>> = []

    for mgr in ($pkgs_record | columns) {
        if not ($mgr in $allowed_mgrs) {
            continue
        }

        let raw_pkgs = ($pkgs_record | get $mgr)
        let pkgs = if (($raw_pkgs | describe) starts-with "list") {
            $raw_pkgs | where { |it| ($it != null) and ($it != "") }
        } else if ($raw_pkgs != null) and ($raw_pkgs != "") {
            [$raw_pkgs]
        } else {
            []
        }

        if ($pkgs | is-empty) {
            continue
        }

        let cmd_str = (format-pkg-command $mgr $pkgs)

        if $dry_run {
            $executed = ($executed | append $cmd_str)
            continue
        }

        if ($mock_log != "") {
            let mock_fails = ($env.YGG_MOCK_PKG_FAIL? | default "" | split row "," | each { |s| $s | str trim } | where { |it| $it != "" })
            if ($mgr in $mock_fails) {
                let err_msg = $"Package manager '($mgr)' error: simulated failure"
                print -e $err_msg
                $failed = ($failed | append { mgr: $mgr, stderr: $err_msg })
            } else {
                # Mock mode: append command to the specified log file
                $"($cmd_str)\n" | save -a $mock_log
                $executed = ($executed | append $cmd_str)
            }
        } else {
            # Real execution via Nushell
            let res = (^nu -c $cmd_str | complete)
            if $res.exit_code != 0 {
                print -e $"Package manager '($mgr)' error: ($res.stderr)"
                $failed = ($failed | append { mgr: $mgr, stderr: $res.stderr })
            } else {
                $executed = ($executed | append $cmd_str)
            }
        }
    }

    { executed: $executed, failed: $failed }
}
