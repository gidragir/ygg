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
        assert equal (get-ygg-home) $home
    }
}

export def test_expand_target_path_with_sandbox_and_tokens [] {
    let sb = "/tmp/ygg-sb-check"
    let p = (expand-target-path "~/.config/niri" --sandbox $sb)
    assert equal $p "/tmp/ygg-sb-check/.config/niri"

    # Also verify token expansions with sandbox
    let p_appdata = (expand-target-path "$APPDATA/test" --sandbox $sb)
    assert equal $p_appdata "/tmp/ygg-sb-check/AppData/Roaming/test"

    let p_local = (expand-target-path "$LOCALAPPDATA/test" --sandbox $sb)
    assert equal $p_local "/tmp/ygg-sb-check/AppData/Local/test"

    let p_docs = (expand-target-path "$DOCUMENTS/test" --sandbox $sb)
    assert equal $p_docs "/tmp/ygg-sb-check/Documents/test"

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
    # 1. No sandbox -> success
    with-env { YGG_SANDBOX: "", YGG_HOME: "" } {
        assert-sandbox-home ""
    }

    # 2. Sandbox provided, YGG_HOME set -> success
    with-env { YGG_SANDBOX: "", YGG_HOME: "/tmp/ygg-home" } {
        assert-sandbox-home "/tmp/preview"
    }

    # 3. YGG_SANDBOX in env, YGG_HOME set -> success
    with-env { YGG_SANDBOX: "/tmp/preview", YGG_HOME: "/tmp/ygg-home" } {
        assert-sandbox-home ""
    }

    # 4. Sandbox provided, YGG_HOME empty -> error
    let err_arg = (try {
        with-env { YGG_SANDBOX: "", YGG_HOME: "" } {
            assert-sandbox-home "/tmp/preview"
        }
        ""
    } catch { |e| $e.msg })
    assert ($err_arg | str contains "YGG_HOME")

    # 5. YGG_SANDBOX in env, YGG_HOME empty -> error
    let err_env = (try {
        with-env { YGG_SANDBOX: "/tmp/preview", YGG_HOME: "" } {
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
