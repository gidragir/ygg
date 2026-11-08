use std/assert
use ../src/state.nu *
use ../src/sdk.nu *
use helpers.nu [with-temp-ygg]

export def test_onchange_skips_recovers_missing_target_and_rolls_back_on_error [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let mod_dir = ($home | path join "modules" "m")
        mkdir $mod_dir
        let src = ($mod_dir | path join "cfg.yaml")
        let out = ($home | path join "built.yaml")
        "v1" | save -f $src

        with-env { YGG_HOME: $home, YGG_MODULE_DIR: $mod_dir, YGG_FORCE: "false" } {
            # 1. First run executes
            let r1 = (onchange "build" ["cfg.yaml"] --target $out { cp $src $out })
            assert equal $r1 true
            assert ($out | path exists)

            # 2. Second run skips
            let r2 = (onchange "build" ["cfg.yaml"] --target $out { cp $src $out })
            assert equal $r2 false

            # 3. Deleted target triggers self-healing re-run
            rm $out
            let r3 = (onchange "build" ["cfg.yaml"] --target $out { cp $src $out })
            assert equal $r3 true
            assert ($out | path exists)

            # 4. Failing block does NOT record new hash
            "v2" | save -f $src
            let failed = (try { onchange "build" ["cfg.yaml"] { error make { msg: "boom" } }; false } catch { true })
            assert $failed
            let r4 = (onchange "build" ["cfg.yaml"] { cp $src $out })
            assert equal $r4 true
        }
    }
}

export def test_onchange_force_flag_triggers_execution [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let mod_dir = ($home | path join "modules" "m")
        mkdir $mod_dir
        let src = ($mod_dir | path join "cfg.yaml")
        let out = ($home | path join "built.yaml")
        "hello" | save -f $src

        with-env { YGG_HOME: $home, YGG_MODULE_DIR: $mod_dir, YGG_FORCE: "false" } {
            let r1 = (onchange "forced_task" ["cfg.yaml"] --target $out { cp $src $out })
            assert equal $r1 true

            # Second call without force skips
            let r2 = (onchange "forced_task" ["cfg.yaml"] --target $out { cp $src $out })
            assert equal $r2 false
        }

        # Second call with YGG_FORCE=true forces re-run even with same hash and target existing
        with-env { YGG_HOME: $home, YGG_MODULE_DIR: $mod_dir, YGG_FORCE: "true" } {
            let r3 = (onchange "forced_task" ["cfg.yaml"] --target $out { cp $src $out })
            assert equal $r3 true
        }
    }
}

export def test_onchange_external_failure_does_not_record_hash [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let mod_dir = ($home | path join "modules" "m")
        mkdir $mod_dir
        let src = ($mod_dir | path join "cfg.yaml")
        "v1" | save -f $src

        with-env { YGG_HOME: $home, YGG_MODULE_DIR: $mod_dir, YGG_FORCE: "false" } {
            let failed = (try { onchange "k" ["cfg.yaml"] { ^false }; false } catch { true })
            assert $failed
            let r = (onchange "k" ["cfg.yaml"] { })
            assert equal $r true
        }
    }
}

export def test_merge_json_missing_and_symlink_target [] {
    with-temp-ygg { |home|
        let frag = ($home | path join "plugins.json")
        let dummy = ($home | path join "dummy.json")
        let live = ($home | path join "gemini/config.json")
        '{"plugins":{"a":true},"ui":{"font":14}}' | save -f $frag
        '{"session":"secret-token","ui":{"theme":"dark"}}' | save -f $dummy
        mkdir ($live | path dirname)
        ^ln -s $dummy $live

        merge-json $frag $live --mode "0600"
        assert equal (($live | path type)) "file"
        if ($nu.os-info.family != "windows") {
            assert equal (ls -l $live | get 0.mode) "rw-------"
        }
        let res = (open $live)
        assert equal $res.plugins.a true
        assert equal $res.ui.font 14
        assert equal $res.session "secret-token"
        assert equal $res.ui.theme "dark"
    }
}

export def test_merge_json_missing_and_empty_target [] {
    with-temp-ygg { |home|
        let frag = ($home | path join "fragment.json")
        let missing_dest = ($home | path join "deep/nested/config.json")
        let empty_dest = ($home | path join "deep/nested/empty.json")
        '{"feature":{"enabled":true}}' | save -f $frag

        # 1. Target is completely missing (should create parent directories and write file)
        merge-json $frag $missing_dest --mode "0600"
        assert equal (($missing_dest | path type)) "file"
        let res1 = (open $missing_dest)
        assert equal $res1.feature.enabled true

        # 2. Target is an empty (0-byte) file
        "" | save -f $empty_dest
        assert equal (ls -D $empty_dest | get 0.size) 0b
        merge-json $frag $empty_dest --mode "0600"
        assert equal (($empty_dest | path type)) "file"
        let res2 = (open $empty_dest)
        assert equal $res2.feature.enabled true
    }
}

export def test_merge_json_invalid_host_json_is_preserved [] {
    with-temp-ygg { |home|
        let frag = ($home | path join "frag.json")
        let dest = ($home | path join "dest.json")
        '{"foo":"bar"}' | save -f $frag
        "{broken" | save -f $dest
        let failed = (try { merge-json $frag $dest; false } catch { true })
        assert $failed
        assert equal (open --raw $dest) "{broken"
    }
}

export def test_merge_json_non_record_host_json_is_preserved [] {
    with-temp-ygg { |home|
        let frag = ($home | path join "frag.json")
        let dest = ($home | path join "dest.json")
        '{"foo":"bar"}' | save -f $frag
        "[1,2]" | save -f $dest
        let failed = (try { merge-json $frag $dest; false } catch { true })
        assert $failed
        assert equal (open --raw $dest) "[1,2]"
    }
}

export def test_merge_json_dangling_symlink_becomes_file [] {
    with-temp-ygg { |home|
        let frag = ($home | path join "frag.json")
        let dest = ($home | path join "dest.json")
        '{"feature":{"enabled":true}}' | save -f $frag
        ^ln -s "/nonexistent/ygg-x" $dest
        merge-json $frag $dest
        assert equal ($dest | path type) "file"
        let res = (open $dest)
        assert equal $res.feature.enabled true
    }
}

export def test_merge_json_leaves_no_temp_files [] {
    with-temp-ygg { |home|
        let frag = ($home | path join "frag.json")
        let dest = ($home | path join "dest.json")
        '{"ui":{"theme":"dark"}}' | save -f $frag
        merge-json $frag $dest --mode "0600"
        assert equal (ls -a ($dest | path dirname) | where { |it| ($it.name | path basename) =~ 'tmp' } | length) 0
        if ($nu.os-info.family != "windows") {
            assert equal (ls -l $dest | get 0.mode) "rw-------"
        }
    }
}

export def test_export_secrets_soft_skip_and_filtering [] {
    with-temp-ygg { |home|
        let dest = ($home | path join ".hermes" ".env")

        # 1. secrets.toml does not exist -> soft skip without error
        export-secrets $dest --keys ["TOKEN"]
        assert not ($dest | path exists)

        # 2. secrets.toml exists with special characters
        let secrets_file = ($home | path join "secrets.toml")
        "[env]\nAPI_KEY = \"sk-12345\"\nTOKEN = \"pa$$w0rd=\\\"x\\\"&y=1\"\nK = \"it's\"\nP = \"a\\\\b\"\nUNUSED = \"skip-me\"\n" | save -f $secrets_file

        # Filter by keys
        export-secrets $dest --keys ["API_KEY", "TOKEN", "K", "P"]
        assert ($dest | path exists)
        if ($nu.os-info.family != "windows") {
            assert equal (ls -l $dest | get 0.mode) "rw-------"
        }
        let content = (open --raw $dest)
        assert ($content | str contains "API_KEY='sk-12345'")
        assert ($content | str contains "TOKEN='pa$$w0rd=\"x\"&y=1'")
        assert ($content | str contains "K='it\\'s'")
        assert ($content | str contains "P='a\\\\b'")
        assert not ($content | str contains "UNUSED")
    }
}

export def test_run_module_setup_subprocess_and_env [] {
    with-temp-ygg { |home|
        let mod_dir = ($home | path join "modules" "demo")
        mkdir $mod_dir
        let marker = ($home | path join "setup_done.json")

        let script = ('use sdk.nu *
let mod_cfg = ($env.YGG_MOD_CONFIG | from json)
let scopes = ($env.YGG_SCOPES | from json)
{
    home: $env.YGG_HOME,
    mod_dir: $env.YGG_MODULE_DIR,
    theme: $mod_cfg.theme,
    scopes: $scopes,
    dry_run: $env.YGG_DRY_RUN
} | to json | save -f "' + $marker + '"' + "\n")
        $script | save -f ($mod_dir | path join "setup.nu")

        let mod_plan = {
            name: "demo",
            dir: $mod_dir,
            config: { theme: "catppuccin" },
            scopes: ["linux", "pc"],
            has_setup: true
        }

        run-module-setup $home $mod_plan --dry-run
        assert ($marker | path exists)
        let res = (open $marker)
        assert equal $res.home $home
        assert equal $res.mod_dir $mod_dir
        assert equal $res.theme "catppuccin"
        assert equal $res.scopes ["linux", "pc"]
        assert equal $res.dry_run "true"

        # Failing setup.nu raises error
        let fail_script = "error make { msg: 'setup fatal error' }"
        $fail_script | save -f ($mod_dir | path join "setup.nu")
        let failed = (try { run-module-setup $home $mod_plan; false } catch { true })
        assert $failed
    }
}
