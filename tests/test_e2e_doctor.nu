use std/assert
use ../src/state.nu [ensure-ygg-dirs]
use ../src/link.nu [is-link-or-junction]
use ../scripts/release.nu [read-ygg-version]
use helpers.nu [with-temp-ygg, test-link-dir, test-dangling-link]

export def test_cli_doctor_fix [] {
    with-temp-ygg { |home|
        let sb = $env.YGG_SANDBOX
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: "cachyos" } {
            ensure-ygg-dirs $home
            let sec = ($home | path join "secrets.toml")
            "val = 1" | save -f $sec
            if $nu.os-info.family != "windows" {
                ^chmod 644 $sec | complete | ignore
            }
            let cfg = ($sb | path join ".config")
            mkdir $cfg
            let dead_link = ($cfg | path join "locked-orphan.conf")
            test-dangling-link ($home | path join "gone-target") $dead_link

            let cfg = ($sb | path join ".config")
            mkdir $cfg
            let dead_link = ($cfg | path join "broken.conf")
            test-dangling-link ($home | path join "not-existing-target") $dead_link

            # Check doctor without --fix reports errors/warnings and does not mutate
            let res_audit = (^nu $ygg_bin doctor --sandbox $sb | complete)
            if $nu.os-info.family != "windows" {
                assert equal $res_audit.exit_code 1
                assert ($res_audit.stdout | str contains "perm")
            }
            assert ($res_audit.stdout | str contains "orphan_link")

            # Check doctor --fix -y fixes perm and orphan_link
            let res_fix = (^nu $ygg_bin doctor --fix -y --sandbox $sb | complete)
            assert equal $res_fix.exit_code 0 $res_fix.stderr
            assert ($res_fix.stdout | str contains "Fixed findings:")
            if $nu.os-info.family != "windows" {
                assert ($res_fix.stdout | str contains "perm")
            }
            assert ($res_fix.stdout | str contains "orphan_link")

            # Verify on filesystem
            if $nu.os-info.family != "windows" {
                let mode = (ls -lD $sec | get -o 0.mode | default "")
                assert ($mode =~ 'rw-------') "Expected 0600 mode after fix"
            }
            assert (try { ($dead_link | path type) != "symlink" } catch { true }) $"Expected orphan link removed. stdout:\n($res_fix.stdout)"

            # Check doctor --fix --json output structure
            let res_json = (^nu $ygg_bin doctor --fix -y --json --sandbox $sb | complete)
            assert equal $res_json.exit_code 0
            let parsed = ($res_json.stdout | from json)
            assert ($parsed | columns | any { |c| $c == "findings" })
            assert ($parsed | columns | any { |c| $c == "fixed" })
        }
    }
}

export def test_cli_doctor_fix_refuses_when_host_locked [] {
    with-temp-ygg { |home|
        let sb = $env.YGG_SANDBOX
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: "cachyos" } {
            ensure-ygg-dirs $home
            let sec = ($home | path join "secrets.toml")
            "val = 1" | save -f $sec
            if $nu.os-info.family != "windows" {
                ^chmod 644 $sec | complete | ignore
            }
            let cfg = ($sb | path join ".config")
            mkdir $cfg
            let dead_link = ($cfg | path join "locked-orphan.conf")
            test-dangling-link ($home | path join "gone-target") $dead_link
            {
                pid: $nu.pid,
                host: (sys host | get hostname),
                timestamp: "2026-11-08T00:00:00Z",
                command: "apply"
            } | to json | save -f ($home | path join ".state" "host.lock")
            let res = (^nu $ygg_bin doctor --fix -y --sandbox $sb | complete)
            assert equal $res.exit_code 1
            assert ($res.stderr | str contains "Host is locked")
            let mode = (ls -lD $sec | get -o 0.mode | default "")
            assert (not ($mode =~ 'rw-------')) "locked host must not be mutated"
        }
    }
}

# Flags (long names) of one `export extern "ygg <cmd>"` block of the generated nu completions
export def test_cli_clean_subcommand [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "clean-mod")
        mkdir $mod_src
        "hello" | save -f ($mod_src | path join "app.txt")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_MOCK_PKG_LOG: ($home | path join "pkg.log") } {
            cd $mod_src
            ^nu $ygg_bin init "clean-mod" --os "linux,windows,macos,cachyos"
            "[links]\n\"app.txt\" = \"~/.config/clean/app.txt\"\n" | save --append ($mod_src | path join "ygg.toml")
            ^nu $ygg_bin add $mod_src

            # Create 25 dummy backups
            let bkp_root = ($home | path join ".state" "backups")
            for i in 1..25 {
                mkdir ($bkp_root | path join $"2026110($i)_120000_000000")
            }

            # Put orphan hash into state.json
            let state_file = ($home | path join ".state" "state.json")
            let current_state = (open $state_file)
            let updated_state = ($current_state | upsert hashes {
                "pkg:active_fake": "valid",
                "pkg:orphan_fake": "stale"
            })
            $updated_state | to json | save -f $state_file

            # 1. Test ygg clean --dry-run
            let dry_res = (^nu $ygg_bin clean --dry-run | complete)
            assert equal $dry_res.exit_code 0 $dry_res.stderr
            assert ($dry_res.stdout | str contains "Would remove")
            assert ($dry_res.stdout | str contains "Would purge")
            # Dry run must not remove anything
            assert equal (ls $bkp_root | where type == "dir" | length) 25
            assert equal ((open $state_file).hashes."pkg:orphan_fake"? | default "") "stale"

            # 2. Test ygg clean --backups
            let bkp_res = (^nu $ygg_bin clean --backups | complete)
            assert equal $bkp_res.exit_code 0 $bkp_res.stderr
            assert ($bkp_res.stdout | str contains "Cleaned 5 old backup(s)")
            assert equal (ls $bkp_root | where type == "dir" | length) 20
            # Hashes still untouched
            assert equal ((open $state_file).hashes."pkg:orphan_fake"? | default "") "stale"

            # 3. Test ygg clean --hashes
            let hash_res = (^nu $ygg_bin clean --hashes | complete)
            assert equal $hash_res.exit_code 0 $hash_res.stderr
            assert ($hash_res.stdout | str contains "Purged")
            let final_state = (open $state_file)
            assert ("pkg:orphan_fake" not-in ($final_state.hashes | columns))

            # 4. Test that ygg apply automatically purges orphan hashes and rotates backups
            let state_with_orphan = ($final_state | upsert hashes {
                "pkg:orphan_during_apply": "stale"
            })
            $state_with_orphan | to json | save -f $state_file
            for i in 1..25 {
                mkdir ($bkp_root | path join $"2026110($i)_120000_000000")
            }
            let apply_res = (^nu $ygg_bin apply | complete)
            assert equal $apply_res.exit_code 0 $apply_res.stderr
            let post_apply_state = (open $state_file)
            assert ("pkg:orphan_during_apply" not-in ($post_apply_state.hashes | columns))
            assert ((ls $bkp_root | where type == "dir" | length) <= 20)
        }
    }
}

