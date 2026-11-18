use std/assert
use ../src/state.nu [ensure-ygg-dirs]
use ../src/link.nu [is-link-or-junction]
use ../scripts/release.nu [read-ygg-version]
use helpers.nu [with-temp-ygg, test-link-dir, test-dangling-link]

def tree-snapshot [root: string]: nothing -> list<string> {
    glob (($root | path join "**" "*") | str replace --all '\' '/') | sort | each { |p| $"($p)|(try { ls -D $p | get -o 0.modified | into int | into string } catch { '' })" }
}

export def test_cli_sdk_subcommands [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let work = ($home | path join "work")
        mkdir $work

        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_MODULE_DIR: $work } {
            # 1. merge-json
            let frag = ($work | path join "frag.json")
            let target = ($work | path join "target.json")
            '{"theme": "nord", "key": "val1"}' | save -f $frag
            '{"font": "mono", "key": "val0"}' | save -f $target

            ^nu $ygg_bin merge-json $frag $target
            let res_json = (open $target)
            assert equal $res_json.theme "nord"
            assert equal $res_json.font "mono"
            assert equal $res_json.key "val1"

            # 2. export-secrets
            let sec_file = ($home | path join "secrets.toml")
            "[env]\nAPI_KEY = \"secret123\"\n" | save -f $sec_file
            let env_out = ($work | path join ".env")

            ^nu $ygg_bin export-secrets $env_out --keys "API_KEY"
            assert ($env_out | path exists)
            let env_content = (open --raw $env_out)
            assert ($env_content | str contains "secret123")

            # 3. onchange
            let watch_file = ($work | path join "watch.txt")
            let out_file = ($work | path join "out.txt")
            "v1" | save -f $watch_file

            ^nu $ygg_bin onchange "test" "watch.txt" $"\"done\" | save -f '($out_file)'"
            assert ($out_file | path exists)
        }
    }
}

export def test_sandbox_without_ygg_home_is_refused [] {
    with-temp-ygg { |home|
        let fake_home = ($home | path join "fake_user_home")
        mkdir $fake_home
        let sb = ($home | path join "preview")
        mkdir $sb
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)

        let res = (with-env { HOME: $fake_home, YGG_HOME: "", YGG_SANDBOX: $sb } { ^nu $ygg_bin apply --sandbox $sb | complete })
        assert ($res.exit_code != 0)
        assert ($res.stderr | str contains "YGG_HOME")
        assert (not (($fake_home | path join ".ygg") | path exists))
    }
}

export def test_cli_version_flag_and_subcommand [] {
    let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
    let v1 = (^nu $ygg_bin --version | complete)
    let v2 = (^nu $ygg_bin -v | complete)
    let v3 = (^nu $ygg_bin version | complete)
    assert equal $v1.exit_code 0
    assert ($v1.stdout | str starts-with $"ygg (read-ygg-version $ygg_bin)")
    assert equal ($v1.stdout | str trim) ($v2.stdout | str trim)
    assert equal ($v1.stdout | str trim) ($v3.stdout | str trim)
}

export def test_ygg_cmd_shim_search_paths_and_setlocal [] {
    let cmd_file = ($env.FILE_PWD | path join "../bin/ygg.cmd" | path expand)
    let raw = (open --raw $cmd_file)
    let pos_setlocal = ($raw | str index-of "setlocal")
    let pos_path = ($raw | str index-of "set \"PATH=")
    assert ($pos_setlocal >= 0)
    assert ($pos_setlocal < $pos_path)

    let p1 = ($raw | str index-of "%USERPROFILE%\\.local\\bin\\nu.exe")
    let p2 = ($raw | str index-of "%LOCALAPPDATA%\\Programs\\nu\\bin\\nu.exe")
    let p3 = ($raw | str index-of "%LOCALAPPDATA%\\Microsoft\\WinGet\\Links\\nu.exe")
    let p4 = ($raw | str index-of "%ProgramFiles%\\nu\\bin\\nu.exe")
    let p5 = ($raw | str index-of "%USERPROFILE%\\scoop\\shims\\nu.exe")
    assert (($p1 < $p2) and ($p2 < $p3) and ($p3 < $p4) and ($p4 < $p5))
}

# Byte-level snapshot of a directory tree (type, symlink literal target, file sha256) without following links
export def test_status_json_output_in_pipe [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "json-mod")
        mkdir $mod_src
        'name = "json-mod"
os = ["linux", "windows", "macos", "cachyos"]
' | save -f ($mod_src | path join "ygg.toml")
        mkdir ($home | path join "modules")
        test-link-dir $mod_src ($home | path join "modules" "json-mod")
        "[[modules]]\nname = \"json-mod\"\nscopes = [\"pc\"]\n" | save -f ($home | path join "host.toml")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: "cachyos", COLUMNS: "20" } {
            let res = (^nu $ygg_bin status --json | complete)
            assert equal $res.exit_code 0 $res.stderr
            let rows = ($res.stdout | from json)
            assert equal ($rows | length) 1
            let row = ($rows | first)
            assert equal ($row | columns | sort) (["name", "scopes", "path", "target", "branch", "dirty", "links_ok", "sync_conflicts", "pending_save", "containers"] | sort)
            assert equal $row.name "json-mod"
            assert equal $row.scopes ["pc"]
            assert equal $row.target ($mod_src | path expand)
            assert equal $row.links_ok true
            assert equal $row.sync_conflicts 0
            assert equal $row.pending_save 0
        }
    }
}

export def test_cli_host_lock_and_no_lock [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "lock-mod")
        mkdir $mod_src
        'name = "lock-mod"
os = ["linux", "windows", "macos", "cachyos"]
' | save -f ($mod_src | path join "ygg.toml")
        mkdir ($home | path join "modules")
        test-link-dir $mod_src ($home | path join "modules" "lock-mod")
        "[[modules]]\nname = \"lock-mod\"\n" | save -f ($home | path join "host.toml")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb } {
            # 1. Normal apply creates and cleans lock file
            let ap = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert equal $ap.exit_code 0 $ap.stderr
            assert (not ($home | path join ".state" "host.lock" | path exists))

            # 2. Simulate concurrent run with active PID
            mkdir ($home | path join ".state")
            {
                pid: $nu.pid,
                timestamp: "2026-11-08T00:00:00Z",
                command: "apply"
            } | to json | save -f ($home | path join ".state" "host.lock")

            let locked_res = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert equal $locked_res.exit_code 1
            assert ($locked_res.stderr | str contains "Host is locked by another ygg instance")

            # 3. --no-lock bypasses lock check
            let no_lock_res = (^nu $ygg_bin apply --no-lock --sandbox $sb | complete)
            assert equal $no_lock_res.exit_code 0 $no_lock_res.stderr

            # 4. Remove with --no-lock also bypasses
            let rm_res = (^nu $ygg_bin remove "lock-mod" --no-lock | complete)
            assert equal $rm_res.exit_code 0 $rm_res.stderr
        }
    }
}

export def test_readonly_commands_do_not_touch_fresh_home [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb"); mkdir $sb
        "modules = []\n" | save -f ($home | path join "host.toml")
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        # sources for `add --dry-run` (created before the snapshot, so they are part of it)
        let loc = ($home | path join "src-loc"); mkdir $loc
        "name = \"loc\"\nos = [\"linux\", \"cachyos\"]\n" | save -f ($loc | path join "ygg.toml")
        let gitsrc = ($home | path dirname | path join "src-git.git"); mkdir $gitsrc
        "name = \"gm\"\nos = [\"linux\", \"windows\", \"macos\", \"cachyos\"]\n" | save -f ($gitsrc | path join "ygg.toml")
        ^git -C $gitsrc init -q -b main
        ^git -C $gitsrc add .
        ^git -c gc.auto=0 -c maintenance.auto=0 -c user.email=t@t -c user.name=t -C $gitsrc commit -q -m init
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let before = (tree-snapshot $home)
            for cmd in [["diff"], ["status"], ["doctor"], ["apply", "--dry-run"], ["add", "--dry-run", $loc], ["add", "--dry-run", $gitsrc], ["clean", "--dry-run"]] {
                let r = (^nu $ygg_bin ...$cmd | complete)
                if ($cmd | first) in ["add", "clean"] {
                    assert equal $r.exit_code 0 $"($cmd | str join ' ') failed: ($r.stderr)"
                }
                assert equal (tree-snapshot $home) $before $"($cmd | str join ' ') mutated YGG_HOME"
            }
            assert (not ($home | path join ".state" | path exists))
        }
    }
}

# regression: #10
export def test_status_shows_recent_backups_and_preserves_json [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "st-mod")
        mkdir $mod_src ($sb | path join ".config" "st") ($home | path join "modules")
        'name = "st-mod"
os = ["linux", "windows", "macos", "cachyos"]
[links]
"a.conf" = "~/.config/st/a.conf"
' | save -f ($mod_src | path join "ygg.toml")
        "src-a" | save -f ($mod_src | path join "a.conf")
        "old-a" | save -f ($sb | path join ".config" "st" "a.conf")
        test-link-dir $mod_src ($home | path join "modules" "st-mod")
        "[[modules]]\nname = \"st-mod\"\n" | save -f ($home | path join "host.toml")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let host_os_ovr = if $nu.os-info.family == "windows" { "windows" } else { "cachyos" }
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: $host_os_ovr } {
            let ap = (^nu $ygg_bin apply --force --sandbox $sb | complete)
            assert equal $ap.exit_code 0 $ap.stderr

            # Add an older legacy backup directory without .json index
            mkdir ($home | path join ".state" "backups" "20250101_000000_000001")

            let st = (^nu $ygg_bin status | complete)
            assert equal $st.exit_code 0 $st.stderr
            assert ($st.stdout | str contains "st-mod")
            assert ($st.stdout | str contains "Recent backups")
            assert ($st.stdout | str contains "a.conf")
            assert ($st.stdout | str contains "20250101_000000_000001  (legacy)")

            let st_json = (^nu $ygg_bin status --json | complete)
            assert equal $st_json.exit_code 0 $st_json.stderr
            let parsed = ($st_json.stdout | from json)
            assert equal ($parsed | length) 1
            assert equal $parsed.0.name "st-mod"
        }
    }
}

