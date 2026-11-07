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
