# src/pkg.nu
# Yggdrasil configuration manager — Package providers driver

use state.nu [detect-host-os]

# Formulate package installation command for a specific provider
def format-pkg-command [mgr: string, pkgs: list<string>]: nothing -> string {
    let pkg_args = ($pkgs | str join " ")
    match $mgr {
        "pacman" => $"sudo pacman -S --needed --noconfirm ($pkg_args)",
        "paru" => $"paru -S --needed --noconfirm ($pkg_args)",
        "mise" => $"mise use -g ($pkg_args)",
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
    --sandbox: string = ""
]: nothing -> list<string> {
    # Skip package installation when inside a sandbox or sandbox path is passed
    if ($sandbox != "") {
        return []
    }

    let pkgs_record = ($plan.packages? | default {})
    if ($pkgs_record | columns | is-empty) {
        return []
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

    mut executed = []

    for mgr in ($pkgs_record | columns) {
        if not ($mgr in $allowed_mgrs) {
            continue
        }

        let raw_pkgs = ($pkgs_record | get $mgr)
        let pkgs = if (($raw_pkgs | describe) starts-with "list") {
            $raw_pkgs | where { |p| ($p != null) and ($p != "") }
        } else if ($raw_pkgs != null) and ($raw_pkgs != "") {
            [$raw_pkgs]
        } else {
            []
        }

        if ($pkgs | is-empty) {
            continue
        }

        let cmd_str = (format-pkg-command $mgr $pkgs)
        $executed = ($executed | append $cmd_str)

        if $dry_run {
            continue
        }

        let mock_log = ($env.YGG_MOCK_PKG_LOG? | default "")
        if ($mock_log != "") {
            # Mock mode: append command to the specified log file
            $"($cmd_str)\n" | save -a $mock_log
        } else {
            # Real execution via Nushell
            let res = (^nu -c $cmd_str | complete)
            if $res.exit_code != 0 {
                print -e $"Package manager '($mgr)' error: ($res.stderr)"
            }
        }
    }

    $executed
}
