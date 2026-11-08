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
