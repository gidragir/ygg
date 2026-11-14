use std/assert
use ../src/state.nu *
use ../src/manifest.nu *
use ../src/link.nu *
use ../src/sdk.nu *
use helpers.nu [with-temp-ygg, test-link-dir, test-dangling-link]

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
        test-dangling-link ($home | path join "nonexistent-ygg-x") $dest
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
} | to json | save -f ' + "'" + $marker + "'" + "\n")
        $script | save -f ($mod_dir | path join "setup.nu")

        let mod_plan = {
            name: "demo",
            dir: $mod_dir,
            config: { theme: "catppuccin" },
            scopes: ["linux", "pc"],
            has_setup: true,
            setup: { dry_run_safe: true }
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

export def test_sdk_functions_respect_ygg_dry_run [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let mod_dir = ($home | path join "modules" "m")
        mkdir $mod_dir
        let src = ($mod_dir | path join "cfg.yaml")
        let out = ($home | path join "built.yaml")
        let frag = ($mod_dir | path join "frag.json")
        let dest_json = ($home | path join "target.json")
        let dest_env = ($home | path join ".env")
        "v1" | save -f $src
        '{"a": 1}' | save -f $frag
        "[env]\nAPI_KEY = \"sec\"\n" | save -f ($home | path join "secrets.toml")

        with-env { YGG_HOME: $home, YGG_MODULE_DIR: $mod_dir, YGG_DRY_RUN: "true", YGG_FORCE: "false" } {
            let r_dry = (onchange "build_dry" ["cfg.yaml"] { cp $src $out } --target $out)
            assert equal $r_dry false
            assert (not ($out | path exists))
            assert equal ((load-state $home).hashes | get -o "build_dry" | default "") ""

            merge-json $frag $dest_json
            assert (not ($dest_json | path exists))

            export-secrets $dest_env --keys ["API_KEY"]
            assert (not ($dest_env | path exists))
        }

        # Последующий реальный запуск выполняет onchange
        with-env { YGG_HOME: $home, YGG_MODULE_DIR: $mod_dir, YGG_DRY_RUN: "false", YGG_FORCE: "false" } {
            let r_real = (onchange "build_dry" ["cfg.yaml"] { cp $src $out } --target $out)
            assert equal $r_real true
            assert ($out | path exists)
        }
    }
}

export def test_onchange_wildcard_pattern_does_not_call_path_exists_on_glob [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let mod_dir = ($home | path join "modules" "m")
        mkdir ($mod_dir | path join "cfg")
        "a: 1\n" | save -f ($mod_dir | path join "cfg" "one.yaml")
        with-env { YGG_HOME: $home, YGG_MODULE_DIR: $mod_dir, YGG_FORCE: "false" } {
            let r1 = (onchange "globs" ["cfg/*.yaml", "nonexistent/*.yaml"] { })
            assert equal $r1 true
            let r2 = (onchange "globs" ["cfg/*.yaml", "nonexistent/*.yaml"] { })
            assert equal $r2 false
        }
    }
}

export def test_export_secrets_warns_on_missing_requested_keys [] {
    with-temp-ygg { |home|
        let dest = ($home | path join ".env")
        "[env]\nPRESENT_KEY = \"val123\"\nEMPTY_KEY = \"\"\n" | save -f ($home | path join "secrets.toml")
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let res = (with-env { YGG_HOME: $home } {
            ^nu $ygg_bin export-secrets $dest --keys "PRESENT_KEY,EMPTY_KEY,MISSING_KEY" | complete
        })
        assert equal $res.exit_code 0
        assert ($res.stderr | str contains "EMPTY_KEY")
        assert ($res.stderr | str contains "MISSING_KEY")
        assert (not ($res.stderr | str contains "val123"))
        let written = (open --raw $dest)
        assert ($written | str contains "PRESENT_KEY='val123'")
    }
}

export def test_safe_link_backs_up_real_dir_and_preserves_relative_src [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = $env.YGG_SANDBOX
        let plugins = ($sb | path join ".hermes" "plugins")
        let plugins2 = ($sb | path join ".hermes" "plugins2")
        mkdir $plugins $plugins2
        "p\n" | save -f ($plugins | path join "p.py")
        let dest = ($sb | path join ".hermes" "profiles" "coder" "plugins")
        mkdir $dest
        "host data\n" | save -f ($dest | path join "local.txt")
        let backups = ($home | path join ".state" "backups")

        with-env { YGG_HOME: $home } {
            # 1. Dry-run: nothing on disk changes
            with-env { YGG_DRY_RUN: "true" } {
                safe-link "../../plugins" "~/.hermes/profiles/coder/plugins"
            }
            assert equal ($dest | path type) "dir"
            assert equal (open --raw ($dest | path join "local.txt")) "host data\n"
            assert (ls $backups | is-empty)

            # 2. Real directory: moved to backups, replaced by a link with the literal relative target
            safe-link "../../plugins" "~/.hermes/profiles/coder/plugins"
            assert equal ($dest | path type) "symlink"
            assert equal (ls -lD $dest | get 0.target) "../../plugins"
            assert (not ($plugins | path join "plugins" | path exists))
            assert ($dest | path join "p.py" | path exists)
            let saved = (glob (($backups | path join "**" "local.txt") | str replace --all '\' '/'))
            assert equal ($saved | length) 1
            assert equal (open --raw ($saved | first)) "host data\n"

            # 3. Repeated call is a no-op (same inode)
            let inode1 = (ls -lD $dest | get 0.inode)
            safe-link "../../plugins" "~/.hermes/profiles/coder/plugins"
            assert equal (ls -lD $dest | get 0.inode) $inode1
            assert equal (glob (($backups | path join "**" "local.txt") | str replace --all '\' '/') | length) 1

            # 4. A different target replaces the link (no nested link inside the old target)
            safe-link "../../plugins2" "~/.hermes/profiles/coder/plugins"
            assert equal (ls -lD $dest | get 0.target) "../../plugins2"
            assert (not ($plugins2 | path join "plugins2" | path exists))
            assert ($plugins | path join "p.py" | path exists)

            # 5. Missing source is an error and creates nothing
            let other = ($sb | path join ".hermes" "profiles" "gemini" "plugins")
            let err = (try { safe-link "../../nope" "~/.hermes/profiles/gemini/plugins"; "ok" } catch { |e| $e.msg })
            assert ($err | str contains "does not exist")
            assert (($other | path type) == null)

            # 6. Dry-run over an existing different link changes nothing
            with-env { YGG_DRY_RUN: "true" } {
                safe-link "../../plugins" "~/.hermes/profiles/coder/plugins"
            }
            assert equal (ls -lD $dest | get 0.target) "../../plugins2"
        }

        # 7. Static check: no recursive deletion in the SDK
        assert (not (open --raw ($env.FILE_PWD | path join "../src/sdk.nu") | str contains "rm -rf"))
    }
}

# Plan -> ops -> apply-links -> run-link-hooks, like `ygg apply` does (no package / setup steps)
def apply-with-hooks [home: string, sb: string, --force, --dry-run]: nothing -> list {
    let plan = (resolve-effective-plan $home)
    let resolved = (resolve-link-targets $plan --sandbox $sb)
    let ops = (compute-link-ops $home $resolved --force=$force --sandbox $sb)
    if not $dry_run {
        apply-links $home $plan --force=$force --sandbox $sb | ignore
    }
    run-link-hooks $home $resolved.targets $ops --dry-run=$dry_run --force=$force --sandbox $sb
}

def hook-log [log: string]: nothing -> list<string> {
    if ($log | path exists) { open --raw $log | lines | where { |l| $l | str starts-with "hook: " } } else { [] }
}

export def test_run_link_hooks_lifecycle_dedup_and_failure_recovery [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = $env.YGG_SANDBOX
        let log = ($home | path join "pkg.log")
        let mod_src = ($home | path dirname | path join "hook-mod")
        mkdir ($mod_src | path join "cfg" "dir")
        for f in ["a.conf", "b.conf", "c.conf", "x.conf"] {
            $"($f)\n" | save -f ($mod_src | path join "cfg" $f)
        }
        "d1\n" | save -f ($mod_src | path join "cfg" "dir" "inner.conf")
        'name = "hm"
os = ["linux", "windows", "macos"]
[links."cfg/a.conf"]
target = "~/.config/hm/a.conf"
on_change = "reload-a"
[links."cfg/b.conf"]
target = "~/.config/hm/b.conf"
on_change = "reload-shared"
[links."cfg/c.conf"]
target = "~/.config/hm/c.conf"
on_change = "reload-shared"
[links."cfg/x.conf"]
target = "~/.config/hm/x.conf"
on_change = "reload-excluded"
[links."cfg/dir"]
target = "~/.config/hm/dir"
on_change = "reload-dir"
' | save -f ($mod_src | path join "ygg.toml")
        test-link-dir $mod_src ($home | path join "modules" "hm")
        "[[modules]]\nname = \"hm\"\nexclude = [\"cfg/x.conf\"]\n" | save -f ($home | path join "host.toml")
        let hkey = { |k| "on_change:hm:" + $k }
        let host_os_ovr = if $nu.os-info.family == "windows" { "windows" } else { "cachyos" }

        with-env { YGG_HOST_OS_OVERRIDE: $host_os_ovr, YGG_MOCK_PKG_LOG: $log } {
            # 1. First run: every hook fires once, the shared command once for two keys
            let r1 = (apply-with-hooks $home $sb)
            assert equal (hook-log $log | sort) ["hook: reload-a", "hook: reload-dir", "hook: reload-shared"]
            assert ($r1 | all { |r| $r.status == "ok" })
            let shared = ($r1 | where cmd == "reload-shared" | first)
            assert equal ($shared.keys | sort) ["cfg/b.conf", "cfg/c.conf"]
            let h1 = (load-state $home).hashes
            for k in ["cfg/a.conf", "cfg/b.conf", "cfg/c.conf", "cfg/dir"] {
                assert ((($h1 | get -o (do $hkey $k) | default "")) != "")
            }
            # Excluded link: no hook, no hash
            assert equal ($h1 | get -o (do $hkey "cfg/x.conf")) null
            assert (not ($sb | path join ".config" "hm" "x.conf" | path exists))

            # 2. No change -> nothing runs
            let r2 = (apply-with-hooks $home $sb)
            assert equal $r2 []
            assert equal (hook-log $log | length) 3

            # 3. One of two keys of the shared command changes -> runs once, both hashes recorded
            "b2\n" | save -f ($mod_src | path join "cfg" "b.conf")
            let r3 = (apply-with-hooks $home $sb)
            assert equal ($r3 | get cmd) ["reload-shared"]
            assert equal (hook-log $log | last) "hook: reload-shared"
            assert equal (hook-log $log | length) 4
            let h3 = (load-state $home).hashes
            assert ((($h3 | get (do $hkey "cfg/b.conf"))) != ($h1 | get (do $hkey "cfg/b.conf")))

            # 4. A file deep inside a directory link changes -> its hook runs
            "d2\n" | save -f ($mod_src | path join "cfg" "dir" "inner.conf")
            assert equal (apply-with-hooks $home $sb | get cmd) ["reload-dir"]

            # 5. A LINK op on the key fires the hook even without content changes
            rm ($sb | path join ".config" "hm" "a.conf")
            assert equal (apply-with-hooks $home $sb | get cmd) ["reload-a"]

            # 6. Failing hook: no exception, status failed, hash kept, retried next run
            "a2\n" | save -f ($mod_src | path join "cfg" "a.conf")
            let h_before = ((load-state $home).hashes | get (do $hkey "cfg/a.conf"))
            let r6 = (with-env { YGG_MOCK_HOOK_FAIL: "reload-a" } { apply-with-hooks $home $sb })
            assert equal ($r6 | length) 1
            assert equal ($r6 | first | get status) "failed"
            assert (($r6 | first | get stderr) != "")
            assert equal ((load-state $home).hashes | get (do $hkey "cfg/a.conf")) $h_before
            let r7 = (apply-with-hooks $home $sb)
            assert equal ($r7 | get cmd) ["reload-a"]
            assert equal ($r7 | first | get status) "ok"
            assert (((load-state $home).hashes | get (do $hkey "cfg/a.conf")) != $h_before)

            # 7. Dry-run: HOOK planned, nothing executed, state.hashes untouched
            "c2\n" | save -f ($mod_src | path join "cfg" "c.conf")
            let log_len = (hook-log $log | length)
            let state_before = (open --raw ($home | path join ".state" "state.json"))
            let r8 = (apply-with-hooks $home $sb --dry-run)
            assert equal ($r8 | get cmd) ["reload-shared"]
            assert equal ($r8 | first | get status) "dry_run"
            assert equal (hook-log $log | length) $log_len
            assert equal (open --raw ($home | path join ".state" "state.json")) $state_before
            assert equal (apply-with-hooks $home $sb | get cmd) ["reload-shared"]

            # 8. --force runs every (non-excluded) hook once
            let r9 = (apply-with-hooks $home $sb --force)
            assert equal ($r9 | get cmd | sort) ["reload-a", "reload-dir", "reload-shared"]
        }

        # 9. Sandbox without the mock log: never executed, hash not recorded
        "a3\n" | save -f ($mod_src | path join "cfg" "a.conf")
        let h_a = ((load-state $home).hashes | get (do $hkey "cfg/a.conf"))
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: "" } {
            let r10 = (apply-with-hooks $home $sb)
            assert equal ($r10 | get status) ["skipped_sandbox"]
            assert equal ((load-state $home).hashes | get (do $hkey "cfg/a.conf")) $h_a
        }
    }
}

export def test_hash_watch_set_matches_onchange_semantics [] {
    with-temp-ygg { |home|
        let mod_dir = ($home | path join "modules" "m")
        mkdir ($mod_dir | path join "cfg")
        "a: 1\n" | save -f ($mod_dir | path join "cfg" "one.yaml")
        let h1 = (hash-watch-set ["cfg", "missing/*.yaml"] $mod_dir)
        assert equal (hash-watch-set ["cfg/*.yaml"] $mod_dir) $h1
        "a: 2\n" | save -f ($mod_dir | path join "cfg" "one.yaml")
        assert ((hash-watch-set ["cfg"] $mod_dir) != $h1)
    }
}

export def test_declarative_services_reload_on_change [] {
    let plan = {
        services: {
            systemd: {
                user: {
                    reload_on_change: { "waybar.service": ["config.jsonc"] },
                    restart_on_change: { "ollama.service": ["config.json"] },
                    enable: ["syncthing.service"]
                }
            }
        }
    }
    let ops = [
        { op: "LINK", dest: "~/.config/waybar/config.jsonc", key: "config.jsonc" },
        { op: "BACKUP_REPLACE", dest: "~/.config/ollama/config.json", key: "config.json" }
    ]
    let actions = (run-service-actions "/tmp" $plan $ops --dry-run)
    assert (($actions | length) == 3) $"Expected 3 service actions, got ($actions | length)"

    let waybar = ($actions | where service == "waybar.service" | first)
    assert equal $waybar.service "waybar.service"
    assert equal $waybar.action "reload"

    let ollama = ($actions | where service == "ollama.service" | first)
    assert equal $ollama.service "ollama.service"
    assert equal $ollama.action "restart"

    let syncthing = ($actions | where service == "syncthing.service" | first)
    assert equal $syncthing.service "syncthing.service"
    assert equal $syncthing.action "enable"

    # If ops do not affect service triggers, service is not reloaded or restarted
    let unmatching_ops = [
        { op: "LINK", dest: "~/.config/kitty/kitty.conf", key: "kitty.conf" },
        { op: "OK", dest: "~/.config/waybar/config.jsonc", key: "config.jsonc" }
    ]
    let no_reload_actions = (run-service-actions "/tmp" $plan $unmatching_ops --dry-run)
    assert equal ($no_reload_actions | where service == "waybar.service" | length) 0
    assert equal ($no_reload_actions | where service == "ollama.service" | length) 0
    assert equal ($no_reload_actions | where service == "syncthing.service" | length) 1
}

export def test_declarative_services_mock_execution_and_failure [] {
    with-temp-ygg { |home|
        let mock_log = ($home | path join "mock.log")
        let plan = {
            services: {
                systemd: {
                    user: {
                        reload_on_change: { "waybar.service": ["config.jsonc"] },
                        restart_on_change: { "failing.service": ["fail.conf"] }
                    }
                },
                windows: {
                    restart_on_change: { "glazewm": ["config.yaml"] }
                }
            }
        }
        let ops = [
            { op: "LINK", dest: "~/.config/waybar/config.jsonc", key: "config.jsonc" },
            { op: "RELINK", dest: "~/.config/fail.conf", key: "fail.conf" },
            { op: "COPY_UPDATE", dest: "C:/config.yaml", key: "config.yaml" }
        ]

        with-env {
            YGG_MOCK_PKG_LOG: $mock_log,
            YGG_MOCK_SERVICE_FAIL: "failing.service"
        } {
            let actions = (run-service-actions $home $plan $ops)
            assert equal ($actions | length) 3

            let waybar = ($actions | where service == "waybar.service" | first)
            assert equal $waybar.status "ok"
            assert equal $waybar.cmd "systemctl --user reload waybar.service"

            let failing = ($actions | where service == "failing.service" | first)
            assert equal $failing.status "failed"
            assert ($failing.stderr | str contains "mock service failure")

            let glazewm = ($actions | where service == "glazewm" | first)
            assert equal $glazewm.status "ok"
            assert ($glazewm.cmd | str contains "Restart-Service -Name $args[0] glazewm")

            let log_content = (open --raw $mock_log)
            assert ($log_content | str contains "service: systemctl --user reload waybar.service")
            assert ($log_content | str contains "service: systemctl --user restart failing.service")
        }
    }
}

export def test_onchange_namespaces_and_migrates_key [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let mod_dir = ($home | path join "modules" "m")
        mkdir $mod_dir
        "v1" | save -f ($mod_dir | path join "cfg.yaml")
        with-env { YGG_HOME: $home, YGG_MODULE_DIR: $mod_dir, YGG_MODULE_NAME: "m", YGG_FORCE: "false" } {
            let h = (hash-watch-set ["cfg.yaml"] $mod_dir)
            save-state $home { links: {}, copies: {}, packages: {}, hashes: { build: $h } }
            let ran = (onchange "build" ["cfg.yaml"] { error make { msg: "must not run" } })
            assert equal $ran false
            let hashes = (load-state $home).hashes
            assert equal ($hashes | get -o "setup:m:build") $h
        }
    }
}


export def test_service_enable_runs_once_and_triggers_are_exact [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let log = ($home | path join "svc.log")
        let plan = { services: { systemd: { user: {
            enable: ["a.service"], restart_on_change: { "b.service": ["waybar/config"] } } } } }
        with-env { YGG_MOCK_PKG_LOG: $log } {
            run-service-actions $home $plan [] | ignore
            run-service-actions $home $plan [] | ignore
            assert equal (open --raw $log | lines | where { |l| $l | str contains "enable a.service" } | length) 1
            let other = [{ op: "LINK", key: "foot/config", dest: ($home | path join "sb/.config/foot/config"), src: "x" }]
            assert equal (run-service-actions $home $plan $other | where action == "restart") []
            let hit = [{ op: "RELINK", key: "waybar/config", dest: "d", src: "s" }]
            assert equal (run-service-actions $home $plan $hit | where action == "restart" | length) 1
            assert equal (run-service-actions $home $plan [] --force | where action == "enable" | length) 1
            # basename / suffix matching is gone
            let base = [{ op: "LINK", key: "x/y", dest: "/h/.config/waybar/config", src: "s" }]
            assert equal (run-service-actions $home $plan $base | where action == "restart") []
            # raw destination of the plan link matches
            let plan2 = ($plan | merge { links: [{ module: "m", key: "wb", dest_raw: "~/.config/waybar/config" }], services: { systemd: { user: { restart_on_change: { "w.service": ["~/.config/waybar/config"] } } } } })
            let rawop = [{ op: "LINK", module: "m", key: "wb", dest: "/h/.config/waybar/config", src: "s" }]
            assert equal (run-service-actions $home $plan2 $rawop | where action == "restart" | length) 1
        }
    }
}

export def test_service_enable_cache_key_survives_gc [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let plan = { services: { systemd: { system: { enable: ["a.service"] } }, launchd: { enable: ["l"] } } }
        with-env { YGG_MOCK_PKG_LOG: ($home | path join "svc.log") } {
            run-service-actions $home $plan [] | ignore
            let keys = ((load-state $home).hashes | columns)
            assert ("svc:systemd-system:a.service" in $keys)
            assert ("svc:launchd:l" in $keys)
            gc-state-hashes $home (collect-active-hash-keys $plan) [] | ignore
            let after = ((load-state $home).hashes | columns)
            assert ("svc:systemd-system:a.service" in $after)
            assert ("svc:launchd:l" in $after)
            assert (open --raw ($home | path join "svc.log") | str contains "service: sudo systemctl enable a.service")
        }
    }
}

export def test_service_systemd_system_requires_sudo [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let log = ($home | path join "svc.log")
        let plan = { services: { systemd: { system: { enable: ["a.service"] } } } }
        with-env { YGG_MOCK_PKG_LOG: $log, YGG_MOCK_SUDO_DENIED: "1" } {
            let res = (run-service-actions $home $plan [])
            assert equal ($res | first | get status) "failed"
            assert (not ($log | path exists)) "no service command may run without sudo"
            assert equal ((load-state $home).hashes | columns | where { |k| $k starts-with "svc:" }) []
        }
    }
}

export def test_service_sandbox_skips_before_sudo_check [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let bin = ($home | path join "shim")
        mkdir $bin
        let rec = ($home | path join "sudo.rec")
        "#!/bin/sh\necho called >> \"$0.rec\"\nexit 1\n" | save -f ($bin | path join "sudo")
        ^chmod +x ($bin | path join "sudo")
        let plan = { services: { systemd: { system: { enable: ["a.service"] } } } }
        with-env { PATH: ($env.PATH | prepend $bin), YGG_NONINTERACTIVE: "1", YGG_MOCK_PKG_LOG: "" } {
            let res = (run-service-actions $home $plan [] --sandbox ($home | path join "sb"))
            assert equal ($res | first | get status) "skipped_sandbox"
            assert (not (($bin | path join "sudo.rec") | path exists)) "sudo must not be invoked in sandbox"
            assert equal ((load-state $home).hashes | columns | where { |k| $k starts-with "svc:" }) []
        }
    }
}

# BUG-2 / RFC-055 p.7: the manifest names a launchd label; ygg derives the plist path and the gui/<uid> target
export def test_service_launchd_label_builds_plist_and_domain_target [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let log = ($home | path join "svc.log")
        let plan = { services: { launchd: { enable: ["com.example.agent"], restart_on_change: { "com.example.agent": ["k"] } } } }
        with-env { YGG_MOCK_PKG_LOG: $log } {
            let res = (run-service-actions $home $plan [{ op: "LINK", key: "k", dest: "d", src: "s" }])
            assert equal ($res | where status != "ok") []
        }
        let plist = ($nu.home-dir | path join "Library" "LaunchAgents" "com.example.agent.plist")
        let uid = (^id -u | str trim)
        let text = (open --raw $log)
        assert ($text | str contains $"service: launchctl load -w ($plist)") $text
        assert ($text | str contains $"service: launchctl kickstart -k gui/($uid)/com.example.agent") $text
    }
}
