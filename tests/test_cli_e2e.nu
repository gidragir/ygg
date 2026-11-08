use std/assert
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
