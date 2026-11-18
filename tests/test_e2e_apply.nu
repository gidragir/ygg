use std/assert
use ../src/state.nu [ensure-ygg-dirs]
use ../src/link.nu [is-link-or-junction]
use ../scripts/release.nu [read-ygg-version]
use helpers.nu [with-temp-ygg, test-link-dir, test-dangling-link, snapshot-all]

export def test_apply_refuses_prune_all_without_force [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "my-mod")
        mkdir ($mod_src | path join "conf")
        "key = val" | save -f ($mod_src | path join "conf" "app.conf")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_MOCK_PKG_LOG: ($home | path join "pkg.log") } {
            cd $mod_src
            ^nu $ygg_bin init "my-mod" --os "linux,windows,macos,cachyos"
            "[links]\nconf = \"~/.config/conf\"\n" | save --append ($mod_src | path join "ygg.toml")
            ^nu $ygg_bin add $mod_src

            let target_link = ($sb | path join ".config" "conf")
            assert ($target_link | path exists)

            let state_file = ($home | path join ".state" "state.json")
            let initial_state = (open $state_file)
            assert (($initial_state.links | columns | length) > 0)

            # 1. Broken host.toml -> exit_code != 0, link exists, state.links unmodified
            let broken_toml = "[[modules\nname = invalid\n"
            $broken_toml | save -f ($home | path join "host.toml")

            let res_broken = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert ($res_broken.exit_code != 0)
            assert ($target_link | path exists)
            let state_after_broken = (open $state_file)
            assert equal $state_after_broken.links $initial_state.links

            # 2. modules = [] -> exit_code != 0, link exists, stderr contains --force
            "modules = []\n" | save -f ($home | path join "host.toml")
            let res_empty = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert ($res_empty.exit_code != 0)
            assert ($target_link | path exists)
            assert ($res_empty.stderr | str contains "--force")

            # 3. modules = [] + apply --force -> exit_code == 0, link pruned
            let res_force = (^nu $ygg_bin apply --force --sandbox $sb | complete)
            assert equal $res_force.exit_code 0
            assert (not ($target_link | path exists))
            let state_after_force = (open $state_file)
            assert equal ($state_after_force.links | columns | length) 0
        }
    }
}

export def test_apply_fails_after_completing_when_package_manager_fails [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "pkg-fail-mod")
        mkdir ($mod_src | path join "conf")
        "key = val" | save -f ($mod_src | path join "conf" "app.conf")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env {
            YGG_HOME: $home,
            YGG_SANDBOX: $sb,
            YGG_HOST_OS_OVERRIDE: "cachyos",
            YGG_MOCK_PKG_LOG: ($home | path join "pkg.log"),
            YGG_MOCK_PKG_FAIL: "pacman"
        } {
            cd $mod_src
            ^nu $ygg_bin init "pkg-fail-mod" --os "linux,windows,macos,cachyos"
            "[packages]\npacman = [\"curl\"]\n\n[links]\nconf = \"~/.config/conf\"\n" | save --append ($mod_src | path join "ygg.toml")

            let mod_target = ($home | path join "modules" "pkg-fail-mod")
            mkdir ($home | path join "modules")
            test-link-dir $mod_src $mod_target
            "[[modules]]\nname = \"pkg-fail-mod\"\n" | save -f ($home | path join "host.toml")

            let res = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert ($res.exit_code != 0)
            assert ($res.stderr | str contains "pacman")
            assert not ($res.stdout | str contains "Applied")
            let target_link = ($sb | path join ".config" "conf")
            assert ($target_link | path exists)
        }
    }
}



export def test_ygg_diff_and_dry_run_plan_output [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "plan-mod")
        mkdir ($mod_src | path join "niri") ($sb | path join ".config")
        "layout {}\n" | save -f ($mod_src | path join "niri" "config.kdl")
        "add_newline = false\n" | save -f ($mod_src | path join "starship.toml")
        "host-version\n" | save -f ($sb | path join ".config" "starship.toml")
        'name = "plan-mod"
os = ["linux", "windows", "macos", "cachyos"]
[links]
niri = "~/.config/niri"
"starship.toml" = "~/.config/starship.toml"
' | save -f ($mod_src | path join "ygg.toml")
        mkdir ($home | path join "modules")
        test-link-dir $mod_src ($home | path join "modules" "plan-mod")
        "[[modules]]\nname = \"plan-mod\"\n" | save -f ($home | path join "host.toml")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let niri = ($sb | path join ".config" "niri")
        let star = ($sb | path join ".config" "starship.toml")
        let host_os_ovr = if $nu.os-info.family == "windows" { "windows" } else { "cachyos" }
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: $host_os_ovr, YGG_MOCK_PKG_LOG: ($home | path join "pkg.log") } {
            # 1. diff and apply --dry-run show the plan and change nothing
            for args in [["diff"], ["apply", "--dry-run"]] {
                let before = (snapshot-all $home $sb)
                let res = (^nu $ygg_bin ...$args --sandbox $sb | complete)
                assert equal $res.exit_code 0 $res.stderr
                let out_lines = ($res.stdout | lines | each { |l| $l | str trim })
                assert ($out_lines | any { |l| ($l | str starts-with "LINK") and ($l | str contains $niri) })
                assert ($out_lines | any { |l| ($l | str starts-with "BACKUP_REPLACE") and ($l | str contains $star) })
                assert ($res.stdout | str contains "Plan: 2 change(s), 0 unchanged across 1 module(s). No changes made.")
                assert (not ($res.stdout | str contains "Applied"))
                assert equal (snapshot-all $home $sb) $before
            }

            # 2. Real apply prints the backup notice; the file is at the reported path
            let ap = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert equal $ap.exit_code 0 $ap.stderr
            let notice = ($ap.stderr | lines | where { |l| $l | str starts-with ("[ygg] Backed up existing '" + $star + "'") })
            assert equal ($notice | length) 1
            let bkp = ($notice | first | parse --regex "-> '(?P<p>.+)'$" | get 0.p)
            assert equal (open --raw $bkp) "host-version\n"
            assert equal ($star | path type) (if $nu.os-info.family == "windows" { "file" } else { "symlink" })

            # 3. diff after apply hides OK lines by default, --all shows them; no change on disk
            let before2 = (snapshot-all $home $sb)
            let d1 = (^nu $ygg_bin diff --sandbox $sb | complete)
            assert equal $d1.exit_code 0 $d1.stderr
            assert (not ($d1.stdout | lines | any { |l| $l | str trim | str starts-with "OK" }))
            assert ($d1.stdout | str contains "Plan: 0 change(s), 2 unchanged across 1 module(s). No changes made.")
            let d2 = (^nu $ygg_bin diff --all --sandbox $sb | complete)
            assert equal $d2.exit_code 0 $d2.stderr
            let ok_lines = ($d2.stdout | lines | each { |l| $l | str trim } | where { |l| $l | str starts-with "OK" })
            assert equal ($ok_lines | length) 2
            assert ($ok_lines | any { |l| $l | str contains $niri })
            assert equal (snapshot-all $home $sb) $before2
        }
    }
}

export def test_apply_exits_1_when_a_link_fails [] {
    if ($nu.os-info.family == "windows") or ((^id -u | str trim) == "0") {
        return
    }
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "fail-mod")
        let locked = ($sb | path join ".config" "locked")
        mkdir $mod_src $locked
        "a\n" | save -f ($mod_src | path join "a.txt")
        "b\n" | save -f ($mod_src | path join "b.txt")
        'name = "fail-mod"
os = ["linux", "windows", "macos", "cachyos"]
[links]
"a.txt" = "~/.config/locked/a.txt"
"b.txt" = "~/.config/b.txt"
' | save -f ($mod_src | path join "ygg.toml")
        mkdir ($home | path join "modules")
        ^ln -s $mod_src ($home | path join "modules" "fail-mod")
        "[[modules]]\nname = \"fail-mod\"\n" | save -f ($home | path join "host.toml")
        ^chmod 555 $locked

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let res = (with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: ($home | path join "pkg.log") } {
            ^nu $ygg_bin apply --sandbox $sb | complete
        })
        ^chmod 755 $locked
        assert ($res.exit_code != 0)
        assert ($res.stderr | str contains ($locked | path join "a.txt"))
        # Other links are still applied
        assert equal (($sb | path join ".config" "b.txt") | path type) "symlink"
    }
}

# regression: #22
export def test_apply_locked_target_aborts_before_mutations [] {
    with-temp-ygg { |home|
        let ygg_home = ($home | path join "ygg")
        let sb = ($home | path join "sb")
        let pkg_log = ($home | path join "pkg.log")
        let mod_src = ($ygg_home | path join "modules" "lockmod")
        mkdir $ygg_home $sb ($mod_src | path join "cfg" "app") ($sb | path join ".config" "app")
        "mod_state\n" | save -f ($mod_src | path join "cfg" "app" "mod.txt")
        "host_state" | save -f ($sb | path join ".config" "app" "host.txt")
        'name = "lockmod"
os = ["linux", "windows", "macos", "cachyos"]
[packages]
pacman = ["curl"]
[links]
"cfg/app" = "~/.config/app"
' | save -f ($mod_src | path join "ygg.toml")
        "[[modules]]\nname = \"lockmod\"\n" | save -f ($ygg_home | path join "host.toml")

        let locked_dest = ($sb | path join ".config" "app")
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let res = (with-env {
            YGG_HOME: $ygg_home
            YGG_SANDBOX: $sb
            YGG_HOST_OS_OVERRIDE: "cachyos"
            YGG_MOCK_PKG_LOG: $pkg_log
            YGG_MOCK_LOCKED_PATHS: $locked_dest
        } { ^nu $ygg_bin apply --force --sandbox $sb | complete })
        assert ($res.exit_code != 0)
        assert ($res.stderr | str contains "(target_locked)")
        assert ($res.stderr | str contains "re-run ygg apply")
        assert (not ($pkg_log | path exists))
        assert equal (open --raw ($sb | path join ".config" "app" "host.txt")) "host_state"

        let res_dry = (with-env {
            YGG_HOME: $ygg_home
            YGG_SANDBOX: $sb
            YGG_HOST_OS_OVERRIDE: "cachyos"
            YGG_MOCK_PKG_LOG: $pkg_log
            YGG_MOCK_LOCKED_PATHS: $locked_dest
        } { ^nu $ygg_bin apply --force --dry-run --sandbox $sb | complete })
        assert equal $res_dry.exit_code 0 $res_dry.stderr
        assert (not ($res_dry.stderr | str contains "target_locked"))
    }
}

export def test_apply_summary_is_last_and_counts_hook_warnings [] {
    with-temp-ygg { |home|
        let ygg_home = ($home | path join "ygg")
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "hm")
        mkdir $ygg_home $sb ($mod_src | path join "cfg")
        "modules = []\n" | save -f ($ygg_home | path join "host.toml")
        "a = 1\n" | save -f ($mod_src | path join "cfg" "a.conf")
        'name = "hm"
os = ["linux", "windows", "macos", "cachyos"]
[links."cfg/a.conf"]
target = "~/.config/hm/a.conf"
on_change = "reload-a"
' | save -f ($mod_src | path join "ygg.toml")
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let log1 = ($home | path join "add.log")
        with-env {
            YGG_HOME: $ygg_home
            YGG_SANDBOX: $sb
            YGG_HOST_OS_OVERRIDE: "cachyos"
            YGG_MOCK_PKG_LOG: ($home | path join "pkg.log")
            YGG_MOCK_HOOK_FAIL: "reload-a"
            YGG_NONINTERACTIVE: "1"
        } {
            ^nu $ygg_bin add $mod_src --sandbox $sb o+e> $log1
            let out = (open --raw $log1 | lines)
            let i_fin = ($out | enumerate | where { |it| $it.item | str contains "[finalize]" } | get -o 0.index | default (-1))
            let i_app = ($out | enumerate | where { |it| $it.item == "Applied 1 module(s) with 1 warning(s)." } | get -o 0.index | default (-1))
            assert ($i_fin >= 0) "Expected [finalize] in output"
            assert ($i_app > $i_fin) "Expected Applied summary after [finalize]"
            let full = (open --raw $log1)
            assert ($full | str contains "  - on_change 'cfg/a.conf' (hm): mock hook failure")
            assert ($full | str contains "`ygg remove hm` to roll back")

            let res2 = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert equal $res2.exit_code 0
            assert equal ($res2.stdout | lines | last) "Applied 1 module(s) with 1 warning(s)."
            assert not ($res2.stderr | str contains "ygg remove")
        }
    }
}

export def test_apply_link_error_prints_no_applied [] {
    with-temp-ygg { |home|
        let ygg_home = ($home | path join "ygg")
        let sb = ($home | path join "sb")
        let mod_src = ($ygg_home | path join "modules" "hm")
        mkdir $ygg_home $sb ($mod_src | path join "cfg")
        "a = 1\n" | save -f ($mod_src | path join "cfg" "a.conf")
        'name = "hm"
os = ["linux", "windows", "macos", "cachyos"]
[links]
"cfg/a.conf" = "~/.config/hm/a.conf"
' | save -f ($mod_src | path join "ygg.toml")
        "[[modules]]\nname = \"hm\"\n" | save -f ($ygg_home | path join "host.toml")
        # On Windows, a regular file at ~/.config/hm makes mkdir of parent fail in apply-links.
        # On Unix, chmod 555 on ~/.config/hm makes ln -s fail in apply-links (a regular file would ENOTDIR earlier in compute-link-ops).
        let hm_dir = ($sb | path join ".config" "hm")
        mkdir ($sb | path join ".config")
        if $nu.os-info.family == "windows" {
            "blocker" | save -f $hm_dir
        } else {
            mkdir $hm_dir
            ^chmod 555 $hm_dir
        }

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let res = (with-env {
            YGG_HOME: $ygg_home
            YGG_SANDBOX: $sb
            YGG_HOST_OS_OVERRIDE: "cachyos"
            YGG_MOCK_PKG_LOG: ($home | path join "pkg.log")
        } {
            ^nu $ygg_bin apply --sandbox $sb | complete
        })
        if $nu.os-info.family != "windows" {
            ^chmod 755 $hm_dir
        }
        assert ($res.exit_code != 0)
        assert ($res.stderr | str contains "[ygg] Error: failed to link")
        assert not ($res.stdout | str contains "Applied")
    }
}

# Create a bare git repo in `home` whose single commit holds `files` (relative path -> content)
export def test_cli_pkg_selection_cache_and_failed_package_names [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let pkg_log = ($home | path join "pkg.log")
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let mod_src = ($home | path join "pkg-mod")
        mkdir $mod_src ($home | path join "modules") $sb
        'name = "pkg-mod"
os = ["linux", "windows", "macos", "cachyos"]
[packages]
pacman = ["curl"]
cargo = ["bat"]
mise = ["ripgrep"]
' | save -f ($mod_src | path join "ygg.toml")
        test-link-dir $mod_src ($home | path join "modules" "pkg-mod")
        "[[modules]]\nname = \"pkg-mod\"\n" | save -f ($home | path join "host.toml")
        let log_lines = { || if ($pkg_log | path exists) { open --raw $pkg_log | lines | where { |l| $l != "" } } else { [] } }

        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: $pkg_log } {
            # --pkg with --skip-packages is rejected before anything runs
            let e1 = (^nu $ygg_bin apply --pkg mise --skip-packages --sandbox $sb | complete)
            assert ($e1.exit_code != 0)
            assert ($e1.stderr | str contains "--skip-packages")
            assert equal (do $log_lines) []

            # diff --pkg shows only the selected manager
            let d1 = (^nu $ygg_bin diff --pkg cargo --sandbox $sb | complete)
            assert equal $d1.exit_code 0 $d1.stderr
            let pkg1 = ($d1.stdout | lines | each { |l| $l | str trim } | where { |l| $l starts-with "PKG" })
            assert equal ($pkg1 | length) 1
            assert ($pkg1.0 | str contains "cargo install bat")

            # First apply installs everything, the second one skips cached managers
            let a1 = (^nu $ygg_bin apply --pkg-timeout 30 --sandbox $sb | complete)
            assert equal $a1.exit_code 0 $a1.stderr
            assert ((do $log_lines) | any { |l| $l == "cargo install bat" })
            assert ((do $log_lines) | any { |l| $l | str contains "mise use" })
            rm -f $pkg_log
            let a2 = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert equal $a2.exit_code 0 $a2.stderr
            assert (not ((do $log_lines) | any { |l| $l | str contains "cargo" }))
            assert ((do $log_lines) | any { |l| $l | str contains "pacman" })

            let d2 = (^nu $ygg_bin diff --sandbox $sb | complete)
            assert ($d2.stdout | lines | any { |l| ($l | str trim | str starts-with "PKG") and ($l | str contains "cargo SKIP (cached)") })

            # --refresh-packages bypasses the cache
            rm -f $pkg_log
            let a3 = (^nu $ygg_bin apply --refresh-packages --sandbox $sb | complete)
            assert equal $a3.exit_code 0 $a3.stderr
            assert ((do $log_lines) | any { |l| $l == "cargo install bat" })
        }

        # Failing package names are listed in the final error
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: $pkg_log, YGG_MOCK_PKG_FAIL: "cargo:bat" } {
            let f = (^nu $ygg_bin apply --pkg cargo --sandbox $sb | complete)
            assert ($f.exit_code != 0)
            assert ($f.stderr | str contains "cargo")
            assert ($f.stderr | str contains "bat")
            assert not ($f.stdout | str contains "Applied")
        }
    }
}

export def test_apply_runs_on_change_hooks_and_dry_run_plans_them [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "hook-mod")
        mkdir $mod_src
        "k = 1\n" | save -f ($mod_src | path join "app.toml")
        'name = "hook-mod"
os = ["linux", "windows", "macos", "cachyos"]
[links."app.toml"]
target = "~/.config/app/app.toml"
on_change = "app msg reload"
' | save -f ($mod_src | path join "ygg.toml")
        mkdir ($home | path join "modules")
        test-link-dir $mod_src ($home | path join "modules" "hook-mod")
        "[[modules]]\nname = \"hook-mod\"\n" | save -f ($home | path join "host.toml")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let log = ($home | path join "pkg.log")
        let host_os_ovr = if $nu.os-info.family == "windows" { "windows" } else { "cachyos" }
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: $host_os_ovr, YGG_MOCK_PKG_LOG: $log } {
            let before = (snapshot-all $home $sb)
            let dry = (^nu $ygg_bin apply --dry-run --sandbox $sb | complete)
            assert equal $dry.exit_code 0 $dry.stderr
            assert ($dry.stdout | lines | any { |l| ($l | str trim | str starts-with "HOOK") and ($l | str contains "app msg reload") })
            assert equal (snapshot-all $home $sb) $before
            assert (not ($log | path exists))

            let ap = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert equal $ap.exit_code 0 $ap.stderr
            assert equal (open --raw $log | lines | where { |l| $l | str starts-with "hook: " }) ["hook: app msg reload"]
            let hashes = (open ($home | path join ".state" "state.json") | get hashes)
            assert (($hashes | get -o "on_change:hook-mod:app.toml" | default "") != "")

            # Second apply: unchanged -> the hook does not run again
            let ap2 = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert equal $ap2.exit_code 0 $ap2.stderr
            assert equal (open --raw $log | lines | where { |l| $l | str starts-with "hook: " } | length) 1
        }
    }
}

export def test_journal_transaction_apply_lifecycle_and_warning [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "wal-mod")
        mkdir $mod_src
        'name = "wal-mod"
os = ["linux", "windows", "macos", "cachyos"]
[links]
"test.conf" = "~/.config/test.conf"
' | save -f ($mod_src | path join "ygg.toml")
        "wal-content\n" | save -f ($mod_src | path join "test.conf")
        mkdir ($home | path join "modules")
        test-link-dir $mod_src ($home | path join "modules" "wal-mod")
        "[[modules]]\nname = \"wal-mod\"\n" | save -f ($home | path join "host.toml")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb } {
            # 1. Normal apply cleans up journal on success
            let ap = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert equal $ap.exit_code 0 $ap.stderr
            assert (not ($home | path join ".state" "journal.json" | path exists))

            # 2. Simulate interrupted transaction in journal.json (v1 format without version)
            let jfile = ($home | path join ".state" "journal.json")
            {
                timestamp: "2026-11-08T12:00:00Z",
                plan_hash: "dummyhash",
                steps: {
                    packages: "COMMITTED",
                    links: "IN_PROGRESS"
                }
            } | to json | save -f $jfile

            # 3. ygg doctor detects interrupted journal
            let doc_res = (^nu $ygg_bin doctor --json --sandbox $sb | complete)
            assert equal $doc_res.exit_code 1
            let findings = ($doc_res.stdout | from json)
            let wal_errors = ($findings | where check == "journal_interrupted")
            assert equal ($wal_errors | length) 1
            assert equal ($wal_errors | first | get severity) "error"

            # 4. ygg apply warns about interrupted transaction and recovers cleanly
            let resume_res = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert equal $resume_res.exit_code 0 $resume_res.stderr
            assert ($resume_res.stderr | str contains "Recovering:")
            assert (not ($jfile | path exists)) "Journal must be removed after successful apply"

            # 5. ygg doctor is clean again
            let doc_clean = (^nu $ygg_bin doctor --json --sandbox $sb | complete)
            assert equal $doc_clean.exit_code 0
            let findings_clean = ($doc_clean.stdout | from json)
            assert equal ($findings_clean | where check == "journal_interrupted" | length) 0
        }
    }
}

export def test_apply_failure_marks_journal_failed_and_recovers [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "fail-setup-mod")
        mkdir $mod_src
        'name = "fail-setup-mod"
os = ["linux", "windows", "macos", "cachyos"]
[links]
"test.conf" = "~/.config/test.conf"
' | save -f ($mod_src | path join "ygg.toml")
        "test-content\n" | save -f ($mod_src | path join "test.conf")
        "exit 3\n" | save -f ($mod_src | path join "setup.nu")
        mkdir ($home | path join "modules")
        test-link-dir $mod_src ($home | path join "modules" "fail-setup-mod")
        "[[modules]]\nname = \"fail-setup-mod\"\n" | save -f ($home | path join "host.toml")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: ($home | path join "pkg.log") } {
            # 1. First apply fails due to setup.nu exit 3
            let ap1 = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert ($ap1.exit_code != 0) "Expected apply to fail"

            let jfile = ($home | path join ".state" "journal.json")
            assert ($jfile | path exists) "journal.json must exist after failure"
            let j = (open $jfile)
            assert equal $j.status "failed"
            assert equal $j.failed_step "setup"
            assert equal $j.steps.links "COMMITTED"

            # doctor --json contains journal_failed with severity warn
            let doc_res = (^nu $ygg_bin doctor --json --sandbox $sb | complete)
            let findings = ($doc_res.stdout | from json)
            let fail_findings = ($findings | where check == "journal_failed")
            assert equal ($fail_findings | length) 1
            assert equal ($fail_findings | first | get severity) "warn"

            # Review Focus 2: PID in journal replaced with dead PID 2147483646 -> doctor --json has journal_interrupted with error
            open $jfile | upsert pid 2147483646 | upsert status "in_progress" | to json | save -f $jfile
            let doc_int = (^nu $ygg_bin doctor --json --sandbox $sb | complete)
            let findings_int = ($doc_int.stdout | from json)
            let int_findings = ($findings_int | where check == "journal_interrupted")
            assert equal ($int_findings | length) 1
            assert equal ($int_findings | first | get severity) "error"

            # Restore failed state for roll-forward recovery test
            open $jfile | upsert pid $nu.pid | upsert status "failed" | to json | save -f $jfile

            # 2. Fix setup.nu: replace with empty file
            "" | save -f ($mod_src | path join "setup.nu")

            # Second apply succeeds, prints Recovering: to stderr, journal is removed
            let ap2 = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert equal $ap2.exit_code 0 $ap2.stderr
            assert ($ap2.stderr | str contains "Recovering:") "Expected stderr to contain Recovering:"
            assert (not ($jfile | path exists)) "journal.json must be removed on clean apply"
        }
    }
}

export def test_cli_ygg_apply_locked_and_lockfile [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        mkdir $sb
        let mod_dir = ($home | path join "modules" "git-mod")
        mkdir $mod_dir
        ^git -C $mod_dir init | complete | ignore
        ^git -C $mod_dir config user.name "Test" | complete | ignore
        ^git -C $mod_dir config user.email "test@example.com" | complete | ignore
        "name = 'git-mod'\nos = ['linux', 'cachyos']\n" | save -f ($mod_dir | path join "ygg.toml")
        ^git -C $mod_dir add . | complete | ignore
        ^git -C $mod_dir commit -m "init" | complete | ignore

        "[[modules]]\nname = 'git-mod'\n" | save -f ($home | path join "host.toml")
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)

        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: "linux" } {
            # 1. apply creates ygg.lock
            let a1 = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert equal $a1.exit_code 0 $a1.stderr
            let lock_path = ($home | path join "ygg.lock")
            assert ($lock_path | path exists) "ygg.lock must exist after apply"
            let lock_data = (open --raw $lock_path | from toml)
            assert equal $lock_data.version 1
            assert equal (($lock_data.modules | first).name) "git-mod"

            # 2. apply --locked passes when lockfile matches
            let a2 = (^nu $ygg_bin apply --locked --sandbox $sb | complete)
            assert equal $a2.exit_code 0 $a2.stderr

            # 3. New commit creates mismatch
            "name = 'git-mod'\nos = ['linux', 'cachyos']\n# modified\n" | save -f ($mod_dir | path join "ygg.toml")
            ^git -C $mod_dir commit -am "second" | complete | ignore

            # apply --locked fails
            let a3 = (^nu $ygg_bin apply --locked --sandbox $sb | complete)
            assert equal $a3.exit_code 1
            assert ($a3.stderr | str contains "commit mismatch")

            # 4. Normal apply updates ygg.lock
            let a4 = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert equal $a4.exit_code 0 $a4.stderr
            let updated_lock = (open --raw $lock_path | from toml)
            let new_commit = (^git -C $mod_dir rev-parse HEAD | complete).stdout | str trim
            assert equal (($updated_lock.modules | first).commit) $new_commit

            # 5. apply --locked passes again
            let a5 = (^nu $ygg_bin apply --locked --sandbox $sb | complete)
            assert equal $a5.exit_code 0 $a5.stderr
        }
    }
}

export def test_dry_run_skips_setup_unless_dry_run_safe [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb"); mkdir $sb
        let m = ($home | path join "modules" "m"); mkdir $m
        let marker = ($home | path join "marker")
        "name = \"m\"\nos = [\"linux\", \"windows\", \"macos\"]\n" | save -f ($m | path join "ygg.toml")
        $"touch '($marker)'\n" | save -f ($m | path join "setup.nu")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let res = (^nu $ygg_bin diff | complete)
            assert (not ($marker | path exists))
            assert ($res.stdout | str contains "SETUP m (skipped)")
            "\n[setup]\ndry_run_safe = true\n" | save --append ($m | path join "ygg.toml")
            ^nu $ygg_bin diff | complete | ignore
            assert ($marker | path exists)
        }
    }
}

export def test_cli_apply_blocks_missing_secret_provider_before_packages [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let pkg_log = ($home | path join "pkg.log")
        let mod_src = ($home | path join "mod-a")
        mkdir $mod_src

        'name = "mod-a"
os = ["linux", "windows", "macos", "cachyos"]
[packages]
cargo = ["x"]
' | save -f ($mod_src | path join "ygg.toml")

        mkdir ($home | path join "modules")
        test-link-dir $mod_src ($home | path join "modules" "mod-a")
        "[[modules]]\nname = \"mod-a\"\n" | save -f ($home | path join "host.toml")
        "K = \"op://v/i/f\"\n" | save -f ($home | path join "secrets.toml")

        # host lock needs `ln` (hard link) on PATH; expose only it, not op/bw/pass
        let ln_dir = ($home | path join "ln-bin")
        mkdir $ln_dir
        let nu_dir = ($nu.current-exe | path dirname)
        let path_list = if $nu.os-info.family == "windows" {
            ^cp (which ln | get 0.path) ($ln_dir | path join "ln.exe")
            [$nu_dir, $ln_dir, "C:\\Windows\\System32"]
        } else {
            ^ln -s (which ln | get 0.path) ($ln_dir | path join "ln")
            [$nu_dir, $ln_dir]
        }
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let res = (with-env {
            YGG_HOME: $home,
            YGG_SANDBOX: $sb,
            YGG_HOST_OS_OVERRIDE: "cachyos",
            YGG_MOCK_PKG_LOG: $pkg_log,
            PATH: $path_list
        } { ^nu $ygg_bin apply --force --sandbox $sb | complete })

        assert ($res.exit_code != 0)
        assert ($res.stderr | str contains "op")
        assert (not ($pkg_log | path exists))
    }
}

# regression: #21
export def test_apply_dry_run_reports_would_recover [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb"); mkdir $sb
        "modules = []\n" | save -f ($home | path join "host.toml")
        mkdir ($home | path join ".state")
        { version: 2, status: "failed", started: "2026-11-08T00:00:00Z", plan_hash: "h", steps: {} }
            | to json | save -f ($home | path join ".state" "journal.json")
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let res = (^nu $ygg_bin apply --dry-run | complete)
            assert equal $res.exit_code 0 $res.stderr
            assert ($res.stderr | str contains "Would recover: previous apply failed at step 'unknown'") $res.stderr
            assert (not ($res.stderr | str contains "Recovering:"))
        }
    }
}

export def test_cli_progress_phases_and_readonly_silence [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "prog-mod")
        mkdir $mod_src $sb ($home | path join "modules")
        'name = "prog-mod"
os = ["linux", "windows", "macos", "cachyos"]
[links]
"a.conf" = "~/.config/prog/a.conf"
' | save -f ($mod_src | path join "ygg.toml")
        "a=1\n" | save -f ($mod_src | path join "a.conf")
        test-link-dir $mod_src ($home | path join "modules" "prog-mod")
        "[[modules]]\nname = \"prog-mod\"\n" | save -f ($home | path join "host.toml")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let host_os_ovr = if $nu.os-info.family == "windows" { "windows" } else { "cachyos" }

        # Локальный bare git-репозиторий для проверки молчания `add --dry-run`
        let bare = ($home | path join "dry-git.git")
        let work = ($home | path join "dry-git-work")
        ^git init --bare -b main $bare
        ^git clone $bare $work
        ^git -C $work config user.email "t@t.local"
        ^git -C $work config user.name "Tester"
        $"name = \"dry-git\"\nos = [\"linux\", \"windows\", \"macos\", \"cachyos\"]\n" | save -f ($work | path join "ygg.toml")
        ^git -C $work add .
        ^git -C $work commit -m "init"
        ^git -C $work push -u origin main

        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: $host_os_ovr, YGG_MOCK_PKG_LOG: ($home | path join "pkg.log") } {
            # Read-only / dry-run команды не выводят прогресс
            for cmd in [["diff"], ["apply", "--dry-run", "--sandbox", $sb], ["add", $bare, "--dry-run", "--sandbox", $sb], ["status", "--json"], ["doctor", "--json", "--sandbox", $sb]] {
                let r = (^nu $ygg_bin ...$cmd | complete)
                assert equal $r.exit_code 0 $r.stderr
                assert not ($r.stdout | str contains "[links]")
                assert not ($r.stderr | str contains "[links]")
                assert not ($r.stderr | str contains "[git]")
                assert not ($r.stderr | str contains "[preflight]")
                assert not ($r.stderr | str contains "\x1b[")
            }

            # Реальный apply выводит фазы прогресса в stderr и чистый stdout
            let ap = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert equal $ap.exit_code 0 $ap.stderr
            assert ($ap.stdout | str contains "Applied 1 module")
            assert ($ap.stderr | str contains "[preflight]")
            assert ($ap.stderr | str contains "[links]")
            assert ($ap.stderr | str contains "[finalize]")
            assert not ($ap.stderr | str contains "\x1b[")

            # Реальный remove выводит фазу в stderr и чистый stdout
            let rm_res = (^nu $ygg_bin remove "prog-mod" | complete)
            assert equal $rm_res.exit_code 0 $rm_res.stderr
            assert ($rm_res.stdout | str contains "Removed module prog-mod")
            assert ($rm_res.stderr | str contains "[ygg]")
        }
    }
}

# regression: #10
export def test_apply_and_setup_group_backups_and_print_summary [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "grp-mod")
        mkdir $mod_src ($sb | path join ".config" "grp") ($home | path join "modules")
        'name = "grp-mod"
os = ["linux", "windows", "macos", "cachyos"]
[links]
"a.conf" = "~/.config/grp/a.conf"
"b.conf" = "~/.config/grp/b.conf"
' | save -f ($mod_src | path join "ygg.toml")
        "src-a" | save -f ($mod_src | path join "a.conf")
        "src-b" | save -f ($mod_src | path join "b.conf")
        mkdir ($mod_src | path join "c-dir")
        "src-c" | save -f ($mod_src | path join "c-dir" "c.conf")
        'use sdk.nu *
safe-link "c-dir" "~/.config/grp/c-dir"
' | save -f ($mod_src | path join "setup.nu")

        let dest_a = ($sb | path join ".config" "grp" "a.conf")
        let dest_b = ($sb | path join ".config" "grp" "b.conf")
        let dest_c_dir = ($sb | path join ".config" "grp" "c-dir")
        mkdir $dest_c_dir
        "old-a" | save -f $dest_a
        "old-b" | save -f $dest_b
        "old-c" | save -f ($dest_c_dir | path join "c.conf")

        test-link-dir $mod_src ($home | path join "modules" "grp-mod")
        "[[modules]]\nname = \"grp-mod\"\n" | save -f ($home | path join "host.toml")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let host_os_ovr = if $nu.os-info.family == "windows" { "windows" } else { "cachyos" }
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: $host_os_ovr } {
            let ap = (^nu $ygg_bin apply --force --sandbox $sb | complete)
            assert equal $ap.exit_code 0 $ap.stderr
            let bkp_root = ($home | path join ".state" "backups")
            let dirs = (ls $bkp_root | where type == "dir")
            let jsons = (ls $bkp_root | where type == "file" | where { |f| ($f.name | str ends-with ".json") })
            assert equal ($dirs | length) 1
            assert equal ($jsons | length) 1
            assert ($ap.stderr | str contains "Backed up 3 path(s) ->")
            assert ($ap.stderr | str contains "a.conf")
            assert ($ap.stderr | str contains "b.conf")
            assert ($ap.stderr | str contains "c-dir")
        }
    }
}

# regression: #10
export def test_apply_failure_still_prints_backup_summary [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "fail-mod")
        mkdir $mod_src ($sb | path join ".config" "fail") ($home | path join "modules")
        'name = "fail-mod"
os = ["linux", "windows", "macos", "cachyos"]
[links]
"a.conf" = "~/.config/fail/a.conf"
' | save -f ($mod_src | path join "ygg.toml")
        "src-a" | save -f ($mod_src | path join "a.conf")
        'error make { msg: "intentional setup failure" }
' | save -f ($mod_src | path join "setup.nu")
        "old-a" | save -f ($sb | path join ".config" "fail" "a.conf")

        test-link-dir $mod_src ($home | path join "modules" "fail-mod")
        "[[modules]]\nname = \"fail-mod\"\n" | save -f ($home | path join "host.toml")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let host_os_ovr = if $nu.os-info.family == "windows" { "windows" } else { "cachyos" }
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: $host_os_ovr } {
            let ap = (^nu $ygg_bin apply --force --sandbox $sb | complete)
            assert ($ap.exit_code != 0)
            assert ($ap.stderr | str contains "Backed up 1 path(s) ->")
            assert ($ap.stderr | str contains "a.conf")
        }
    }
}

# regression: #10
export def test_apply_dry_run_creates_no_backup_index [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "dry-bkp-mod")
        mkdir $mod_src ($sb | path join ".config" "drybkp") ($home | path join "modules")
        'name = "dry-bkp-mod"
os = ["linux", "windows", "macos", "cachyos"]
[links]
"a.conf" = "~/.config/drybkp/a.conf"
' | save -f ($mod_src | path join "ygg.toml")
        "src-a" | save -f ($mod_src | path join "a.conf")
        "old-a" | save -f ($sb | path join ".config" "drybkp" "a.conf")

        test-link-dir $mod_src ($home | path join "modules" "dry-bkp-mod")
        "[[modules]]\nname = \"dry-bkp-mod\"\n" | save -f ($home | path join "host.toml")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let host_os_ovr = if $nu.os-info.family == "windows" { "windows" } else { "cachyos" }
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: $host_os_ovr } {
            let ap = (^nu $ygg_bin apply --dry-run --force --sandbox $sb | complete)
            assert equal $ap.exit_code 0 $ap.stderr
            let bkp_root = ($home | path join ".state" "backups")
            if ($bkp_root | path exists) {
                assert equal (ls $bkp_root | length) 0
            }
            assert not ($ap.stderr | str contains "Backed up")
        }
    }
}
