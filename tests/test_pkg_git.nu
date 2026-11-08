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
os = ["linux"]
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
os = ["linux"]
[packages]
pacman = ["curl"]' | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", YGG_SANDBOX: "/tmp/sb" } {
            let res = (install-packages (resolve-effective-plan $home) --sandbox "/tmp/sb")
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
os = ["linux"]
[packages]
pacman = ["curl"]' | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: $log, YGG_SANDBOX: "/tmp/sb" } {
            let res = (install-packages (resolve-effective-plan $home) --sandbox "/tmp/sb")
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
os = ["linux"]
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
os = ["linux"]
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
os = ["linux"]
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
        $"name = \"demo\"\nos = [\"linux\", \"cachyos\"]\n" | save -f ($work_up | path join "ygg.toml")
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
        let content = (open --raw ($cloned | path join "app.conf"))
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
        $"name = \"demo\"\nos = [\"linux\", \"cachyos\"]\n" | save -f ($work_up | path join "ygg.toml")
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

        let content = (open --raw ($cloned | path join "app.conf"))
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
            assert (glob ($tmp_root | path join "clone-*") | is-empty)

            # 4. --force replaces it; the dirty tree goes to .state/backups, not deleted
            add-module $home $bare --force | ignore
            assert equal (open --raw ($mod_dir | path join "file.txt")) "test content\n"
            let saved = (glob ($home | path join ".state" "backups" "**" "guarded" "file.txt"))
            assert equal ($saved | length) 1
            assert equal (open --raw ($saved | first)) "dirty change\n"
            assert (glob ($tmp_root | path join "clone-*") | is-empty)
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
