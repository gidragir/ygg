use std/assert
use ../src/state.nu [ensure-ygg-dirs]
use helpers.nu [with-temp-ygg]

export def test_full_cli_lifecycle [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "my-dotfiles")
        mkdir ($mod_src | path join "niri")
        "layout {}" | save -f ($mod_src | path join "niri" "config.kdl")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_MOCK_PKG_LOG: ($home | path join "pkg.log") } {
            # 1. Init module
            cd $mod_src
            ^nu $ygg_bin init "my-dotfiles" --os "linux,cachyos"
            "[links]\nniri = \"~/.config/niri\"\n" | save --append ($mod_src | path join "ygg.toml")

            # 2. Add local module (auto-applies strictly inside YGG_SANDBOX)
            ^nu $ygg_bin add $mod_src
            assert (($sb | path join ".config/niri/config.kdl" | path exists))

            # 3. Check status output
            let st = (^nu $ygg_bin status)
            assert ($st | str contains "my-dotfiles")

            # 4. Remove module unlinks from sandbox while keeping source dir intact
            ^nu $ygg_bin remove "my-dotfiles"
            assert (not ($sb | path join ".config/niri" | path exists))
            assert (($mod_src | path join "niri/config.kdl" | path exists))
        }
    }
}

export def test_cli_add_with_scope_and_save [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "scoped-mod")
        mkdir $mod_src
        "original_content" | save -f ($mod_src | path join "app.conf")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_MOCK_PKG_LOG: ($home | path join "pkg.log") } {
            cd $mod_src
            ^nu $ygg_bin init "scoped-mod" --os "linux"
            "[save]\n\"app.conf\" = \"~/.config/app/app.conf\"\n" | save --append ($mod_src | path join "ygg.toml")

            # Add module with scope
            ^nu $ygg_bin add $"($mod_src)@pc,work"
            let deployed = ($sb | path join ".config/app/app.conf")
            assert ($deployed | path exists)
            assert equal (open $deployed) "original_content"

            # Simulate external edit in sandbox
            "modified_by_gui" | save -f $deployed

            # Run save command
            ^nu $ygg_bin save
            assert equal (open ($mod_src | path join "app.conf")) "modified_by_gui"
        }
    }
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

export def test_apply_refuses_prune_all_without_force [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "my-mod")
        mkdir ($mod_src | path join "conf")
        "key = val" | save -f ($mod_src | path join "conf" "app.conf")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_MOCK_PKG_LOG: ($home | path join "pkg.log") } {
            cd $mod_src
            ^nu $ygg_bin init "my-mod" --os "linux,cachyos"
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

export def test_add_does_not_overwrite_broken_host_toml [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "another-mod")
        mkdir $mod_src
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_MOCK_PKG_LOG: ($home | path join "pkg.log") } {
            cd $mod_src
            ^nu $ygg_bin init "another-mod" --os "linux,cachyos"

            let host_file = ($home | path join "host.toml")
            let broken_content = "[[modules\nname = bad_syntax\n"
            $broken_content | save -f $host_file

            let res = (^nu $ygg_bin add $mod_src | complete)
            assert ($res.exit_code != 0)
            assert equal (open --raw $host_file) $broken_content
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
            ^nu $ygg_bin init "pkg-fail-mod" --os "linux,cachyos"
            "[packages]\npacman = [\"curl\"]\n\n[links]\nconf = \"~/.config/conf\"\n" | save --append ($mod_src | path join "ygg.toml")

            let mod_target = ($home | path join "modules" "pkg-fail-mod")
            mkdir ($home | path join "modules")
            ^ln -s $mod_src $mod_target
            "[[modules]]\nname = \"pkg-fail-mod\"\n" | save -f ($home | path join "host.toml")

            let res = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert ($res.exit_code != 0)
            assert ($res.stderr | str contains "pacman")
            assert ($res.stdout | str contains "Applied 1 module")
            let target_link = ($sb | path join ".config" "conf")
            assert ($target_link | path exists)
        }
    }
}



export def test_preflight_blocks_missing_link_source_before_packages [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let pkg_log = ($home | path join "pkg.log")
        let mod_src = ($home | path join "bad-mod")
        mkdir $mod_src
        mkdir ($sb | path join ".config" "ollama")
        "host_model_state" | save -f ($sb | path join ".config" "ollama" "models.txt")

        'name = "bad-mod"
os = ["linux", "cachyos"]
[packages]
pacman = ["curl"]
[links]
"configs/ollama" = "~/.config/ollama"
"missing/glob/*" = "~/.config/glob/*"
' | save -f ($mod_src | path join "ygg.toml")

        mkdir ($home | path join "modules")
        ^ln -s $mod_src ($home | path join "modules" "bad-mod")
        "[[modules]]\nname = \"bad-mod\"\n" | save -f ($home | path join "host.toml")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let res = (with-env {
            YGG_HOME: $home,
            YGG_SANDBOX: $sb,
            YGG_HOST_OS_OVERRIDE: "cachyos",
            YGG_MOCK_PKG_LOG: $pkg_log
        } { ^nu $ygg_bin apply --force --sandbox $sb | complete })

        assert ($res.exit_code != 0)
        assert ($res.stderr | str contains "configs/ollama")
        assert ($res.stderr | str contains "missing/glob/*")
        assert (not ($pkg_log | path exists))
        assert equal (open --raw ($sb | path join ".config" "ollama" "models.txt")) "host_model_state"
    }
}

export def test_cli_version_flag_and_subcommand [] {
    let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
    let v1 = (^nu $ygg_bin --version | complete)
    let v2 = (^nu $ygg_bin -v | complete)
    let v3 = (^nu $ygg_bin version | complete)
    assert equal $v1.exit_code 0
    assert ($v1.stdout | str starts-with "ygg 0.1.0")
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
def snapshot-tree [root: string]: nothing -> list<string> {
    if not ($root | path exists) {
        return []
    }
    mut out = []
    for it in (ls -la $root | sort-by name) {
        let rel = ($it.name | path relative-to $root)
        if ($it.type == "symlink") {
            $out = ($out | append $"L ($rel) -> ($it.target)")
        } else if ($it.type == "dir") {
            $out = ($out | append $"D ($rel) ($it.mode)")
            $out = ($out | append (snapshot-tree $it.name | each { |l| $l | str replace --regex '^(\w) ' ('$1 ' + $rel + '/') }))
        } else {
            $out = ($out | append $"F ($rel) ($it.mode) (open --raw $it.name | hash sha256)")
        }
    }
    $out
}

def snapshot-all [home: string, sb: string]: nothing -> record {
    let state_file = ($home | path join ".state" "state.json")
    {
        sandbox: (snapshot-tree $sb),
        state: (if ($state_file | path exists) { open --raw $state_file | hash sha256 } else { "" }),
        backups: (snapshot-tree ($home | path join ".state" "backups"))
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
os = ["linux", "cachyos"]
[links]
niri = "~/.config/niri"
"starship.toml" = "~/.config/starship.toml"
' | save -f ($mod_src | path join "ygg.toml")
        mkdir ($home | path join "modules")
        ^ln -s $mod_src ($home | path join "modules" "plan-mod")
        "[[modules]]\nname = \"plan-mod\"\n" | save -f ($home | path join "host.toml")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let niri = ($sb | path join ".config" "niri")
        let star = ($sb | path join ".config" "starship.toml")
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: ($home | path join "pkg.log") } {
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
            let notice = ($ap.stdout | lines | where { |l| $l | str starts-with ("[ygg] Backed up existing '" + $star + "'") })
            assert equal ($notice | length) 1
            let bkp = ($notice | first | parse --regex "-> '(?P<p>.+)'$" | get 0.p)
            assert equal (open --raw $bkp) "host-version\n"
            assert equal ($star | path type) "symlink"

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
    if ((^id -u | str trim) == "0") {
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
os = ["linux", "cachyos"]
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

# Create a bare git repo in `home` whose single commit holds `files` (relative path -> content)
def make-bare-module [home: string, name: string, files: record]: nothing -> string {
    let bare = ($home | path join $"($name).git")
    let work = ($home | path join $"work-($name)")
    ^git init -q --bare -b main $bare
    ^git clone -q $bare $work
    ^git -C $work config user.email "t@t.local"
    ^git -C $work config user.name "Tester"
    for f in ($files | transpose path content) {
        let p = ($work | path join $f.path)
        mkdir ($p | path dirname)
        $f.content | save -f $p
    }
    ^git -C $work add .
    ^git -C $work commit -q -m "init"
    ^git -C $work push -q -u origin main | complete | ignore
    $bare
}

def snapshot-add [home: string, sb: string]: nothing -> record {
    let host_file = ($home | path join "host.toml")
    (snapshot-all $home $sb) | merge {
        host: (if ($host_file | path exists) { open --raw $host_file } else { "" }),
        modules: (snapshot-tree ($home | path join "modules"))
    }
}

export def test_cli_add_dry_run_and_preflight_rollback [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let pkg_log = ($home | path join "pkg.log")
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let clones = ($home | path join ".state" "tmp" "clone-*")

        # Already registered module "keep" (no links)
        let keep_src = ($home | path join "keep-mod")
        mkdir $keep_src ($home | path join "modules") ($home | path join ".state" "backups") ($home | path join ".state" "env")
        mkdir ($sb | path join ".config")
        "name = \"keep\"\nos = [\"linux\", \"cachyos\"]\n" | save -f ($keep_src | path join "ygg.toml")
        ^ln -s $keep_src ($home | path join "modules" "keep")
        "[[modules]]\nname = \"keep\"\n" | save -f ($home | path join "host.toml")

        # Local module with a valid directory link and a package
        let good = ($home | path join "good-mod")
        mkdir ($good | path join "app")
        "x = 1\n" | save -f ($good | path join "app" "app.conf")
        'name = "good"
os = ["linux", "cachyos"]
[packages]
pacman = ["curl"]
[links]
app = "~/.config/app"
' | save -f ($good | path join "ygg.toml")

        # Local module whose link source is missing
        let bad = ($home | path join "bad-mod")
        mkdir $bad
        'name = "bad"
os = ["linux", "cachyos"]
[packages]
pacman = ["curl"]
[links]
"configs/nope" = "~/.config/nope"
' | save -f ($bad | path join "ygg.toml")

        # Remote-style modules (local bare repos)
        let remote_ok = (make-bare-module $home "remote-ok" {
            "ygg.toml": "name = \"remote-ok\"\nos = [\"linux\", \"cachyos\"]\n[links]\ncfg = \"~/.config/remote-cfg\"\n",
            "cfg/a.conf": "a\n"
        })
        let remote_bad = (make-bare-module $home "remote-bad" {
            "ygg.toml": "name = \"remote-bad\"\nos = [\"linux\", \"cachyos\"]\n[links]\n\"absent\" = \"~/.config/absent\"\n"
        })

        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: $pkg_log } {
            let before = (snapshot-add $home $sb)

            # 1. Local dry-run: plan of the future module, nothing changes
            let d1 = (^nu $ygg_bin add $good --dry-run --sandbox $sb | complete)
            assert equal $d1.exit_code 0 $d1.stderr
            let lines1 = ($d1.stdout | lines | each { |l| $l | str trim })
            assert ($lines1 | any { |l| ($l | str starts-with "LINK") and ($l | str contains ($sb | path join ".config" "app")) and ($l | str contains "(good: app)") })
            assert ($lines1 | any { |l| ($l | str starts-with "PKG") and ($l | str contains "curl") })
            assert ($d1.stdout | str contains "across 2 module(s). No changes made.")
            assert (not ($d1.stdout | str contains "Added module"))
            assert equal (snapshot-add $home $sb) $before
            assert (not ($pkg_log | path exists))

            # 2. Remote dry-run: the temporary clone is removed afterwards
            let d2 = (^nu $ygg_bin add $remote_ok --dry-run --sandbox $sb | complete)
            assert equal $d2.exit_code 0 $d2.stderr
            assert ($d2.stdout | lines | any { |l| ($l | str trim | str starts-with "LINK") and ($l | str contains "remote-cfg") })
            assert equal (snapshot-add $home $sb) $before
            assert (glob $clones | is-empty)

            # 3. Real add with a missing source fails on pre-flight before registration
            let r3 = (^nu $ygg_bin add $bad --sandbox $sb | complete)
            assert ($r3.exit_code != 0)
            assert ($r3.stderr | str contains "Pre-flight check failed")
            assert ($r3.stderr | str contains "configs/nope")
            assert equal (snapshot-add $home $sb) $before
            assert (not ($pkg_log | path exists))

            # 4. Same for a remote module: not registered, clone removed
            let r4 = (^nu $ygg_bin add $remote_bad --sandbox $sb | complete)
            assert ($r4.exit_code != 0)
            assert ($r4.stderr | str contains "absent")
            assert equal (snapshot-add $home $sb) $before
            assert (glob $clones | is-empty)

            # 5. Real add of the valid module registers and applies it
            let r5 = (^nu $ygg_bin add $good --sandbox $sb | complete)
            assert equal $r5.exit_code 0 $r5.stderr
            assert ($r5.stdout | str contains "Added module good")
            assert equal (($sb | path join ".config" "app") | path type) "symlink"
            let names = (open ($home | path join "host.toml") | get modules | get name)
            assert equal $names ["keep", "good"]
        }
    }
}

export def test_cli_pkg_selection_cache_and_failed_package_names [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let pkg_log = ($home | path join "pkg.log")
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let mod_src = ($home | path join "pkg-mod")
        mkdir $mod_src ($home | path join "modules") $sb
        'name = "pkg-mod"
os = ["linux", "cachyos"]
[packages]
pacman = ["curl"]
cargo = ["bat"]
mise = ["ripgrep"]
' | save -f ($mod_src | path join "ygg.toml")
        ^ln -s $mod_src ($home | path join "modules" "pkg-mod")
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
            assert ($f.stdout | str contains "Applied 1 module")
        }
    }
}

export def test_status_json_output_in_pipe [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "json-mod")
        mkdir $mod_src
        'name = "json-mod"
os = ["linux", "cachyos"]
' | save -f ($mod_src | path join "ygg.toml")
        mkdir ($home | path join "modules")
        ^ln -s $mod_src ($home | path join "modules" "json-mod")
        "[[modules]]\nname = \"json-mod\"\nscopes = [\"pc\"]\n" | save -f ($home | path join "host.toml")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: "cachyos", COLUMNS: "20" } {
            let res = (^nu $ygg_bin status --json | complete)
            assert equal $res.exit_code 0 $res.stderr
            let rows = ($res.stdout | from json)
            assert equal ($rows | length) 1
            let row = ($rows | first)
            assert equal ($row | columns | sort) (["name", "scopes", "path", "target", "branch", "dirty", "links_ok", "sync_conflicts", "pending_save"] | sort)
            assert equal $row.name "json-mod"
            assert equal $row.scopes ["pc"]
            assert equal $row.target ($mod_src | path expand)
            assert equal $row.links_ok true
            assert equal $row.sync_conflicts 0
            assert equal $row.pending_save 0
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
os = ["linux", "cachyos"]
[links."app.toml"]
target = "~/.config/app/app.toml"
on_change = "app msg reload"
' | save -f ($mod_src | path join "ygg.toml")
        mkdir ($home | path join "modules")
        ^ln -s $mod_src ($home | path join "modules" "hook-mod")
        "[[modules]]\nname = \"hook-mod\"\n" | save -f ($home | path join "host.toml")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let log = ($home | path join "pkg.log")
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: $log } {
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

export def test_cli_host_lock_and_no_lock [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "lock-mod")
        mkdir $mod_src
        'name = "lock-mod"
os = ["linux", "cachyos"]
' | save -f ($mod_src | path join "ygg.toml")
        mkdir ($home | path join "modules")
        ^ln -s $mod_src ($home | path join "modules" "lock-mod")
        "[[modules]]\nname = \"lock-mod\"\n" | save -f ($home | path join "host.toml")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb } {
            # 1. Normal apply creates and cleans lock file
            let ap = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert equal $ap.exit_code 0 $ap.stderr
            assert (not ($home | path join ".state" "ygg.lock" | path exists))

            # 2. Simulate concurrent run with active PID
            mkdir ($home | path join ".state")
            {
                pid: $nu.pid,
                timestamp: "2026-11-08T00:00:00Z",
                command: "apply"
            } | to json | save -f ($home | path join ".state" "ygg.lock")

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

export def test_journal_transaction_apply_lifecycle_and_warning [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "wal-mod")
        mkdir $mod_src
        'name = "wal-mod"
os = ["linux", "cachyos"]
[links]
"test.conf" = "~/.config/test.conf"
' | save -f ($mod_src | path join "ygg.toml")
        "wal-content\n" | save -f ($mod_src | path join "test.conf")
        mkdir ($home | path join "modules")
        ^ln -s $mod_src ($home | path join "modules" "wal-mod")
        "[[modules]]\nname = \"wal-mod\"\n" | save -f ($home | path join "host.toml")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb } {
            # 1. Normal apply cleans up journal on success
            let ap = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert equal $ap.exit_code 0 $ap.stderr
            assert (not ($home | path join ".state" "journal.json" | path exists))

            # 2. Simulate interrupted transaction in journal.json
            let jfile = ($home | path join ".state" "journal.json")
            {
                timestamp: "2026-11-08T12:00:00Z",
                plan_hash: "dummyhash",
                steps: {
                    packages: "COMMITTED",
                    links: "IN_PROGRESS"
                }
            } | to json | save -f $jfile

            # 3. ygg doctor detects incomplete journal
            let doc_res = (^nu $ygg_bin doctor --json --sandbox $sb | complete)
            assert equal $doc_res.exit_code 1
            let findings = ($doc_res.stdout | from json)
            let wal_errors = ($findings | where check == "journal_incomplete")
            assert equal ($wal_errors | length) 1
            assert equal ($wal_errors | first | get severity) "error"

            # 4. ygg apply warns about interrupted transaction and recovers cleanly
            let resume_res = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert equal $resume_res.exit_code 0 $resume_res.stderr
            assert ($resume_res.stderr | str contains "Interrupted transaction detected in .state/journal.json")
            assert (not ($jfile | path exists)) "Journal must be removed after successful apply"

            # 5. ygg doctor is clean again
            let doc_clean = (^nu $ygg_bin doctor --json --sandbox $sb | complete)
            assert equal $doc_clean.exit_code 0
            let findings_clean = ($doc_clean.stdout | from json)
            assert equal ($findings_clean | where check == "journal_incomplete" | length) 0
        }
    }
}

export def test_cli_clean_subcommand [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "clean-mod")
        mkdir $mod_src
        "hello" | save -f ($mod_src | path join "app.txt")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_MOCK_PKG_LOG: ($home | path join "pkg.log") } {
            cd $mod_src
            ^nu $ygg_bin init "clean-mod" --os "linux"
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
                active_fake: "valid",
                orphan_fake: "stale"
            })
            $updated_state | to json | save -f $state_file

            # 1. Test ygg clean --dry-run
            let dry_res = (^nu $ygg_bin clean --dry-run | complete)
            assert equal $dry_res.exit_code 0 $dry_res.stderr
            assert ($dry_res.stdout | str contains "Would remove")
            assert ($dry_res.stdout | str contains "Would purge")
            # Dry run must not remove anything
            assert equal (ls $bkp_root | where type == "dir" | length) 25
            assert equal ((open $state_file).hashes.orphan_fake? | default "") "stale"

            # 2. Test ygg clean --backups
            let bkp_res = (^nu $ygg_bin clean --backups | complete)
            assert equal $bkp_res.exit_code 0 $bkp_res.stderr
            assert ($bkp_res.stdout | str contains "Cleaned 5 old backup(s)")
            assert equal (ls $bkp_root | where type == "dir" | length) 20
            # Hashes still untouched
            assert equal ((open $state_file).hashes.orphan_fake? | default "") "stale"

            # 3. Test ygg clean --hashes
            let hash_res = (^nu $ygg_bin clean --hashes | complete)
            assert equal $hash_res.exit_code 0 $hash_res.stderr
            assert ($hash_res.stdout | str contains "Purged")
            let final_state = (open $state_file)
            assert ("orphan_fake" not-in ($final_state.hashes | columns))

            # 4. Test that ygg apply automatically purges orphan hashes and rotates backups
            let state_with_orphan = ($final_state | upsert hashes {
                orphan_during_apply: "stale"
            })
            $state_with_orphan | to json | save -f $state_file
            for i in 1..25 {
                mkdir ($bkp_root | path join $"2026110($i)_120000_000000")
            }
            let apply_res = (^nu $ygg_bin apply | complete)
            assert equal $apply_res.exit_code 0 $apply_res.stderr
            let post_apply_state = (open $state_file)
            assert ("orphan_during_apply" not-in ($post_apply_state.hashes | columns))
            assert ((ls $bkp_root | where type == "dir" | length) <= 20)
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

export def test_cli_doctor_fix [] {
    with-temp-ygg { |home|
        let sb = $env.YGG_SANDBOX
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: "cachyos" } {
            ensure-ygg-dirs $home
            let sec = ($home | path join "secrets.toml")
            "val = 1" | save -f $sec
            ^chmod 644 $sec | complete | ignore

            let cfg = ($sb | path join ".config")
            mkdir $cfg
            let dead_link = ($cfg | path join "broken.conf")
            ^ln -s ($home | path join "not-existing-target") $dead_link

            # Check doctor without --fix reports errors/warnings and does not mutate
            let res_audit = (^nu $ygg_bin doctor --sandbox $sb | complete)
            assert equal $res_audit.exit_code 1
            assert ($res_audit.stdout | str contains "perm")
            assert ($res_audit.stdout | str contains "orphan_link")

            # Check doctor --fix -y fixes perm and orphan_link
            let res_fix = (^nu $ygg_bin doctor --fix -y --sandbox $sb | complete)
            assert equal $res_fix.exit_code 0 $res_fix.stderr
            assert ($res_fix.stdout | str contains "Fixed findings:")
            assert ($res_fix.stdout | str contains "perm")
            assert ($res_fix.stdout | str contains "orphan_link")

            # Verify on filesystem
            let mode = (ls -lD $sec | get -o 0.mode | default "")
            assert ($mode =~ 'rw-------') "Expected 0600 mode after fix"
            assert (try { ($dead_link | path type) != "symlink" } catch { true }) "Expected orphan link removed"

            # Check doctor --fix --json output structure
            let res_json = (^nu $ygg_bin doctor --fix -y --json --sandbox $sb | complete)
            assert equal $res_json.exit_code 0
            let parsed = ($res_json.stdout | from json)
            assert ($parsed | columns | any { |c| $c == "findings" })
            assert ($parsed | columns | any { |c| $c == "fixed" })
        }
    }
}

export def test_cli_completions_generation [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb } {
            let nu_comp = (^nu $ygg_bin completions nu | complete)
            assert equal $nu_comp.exit_code 0 $nu_comp.stderr
            assert ($nu_comp.stdout | str contains "export extern ygg") "Expected extern ygg definition"
            # Verify generated nushell script parses without error
            let nu_parse = (^nu -c $nu_comp.stdout | complete)
            assert equal $nu_parse.exit_code 0 $nu_parse.stderr

            let zsh_comp = (^nu $ygg_bin completions zsh | complete)
            assert equal $zsh_comp.exit_code 0 $zsh_comp.stderr
            assert ($zsh_comp.stdout | str contains "#compdef ygg") "Expected zsh compdef"

            let bash_comp = (^nu $ygg_bin completions bash | complete)
            assert equal $bash_comp.exit_code 0 $bash_comp.stderr
            assert ($bash_comp.stdout | str contains "complete -F") "Expected bash complete -F"

            let fish_comp = (^nu $ygg_bin completions fish | complete)
            assert equal $fish_comp.exit_code 0 $fish_comp.stderr
            assert ($fish_comp.stdout | str contains "complete -c ygg") "Expected fish complete"

            let ps1_comp = (^nu $ygg_bin completions ps1 | complete)
            assert equal $ps1_comp.exit_code 0 $ps1_comp.stderr
            assert ($ps1_comp.stdout | str contains "Register-ArgumentCompleter") "Expected ps1 Register-ArgumentCompleter"

            let pwsh_comp = (^nu $ygg_bin completions powershell | complete)
            assert equal $pwsh_comp.exit_code 0 $pwsh_comp.stderr
            assert ($pwsh_comp.stdout | str contains "Register-ArgumentCompleter") "Expected powershell alias support"

            let invalid_comp = (^nu $ygg_bin completions invalid | complete)
            assert ($invalid_comp.exit_code != 0) "Expected error for invalid shell"
        }
    }
}






