# tests/test_pkg_git.nu
# Tests for package manager providers (src/pkg.nu) and git manager (src/git.nu)

use std/assert
use ../src/state.nu *
use ../src/manifest.nu *
use ../src/link.nu *
use ../src/pkg.nu *
use ../src/git.nu *
use helpers.nu [with-temp-ygg]

export def test_mock_pkg_filters_by_host_os [] {
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        let m1 = ($home | path join "modules" "m")
        mkdir $m1
        'name = "m"
os = ["linux", "windows", "macos"]
[packages]
pacman = ["wireplumber"]
winget = ["Git.Git"]
mise = ["ripgrep"]' | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: $log } {
            install-packages (resolve-effective-plan $home)
            let lines = (open --raw $log)
            assert ($lines | str contains "pacman")
            assert ($lines | str contains "mise")
            assert (not ($lines | str contains "winget"))
        }
    }
}

export def test_sandbox_without_mock_skips_installation [] {
    with-temp-ygg { |home|
        let m1 = ($home | path join "modules" "m")
        mkdir $m1
        'name = "m"
os = ["linux", "windows", "macos"]
[packages]
pacman = ["curl"]' | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")

        let sb = ($home | path join "sb")
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", YGG_SANDBOX: $sb } {
            let res = (install-packages (resolve-effective-plan $home) --sandbox $sb)
            assert (($res | describe) starts-with "record")
            assert equal $res.executed []
            assert equal $res.failed []
        }
    }
}

export def test_mock_pkg_runs_under_sandbox [] {
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        let m1 = ($home | path join "modules" "m")
        mkdir $m1
        'name = "m"
os = ["linux", "windows", "macos"]
[packages]
pacman = ["curl"]' | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")

        let sb = ($home | path join "sb")
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: $log, YGG_SANDBOX: $sb } {
            let res = (install-packages (resolve-effective-plan $home) --sandbox $sb)
            assert ($log | path exists)
            let lines = (open --raw $log)
            assert ($lines | str contains "pacman")
            assert (($res.executed | length) > 0)
            assert equal $res.failed []
        }
    }
}

export def test_mock_pkg_dry_run_returns_cmds_without_logging [] {
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        let m1 = ($home | path join "modules" "m")
        mkdir $m1
        'name = "m"
os = ["linux", "windows", "macos"]
[packages]
pacman = ["curl"]' | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: $log } {
            let res = (install-packages (resolve-effective-plan $home) --dry-run)
            assert (($res.executed | length) > 0)
            assert ($res.executed | first | str contains "pacman")
            assert equal $res.failed []
            assert (not ($log | path exists))
        }
    }
}

export def test_pkg_failure_is_reported [] {
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        let m1 = ($home | path join "modules" "m")
        mkdir $m1
        'name = "m"
os = ["linux", "windows", "macos"]
[packages]
pacman = ["curl"]
cargo = ["ripgrep"]' | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")

        with-env {
            YGG_HOST_OS_OVERRIDE: "cachyos",
            YGG_MOCK_PKG_LOG: $log,
            YGG_MOCK_PKG_FAIL: "pacman"
        } {
            let res = (install-packages (resolve-effective-plan $home))
            assert equal ($res.failed | length) 1
            assert equal $res.failed.0.mgr "pacman"
            assert ($log | path exists)
            let lines = (open --raw $log)
            assert ($lines | str contains "cargo")
            assert (not ($lines | str contains "pacman"))
        }
    }
}

export def test_mise_writes_local_config [] {
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        let m1 = ($home | path join "modules" "m")
        mkdir $m1
        'name = "m"
os = ["linux", "windows", "macos"]
[packages]
mise = ["ripgrep"]' | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: $log } {
            install-packages (resolve-effective-plan $home)
            let lines = (open --raw $log)
            assert ($lines | str contains "mise use --path ~/.config/mise/config.local.toml ripgrep")
            assert (not ($lines | str contains "mise use -g"))
        }
    }
}

export def test_add_module_local_path_symlinks [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let ext_dir = ($home | path join "external_mod")
        mkdir $ext_dir
        'name = "local_mod"
os = ["linux", "cachyos"]' | save -f ($ext_dir | path join "ygg.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let mod_rec = (add-module $home $ext_dir --scopes ["work", "pc"])
            assert equal $mod_rec.name "local_mod"
            assert equal $mod_rec.scopes ["work", "pc"]

            let mod_link = ($home | path join "modules" "local_mod")
            assert (is-link-or-junction $mod_link)

            let host_cfg = (load-host-config $home)
            let mod_in_cfg = ($host_cfg.modules | where name == "local_mod" | first)
            assert equal $mod_in_cfg.name "local_mod"
            assert equal $mod_in_cfg.scopes ["work", "pc"]
        }
    }
}

export def test_add_module_rejects_incompatible_os_and_rolls_back [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let ext_dir = ($home | path join "win_only_mod")
        mkdir $ext_dir
        'name = "win_only"
os = ["windows"]' | save -f ($ext_dir | path join "ygg.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let res = (try { add-module $home $ext_dir; "ok" } catch { |e| $e.msg })
            assert ($res | str contains "does not support host OS")

            let mod_link = ($home | path join "modules" "win_only")
            assert (not ($mod_link | path exists))
            let host_cfg = (load-host-config $home)
            assert ($host_cfg.modules | where name == "win_only" | is-empty)
        }
    }
}

export def test_remove_module_safe_unlink_and_dirty_guard [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let bare = ($home | path join "mod.git")
        let work = ($home | path join "work_mod")
        ^git init --bare -b main $bare
        ^git clone $bare $work
        ^git -C $work config user.email "t@t.local"
        ^git -C $work config user.name "Tester"
        $"name = \"removable\"\nos = [\"linux\", \"cachyos\"]\n" | save -f ($work | path join "ygg.toml")
        "test content\n" | save -f ($work | path join "file.txt")
        ^git -C $work add .
        ^git -C $work commit -m "init"
        ^git -C $work push -u origin main

        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            add-module $home $bare
            let mod_dir = ($home | path join "modules" "removable")
            assert ($mod_dir | path exists)

            # Dirty guard: make an uncommitted change
            "dirty change\n" | save -f ($mod_dir | path join "file.txt")
            let err_res = (try { remove-module $home "removable"; "ok" } catch { |e| $e.msg })
            assert ($err_res | str contains "uncommitted changes")
            assert ($mod_dir | path exists)

            # Revert change to clean state
            ^git -C $mod_dir checkout file.txt
            remove-module $home "removable"
            assert (not ($mod_dir | path exists))

            let host_cfg = (load-host-config $home)
            assert ($host_cfg.modules | where name == "removable" | is-empty)
        }
    }
}

export def test_update_aborts_cleanly_on_conflict [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let upstream = ($home | path join "upstream.git")
        let work_up = ($home | path join "work_up")
        ^git init --bare -b main $upstream
        ^git clone $upstream $work_up
        ^git -C $work_up config user.email "t@t.local"
        ^git -C $work_up config user.name "Tester"
        $"name = \"demo\"\nos = [\"linux\", \"windows\", \"macos\", \"cachyos\"]\n" | save -f ($work_up | path join "ygg.toml")
        "line = 1\n" | save -f ($work_up | path join "app.conf")
        ^git -C $work_up add .
        ^git -C $work_up commit -m "init"
        ^git -C $work_up push -u origin main

        add-module $home $upstream
        let cloned = ($home | path join "modules" "demo")

        # Upstream changes line, local user also changes same line without committing
        "line = upstream\n" | save -f ($work_up | path join "app.conf")
        ^git -C $work_up commit -am "upstream change"
        ^git -C $work_up push

        "line = local_custom\n" | save -f ($cloned | path join "app.conf")
        let res = (update-modules $home)
        assert equal ($res | first | get status) "conflict"
        # Working file must remain clean without <<<<<<< markers and no active rebase-merge dir
        let content = (open --raw ($cloned | path join "app.conf") | str replace --all "\r\n" "\n")
        assert (not ($content | str contains "<<<<<<<"))
        assert equal $content "line = local_custom\n"
        assert (not ($cloned | path join ".git/rebase-merge" | path exists))
    }
}

export def test_modules_status [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let ext_dir = ($home | path join "my_mod")
        mkdir $ext_dir
        'name = "my_mod"
os = ["linux", "cachyos"]' | save -f ($ext_dir | path join "ygg.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            add-module $home $ext_dir --scopes ["pc"]
            let st = (modules-status $home)
            assert equal ($st | length) 1
            let row = ($st | first)
            assert equal $row.name "my_mod"
            assert equal $row.scopes ["pc"]
            assert ($row.path | path exists)
            assert equal $row.dirty false
            assert equal $row.links_ok true
        }
    }
}

export def test_mock_pkg_filters_windows_providers [] {
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        let m1 = ($home | path join "modules" "winmod")
        mkdir $m1
        'name = "winmod"
os = ["windows"]
[packages]
pacman = ["wireplumber"]
winget = ["Microsoft.PowerToys"]
scoop = ["neovim"]
paru = ["some-aur"]
cargo = ["ripgrep"]' | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"winmod\"\n" | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "windows", YGG_MOCK_PKG_LOG: $log } {
            install-packages (resolve-effective-plan $home)
            let lines = (open --raw $log)
            assert ($lines | str contains "winget")
            assert ($lines | str contains "scoop")
            assert ($lines | str contains "cargo")
            assert (not ($lines | str contains "pacman"))
            assert (not ($lines | str contains "paru"))
        }
    }
}

export def test_update_modules_clean_success [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let upstream = ($home | path join "upstream.git")
        let work_up = ($home | path join "work_up")
        ^git init --bare -b main $upstream
        ^git clone $upstream $work_up
        ^git -C $work_up config user.email "t@t.local"
        ^git -C $work_up config user.name "Tester"
        $"name = \"demo\"\nos = [\"linux\", \"windows\", \"macos\", \"cachyos\"]\n" | save -f ($work_up | path join "ygg.toml")
        "v1\n" | save -f ($work_up | path join "app.conf")
        ^git -C $work_up add .
        ^git -C $work_up commit -m "init"
        ^git -C $work_up push -u origin main

        add-module $home $upstream
        let cloned = ($home | path join "modules" "demo")

        # Upstream pushes an update
        "v2\n" | save -f ($work_up | path join "app.conf")
        ^git -C $work_up commit -am "update to v2"
        ^git -C $work_up push

        let res = (update-modules $home)
        assert equal ($res | first | get status) "ok"
        assert equal ($res | first | get updated) true

        let content = (open --raw ($cloned | path join "app.conf") | str replace --all "\r\n" "\n")
        assert equal $content "v2\n"
    }
}

export def test_modules_status_detects_broken_link [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let ext_dir = ($home | path join "broken_mod")
        mkdir $ext_dir
        'name = "broken_mod"
os = ["linux", "cachyos"]' | save -f ($ext_dir | path join "ygg.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            add-module $home $ext_dir
            # Record a link that doesn't exist
            let broken_dest = ($home | path join "non_existent_dest")
            mut state = (load-state $home)
            $state.links = ($state.links | upsert $broken_dest {
                src: ($ext_dir | path join "ygg.toml"),
                dest: $broken_dest,
                module: "broken_mod",
                hash: "dummy",
                type: "symlink"
            })
            save-state $home $state

            let st = (modules-status $home)
            let row = ($st | where name == "broken_mod" | first)
            assert equal $row.links_ok false
        }
    }
}


export def test_missing_package_manager_warns_and_skips_without_failing [] {
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        let m1 = ($home | path join "modules" "m")
        mkdir $m1
        'name = "m"
os = ["windows"]
[packages]
winget = ["Git.Git"]
scoop = ["neovim"]' | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")

        with-env {
            YGG_HOST_OS_OVERRIDE: "windows",
            YGG_MOCK_PKG_LOG: $log,
            YGG_MOCK_PKG_MISSING: "scoop"
        } {
            let res = (install-packages (resolve-effective-plan $home))
            assert equal $res.failed []
            let lines = (open --raw $log)
            assert ($lines | str contains "winget")
            assert (not ($lines | str contains "scoop"))
        }
    }
}

export def test_add_module_dirty_guard_and_dry_run_clone_cleanup [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let bare = ($home | path join "guarded.git")
        let work = ($home | path join "work_guarded")
        ^git init --bare -b main $bare
        ^git clone $bare $work
        ^git -C $work config user.email "t@t.local"
        ^git -C $work config user.name "Tester"
        $"name = \"guarded\"\nos = [\"linux\", \"cachyos\"]\n" | save -f ($work | path join "ygg.toml")
        "test content\n" | save -f ($work | path join "file.txt")
        ^git -C $work add .
        ^git -C $work commit -m "init"
        ^git -C $work push -u origin main

        let host_file = ($home | path join "host.toml")
        let mod_dir = ($home | path join "modules" "guarded")
        let tmp_root = ($home | path join ".state" "tmp")

        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            # 1. Dry-run stages a clone under .state/tmp, registers nothing
            let prep = (add-module $home $bare --dry-run --scopes ["pc"])
            assert equal $prep.name "guarded"
            assert equal $prep.scopes ["pc"]
            assert ($prep.tmp_clone | str starts-with ($tmp_root | path join "clone-"))
            assert equal $prep.path $prep.tmp_clone
            assert ($prep.tmp_clone | path join "file.txt" | path exists)
            assert (not ($host_file | path exists))
            assert (not ($mod_dir | path exists))
            assert ((ls ($home | path join "modules")) | is-empty)
            discard-staged-module $prep
            assert (not ($prep.tmp_clone | path exists))

            # 2. Real add registers the module
            let added = (add-module $home $bare)
            assert equal $added.path $mod_dir
            assert equal $added.tmp_clone ""
            assert equal (($mod_dir | path type)) "dir"
            assert ((load-host-config $home).modules | any { |m| $m.name == "guarded" })

            # 3. Re-adding over uncommitted changes is refused (also in dry-run), the dir is untouched
            "dirty change\n" | save -f ($mod_dir | path join "file.txt")
            let err_real = (try { add-module $home $bare; "ok" } catch { |e| $e.msg })
            assert ($err_real | str contains "uncommitted changes")
            let err_dry = (try { add-module $home $bare --dry-run; "ok" } catch { |e| $e.msg })
            assert ($err_dry | str contains "uncommitted changes")
            assert equal (open --raw ($mod_dir | path join "file.txt")) "dirty change\n"
            assert (glob (($tmp_root | path join "clone-*") | str replace --all '\' '/') | is-empty)

            # 4. --force replaces it; the dirty tree goes to .state/backups, not deleted
            add-module $home $bare --force | ignore
            assert equal (open --raw ($mod_dir | path join "file.txt") | str replace --all "\r\n" "\n") "test content\n"
            let saved = (glob (($home | path join ".state" "backups" "**" "guarded" "file.txt") | str replace --all '\' '/'))
            assert equal ($saved | length) 1
            assert equal (open --raw ($saved | first)) "dirty change\n"
            assert (glob (($tmp_root | path join "clone-*") | str replace --all '\' '/') | is-empty)
            assert equal ((load-host-config $home).modules | where name == "guarded" | length) 1
        }
    }
}

# Write a single-module host with the given [packages] TOML body
def write-pkg-module [home: string, os: string, packages_toml: string] {
    let m1 = ($home | path join "modules" "m")
    mkdir $m1
    ("name = \"m\"\nos = [\"" + $os + "\"]\n[packages]\n" + $packages_toml + "\n") | save -f ($m1 | path join "ygg.toml")
    "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")
}

def read-log [log: string]: nothing -> list<string> {
    if ($log | path exists) { open --raw $log | lines | where { |l| $l != "" } } else { [] }
}

export def test_pacman_precheck_and_noninteractive_sudo_guard [] {
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        write-pkg-module $home "linux" "pacman = [\"curl\", \"git\"]"

        # 1. Everything already installed: pacman is not invoked at all
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: $log, YGG_MOCK_PKG_INSTALLED: "curl,git" } {
            let res = (install-packages (resolve-effective-plan $home))
            assert equal $res.failed []
            assert equal (read-log $log) []
            assert equal $res.executed []
        }

        # 2. Partially installed: only the missing package reaches pacman (and paru behaves the same)
        write-pkg-module $home "linux" "pacman = [\"curl\", \"ripgrep\"]\nparu = [\"curl\", \"aur-tool\"]"
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: $log, YGG_MOCK_PKG_INSTALLED: "curl" } {
            let res = (install-packages (resolve-effective-plan $home))
            assert equal $res.failed []
            assert equal (read-log $log) ["sudo pacman -S --needed --noconfirm ripgrep", "paru -S --needed --noconfirm aur-tool"]
        }
        rm -f $log

        # 3. No sudo without a TTY: pacman not invoked, failure recorded, other managers still run
        write-pkg-module $home "linux" "pacman = [\"curl\", \"ripgrep\"]\ncargo = [\"bat\"]"
        with-env {
            YGG_HOST_OS_OVERRIDE: "cachyos",
            YGG_MOCK_PKG_LOG: $log,
            YGG_MOCK_PKG_INSTALLED: "curl",
            YGG_MOCK_SUDO_DENIED: "1"
        } {
            let res = (install-packages $home (resolve-effective-plan $home))
            let lines = (read-log $log)
            assert (not ($lines | any { |l| $l | str contains "pacman" }))
            assert equal $lines ["cargo install bat"]
            assert equal ($res.failed | length) 1
            let f = ($res.failed | first)
            assert equal $f.mgr "pacman"
            assert equal $f.pkg "ripgrep"
            assert equal $f.reason "sudo_required"
            assert ("stderr" in ($f | columns))
        }
    }
}

export def test_per_package_providers_and_isolated_failure [] {
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        write-pkg-module $home "windows" "winget = [\"Git.Git\", \"Neovim.Neovim\"]\nscoop = [\"jq\", \"fd\"]\nuv = [\"ruff\", \"black\"]"

        with-env { YGG_HOST_OS_OVERRIDE: "windows", YGG_MOCK_PKG_LOG: $log } {
            let res = (install-packages (resolve-effective-plan $home))
            assert equal $res.failed []
            let lines = (read-log $log)
            assert equal $lines [
                "winget install --exact --disable-interactivity --accept-source-agreements --accept-package-agreements Git.Git",
                "winget install --exact --disable-interactivity --accept-source-agreements --accept-package-agreements Neovim.Neovim",
                "scoop install jq",
                "scoop install fd",
                "uv tool install ruff",
                "uv tool install black"
            ]
        }
        rm -f $log
        let winget_hash = ((load-state $home).hashes | get -o "pkg:winget")
        assert ($winget_hash != null)

        # One failing package does not stop the next one
        write-pkg-module $home "windows" "winget = [\"Bad.Pkg\", \"Good.Pkg\"]"
        with-env { YGG_HOST_OS_OVERRIDE: "windows", YGG_MOCK_PKG_LOG: $log, YGG_MOCK_PKG_FAIL: "winget:Bad.Pkg" } {
            let res = (install-packages (resolve-effective-plan $home))
            assert equal ($res.failed | length) 1
            let f = ($res.failed | first)
            assert equal $f.mgr "winget"
            assert equal $f.pkg "Bad.Pkg"
            assert equal $f.reason "error"
            let lines = (read-log $log)
            assert equal $lines ["winget install --exact --disable-interactivity --accept-source-agreements --accept-package-agreements Good.Pkg"]
            # A failed manager never stores the hash of the new package set
            assert equal ((load-state $home).hashes | get -o "pkg:winget") $winget_hash
        }
    }
}

export def test_pkg_filter_mise_trust_and_timeout_kills_child_tree [] {
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        let sb = $env.YGG_SANDBOX
        write-pkg-module $home "linux" "pacman = [\"curl\"]\ncargo = [\"bat\"]\nmise = [\"ripgrep\"]"
        # Sandbox mise config exists -> trust step logged before `mise use`
        mkdir ($sb | path join ".config" "mise")
        "[tools]\n" | save -f ($sb | path join ".config" "mise" "config.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: $log } {
            let plan = (resolve-effective-plan $home)
            let res = (install-packages $plan --pkg mise --sandbox $sb)
            assert equal $res.failed []
            assert equal (read-log $log) [
                "mise trust --yes ~/.config/mise/config.toml",
                "mise use --path ~/.config/mise/config.local.toml ripgrep"
            ]

            # --pkg together with --skip-packages is an error
            let err = (try { install-packages $plan --pkg mise --skip-packages; "ok" } catch { |e| $e.msg })
            assert ($err | str contains "--pkg")
            assert ($err | str contains "--skip-packages")

            # Without mise packages in the plan there is no trust line
            rm -f $log
            write-pkg-module $home "linux" "cargo = [\"bat\"]"
            install-packages (resolve-effective-plan $home) --sandbox $sb | ignore
            assert equal (read-log $log) ["cargo install bat"]
        }
    }

    # Timeout kills the whole process tree (nu -c -> sleep) and leaves no stale message behind
    if $nu.os-info.family != "windows" {
        let marker = "30.0713"
        let t0 = (date now)
        let r1 = (run-with-timeout ["nu", "-c", ("^sleep " + $marker)] 1)
        let elapsed = ((date now) - $t0)
        sleep 300ms
        let alive = ((^pgrep -f ("sleep " + $marker) | complete).exit_code == 0)
        if $alive {
            ^pkill -KILL -f ("sleep " + $marker) | complete | ignore
        }
        assert equal $r1.timed_out true
        assert equal $r1.exit_code 124
        assert ($elapsed < 10sec) $"run-with-timeout took ($elapsed)"
        assert (not $alive) "child sleep process survived the timeout"

        let r2 = (run-with-timeout ["nu", "-c", "print ok"] 5)
        assert equal $r2.timed_out false
        assert equal $r2.exit_code 0
        assert equal ($r2.stdout | str trim) "ok"

        # Direct external process is killed too
        let marker2 = "30.0714"
        let r3 = (run-with-timeout ["sleep", $marker2] 1)
        sleep 300ms
        let alive2 = ((^pgrep -f ("sleep " + $marker2) | complete).exit_code == 0)
        if $alive2 {
            ^pkill -KILL -f ("sleep " + $marker2) | complete | ignore
        }
        assert equal $r3.timed_out true
        assert (not $alive2) "direct sleep process survived the timeout"
    }

    # Timeout 0 runs inline without a job
    let r4 = (run-with-timeout ["nu", "-c", "print inline"] 0)
    assert equal ($r4.stdout | str trim) "inline"
    assert equal $r4.timed_out false
}

export def test_package_set_hash_cache_and_refresh [] {
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        write-pkg-module $home "linux" "cargo = [\"bat\"]"

        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: $log } {
            # Dry-run never stores the hash
            let dry = (install-packages (resolve-effective-plan $home) --dry-run)
            assert equal $dry.executed ["cargo install bat"]
            assert equal ((load-state $home).hashes | get -o "pkg:cargo") null

            # 1. First run installs and stores the hash
            let r1 = (install-packages (resolve-effective-plan $home))
            assert equal (read-log $log) ["cargo install bat"]
            let h1 = ((load-state $home).hashes | get -o "pkg:cargo")
            assert ($h1 != null)
            assert equal $r1.skipped []

            # 2. Same plan: manager skipped, nothing logged
            rm -f $log
            let r2 = (install-packages (resolve-effective-plan $home))
            assert ("cargo" in $r2.skipped)
            assert equal (read-log $log) []
            assert equal $r2.executed []

            # Dry-run reports the cached skip as well
            let d2 = (install-packages (resolve-effective-plan $home) --dry-run)
            assert ("cargo" in $d2.skipped)
            assert equal $d2.executed []

            # 3. --refresh-packages bypasses the cache
            let r3 = (install-packages (resolve-effective-plan $home) --refresh-packages)
            assert equal (read-log $log) ["cargo install bat"]
            assert equal $r3.skipped []

            # 4. Explicit --pkg bypasses the cache
            rm -f $log
            install-packages (resolve-effective-plan $home) --pkg cargo | ignore
            assert equal (read-log $log) ["cargo install bat"]

            # 5. A new package in the manifest triggers the manager again
            rm -f $log
            write-pkg-module $home "linux" "cargo = [\"bat\", \"fd-find\"]"
            install-packages (resolve-effective-plan $home) | ignore
            assert equal (read-log $log) ["cargo install bat fd-find"]
            let h2 = ((load-state $home).hashes | get -o "pkg:cargo")
            assert ($h2 != $h1)

            # 6. A failed install does not store the new hash
            rm -f $log
            write-pkg-module $home "linux" "cargo = [\"bat\", \"fd-find\", \"eza\"]"
            with-env { YGG_MOCK_PKG_FAIL: "cargo" } {
                let r6 = (install-packages (resolve-effective-plan $home))
                assert equal ($r6.failed | length) 1
                assert equal $r6.failed.0.reason "error"
            }
            assert equal ((load-state $home).hashes | get -o "pkg:cargo") $h2

            # pacman never participates in the cache
            write-pkg-module $home "linux" "pacman = [\"curl\"]"
            install-packages (resolve-effective-plan $home) | ignore
            assert equal ((load-state $home).hashes | get -o "pkg:pacman") null
        }
    }
}

export def test_modules_status_columns_and_accurate_links_ok [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = $env.YGG_SANDBOX
        let ext_dir = ($home | path dirname | path join "status_mod")
        mkdir $ext_dir
        'name = "status_mod"
os = ["linux", "cachyos"]
[links]
"a.conf" = "~/.config/a.conf"
"b.conf" = "~/.config/b.conf"
[save]
"s.json" = "~/.config/s.json"
' | save -f ($ext_dir | path join "ygg.toml")
        "a\n" | save -f ($ext_dir | path join "a.conf")
        "b\n" | save -f ($ext_dir | path join "b.conf")
        "{}\n" | save -f ($ext_dir | path join "s.json")
        let cfg = ($sb | path join ".config")

        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            add-module $home $ext_dir | ignore
            apply-links $home (resolve-effective-plan $home) --sandbox $sb | ignore

            let row = (modules-status $home | first)
            assert equal ($row | columns) ["name", "scopes", "path", "target", "branch", "dirty", "links_ok", "sync_conflicts", "pending_save", "containers"]
            assert equal $row.path ($home | path join "modules" "status_mod")
            assert equal $row.target ($ext_dir | path expand)
            assert equal $row.links_ok true
            assert equal $row.sync_conflicts 0
            assert equal $row.pending_save 0

            # Host-only edit -> pending save; edits on both sides -> conflict
            '{"host": 1}' | save -f ($cfg | path join "s.json")
            let r1 = (modules-status $home | first)
            assert equal $r1.pending_save 1
            assert equal $r1.sync_conflicts 0
            '{"mod": 1}' | save -f ($ext_dir | path join "s.json")
            let r2 = (modules-status $home | first)
            assert equal $r2.pending_save 0
            assert equal $r2.sync_conflicts 1

            # Dangling symlink in place of a managed link
            rm ($cfg | path join "a.conf")
            ^ln -s ($home | path join "nowhere") ($cfg | path join "a.conf")
            assert equal (modules-status $home | first | get links_ok) false
            # Managed link pointing at the right source, but the source is gone
            rm ($cfg | path join "a.conf")
            ^ln -s ($ext_dir | path join "a.conf") ($cfg | path join "a.conf")
            assert equal (modules-status $home | first | get links_ok) true
            mv ($ext_dir | path join "a.conf") ($ext_dir | path join "a.conf.moved")
            assert equal (modules-status $home | first | get links_ok) false
            mv ($ext_dir | path join "a.conf.moved") ($ext_dir | path join "a.conf")
            # Regular file in place of a managed link
            rm ($cfg | path join "b.conf")
            "host\n" | save -f ($cfg | path join "b.conf")
            assert equal (modules-status $home | first | get links_ok) false
            rm ($cfg | path join "b.conf")
            ^ln -s ($ext_dir | path join "b.conf") ($cfg | path join "b.conf")
            assert equal (modules-status $home | first | get links_ok) true

            # A copy-type link entry only needs the file to exist
            let copy_dest = ($cfg | path join "copied.conf")
            mut st = (load-state $home)
            $st.links = ($st.links | upsert $copy_dest { module: "status_mod", src: ($ext_dir | path join "a.conf"), type: "copy", cmd_shim: "" })
            save-state $home $st
            assert equal (modules-status $home | first | get links_ok) false
            "a\n" | save -f $copy_dest
            assert equal (modules-status $home | first | get links_ok) true
        }
    }
}

export def test_add_module_warns_on_non_canonicalizable_volume [] {
    with-temp-ygg { |home|
        let src_dir = ($env.FILE_PWD | path join "../src" | path expand)
        let ext_dir = ($home | path dirname | path join "vol_mod")
        mkdir $ext_dir
        'name = "vol_mod"
os = ["linux", "cachyos"]' | save -f ($ext_dir | path join "ygg.toml")
        let script = ("use " + ($src_dir | path join "git.nu") + " *; add-module '" + $home + "' '" + $ext_dir + "' | ignore")

        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_NO_CANONICALIZE: "1" } {
            let res = (^nu -c $script | complete)
            assert equal $res.exit_code 0 $res.stderr
            assert ($res.stderr | str contains "is on a volume without path canonicalization support")
            assert ($res.stderr | str contains $ext_dir)
        }
        let cfg = (load-host-config $home)
        assert equal ($cfg.modules | where name == "vol_mod" | length) 1
        assert (is-link-or-junction ($home | path join "modules" "vol_mod"))

        # Without the mock a local /tmp path canonicalizes: no warning
        let ext2 = ($home | path dirname | path join "vol_mod2")
        mkdir $ext2
        'name = "vol_mod2"
os = ["linux", "cachyos"]' | save -f ($ext2 | path join "ygg.toml")
        let script2 = ("use " + ($src_dir | path join "git.nu") + " *; add-module '" + $home + "' '" + $ext2 + "' | ignore")
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_NO_CANONICALIZE: "" } {
            let res2 = (^nu -c $script2 | complete)
            assert equal $res2.exit_code 0 $res2.stderr
            assert (not ($res2.stderr | str contains "canonicalization"))
        }
    }
}

export def test_discard_staged_module_refuses_unsafe_path [] {
    with-temp-ygg { |home|
        let unsafe_dir = ($home | path join "unsafe_dir")
        mkdir $unsafe_dir
        "important\n" | save -f ($unsafe_dir | path join "file.txt")

        # tmp_clone path outside .state/tmp must not be deleted
        discard-staged-module { tmp_clone: $unsafe_dir }
        assert ($unsafe_dir | path exists)
        assert ($unsafe_dir | path join "file.txt" | path exists)

        # tmp_clone path inside .state/tmp IS deleted
        let safe_dir = ($home | path join ".state" "tmp" "test_clone")
        mkdir $safe_dir
        "clone\n" | save -f ($safe_dir | path join "file.txt")
        discard-staged-module { tmp_clone: $safe_dir }
        assert (not ($safe_dir | path exists))

        # Empty or missing tmp_clone is a safe no-op
        discard-staged-module {}
        discard-staged-module { tmp_clone: "" }
    }
}

export def test_package_providers_macos_and_linux_distros [] {
    with-temp-ygg { |home|
        let log = ($home | path join "mock.log")
        with-env { YGG_MOCK_PKG_LOG: $log, YGG_HOST_OS_OVERRIDE: "macos" } {
            let plan = { packages: { brew: ["ripgrep", "fd"] } }
            let res = (install-packages $home $plan --dry-run)
            assert ($res.executed | any { |c| $c =~ "brew install ripgrep fd" }) "Expected brew install"
        }
        with-env { YGG_MOCK_PKG_LOG: $log, YGG_HOST_OS_OVERRIDE: "ubuntu" } {
            let plan = { packages: { apt: ["curl", "git"] } }
            let res = (install-packages $home $plan --dry-run)
            assert ($res.executed | any { |c| $c =~ "apt-get install -y --no-install-recommends curl git" }) "Expected apt-get install"
        }
        with-env { YGG_MOCK_PKG_LOG: $log, YGG_HOST_OS_OVERRIDE: "debian" } {
            let plan = { packages: { apt: ["curl"] } }
            let res = (install-packages $home $plan --dry-run)
            assert ($res.executed | any { |c| $c =~ "apt-get install -y --no-install-recommends curl" }) "Expected apt-get install for debian"
        }
        with-env { YGG_MOCK_PKG_LOG: $log, YGG_HOST_OS_OVERRIDE: "ubuntu", YGG_HOST_BREW: "true" } {
            let plan = { packages: { brew: ["fzf"] } }
            let res = (install-packages $home $plan --dry-run)
            assert ($res.executed | any { |c| $c =~ "brew install fzf" }) "Expected Linuxbrew install"
        }
        with-env { YGG_MOCK_PKG_LOG: $log, YGG_HOST_OS_OVERRIDE: "fedora" } {
            let plan = { packages: { dnf: ["htop", "tmux"] } }
            let res = (install-packages $home $plan --dry-run)
            assert ($res.executed | any { |c| $c =~ "dnf install -y htop tmux" }) "Expected dnf install"
        }
        with-env { YGG_MOCK_PKG_LOG: $log, YGG_HOST_OS_OVERRIDE: "opensuse" } {
            let plan = { packages: { zypper: ["neovim", "zsh"] } }
            let res = (install-packages $home $plan --dry-run)
            assert ($res.executed | any { |c| $c =~ "zypper install -y neovim zsh" }) "Expected zypper install"
        }
    }
}

export def test_ygg_lock_generation_and_pinned_modules [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        # Имитируем git-модуль
        let mod_dir = ($home | path join "modules" "pinned-mod")
        mkdir $mod_dir
        ^git -C $mod_dir init | complete | ignore
        ^git -C $mod_dir config user.name "Test" | complete | ignore
        ^git -C $mod_dir config user.email "test@example.com" | complete | ignore
        "name = 'pinned-mod'\nos = ['linux']\n" | save -f ($mod_dir | path join "ygg.toml")
        ^git -C $mod_dir add . | complete | ignore
        ^git -C $mod_dir commit -m "initial" | complete | ignore

        let plan = { modules: [{ name: "pinned-mod", dir: $mod_dir, pin: true }] }
        let lock = (generate-ygg-lock $home $plan)
        assert ($home | path join "ygg.lock" | path exists) "ygg.lock must be created"
        assert (($lock.modules | first).name == "pinned-mod") "Expected module in lockfile"
        assert (($lock.modules | first).commit | is-not-empty) "Expected commit hash"
        assert equal $lock.version 1 "Lock version must be 1"

        # Verify TOML content on disk
        let lock_raw = (open --raw ($home | path join "ygg.lock"))
        assert ($lock_raw | str contains "version = 1")
        assert (($lock_raw | str contains "[[modules]]") or ($lock_raw | str contains "[[module]]"))

        # verify-ygg-lock should succeed on matching commit
        let verify_res = (verify-ygg-lock $home $plan)
        assert ($verify_res | is-empty) "Expected verify-ygg-lock to pass"

        # Mutate commit in module repository
        "name = 'pinned-mod'\nos = ['linux']\n# updated\n" | save -f ($mod_dir | path join "ygg.toml")
        ^git -C $mod_dir commit -am "second commit" | complete | ignore

        # verify-ygg-lock should now fail with mismatch
        let verify_fail = (verify-ygg-lock $home $plan)
        assert ($verify_fail | is-not-empty) "Expected verify-ygg-lock to fail after commit change"
        assert ($verify_fail | any { |err| $err | str contains "commit mismatch" }) "Expected mismatch error message"

        # Check update-modules / update-module skips pinned module
        "[[modules]]\nname = 'pinned-mod'\npin = true\n" | save -f ($home | path join "host.toml")
        let up_res = (update-modules $home)
        let pinned_entry = ($up_res | where name == "pinned-mod" | first)
        assert equal $pinned_entry.status "skipped"
        assert equal $pinned_entry.message "module pinned"
    }
}

export def test_prune_unused_packages_isolated_providers [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        save-state $home { links: {}, copies: {}, hashes: {}, packages: { uv: ["ruff", "black"] } }
        let plan = { packages: { uv: ["ruff"] } }
        with-env { YGG_MOCK_PKG_LOG: ($home | path join "pkg.log") } {
            let cmds = (prune-unused-packages $home $plan --dry-run).executed
            assert ($cmds | any { |c| $c =~ "uv tool uninstall black" }) "Expected black uninstallation"
        }
        # Verify dry-run does not mutate state.packages
        let st = (load-state $home)
        assert equal ($st.packages.uv | sort) (["black", "ruff"] | sort)
    }
}

export def test_prune_unused_packages_real_mock_execution [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let log = ($home | path join "pkg.log")
        save-state $home {
            links: {},
            copies: {},
            hashes: {},
            packages: {
                uv: ["ruff", "black"],
                mise: ["node@20", "python@3.11"],
                pnpm: ["prettier", "eslint"],
                cargo: ["bat", "eza"]
            }
        }
        let plan = {
            packages: {
                uv: ["ruff"],
                mise: ["node@20"],
                pnpm: ["prettier"],
                cargo: ["bat"]
            }
        }
        with-env { YGG_MOCK_PKG_LOG: $log } {
            let cmds = (prune-unused-packages $home $plan).executed
            assert ($cmds | any { |c| $c =~ "uv tool uninstall black" })
            assert ($cmds | any { |c| $c =~ "mise uninstall python@3.11" })
            assert ($cmds | any { |c| $c =~ "pnpm remove -g eslint" })
            assert ($cmds | any { |c| $c =~ "cargo uninstall eza" })

            let log_content = (open --raw $log)
            assert ($log_content | str contains "uv tool uninstall black")
            assert ($log_content | str contains "mise uninstall python@3.11")
            assert ($log_content | str contains "pnpm remove -g eslint")
            assert ($log_content | str contains "cargo uninstall eza")

            let st = (load-state $home)
            assert equal $st.packages.uv ["ruff"]
            assert equal $st.packages.mise ["node@20"]
            assert equal $st.packages.pnpm ["prettier"]
            assert equal $st.packages.cargo ["bat"]
        }
    }
}

export def test_prune_unused_packages_system_guard [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let log = ($home | path join "pkg.log")
        save-state $home {
            links: {},
            copies: {},
            hashes: {},
            packages: {
                pacman: ["git", "curl"],
                uv: ["black"]
            }
        }
        let plan = { packages: {} }

        with-env { YGG_MOCK_PKG_LOG: $log, YGG_HOST_OS_OVERRIDE: "cachyos" } {
            # Without --force-system-prune: system packages must be skipped
            let cmds_safe = (prune-unused-packages $home $plan --dry-run).executed
            assert ($cmds_safe | any { |c| $c =~ "uv tool uninstall black" }) "Safe manager must be pruned"
            assert (not ($cmds_safe | any { |c| $c =~ "pacman" })) "Pacman must not be pruned without force"

            # With --force-system-prune: system packages are included
            let cmds_forced = (prune-unused-packages $home $plan --dry-run --force-system-prune).executed
            assert ($cmds_forced | any { |c| $c =~ "uv tool uninstall black" })
            assert ($cmds_forced | any { |c| $c =~ "pacman -R --noconfirm git" })
            assert ($cmds_forced | any { |c| $c =~ "pacman -R --noconfirm curl" })
        }
    }
}

export def test_install_packages_updates_state_packages [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let log = ($home | path join "pkg.log")
        let m1 = ($home | path join "modules" "m")
        mkdir $m1
        'name = "m"
os = ["linux", "windows", "macos"]
[packages]
uv = ["ruff", "black"]
mise = ["node@20"]' | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "linux", YGG_MOCK_PKG_LOG: $log } {
            install-packages $home (resolve-effective-plan $home)
            let st = (load-state $home)
            assert equal ($st.packages.uv | sort) (["black", "ruff"] | sort)
            assert equal $st.packages.mise ["node@20"]
        }
    }
}

export def test_cli_apply_prune_packages [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let log = ($home | path join "pkg.log")
        let mod_dir = ($home | path join "modules" "m")
        mkdir $mod_dir
        'name = "m"
os = ["linux", "windows", "macos"]
[packages]
uv = ["ruff"]' | save -f ($mod_dir | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")
        ensure-ygg-dirs $home
        save-state $home {
            links: {},
            copies: {},
            hashes: {},
            packages: { uv: ["ruff", "black"] }
        }

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_MOCK_PKG_LOG: $log, YGG_HOST_OS_OVERRIDE: "linux" } {
            # Dry-run
            let dry = (^nu $ygg_bin apply --prune-packages --dry-run | complete)
            assert ($dry.exit_code == 0)
            assert ($dry.stdout | str contains "uv tool uninstall black")
            assert (not ($log | path exists))

            # Real run
            let res = (^nu $ygg_bin apply --prune-packages | complete)
            assert ($res.exit_code == 0)
            let log_content = (open --raw $log)
            assert ($log_content | str contains "uv tool uninstall black")
            let st = (load-state $home)
            assert equal $st.packages.uv ["ruff"]
        }
    }
}
def seed-pkg-state [home: string, pkgs: record] {
    ensure-ygg-dirs $home
    save-state $home { links: {}, copies: {}, hashes: {}, packages: $pkgs }
}

export def test_prune_in_sandbox_without_mock_executes_nothing [] {
    with-temp-ygg { |home|
        seed-pkg-state $home { cargo: ["ripgrep", "stale-crate"] }
        let plan = { packages: { cargo: ["ripgrep"] }, modules: [] }
        let res = (prune-unused-packages $home $plan --sandbox ($home | path join "sb"))
        assert equal $res.executed []
        assert equal (load-state $home).packages.cargo ["ripgrep", "stale-crate"]
    }
}

export def test_prune_history_survives_plain_apply [] {
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        with-env { YGG_MOCK_PKG_LOG: $log, YGG_HOST_OS_OVERRIDE: "cachyos" } {
            install-packages $home { packages: { cargo: ["a", "b"] }, modules: [] } | ignore
            install-packages $home { packages: { cargo: ["a"] }, modules: [] } | ignore
            install-packages $home { packages: { cargo: ["a"] }, modules: [] } | ignore   # cached branch
            assert ("b" in (load-state $home).packages.cargo)
            let res = (prune-unused-packages $home { packages: { cargo: ["a"] }, modules: [] })
            assert ($res.executed | any { |c| $c | str contains "b" })
            assert equal (load-state $home).packages.cargo ["a"]
        }
    }
}

export def test_prune_respects_pkg_filter_and_system_guard [] {
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        seed-pkg-state $home { cargo: ["x"], pnpm: ["y"], pacman: ["z"] }
        with-env { YGG_MOCK_PKG_LOG: $log, YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let res = (prune-unused-packages $home { packages: {}, modules: [] } --pkg "cargo")
            assert equal ($res.executed | length) 1
            assert ($res.executed.0 | str contains "x")
            let st = (load-state $home).packages
            assert equal $st.pnpm ["y"]
            assert equal $st.pacman ["z"]
        }
    }
}

export def test_pkg_uninstall_argv_keeps_spaces_intact [] {
    # через мок-лог: пакет с пробелом в имени не распадается на аргументы
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        seed-pkg-state $home { cargo: ["odd name"] }
        with-env { YGG_MOCK_PKG_LOG: $log } {
            let res = (prune-unused-packages $home { packages: {}, modules: [] })
            assert ($res.executed.0 | str ends-with "odd name")
        }
    }
}



export def test_apt_requires_passwordless_sudo [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        with-env { YGG_MOCK_PKG_LOG: $log, YGG_HOST_OS_OVERRIDE: "ubuntu", YGG_MOCK_SUDO_DENIED: "1" } {
            let res = (install-packages $home { packages: { apt: ["curl"] }, modules: [] })
            assert ($res.failed | any { |f| $f.mgr == "apt" })
            assert equal ($res.failed | first | get reason) "sudo_required"
            assert (($res.failed | first).stderr | str contains "sudo requires a password; run 'sudo -v' first or use --skip-packages")
            assert (not ($log | path exists))
        }
    }
}

export def test_noninteractive_env_and_timeouts [] {
    assert equal (pkg-env "apt").DEBIAN_FRONTEND "noninteractive"
    assert equal (pkg-env "brew").HOMEBREW_NO_AUTO_UPDATE "1"
    assert equal (pkg-env "brew").NONINTERACTIVE "1"
    assert equal (pkg-env "cargo") {}
}

export def test_missing_pkgs_mock_and_passthrough [] {
    with-env { YGG_MOCK_PKG_LOG: "mock.log", YGG_MOCK_PKG_INSTALLED: "curl" } {
        assert equal (missing-pkgs "apt" ["curl", "git"]) ["git"]
        assert equal (missing-pkgs "dnf" ["curl", "git"]) ["git"]
        # User-space managers are prechecked too; winget/scoop still pass everything through
        assert equal (missing-pkgs "cargo" ["curl", "git"]) ["git"]
        assert equal (missing-pkgs "mise" ["curl", "git"]) ["git"]
        assert equal (missing-pkgs "pnpm" ["curl", "git"]) ["git"]
        assert equal (missing-pkgs "uv" ["curl", "git"]) ["git"]
        assert equal (missing-pkgs "winget" ["curl", "git"]) ["curl", "git"]
    }
}

export def test_parse_installed_pkgs_listings [] {
    let cargo = (parse-installed-pkgs "cargo" "foo v0.1.0 (https://github.com/x/foo#abc1234):\n    foo\nripgrep v14.1.0:\n    rg\n")
    assert equal $cargo [
        { name: "foo", version: "0.1.0", requested: "" },
        { name: "ripgrep", version: "14.1.0", requested: "" }
    ]

    let uv = (parse-installed-pkgs "uv" "headroom-ai v0.41.0\n- headroom\n- headroom-cache-ttl\nruff v0.5.0\n- ruff\n")
    assert equal ($uv | get name) ["headroom-ai", "ruff"]
    assert equal ($uv | get version) ["0.41.0", "0.5.0"]

    let pnpm_json = '[{"path": "/g", "private": true, "dependencies": {"typescript": {"version": "5.4.0"}, "@biomejs/biome": {"version": "1.8.0"}}}]'
    let pnpm = (parse-installed-pkgs "pnpm" $pnpm_json)
    assert equal ($pnpm | sort-by name | get name) ["@biomejs/biome", "typescript"]
    assert equal ($pnpm | where name == "typescript" | first | get version) "5.4.0"
    assert equal (parse-installed-pkgs "pnpm" '[{"path": "/g", "dependencies": {}}]') []

    # mise: only installed entries; the requested version is kept for `tool@20`-style specs
    let mise_json = '{"node": [{"version": "20.11.0", "requested_version": "20", "installed": true}], "aqua:BurntSushi/ripgrep": [{"version": "15.2.0", "requested_version": "latest", "installed": true}], "python": [{"version": "3.12.1", "requested_version": "3.12", "installed": false}]}'
    let mise = (parse-installed-pkgs "mise" $mise_json)
    assert equal ($mise | sort-by name) [
        { name: "aqua:BurntSushi/ripgrep", version: "15.2.0", requested: "latest" },
        { name: "node", version: "20.11.0", requested: "20" }
    ]

    # Unparseable output yields nothing (the caller then treats every package as missing)
    assert equal (parse-installed-pkgs "pnpm" "not json") []
    assert equal (parse-installed-pkgs "mise" "") []
}

export def test_pkg_spec_installed_matching [] {
    let cargo = [{ name: "ripgrep", version: "14.1.0", requested: "" }]
    assert (pkg-spec-installed "cargo" "ripgrep" $cargo)
    assert (pkg-spec-installed "cargo" "ripgrep@14.1.0" $cargo)
    assert (pkg-spec-installed "cargo" "ripgrep@14" $cargo)
    assert (not (pkg-spec-installed "cargo" "ripgrep@13" $cargo))
    assert (not (pkg-spec-installed "cargo" "ripgrep@14.1.01" $cargo))
    assert (not (pkg-spec-installed "cargo" "bat" $cargo))

    let mise = [
        { name: "node", version: "20.11.0", requested: "20" },
        { name: "aqua:BurntSushi/ripgrep", version: "15.2.0", requested: "latest" },
        { name: "npm:@scope/tool", version: "1.0.0", requested: "latest" }
    ]
    assert (pkg-spec-installed "mise" "node" $mise)
    assert (pkg-spec-installed "mise" "node@20" $mise)
    assert (pkg-spec-installed "mise" "node@20.11.0" $mise)
    assert (pkg-spec-installed "mise" "node@latest" $mise)
    assert (not (pkg-spec-installed "mise" "node@18" $mise))
    assert (pkg-spec-installed "mise" "aqua:BurntSushi/ripgrep" $mise)
    assert (pkg-spec-installed "mise" "aqua:BurntSushi/ripgrep@latest" $mise)
    assert (pkg-spec-installed "mise" "npm:@scope/tool" $mise)
    assert (not (pkg-spec-installed "mise" "python@3.12" $mise))

    let pnpm = [{ name: "@biomejs/biome", version: "1.8.0", requested: "" }, { name: "typescript", version: "5.4.0", requested: "" }]
    assert (pkg-spec-installed "pnpm" "@biomejs/biome" $pnpm)
    assert (pkg-spec-installed "pnpm" "@biomejs/biome@1.8.0" $pnpm)
    assert (pkg-spec-installed "pnpm" "typescript@5" $pnpm)
    assert (not (pkg-spec-installed "pnpm" "typescript@4" $pnpm))
    assert (not (pkg-spec-installed "pnpm" "eslint" $pnpm))

    # uv: PEP 503 name normalization; only exact pins (== / @) constrain the version
    let uv = [{ name: "ruff", version: "0.5.0", requested: "" }, { name: "headroom-ai", version: "0.41.0", requested: "" }]
    assert (pkg-spec-installed "uv" "ruff" $uv)
    assert (pkg-spec-installed "uv" "Ruff" $uv)
    assert (pkg-spec-installed "uv" "ruff==0.5.0" $uv)
    assert (pkg-spec-installed "uv" "ruff@0.5.0" $uv)
    assert (pkg-spec-installed "uv" "ruff>=0.4" $uv)
    assert (not (pkg-spec-installed "uv" "ruff==0.4" $uv))
    assert (pkg-spec-installed "uv" "headroom_ai" $uv)
    assert (not (pkg-spec-installed "uv" "black" $uv))
}

# Real `cargo install --list` output, read from a fake CARGO_HOME (the host's crates are never read)
export def test_missing_pkgs_reads_real_cargo_listing [] {
    if (which cargo | is-empty) { return }
    with-temp-ygg { |home|
        let cargo_home = ($home | path join "cargo-home")
        mkdir $cargo_home
        "[v1]\n\"ripgrep 14.1.0 (registry+https://github.com/rust-lang/crates.io-index)\" = [\"rg\"]\n" | save -f ($cargo_home | path join ".crates.toml")
        with-env { CARGO_HOME: $cargo_home } {
            assert equal (missing-pkgs "cargo" ["ripgrep", "bat", "ripgrep@13"]) ["bat", "ripgrep@13"]
        }
    }
}

export def test_dry_run_precheck_never_writes_state [] {
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        let state_file = ($home | path join ".state" "state.json")
        write-pkg-module $home "linux" "pacman = [\"curl\"]"
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: $log, YGG_MOCK_PKG_INSTALLED: "curl" } {
            let res = (install-packages (resolve-effective-plan $home) --dry-run)
            assert equal $res.executed []
            assert equal (read-log $log) []
            assert (not ($state_file | path exists)) "ygg diff must not write state.json"

            # An existing state.json is left byte-for-byte untouched
            save-state $home { links: {}, copies: {}, hashes: {}, packages: {} }
            let before = (open --raw $state_file)
            install-packages (resolve-effective-plan $home) --dry-run | ignore
            assert equal (open --raw $state_file) $before
        }
    }
}

export def test_precheck_satisfied_set_is_cached [] {
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        write-pkg-module $home "linux" "cargo = [\"bat\"]"
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: $log, YGG_MOCK_PKG_INSTALLED: "bat" } {
            let r1 = (install-packages (resolve-effective-plan $home))
            assert equal $r1.executed []
            assert ((load-state $home).hashes | get -o "pkg:cargo" | is-not-empty) "satisfied set must store its hash"
            assert equal ((load-state $home).packages | get -o cargo) ["bat"]
        }
        # The next run trusts the cache and skips the precheck
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: $log, YGG_MOCK_PKG_INSTALLED: "" } {
            let r2 = (install-packages (resolve-effective-plan $home))
            assert equal $r2.skipped ["cargo"]
            assert equal (read-log $log) []
        }
    }
}

export def test_prune_system_requires_sudo_for_apt [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        with-env { YGG_MOCK_PKG_LOG: $log, YGG_HOST_OS_OVERRIDE: "ubuntu", YGG_MOCK_SUDO_DENIED: "1" } {
            save-state $home { packages: { apt: ["curl"] } }
            let res = (prune-unused-packages $home { packages: {}, modules: [] } --force-system-prune)
            assert (not ($log | path exists))
        }
    }
}

def git-in [dir: string, args: list<string>]: nothing -> nothing {
    ^git -C $dir -c user.email=t@t -c user.name=t ...$args | complete | ignore
}

def make-origin [root: string]: nothing -> record<origin: string, first: string, second: string> {
    let origin = ($root | path join "origin"); mkdir $origin
    git-in $origin [init -q -b main]
    "name = \"m\"\nos = [\"linux\", \"windows\", \"macos\"]\n" | save -f ($origin | path join "ygg.toml")
    git-in $origin [add -A]; git-in $origin [commit -q -m one]
    let first = (^git -C $origin rev-parse HEAD | str trim)
    "x" | save -f ($origin | path join "f"); git-in $origin [add -A]; git-in $origin [commit -q -m two]
    git-in $origin [tag v1 $first]
    { origin: $origin, first: $first, second: (^git -C $origin rev-parse HEAD | str trim) }
}

export def test_checkout_module_ref_rev_tag_and_dirty [] {
    with-temp-ygg { |home|
        let o = (make-origin $home)
        let clone = ($home | path join "modules" "m")
        mkdir ($home | path join "modules")
        ^git clone -q $o.origin $clone | complete | ignore
        assert equal (checkout-module-ref $clone "" "").status "skipped"
        let r = (checkout-module-ref $clone "" $o.first)
        assert equal $r.status "ok"; assert equal $r.head $o.first
        assert equal (checkout-module-ref $clone "main" "").head $o.second
        assert equal (checkout-module-ref $clone "v1" "").head $o.first
        "dirty" | save -f ($clone | path join "f")
        assert equal (checkout-module-ref $clone "main" "").status "error"
    }
}

export def test_ygg_lock_is_deterministic_and_detects_dirty [] {
    with-temp-ygg { |home|
        let o = (make-origin $home)
        let clone = ($home | path join "modules" "m")
        mkdir ($home | path join "modules")
        ^git clone -q $o.origin $clone | complete | ignore
        let plan = { modules: [{ name: "m", dir: $clone }] }
        generate-ygg-lock $home $plan | ignore
        let lf = ($home | path join "ygg.lock")
        let a = (open --raw $lf); let m1 = (ls $lf | get 0.modified)
        sleep 1100ms
        generate-ygg-lock $home $plan | ignore
        assert equal (open --raw $lf) $a
        assert equal (ls $lf | get 0.modified) $m1
        assert equal (verify-ygg-lock $home $plan) []
        "dirty" | save -f ($clone | path join "f")
        assert ((verify-ygg-lock $home $plan) | any { |e| $e | str contains "uncommitted changes" })
    }
}

export def test_update_honors_rev_pin_cli [] {
    with-temp-ygg { |home|
        let o = (make-origin $home)
        let clone = ($home | path join "modules" "m")
        mkdir ($home | path join "modules")
        ^git clone -q $o.origin $clone | complete | ignore
        $"[[modules]]\nname = \"m\"\nrev = \"($o.first)\"\n" | save -f ($home | path join "host.toml")
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let res = (^nu $ygg_bin update | complete)
            assert equal $res.exit_code 0 $res.stderr
        }
        assert equal (^git -C $clone rev-parse HEAD | str trim) $o.first
    }
}

export def test_update_conflict_exits_1_cli [] {
    with-temp-ygg { |home|
        let o = (make-origin $home)
        let clone = ($home | path join "modules" "m")
        mkdir ($home | path join "modules")
        ^git clone -q $o.origin $clone | complete | ignore
        $"[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")
        "origin side" | save -f ($o.origin | path join "f"); git-in $o.origin [commit -q -am o]
        "clone side" | save -f ($clone | path join "f"); git-in $clone [commit -q -am c]
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let res = (^nu $ygg_bin update | complete)
            assert equal $res.exit_code 1 $res.stderr
        }
    }
}

# Bare upstream + module clone registered via add-module; returns paths
def make-upstream-module [home: string]: nothing -> record {
    let upstream = ($home | path join "upstream.git")
    let work_up = ($home | path join "work_up")
    ^git init --bare -b main $upstream
    ^git clone $upstream $work_up
    ^git -C $work_up config user.email "t@t.local"
    ^git -C $work_up config user.name "Tester"
    $"name = \"demo\"\nos = [\"linux\", \"windows\", \"macos\", \"cachyos\"]\n" | save -f ($work_up | path join "ygg.toml")
    "base\n" | save -f ($work_up | path join "notes.txt")
    "base\n" | save -f ($work_up | path join "other.txt")
    ^git -C $work_up add .
    ^git -C $work_up commit -m "init"
    ^git -C $work_up push -u origin main
    with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } { add-module $home $upstream | ignore }
    { upstream: $upstream, work_up: $work_up, cloned: ($home | path join "modules" "demo") }
}

# Put the module into a mid-merge state (UU notes.txt) plus an unstaged edit of other.txt
def make-unstashable-module [home: string]: nothing -> record {
    let r = (make-upstream-module $home)
    let git_c = [-c user.email=t@t -c user.name=t]
    "local\n" | save -f ($r.cloned | path join "notes.txt")
    ^git ...$git_c -C $r.cloned commit -qam "local change"
    "upstream\n" | save -f ($r.work_up | path join "notes.txt")
    ^git ...$git_c -C $r.work_up commit -qam "upstream change"
    ^git -C $r.work_up push -q
    ^git ...$git_c -C $r.cloned pull --no-rebase --no-edit | complete | ignore
    "my unstaged edit\n" | save -f ($r.cloned | path join "other.txt")
    $r
}

export def test_update_never_resets_dirty_tree_when_stash_fails [] {
    with-temp-ygg { |home|
        let r = (make-unstashable-module $home)
        let st_before = (^git -C $r.cloned status --porcelain | complete | get stdout)
        assert ($st_before | str contains "UU notes.txt") "setup must produce an unmerged path"
        let head_before = (^git -C $r.cloned rev-parse HEAD | str trim)
        let notes_before = (open --raw ($r.cloned | path join "notes.txt"))

        let res = (update-module $home "demo")
        assert equal $res.status "error"
        assert ($res.message | str contains "cannot stash")
        assert equal (open --raw ($r.cloned | path join "other.txt")) "my unstaged edit\n"
        assert equal (open --raw ($r.cloned | path join "notes.txt")) $notes_before
        assert equal (^git -C $r.cloned rev-parse HEAD | str trim) $head_before
        assert equal (^git -C $r.cloned status --porcelain | complete | get stdout) $st_before
    }
}

export def test_cli_update_keeps_local_changes_when_stash_fails [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb"); mkdir $sb
        let r = (make-unstashable-module $home)
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let res = (with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: "cachyos" } {
            ^nu $ygg_bin update | complete
        })
        assert equal $res.exit_code 1
        assert equal (open --raw ($r.cloned | path join "other.txt")) "my unstaged edit\n"
        assert (^git -C $r.cloned status --porcelain | complete | get stdout | str contains "UU notes.txt")
    }
}

export def test_checkout_module_ref_rejects_option_like_pins [] {
    with-temp-ygg { |home|
        let r = (make-upstream-module $home)
        let head_before = (^git -C $r.cloned rev-parse HEAD | str trim)
        for pin in [["--orphan=x" ""] ["" "-f"]] {
            let res = (checkout-module-ref $r.cloned ($pin | get 0) ($pin | get 1))
            assert equal $res.status "error"
            assert ($res.message | str contains "invalid ref") $res.message
            assert equal $res.head $head_before
        }
    }
}

export def test_add_dry_run_read_only_leaves_home_untouched [] {
    with-temp-ygg { |home|
        let r = (make-upstream-module $home)
        # fresh second home so the snapshot is exactly "nothing"
        let home2 = ($home | path join "fresh-home"); mkdir $home2
        let local_src = ($home | path join "local-mod"); mkdir $local_src
        $"name = \"loc\"\nos = [\"linux\", \"cachyos\"]\n" | save -f ($local_src | path join "ygg.toml")
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            for src in [$local_src $r.upstream] {
                let prep = (add-module $home2 $src --dry-run --read-only)
                assert equal (ls -a $home2 | length) 0 $"add-module --read-only created files for ($src)"
                if $prep.tmp_clone != "" {
                    assert (not ($prep.tmp_clone | str starts-with $home2))
                    assert ($prep.tmp_clone | path exists)
                }
                discard-staged-module $prep
                if $prep.tmp_clone != "" { assert (not ($prep.tmp_clone | path exists)) }
            }
        }
    }
}

# BUG-4: a failing `git status` must never be read as "clean tree" (update would reset --hard,
# remove would rm -rf uncommitted work).
def git-status-failing-shim [home: string]: nothing -> string {
    let bin = ($home | path join "git-shim"); mkdir $bin
    let real = (which git | get 0.path)
    $"#!/bin/sh\nfor a in \"$@\"; do [ \"$a\" = status ] && { echo 'fatal: simulated status failure' >&2; exit 128; }; done\nexec '($real)' \"$@\"\n" | save -f ($bin | path join "git")
    ^chmod +x ($bin | path join "git")
    $bin
}

export def test_failed_git_status_never_destroys_local_changes [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let bare = ($home | path join "mod.git")
        let work = ($home | path join "work_mod")
        ^git init -q --bare -b main $bare
        ^git clone -q $bare $work
        ^git -C $work config user.email "t@t.local"
        ^git -C $work config user.name "Tester"
        "name = \"fragile\"\nos = [\"linux\", \"cachyos\"]\n" | save -f ($work | path join "ygg.toml")
        "line = base\n" | save -f ($work | path join "app.conf")
        ^git -C $work add .
        ^git -C $work commit -q -m "init"
        ^git -C $work push -q -u origin main

        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            add-module $home $bare
            let mod_dir = ($home | path join "modules" "fragile")
            "line = local_custom\n" | save -f ($mod_dir | path join "app.conf")
            let shim = (git-status-failing-shim $home)
            with-env { PATH: ($env.PATH | prepend $shim) } {
                let res = (update-module $home "fragile")
                assert equal $res.status "error"
                assert equal (open --raw ($mod_dir | path join "app.conf")) "line = local_custom\n"

                let rm_res = (try { remove-module $home "fragile"; "removed" } catch { |e| $e.msg })
                assert ($rm_res != "removed") "remove must refuse when git status cannot be read"
                assert equal (open --raw ($mod_dir | path join "app.conf")) "line = local_custom\n"
            }
        }
    }
}

export def test_pkg_prepare_sudo_for_progress [] {
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        with-env { YGG_MOCK_PKG_LOG: $log } {
            assert equal (prepare-sudo-for-progress true true) false
            assert equal (prepare-sudo-for-progress false false) false
        }
        with-env { YGG_MOCK_PKG_LOG: "", YGG_NONINTERACTIVE: "1" } {
            assert equal (prepare-sudo-for-progress true true) false
        }
    }
}

# regression: #14
export def test_format_pkg_failure_tail [] {
    assert equal (format-pkg-failure-tail "err line" "out line") "err line"
    assert equal (format-pkg-failure-tail "\x1b[31m   \x1b[0m\r\n" "out fallback") "out fallback"
    assert equal (format-pkg-failure-tail "" "\r\x1b[32m  -\r  \\\rFailed to install\nExit code: 1" --max-lines 2) "Failed to install\nExit code: 1"
    assert equal (format-pkg-failure-tail "1\n2\n3\n4\n5\n6\n7" "") "3\n4\n5\n6\n7"
    assert equal (format-pkg-failure-tail "" "") ""
}

# regression: #14
export def test_run_with_timeout_ok_codes [] {
    let src_dir = ($env.FILE_PWD | path join "../src" | path expand)
    let res = (^nu -I $src_dir -c 'use pkg.nu [run-with-timeout]; let r = (run-with-timeout ["nu" "-c" "exit 42"] 10 --label "test" --no-tty-progress --ok-codes [0, 42]); print $"EXIT=($r.exit_code)"' | complete)
    assert equal $res.exit_code 0 $res.stderr
    assert ($res.stdout | str contains "EXIT=42")
    assert ($res.stderr | str contains "[ok]")
    assert (not ($res.stderr | str contains "[fail]"))
}

# regression: #14
export def test_active_runtime_winget_warning [] {
    assert equal (active-runtime-winget-warning "Nushell.Nushell" { os: "linux", in_pwsh: true }) ""
    assert equal (active-runtime-winget-warning "Microsoft.PowerShell" { os: "linux", in_pwsh: true }) ""

    assert ((active-runtime-winget-warning "Nushell.Nushell" { os: "windows", in_pwsh: false }) | str contains "Nushell")
    assert ((active-runtime-winget-warning "nushell" { os: "windows", in_pwsh: false }) | str contains "Nushell")

    assert ((active-runtime-winget-warning "Microsoft.PowerShell" { os: "windows", in_pwsh: true }) | str contains "pwsh")
    assert ((active-runtime-winget-warning "Microsoft.PowerShell.Preview" { os: "windows", in_pwsh: true }) | str contains "pwsh")
    assert equal (active-runtime-winget-warning "Microsoft.PowerShell" { os: "windows", in_pwsh: false }) ""

    assert equal (active-runtime-winget-warning "Git.Git" { os: "windows", in_pwsh: true }) ""
}

# regression: #14
export def test_install_packages_failure_includes_exit_code_and_tail [] {
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        let m1 = ($home | path join "modules" "m")
        mkdir $m1
        'name = "m"
os = ["linux", "windows", "macos"]
[packages]
winget = ["Bad.Pkg"]' | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "windows", YGG_MOCK_PKG_LOG: $log, YGG_MOCK_PKG_FAIL: "winget:Bad.Pkg" } {
            let res = (install-packages $home (resolve-effective-plan $home))
            assert equal ($res.failed | length) 1
            let f = $res.failed.0
            assert equal $f.mgr "winget"
            assert equal $f.pkg "Bad.Pkg"
            assert equal $f.reason "error"
            assert equal $f.exit_code 1
            assert ($f.tail != "")
        }

        # Verify non-mock run-install-argv propagates exit_code and stdout fallback
        with-env { YGG_MOCK_PKG_LOG: "" } {
            let r = (run-install-argv "winget" ["nu" "-c" "print 'winget stdout err'; exit 23"] ["Bad.Pkg"] 10 --no-tty-progress)
            assert equal $r.ok false
            assert equal $r.exit_code 23
            assert equal (format-pkg-failure-tail $r.stderr $r.stdout) "winget stdout err"
        }
    }
}

# regression: #14
export def test_install_packages_skips_active_runtime_without_caching_hash [] {
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        let m1 = ($home | path join "modules" "m")
        mkdir $m1
        'name = "m"
os = ["linux", "windows", "macos"]
[packages]
winget = ["Nushell.Nushell", "Microsoft.PowerShell", "Git.Git"]' | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "windows", YGG_MOCK_PKG_LOG: $log, YGG_MOCK_ACTIVE_RUNTIME: "nu,pwsh" } {
            let plan = (resolve-effective-plan $home)
            let dry = (install-packages $home $plan --dry-run)
            assert equal $dry.warnings []
            assert equal ($dry.executed | length) 3

            let res = (install-packages $home $plan)
            assert equal $res.failed []
            assert equal $res.skipped []
            assert equal ($res.warnings | length) 2
            assert equal $res.warnings.0.source "pkg"
            let logged = (open --raw $log)
            assert ($logged | str contains "Git.Git")
            assert (not ($logged | str contains "Nushell.Nushell"))
            assert (not ($logged | str contains "Microsoft.PowerShell"))
            assert equal ((load-state $home).hashes? | default {} | get -o "pkg:winget") null
        }
    }
}

def write-mock-cli [bin_dir: string, name: string, sh_body: string, cmd_body: string]: nothing -> nothing {
    mkdir $bin_dir
    let sh_path = ($bin_dir | path join $name)
    $"#!/bin/sh\n($sh_body)\n" | save -f $sh_path
    if $nu.os-info.family != "windows" { ^chmod +x $sh_path }
    $"@echo off\r\nsetlocal\r\n($cmd_body)\r\n" | save -f $"($sh_path).cmd"
}

# regression: #23
export def test_probe_packages_mock_and_os_info [] {
    with-temp-ygg { |home|
        let log = ($home | path join "probe.log")
        let res = (with-env {
            YGG_HOST_OS_OVERRIDE: "cachyos",
            YGG_MOCK_PKG_LOG: $log,
            YGG_MOCK_PKG_UNKNOWN: "bad-pkg,node@22"
        } {
            probe-packages {
                pacman: ["ripgrep", "bad-pkg"],
                mise: ["node@22", "python@3.12"],
                winget: ["Git.Git"],
                cargo: ["fd-find"]
            }
        })
        assert (($res | where mgr == "pacman" and pkg == "ripgrep" | first).status == "ok")
        assert (($res | where mgr == "pacman" and pkg == "bad-pkg" | first).status == "not_found")
        # mise checks name before '@'
        assert (($res | where mgr == "mise" and pkg == "node@22" | first).status == "not_found")
        assert (($res | where mgr == "mise" and pkg == "python@3.12" | first).status == "ok")
        # winget unavailable on cachyos -> info
        assert (($res | where mgr == "winget" and pkg == "Git.Git" | first).status == "info")
        # cargo available everywhere over HTTP -> ok
        assert (($res | where mgr == "cargo" and pkg == "fd-find" | first).status == "ok")

        let logged = (open --raw $log)
        assert ($logged | str contains "probe pacman ripgrep")
        assert ($logged | str contains "probe pacman bad-pkg")
        assert ($logged | str contains "probe mise node@22")
        assert ($logged | str contains "probe mise python@3.12")
        assert ($logged | str contains "probe cargo fd-find")
        assert (not ($logged | str contains "winget"))

        # Check explicit --host-os, bare mise tool name in YGG_MOCK_PKG_UNKNOWN, and paru available on Windows
        let res_win = (with-env {
            YGG_MOCK_PKG_LOG: $log,
            YGG_MOCK_PKG_UNKNOWN: "node,missing-aur"
        } {
            probe-packages {
                mise: ["node@22"],
                paru: ["paru-bin", "missing-aur"],
                pacman: ["ripgrep"]
            } --host-os { os: "windows", distro: "windows", auto_scopes: ["windows"] }
        })
        assert equal ($res_win | where mgr == "mise" and pkg == "node@22" | first).status "not_found"
        assert equal ($res_win | where mgr == "paru" and pkg == "paru-bin" | first).status "ok"
        assert equal ($res_win | where mgr == "paru" and pkg == "missing-aur" | first).status "not_found"
        assert equal ($res_win | where mgr == "pacman" and pkg == "ripgrep" | first).status "info"
        assert equal ($KNOWN_PKG_MANAGERS | length) 12
    }
}

# regression: #23
export def test_probe_packages_cli_probes_and_missing_bin [] {
    with-temp-ygg { |home|
        let bin_dir = ($home | path join "mock-bin")
        write-mock-cli $bin_dir "pacman" '
if [ "$1" != "-Si" ]; then exit 2; fi
case "$2" in
  ripgrep) echo "Name : ripgrep"; exit 0 ;;
  missing-pkg) echo "error: package '\''missing-pkg'\'' was not found" >&2; exit 1 ;;
  err-pkg) echo "error: failed to synchronize all databases" >&2; exit 1 ;;
esac
exit 1
' '
if not "%~1"=="-Si" exit /b 2
if "%~2"=="ripgrep" (echo Name : ripgrep & exit /b 0)
if "%~2"=="missing-pkg" (echo error: package missing-pkg was not found 1>&2 & exit /b 1)
if "%~2"=="err-pkg" (echo error: failed to synchronize all databases 1>&2 & exit /b 1)
exit /b 1
'
        write-mock-cli $bin_dir "mise" '
if [ "$1" != "ls-remote" ]; then exit 2; fi
case "$2" in
  node) echo "20.0.0"; echo "22.0.0"; exit 0 ;;
  missing-tool) echo "mise ERROR no versions found" >&2; exit 1 ;;
  rate-limited) echo "HTTP status client error (403 Forbidden) rate limit exceeded" >&2; exit 1 ;;
esac
exit 1
' '
if not "%~1"=="ls-remote" exit /b 2
if "%~2"=="node" (echo 20.0.0 & echo 22.0.0 & exit /b 0)
if "%~2"=="missing-tool" (echo mise ERROR no versions found 1>&2 & exit /b 1)
if "%~2"=="rate-limited" (echo HTTP status client error ^(403 Forbidden^) rate limit exceeded 1>&2 & exit /b 1)
exit /b 1
'
        write-mock-cli $bin_dir "winget" '
if [ "$4" = "Git.Git" ]; then echo "Found Git"; exit 0; fi
if [ "$4" = "Bad.Pkg" ]; then echo "No package found matching input criteria." >&2; exit 1; fi
echo "Failed to update source" >&2; exit 2
' '
if "%~4"=="Git.Git" (echo Found Git & exit /b 0)
if "%~4"=="Bad.Pkg" (echo No package found matching input criteria. 1>&2 & exit /b 1)
echo Failed to update source 1>&2 & exit /b 2
'

        let clean_path = [$bin_dir]
        let res = (with-env {
            YGG_HOST_OS_OVERRIDE: "cachyos",
            YGG_MOCK_PKG_LOG: "",
            PATH: $clean_path,
            Path: $clean_path
        } {
            probe-packages {
                pacman: ["ripgrep", "missing-pkg", "err-pkg"],
                mise: ["node@22", "missing-tool@1", "rate-limited@1"],
                apt: ["curl"]
            }
        })
        assert equal ($res | where mgr == "pacman" and pkg == "ripgrep" | first).status "ok"
        assert equal ($res | where mgr == "pacman" and pkg == "missing-pkg" | first).status "not_found"
        assert equal ($res | where mgr == "pacman" and pkg == "err-pkg" | first).status "warn"
        assert equal ($res | where mgr == "mise" and pkg == "node@22" | first).status "ok"
        assert equal ($res | where mgr == "mise" and pkg == "missing-tool@1" | first).status "not_found"
        assert equal ($res | where mgr == "mise" and pkg == "rate-limited@1" | first).status "warn"
        assert equal ($res | where mgr == "apt" and pkg == "curl" | first).status "info"

        # Missing binary on PATH -> warn (never not_found)
        let res_missing = (with-env {
            YGG_HOST_OS_OVERRIDE: "fedora",
            YGG_MOCK_PKG_LOG: "",
            PATH: $clean_path,
            Path: $clean_path
        } {
            probe-packages { dnf: ["ripgrep"] }
        })
        assert equal ($res_missing | first).status "warn"
        assert (($res_missing | first).detail | str contains "dnf")

        # winget CLI classifications
        let res_win = (with-env {
            YGG_HOST_OS_OVERRIDE: "windows",
            YGG_MOCK_PKG_LOG: "",
            PATH: $clean_path,
            Path: $clean_path
        } {
            probe-packages { winget: ["Git.Git", "Bad.Pkg", "Net.Err"] }
        })
        assert equal ($res_win | where pkg == "Git.Git" | first).status "ok"
        assert equal ($res_win | where pkg == "Bad.Pkg" | first).status "not_found"
        assert equal ($res_win | where pkg == "Net.Err" | first).status "warn"
    }
}

# regression: #23
export def test_probe_packages_http_probes_and_network_errors [] {
    with-temp-ygg { |home|
        # Connection failure -> warn for all HTTP managers
        let res_err = (with-env {
            YGG_MOCK_PKG_LOG: "",
            YGG_PROBE_AUR_URL: "http://127.0.0.1:1/aur",
            YGG_PROBE_CARGO_URL: "http://127.0.0.1:1/cargo",
            YGG_PROBE_NPM_URL: "http://127.0.0.1:1/npm",
            YGG_PROBE_PYPI_URL: "http://127.0.0.1:1/pypi"
        } {
            probe-packages {
                paru: ["paru-bin"],
                cargo: ["fd-find"],
                pnpm: ["@biomejs/biome"],
                uv: ["ruff"]
            }
        })
        for row in $res_err {
            assert equal $row.status "warn"
        }

        # Real HTTP status 200 / 404 / 500 + AUR 50-chunking + User-Agent + URL encoding
        let py_candidates = (["python3", "python"] | where { |cand|
            (which $cand | is-not-empty) and (try { (^$cand -c "import http.server, json" | complete).exit_code == 0 } catch { false })
        })
        if ($py_candidates | is-empty) {
            return
        }
        let py = ($py_candidates | first)

        let port_file = ($home | path join "port.txt")
        let srv_py = ($home | path join "srv.py")
        '
import json, sys, threading, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port_file = sys.argv[1]
aur_calls = []
stop_event = threading.Event()

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/__shutdown":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"aur_calls": aur_calls}).encode())
            stop_event.set()
            return
        if parsed.path == "/aur":
            qs = urllib.parse.parse_qs(parsed.query)
            args = qs.get("arg[]", [])
            aur_calls.append(len(args))
            results = [{"Name": a} for a in args if a != "missing-aur"]
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"results": results}).encode())
            return
        if parsed.path.startswith("/cargo/"):
            ua = self.headers.get("User-Agent", "")
            if ua != "ygg-lint":
                self.send_response(400)
                self.end_headers()
                return
            name = parsed.path[len("/cargo/"):]
            code = 200 if name == "fd-find" else (500 if name == "err-crate" else 404)
            self.send_response(code)
            self.end_headers()
            return
        if parsed.path.startswith("/npm/"):
            raw_tail = parsed.path[len("/npm/"):]
            code = 200 if raw_tail == "%40biomejs%2Fbiome" else 404
            self.send_response(code)
            self.end_headers()
            return
        if parsed.path.startswith("/pypi/"):
            code = 200 if parsed.path == "/pypi/ruff/json" else 404
            self.send_response(code)
            self.end_headers()
            return
        self.send_response(404)
        self.end_headers()
    def log_message(self, *args):
        pass

srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as f:
    f.write(str(srv.server_address[1]))
t = threading.Thread(target=srv.serve_forever, daemon=True)
t.start()
stop_event.wait(timeout=30)
srv.shutdown()
srv.server_close()
' | save -f $srv_py

        let jid = (job spawn { ^$py $srv_py $port_file | complete | ignore })
        try {
            mut port = ""
            for _ in 1..40 {
                if ($port_file | path type) == "file" {
                    let p = (open --raw $port_file | str trim)
                    if $p != "" {
                        $port = $p
                        break
                    }
                }
                sleep 50ms
            }
            assert ($port != "") "HTTP test server did not start"
            let base = $"http://127.0.0.1:($port)"

            let aur_pkgs = (1..52 | each { |i| $"pkg-($i)" } | append "missing-aur")
            let res_http = (with-env {
                YGG_MOCK_PKG_LOG: "",
                YGG_PROBE_AUR_URL: $"($base)/aur",
                YGG_PROBE_CARGO_URL: $"($base)/cargo",
                YGG_PROBE_NPM_URL: $"($base)/npm",
                YGG_PROBE_PYPI_URL: $"($base)/pypi"
            } {
                probe-packages {
                    paru: $aur_pkgs,
                    cargo: ["fd-find", "bad-crate", "err-crate"],
                    pnpm: ["@biomejs/biome", "bad-npm"],
                    uv: ["ruff", "bad-pypi"]
                }
            })

            assert equal ($res_http | where mgr == "paru" and pkg == "pkg-1" | first).status "ok"
            assert equal ($res_http | where mgr == "paru" and pkg == "pkg-52" | first).status "ok"
            assert equal ($res_http | where mgr == "paru" and pkg == "missing-aur" | first).status "not_found"
            assert equal ($res_http | where mgr == "cargo" and pkg == "fd-find" | first).status "ok"
            assert equal ($res_http | where mgr == "cargo" and pkg == "bad-crate" | first).status "not_found"
            assert equal ($res_http | where mgr == "cargo" and pkg == "err-crate" | first).status "warn"
            assert equal ($res_http | where mgr == "pnpm" and pkg == "@biomejs/biome" | first).status "ok"
            assert equal ($res_http | where mgr == "pnpm" and pkg == "bad-npm" | first).status "not_found"
            assert equal ($res_http | where mgr == "uv" and pkg == "ruff" | first).status "ok"
            assert equal ($res_http | where mgr == "uv" and pkg == "bad-pypi" | first).status "not_found"

            let stats = (http get --max-time 5sec $"($base)/__shutdown")
            assert equal $stats.aur_calls [50, 3]
        } catch { |e|
            try { job kill $jid | ignore } catch { }
            error make { msg: ($e.rendered? | default $e.msg) }
        }
        for _ in 1..20 {
            if (job list | where id == $jid | is-empty) { break }
            sleep 25ms
        }
        try { job kill $jid | ignore } catch { }
    }
}

# regression: #23
export def test_probe_packages_all_cli_classifications_and_isolation [] {
    let src_dir = ($env.FILE_PWD | path join "../src" | path expand)
    assert equal (probe-packages {}) []

    with-temp-ygg { |home|
        let log = ($home | path join "probe.log")
        # Mock YGG_MOCK_PKG_MISSING for CLI managers
        let res_mock_miss = (with-env {
            YGG_HOST_OS_OVERRIDE: "cachyos",
            YGG_MOCK_PKG_LOG: $log,
            YGG_MOCK_PKG_MISSING: "pacman"
        } {
            probe-packages { pacman: ["ripgrep"], cargo: ["fd-find"] }
        })
        assert equal ($res_mock_miss | where mgr == "pacman" | first).status "warn"
        assert equal ($res_mock_miss | where mgr == "cargo" | first).status "ok"

        let bin_dir = ($home | path join "cli-bin")
        write-mock-cli $bin_dir "scoop" '
case "$2" in
  git) echo "Name : git"; exit 0 ;;
  bad-scoop) echo "Could not find manifest for bad-scoop"; exit 0 ;;
  empty-scoop) exit 0 ;;
  net-scoop) echo "fatal: unable to access connection timeout" >&2; exit 1 ;;
esac
' '
if "%~2"=="git" (echo Name : git & exit /b 0)
if "%~2"=="bad-scoop" (echo Could not find manifest for bad-scoop & exit /b 0)
if "%~2"=="empty-scoop" (exit /b 0)
if "%~2"=="net-scoop" (echo fatal: unable to access connection timeout 1>&2 & exit /b 1)
'
        write-mock-cli $bin_dir "apt-cache" '
case "$2" in
  curl) echo "Package: curl"; exit 0 ;;
  missing-apt) echo "E: No packages found" >&2; exit 100 ;;
  broken-apt) echo "E: Lock open failed" >&2; exit 2 ;;
esac
' '
if "%~2"=="curl" (echo Package: curl & exit /b 0)
if "%~2"=="missing-apt" (echo E: No packages found 1>&2 & exit /b 100)
if "%~2"=="broken-apt" (echo E: Lock open failed 1>&2 & exit /b 2)
'
        write-mock-cli $bin_dir "dnf" '
case "$3" in
  ripgrep) echo "Name : ripgrep"; exit 0 ;;
  missing-dnf) echo "Error: No matching Packages to list" >&2; exit 1 ;;
  err-dnf) echo "Failed to download metadata" >&2; exit 1 ;;
esac
' '
if "%~3"=="ripgrep" (echo Name : ripgrep & exit /b 0)
if "%~3"=="missing-dnf" (echo Error: No matching Packages to list 1>&2 & exit /b 1)
if "%~3"=="err-dnf" (echo Failed to download metadata 1>&2 & exit /b 1)
'
        write-mock-cli $bin_dir "zypper" '
case "$3" in
  git) echo "Information for package git:"; exit 0 ;;
  missing-zyp) echo "package '\''missing-zyp'\'' not found." >&2; exit 104 ;;
  err-zyp) echo "System management is locked" >&2; exit 7 ;;
esac
' '
if "%~3"=="git" (echo Information for package git: & exit /b 0)
if "%~3"=="missing-zyp" (echo package missing-zyp not found. 1>&2 & exit /b 104)
if "%~3"=="err-zyp" (echo System management is locked 1>&2 & exit /b 7)
'
        write-mock-cli $bin_dir "brew" '
case "$2" in
  bat) echo "bat: stable 0.24.0"; exit 0 ;;
  missing-brew) echo "Error: No available formula with the name \"missing-brew\"" >&2; exit 1 ;;
  err-brew) echo "curl: (6) Could not resolve host" >&2; exit 1 ;;
esac
' '
if "%~2"=="bat" (echo bat: stable 0.24.0 & exit /b 0)
if "%~2"=="missing-brew" (echo Error: No available formula with the name missing-brew 1>&2 & exit /b 1)
if "%~2"=="err-brew" (echo curl: ^(6^) Could not resolve host 1>&2 & exit /b 1)
'

        let clean_path = [$bin_dir]
        let r_scoop = (with-env { YGG_HOST_OS_OVERRIDE: "windows", YGG_MOCK_PKG_LOG: "", PATH: $clean_path, Path: $clean_path } {
            probe-packages { scoop: ["git", "bad-scoop", "empty-scoop", "net-scoop"] }
        })
        assert equal ($r_scoop | where pkg == "git" | first).status "ok"
        assert equal ($r_scoop | where pkg == "bad-scoop" | first).status "not_found"
        assert equal ($r_scoop | where pkg == "empty-scoop" | first).status "not_found"
        assert equal ($r_scoop | where pkg == "net-scoop" | first).status "warn"

        let r_apt = (with-env { YGG_HOST_OS_OVERRIDE: "ubuntu", YGG_MOCK_PKG_LOG: "", PATH: $clean_path, Path: $clean_path } {
            probe-packages { apt: ["curl", "missing-apt", "broken-apt"] }
        })
        assert equal ($r_apt | where pkg == "curl" | first).status "ok"
        assert equal ($r_apt | where pkg == "missing-apt" | first).status "not_found"
        assert equal ($r_apt | where pkg == "broken-apt" | first).status "warn"

        let r_dnf = (with-env { YGG_HOST_OS_OVERRIDE: "fedora", YGG_MOCK_PKG_LOG: "", PATH: $clean_path, Path: $clean_path } {
            probe-packages { dnf: ["ripgrep", "missing-dnf", "err-dnf"] }
        })
        assert equal ($r_dnf | where pkg == "ripgrep" | first).status "ok"
        assert equal ($r_dnf | where pkg == "missing-dnf" | first).status "not_found"
        assert equal ($r_dnf | where pkg == "err-dnf" | first).status "warn"

        let r_zyp = (with-env { YGG_HOST_OS_OVERRIDE: "opensuse", YGG_MOCK_PKG_LOG: "", PATH: $clean_path, Path: $clean_path } {
            probe-packages { zypper: ["git", "missing-zyp", "err-zyp"] }
        })
        assert equal ($r_zyp | where pkg == "git" | first).status "ok"
        assert equal ($r_zyp | where pkg == "missing-zyp" | first).status "not_found"
        assert equal ($r_zyp | where pkg == "err-zyp" | first).status "warn"

        let r_brew = (with-env { YGG_HOST_OS_OVERRIDE: "macos", YGG_MOCK_PKG_LOG: "", PATH: $clean_path, Path: $clean_path } {
            probe-packages { brew: ["bat", "missing-brew", "err-brew"] }
        })
        assert equal ($r_brew | where pkg == "bat" | first).status "ok"
        assert equal ($r_brew | where pkg == "missing-brew" | first).status "not_found"
        assert equal ($r_brew | where pkg == "err-brew" | first).status "warn"

        # Verify zero stderr output and zero ygg-proc-* temp files in isolated TMPDIR
        let iso_tmp = ($home | path join "iso-tmp")
        mkdir $iso_tmp
        let sub_path = (($env.PATH? | default $env.Path? | default []) | prepend $bin_dir | str join (char esep))
        let sub = (with-env {
            TMPDIR: $iso_tmp,
            TEMP: $iso_tmp,
            TMP: $iso_tmp,
            YGG_HOST_OS_OVERRIDE: "ubuntu",
            YGG_MOCK_PKG_LOG: "",
            PATH: $sub_path,
            Path: $sub_path
        } {
            ^($nu.current-exe) -I $src_dir -c 'use pkg.nu [probe-packages]; let res = (probe-packages { apt: ["curl"] }); print ($res | to json -r)' | complete
        })
        assert equal $sub.exit_code 0 $sub.stderr
        assert equal ($sub.stderr | str trim) ""
        assert equal ($sub.stdout | from json | first).status "ok" $sub.stdout
        assert equal (ls $iso_tmp | where { |f| ($f.name | path basename) starts-with "ygg-proc-" } | length) 0

        # Unknown package manager returns "warn" (not "info") in both normal and mock modes
        let res_unknown_normal = (with-env { YGG_MOCK_PKG_LOG: "" } {
            probe-packages { aptget: ["foo"] }
        })
        assert equal ($res_unknown_normal | length) 1
        assert equal $res_unknown_normal.0.mgr "aptget"
        assert equal $res_unknown_normal.0.pkg "foo"
        assert equal $res_unknown_normal.0.status "warn"
        assert ($res_unknown_normal.0.detail | str contains "unknown package manager")

        let unk_log = ($home | path join "unknown-mgr.log")
        let res_unknown_mock = (with-env { YGG_MOCK_PKG_LOG: $unk_log } {
            probe-packages { aptget: ["foo"] }
        })
        assert equal ($res_unknown_mock | length) 1
        assert equal $res_unknown_mock.0.status "warn"
        assert ($res_unknown_mock.0.detail | str contains "unknown package manager")
        assert (not ($unk_log | path exists))
    }
}
