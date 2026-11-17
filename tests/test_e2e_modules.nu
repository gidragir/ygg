use std/assert
use ../src/state.nu [ensure-ygg-dirs]
use ../src/link.nu [is-link-or-junction]
use ../scripts/release.nu [read-ygg-version]
use helpers.nu [with-temp-ygg, test-link-dir, test-dangling-link, snapshot-all, snapshot-tree]

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
            ^nu $ygg_bin init "my-dotfiles" --os "linux,windows,macos,cachyos"
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
            ^nu $ygg_bin init "scoped-mod" --os "linux,windows,macos,cachyos"
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

export def test_add_does_not_overwrite_broken_host_toml [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "another-mod")
        mkdir $mod_src
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_MOCK_PKG_LOG: ($home | path join "pkg.log") } {
            cd $mod_src
            ^nu $ygg_bin init "another-mod" --os "linux,windows,macos,cachyos"

            let host_file = ($home | path join "host.toml")
            let broken_content = "[[modules\nname = bad_syntax\n"
            $broken_content | save -f $host_file

            let res = (^nu $ygg_bin add $mod_src | complete)
            assert ($res.exit_code != 0)
            assert equal (open --raw $host_file) $broken_content
        }
    }
}

export def test_add_locked_target_does_not_register_module [] {
    with-temp-ygg { |home|
        let ygg_home = ($home | path join "ygg")
        let sb = ($home | path join "sb")
        let pkg_log = ($home | path join "pkg.log")
        let mod_src = ($home | path join "lockmod")
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
        "modules = []\n" | save -f ($ygg_home | path join "host.toml")

        let locked_dest = ($sb | path join ".config" "app")
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let res = (with-env {
            YGG_HOME: $ygg_home
            YGG_SANDBOX: $sb
            YGG_HOST_OS_OVERRIDE: "cachyos"
            YGG_MOCK_PKG_LOG: $pkg_log
            YGG_MOCK_LOCKED_PATHS: $locked_dest
            YGG_NONINTERACTIVE: "1"
        } { ^nu $ygg_bin add $mod_src --force --sandbox $sb | complete })
        assert ($res.exit_code != 0)
        assert ($res.stderr | str contains "(target_locked)")
        assert (not ((open --raw ($ygg_home | path join "host.toml")) | str contains "lockmod"))
        assert (not ($pkg_log | path exists))
    }
}

# regression: #8
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
        "name = \"keep\"\nos = [\"linux\", \"windows\", \"macos\", \"cachyos\"]\n" | save -f ($keep_src | path join "ygg.toml")
        test-link-dir $keep_src ($home | path join "modules" "keep")
        "[[modules]]\nname = \"keep\"\n" | save -f ($home | path join "host.toml")

        # Local module with a valid directory link and a package
        let good = ($home | path join "good-mod")
        mkdir ($good | path join "app")
        "x = 1\n" | save -f ($good | path join "app" "app.conf")
        'name = "good"
os = ["linux", "windows", "macos", "cachyos"]
[packages]
pacman = ["curl"]
winget = ["curl"]
[links]
app = "~/.config/app"
' | save -f ($good | path join "ygg.toml")

        # Local module whose link source is missing
        let bad = ($home | path join "bad-mod")
        mkdir $bad
        'name = "bad"
os = ["linux", "windows", "macos", "cachyos"]
[packages]
pacman = ["curl"]
winget = ["curl"]
[links]
"configs/nope" = "~/.config/nope"
' | save -f ($bad | path join "ygg.toml")

        # Remote-style modules (local bare repos)
        let remote_ok = (make-bare-module $home "remote-ok" {
            "ygg.toml": "name = \"remote-ok\"\nos = [\"linux\", \"windows\", \"macos\", \"cachyos\"]\n[links]\ncfg = \"~/.config/remote-cfg\"\n",
            "cfg/a.conf": "a\n"
        })
        let remote_bad = (make-bare-module $home "remote-bad" {
            "ygg.toml": "name = \"remote-bad\"\nos = [\"linux\", \"windows\", \"macos\", \"cachyos\"]\n[links]\n\"absent\" = \"~/.config/absent\"\n"
        })

        let host_os_ovr = if $nu.os-info.family == "windows" { "windows" } else { "cachyos" }
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: $host_os_ovr, YGG_MOCK_PKG_LOG: $pkg_log } {
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
            assert (glob ($clones | str replace --all '\' '/') | is-empty)

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
            assert (glob ($clones | str replace --all '\' '/') | is-empty)

            # 5. Real add of the valid module registers and applies it
            let r5 = (^nu $ygg_bin add $good --sandbox $sb | complete)
            assert equal $r5.exit_code 0 $r5.stderr
            assert ($r5.stdout | str contains "Added module good")
            assert (is-link-or-junction ($sb | path join ".config" "app"))
            let names = (open ($home | path join "host.toml") | get modules | get name)
            assert equal $names ["keep", "good"]
        }
    }
}

export def test_remove_refuses_real_home_under_sandbox [] {
    with-temp-ygg { |home|
        let fake_home = ($home | path join "fake_user_home")
        mkdir $fake_home
        let sb = ($home | path join "preview")
        mkdir $sb
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)

        let res = (with-env { HOME: $fake_home, YGG_HOME: "", YGG_SANDBOX: $sb } { ^nu $ygg_bin remove x | complete })
        assert ($res.exit_code != 0)
        assert ($res.stderr | str contains "YGG_HOME")
        assert (not (($fake_home | path join ".ygg") | path exists))
    }
}

