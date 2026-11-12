# tests/test_state.nu
use std/assert
use ../src/state.nu *
use helpers.nu [with-temp-ygg]

export def test_state_roundtrip_and_dirs [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        assert (($home | path join "modules" | path exists))
        assert (($home | path join ".state" | path exists))
        assert (($home | path join ".state" "backups" | path exists))
        assert (($home | path join ".state" "env" | path exists))

        let st = (load-state $home | upsert hashes { test_key: "abc" })
        save-state $home $st
        assert equal ((load-state $home).hashes.test_key) "abc"

        # Check default state structure
        let loaded = (load-state $home)
        assert ("links" in $loaded)
        assert ("copies" in $loaded)
        assert ("hashes" in $loaded)

        # Check detect-host-os
        let host_info = (detect-host-os)
        assert ($host_info.os in ["linux", "windows", "macos", "unix"])
        assert (($host_info.auto_scopes | length) > 0)

        # Check get-ygg-home under YGG_HOME
        assert equal (get-ygg-home) ($home | path expand)
    }
}

export def test_expand_target_path_with_sandbox_and_tokens [] {
    let sb = ($env.PWD | path join "fake-sb-check")
    let p = (expand-target-path "~/.config/niri" --sandbox $sb)
    assert equal $p ($sb | path join ".config" "niri")

    # Also verify token expansions with sandbox
    let p_appdata = (expand-target-path "$APPDATA/test" --sandbox $sb)
    assert equal $p_appdata ($sb | path join "AppData" "Roaming" "test")

    let p_local = (expand-target-path "$LOCALAPPDATA/test" --sandbox $sb)
    assert equal $p_local ($sb | path join "AppData" "Local" "test")

    let p_docs = (expand-target-path "$DOCUMENTS/test" --sandbox $sb)
    assert equal $p_docs ($sb | path join "Documents" "test")

    # Verify detect-host-os override
    with-env { YGG_HOST_OS_OVERRIDE: "windows" } {
        let win_os = (detect-host-os)
        assert equal $win_os.os "windows"
        assert equal $win_os.distro "windows"
        assert ($win_os.auto_scopes | any { |s| $s == "windows" })
    }
}

export def test_backup_moves_regular_file_outside_config [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let victim = ($home | path join "fake-config.toml")
        "hello" | save -f $victim
        let bak = (backup-existing $home $victim)
        assert (not ($victim | path exists))
        assert ($bak | path exists)
        assert ($bak | str starts-with ($home | path join ".state" "backups"))
    }
}

export def test_assert_sandbox_home [] {
    let fake_home = ($env.PWD | path join "fake-ygg-home")
    let fake_sb = ($env.PWD | path join "fake-preview")

    # 1. No sandbox -> success
    with-env { YGG_SANDBOX: "", YGG_HOME: "" } {
        assert-sandbox-home ""
    }

    # 2. Sandbox provided, YGG_HOME set -> success
    with-env { YGG_SANDBOX: "", YGG_HOME: $fake_home } {
        assert-sandbox-home $fake_sb
    }

    # 3. YGG_SANDBOX in env, YGG_HOME set -> success
    with-env { YGG_SANDBOX: $fake_sb, YGG_HOME: $fake_home } {
        assert-sandbox-home ""
    }

    # 4. Sandbox provided, YGG_HOME empty -> error
    let err_arg = (try {
        with-env { YGG_SANDBOX: "", YGG_HOME: "" } {
            assert-sandbox-home $fake_sb
        }
        ""
    } catch { |e| $e.msg })
    assert ($err_arg | str contains "YGG_HOME")

    # 5. YGG_SANDBOX in env, YGG_HOME empty -> error
    let err_env = (try {
        with-env { YGG_SANDBOX: $fake_sb, YGG_HOME: "" } {
            assert-sandbox-home ""
        }
        ""
    } catch { |e| $e.msg })
    assert ($err_env | str contains "YGG_HOME")
}


export def test_to_win32_path_preserves_symlink_and_replaces_slashes [] {
    with-temp-ygg { |home|
        let real_dir = ($home | path join "real_dir")
        let link_dir = ($home | path join "lnk")
        mkdir $real_dir
        ^ln -s $real_dir $link_dir

        let win_p = (to-win32-path $link_dir)
        assert (not ($win_p | str contains "/"))
        assert ($win_p | str ends-with "\\lnk")
        assert (not ($win_p | str ends-with "\\real_dir"))
    }
}

export def test_host_lock_prevents_concurrent_runs_and_cleans_stale [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home

        # 1. Acquire lock creates file with expected metadata
        let lock_file = (acquire-host-lock $home "apply")
        assert ($lock_file | path exists) "Lock file must be created"
        let lock_content = (open $lock_file | from json)
        assert equal $lock_content.command "apply"
        assert equal $lock_content.pid $nu.pid

        # 2. Prevent concurrent runs: attempt to acquire by active process fails
        let res = (try { acquire-host-lock $home "add" } catch { |e| { err: ($e.msg? | default ($e | to nuon)) } })
        assert ($res.err? != null) "Expected lock conflict error"
        assert ($res.err | str contains "Host is locked by another ygg instance")

        # 3. Release lock removes lock file
        release-host-lock $lock_file
        assert (not ($lock_file | path exists)) "Lock file must be removed after release"

        # 4. Stale lock recovery: non-existent PID allows new acquire
        let stale_file = ($home | path join ".state" "host.lock")
        {
            pid: 99999999,
            timestamp: "2026-11-08T00:00:00Z",
            command: "stale_cmd"
        } | to json | save -f $stale_file
        assert ($stale_file | path exists)

        let new_lock = (acquire-host-lock $home "update")
        assert ($new_lock | path exists)
        let new_content = (open $new_lock | from json)
        assert equal $new_content.command "update"
        assert equal $new_content.pid $nu.pid
        release-host-lock $new_lock
        assert (not ($new_lock | path exists))

        # 5. --no-lock and YGG_NO_LOCK=1 bypass lock creation
        let no_lock_res = (acquire-host-lock $home "apply" --no-lock)
        assert equal $no_lock_res ""
        assert (not ($home | path join ".state" "host.lock" | path exists))

        with-env { YGG_NO_LOCK: "1" } {
            let env_no_lock = (acquire-host-lock $home "apply")
            assert equal $env_no_lock ""
            assert (not ($home | path join ".state" "host.lock" | path exists))
        }
    }
}

export def test_host_lock_is_exclusive_under_race [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let tests_dir = if ($env.FILE_PWD? != null) { $env.FILE_PWD } else if (($env.PWD | path join "tests") | path exists) { $env.PWD | path join "tests" } else { $env.PWD }
        let src = ($tests_dir | path join "../src" | path expand)
        let script = $"use state.nu *; try { acquire-host-lock '($home)' 'apply' | ignore; sleep 2sec; print WON } catch { print LOST }"
        let outs = (1..8 | par-each { |_| ^nu -I $src -c $script | complete | get stdout | str trim })
        assert equal ($outs | where { |o| $o == "WON" } | length) 1
    }
}

export def test_host_lock_foreign_live_pid_and_foreign_host [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let lf = ($home | path join ".state" "host.lock")
        let me = (sys host | get hostname)
        { pid: 1, timestamp: "x", command: "apply", user: "root", host: $me } | to json | save -f $lf
        let r1 = (try { acquire-host-lock $home "apply"; "taken" } catch { "refused" })
        assert equal $r1 "refused"
        { pid: 2147483646, timestamp: "x", command: "apply", user: "u", host: "other-host" } | to json | save -f $lf
        let r2 = (try { acquire-host-lock $home "apply"; "taken" } catch { |e| $e.msg })
        assert ($r2 | str contains "other-host")
        { pid: 2147483646, timestamp: "x", command: "apply", user: "u", host: $me } | to json | save -f $lf
        let l3 = (acquire-host-lock $home "apply")
        assert equal (open $lf | from json | get pid) $nu.pid
        release-host-lock $l3
        assert (not ($lf | path exists))
    }
}

export def test_release_host_lock_ignores_foreign_owner [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let lf = ($home | path join ".state" "host.lock")
        { pid: 1, host: (sys host | get hostname) } | to json | save -f $lf
        release-host-lock $lf
        assert ($lf | path exists)
    }
}

export def test_journal_v2_states [] {
    with-temp-ygg { |home|
        assert equal (check-pending-journal $home).state "none"
        begin-journal-transaction $home { modules: [], env: { A: "secret-ish" } }
        let j = (open ($home | path join ".state" "journal.json"))
        assert equal $j.version 2
        assert ("plan" not-in ($j | columns))
        assert equal $j.pid $nu.pid
        assert equal (check-pending-journal $home).state "active"

        record-journal-step $home "packages" "COMMITTED"
        record-journal-step $home "links" "IN_PROGRESS"
        fail-journal-transaction $home "boom"
        let st = (check-pending-journal $home)
        assert equal $st.state "failed"
        assert equal $st.failed_step "links"
        assert equal $st.error "boom"

        commit-journal-transaction $home
        assert equal (check-pending-journal $home).state "none"
    }
}

export def test_journal_dead_pid_is_interrupted [] {
    with-temp-ygg { |home|
        begin-journal-transaction $home { modules: [] }
        let jf = ($home | path join ".state" "journal.json")
        open $jf | upsert pid 2147483646 | to json | save -f $jf
        assert equal (check-pending-journal $home).state "interrupted"
        "{\"timestamp\":\"x\",\"steps\":{}}" | save -f $jf     # v1
        assert equal (check-pending-journal $home).state "interrupted"
    }
}

export def test_rotate_backups_and_gc_state_hashes [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        # Создаем 25 фиктивных каталогов бэкапов
        for i in 1..25 {
            mkdir ($home | path join ".state" "backups" $"2026110($i)_120000_000000")
        }
        let removed = (rotate-backups $home --max-count 20)
        assert (($removed | length) == 5) "Expected 5 old backups rotated"
        
        # Проверяем GC хэшей
        save-state $home { links: {}, copies: {}, hashes: { "pkg:keep": "hash1", "pkg:orphan": "hash2" } }
        let purged = (gc-state-hashes $home ["pkg:keep"] [])
        assert ($purged == 1) "Expected 1 orphan hash removed"
        let st = (load-state $home)
        assert ("pkg:orphan" not-in ($st.hashes | columns)) "Orphan hash must be purged"
    }
}

export def test_tests_have_no_literal_tmp_paths [] {
    let tests_dir = if ($env.FILE_PWD? != null) { $env.FILE_PWD } else if (($env.PWD | path join "tests") | path exists) { $env.PWD | path join "tests" } else { $env.PWD }
    let hits = (glob (($tests_dir | path join "*.nu") | str replace --all '\' '/') | each { |f|
        open --raw $f | lines | enumerate
        | where { |l| ($l.item | str contains '"/tmp/') and not ($l.item | str contains "str contains") }
        | each { |l| $"($f | path basename):($l.index + 1)" }
    } | flatten)
    assert equal $hits []
}

export def test_load_state_refuses_corrupted_file [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sf = ($home | path join ".state" "state.json")
        "{broken" | save -f $sf
        let r = (try { load-state $home; "loaded" } catch { |e| $e.msg })
        assert ($r | str contains "Cannot parse")
        assert equal (open --raw $sf) "{broken"
    }
}

export def test_save_state_keeps_bak [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        save-state $home { links: {}, copies: {}, hashes: { a: "1" }, packages: {} }
        save-state $home { links: {}, copies: {}, hashes: { a: "2" }, packages: {} }
        assert equal (open --raw ($home | path join ".state" "state.json.bak") | from json).hashes.a "1"
    }
}

export def test_gc_hashes_by_prefix [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        save-state $home { links: {}, copies: {}, packages: {}, hashes: {
            "pkg:cargo": "h", "pkg:pnpm": "h", "on_change:m:k": "h", "svc:systemd-user:x": "enabled",
            "setup:m:build.v2:x": "h", "setup:gone:k": "h", "legacy-key": "h" } }
        let n = (gc-state-hashes $home ["pkg:cargo"] ["m"])
        assert equal $n 4
        assert equal ((load-state $home).hashes | columns | sort) ["legacy-key", "pkg:cargo", "setup:m:build.v2:x"]
    }
}

export def test_non_integer_pid_in_journal_and_lock_does_not_throw [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let jfile = ($home | path join ".state" "journal.json")
        {
            version: 2, status: "in_progress", pid: "abc", started: "2026-11-08T00:00:00Z",
            plan_hash: "h", steps: { links: "IN_PROGRESS" }
        } | to json | save -f $jfile
        assert equal (check-pending-journal $home).state "interrupted"

        let lock = ($home | path join ".state" "host.lock")
        { pid: "not-a-pid", timestamp: "2026-11-08T00:00:00Z", command: "x" } | to json | save -f $lock
        let got = (acquire-host-lock $home "update")
        assert equal (open $got | from json | get pid) $nu.pid
        release-host-lock $got
    }
}
