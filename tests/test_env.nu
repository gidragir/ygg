use std/assert
use ../src/state.nu *
use ../src/manifest.nu *
use ../src/env.nu *
use helpers.nu [with-temp-ygg]

export def test_env_special_chars_escaping [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "core")
        mkdir $m1
        "name = \"core\"\nos = [\"linux\"]" | save -f ($m1 | path join "ygg.toml")
        "EDITOR = \"nvim\"\nPROJECTS_ROOT = \"~/projects\"" | save -f ($m1 | path join "env.toml")
        "ll = \"eza -la\"" | save -f ($m1 | path join "aliases.toml")
        ("[env]\nWEIRD_SECRET = \"pa$$w0rd=\\\"foo\\\" & 'bar'=1\"") | save -f ($home | path join "secrets.toml")
        "[[modules]]\nname = \"core\"" | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        compile-environment $home $plan --sandbox $sb

        let env_nu = ($home | path join ".state/env/env.nu")
        let env_zsh = ($home | path join ".state/env/env.zsh")
        let env_ps1 = ($home | path join ".state/env/env.ps1")
        let local_nu = ($home | path join ".state/env/local.nu")
        assert ($env_nu | path exists)
        assert ($env_zsh | path exists)
        assert ($env_ps1 | path exists)
        assert ($local_nu | path exists)

        # Verify Nushell and Zsh actually parse and evaluate exact secret string without expansion
        let nu_cmd = ("source " + $env_nu + "; print --raw $env.WEIRD_SECRET")
        let nu_val = (^nu -c $nu_cmd)
        let zsh_cmd = ("source " + $env_zsh + "; printf '%s' \"$WEIRD_SECRET\"")
        let zsh_val = (^zsh -c $zsh_cmd)
        let expected_secret = ("pa$$w0rd=\"foo\" & 'bar'=1")
        assert equal $nu_val $expected_secret
        assert equal $zsh_val $expected_secret

        # Verify PowerShell escaping in env.ps1 (single quotes doubled)
        let ps1_content = (open --raw $env_ps1)
        assert ($ps1_content | str contains "$env:WEIRD_SECRET = 'pa$$w0rd=\"foo\" & ''bar''=1'")

        # Verify systemd 99-ygg.conf written in sandbox
        let conf_file = ($sb | path join ".config" "environment.d" "99-ygg.conf")
        assert ($conf_file | path exists)
        let conf_content = (open --raw $conf_file)
        assert ($conf_content | str contains ("WEIRD_SECRET=\"pa\\$\\$w0rd=\\\"foo\\\" & 'bar'=1\""))

        # Verify 0600 permissions on Unix
        if ($nu.os-info.family != "windows") {
            assert equal (^stat -c "%a" $env_nu | str trim) "600"
            assert equal (^stat -c "%a" $conf_file | str trim) "600"
        }
    }
}

export def test_env_aliases_powershell_recursion_guard [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "core")
        mkdir $m1
        "name = \"core\"\nos = [\"linux\"]" | save -f ($m1 | path join "ygg.toml")
        "git = \"git --no-pager\"\nll = \"eza -la\"\nnu = \"nu\"" | save -f ($m1 | path join "aliases.toml")
        "[[modules]]\nname = \"core\"" | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        compile-environment $home $plan --sandbox $sb

        let aliases_ps1 = ($home | path join ".state/env/aliases.ps1")
        assert ($aliases_ps1 | path exists)
        let ps1_content = (open --raw $aliases_ps1)

        # git should be guarded with Get-Command -CommandType Application
        assert ($ps1_content | str contains "function git { &(Get-Command -CommandType Application -Name 'git') --no-pager @args }")
        # ll target is eza, does not equal ll, so standard function wrapper
        assert ($ps1_content | str contains "function ll { eza -la @args }")
        # nu should be guarded with Get-Command -CommandType Application
        assert ($ps1_content | str contains "function nu { &(Get-Command -CommandType Application -Name 'nu') @args }")
    }
}

export def test_env_aliases_nushell_and_zsh [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "core")
        mkdir $m1
        "name = \"core\"\nos = [\"linux\"]" | save -f ($m1 | path join "ygg.toml")
        "ll = \"echo test_ok\"" | save -f ($m1 | path join "aliases.toml")
        "[[modules]]\nname = \"core\"" | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        compile-environment $home $plan --sandbox $sb

        let aliases_nu = ($home | path join ".state/env/aliases.nu")
        let aliases_zsh = ($home | path join ".state/env/aliases.zsh")
        assert ($aliases_nu | path exists)
        assert ($aliases_zsh | path exists)

        # Nushell test
        let nu_run = (^nu -c $"source ($aliases_nu); ll")
        assert equal ($nu_run | str trim) "test_ok"

        # Zsh test
        let zsh_run = (^zsh -c $"setopt aliases; source ($aliases_zsh); eval ll")
        assert equal ($zsh_run | str trim) "test_ok"
    }
}

export def test_env_local_nu_preservation [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = ($home | path join "sb")
        let local_nu = ($home | path join ".state/env/local.nu")
        "let my_custom_local = 42" | save -f $local_nu

        let m1 = ($home | path join "modules" "core")
        mkdir $m1
        "name = \"core\"\nos = [\"linux\"]" | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"core\"" | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        compile-environment $home $plan --sandbox $sb

        assert ($local_nu | path exists)
        let content = (open --raw $local_nu)
        assert equal $content "let my_custom_local = 42"
    }
}

export def test_env_without_secrets [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "core")
        mkdir $m1
        "name = \"core\"\nos = [\"linux\"]" | save -f ($m1 | path join "ygg.toml")
        "PUB_VAR = \"hello_world\"" | save -f ($m1 | path join "env.toml")
        "[[modules]]\nname = \"core\"" | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        compile-environment $home $plan --sandbox $sb

        let env_nu = ($home | path join ".state/env/env.nu")
        let env_zsh = ($home | path join ".state/env/env.zsh")
        assert ($env_nu | path exists)
        assert ($env_zsh | path exists)

        let nu_cmd = ("source " + $env_nu + "; print --raw $env.PUB_VAR")
        let nu_val = (^nu -c $nu_cmd)
        assert equal $nu_val "hello_world"

        let zsh_cmd = ("source " + $env_zsh + "; printf '%s' \"$PUB_VAR\"")
        let zsh_val = (^zsh -c $zsh_cmd)
        assert equal $zsh_val "hello_world"
    }
}

export def test_env_dry_run_no_files_written [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "core")
        mkdir $m1
        "name = \"core\"\nos = [\"linux\"]" | save -f ($m1 | path join "ygg.toml")
        "PUB_VAR = \"hello\"" | save -f ($m1 | path join "env.toml")
        "[[modules]]\nname = \"core\"" | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        compile-environment $home $plan --dry-run --sandbox $sb

        let env_nu = ($home | path join ".state/env/env.nu")
        assert (not ($env_nu | path exists))
    }
}

export def test_windows_env_script_escapes_and_merges_path [] {
    let s = (format-windows-env-script { K: "it's" } ["~/a", "C:/b"] "C:/Users/u")
    assert ($s | str contains "$ErrorActionPreference = 'Stop'")
    assert ($s | str contains "SetEnvironmentVariable('K', 'it''s', 'User')")
    assert ($s | str contains "GetEnvironmentVariable('Path', 'User')")
    assert ($s | str contains "'C:\\Users\\u\\a'")
    assert ($s | str contains "-notcontains")
}

export def test_windows_env_script_skips_path_block_when_empty [] {
    let s = (format-windows-env-script { K: "v" } [] "C:/Users/u")
    assert (not ($s | str contains "'Path'"))
}


export def test_env_expands_leading_tilde_and_home_only [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "core")
        mkdir $m1
        'name = "core"
os = ["linux"]' | save -f ($m1 | path join "ygg.toml")
        'TILDE_ONLY = "~"
TILDE_SUB = "~/.kube/config"
HOME_SUB = "$HOME/.cargo/bin"
MID_TILDE = "a/~/b"
OTHER_VAR = "$OTHER/x"
' | save -f ($m1 | path join "env.toml")
        "[[modules]]\nname = \"core\"" | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        compile-environment $home $plan --sandbox $sb

        let env_nu = ($home | path join ".state/env/env.nu")
        let env_zsh = ($home | path join ".state/env/env.zsh")
        let conf_file = ($sb | path join ".config/environment.d/99-ygg.conf")

        let nu_out = (^nu -c $"source ($env_nu); [$env.TILDE_ONLY, $env.TILDE_SUB, $env.HOME_SUB, $env.MID_TILDE, $env.OTHER_VAR] | to json -r") | from json
        assert equal $nu_out.0 $sb
        assert equal $nu_out.1 ($sb | path join ".kube/config")
        assert equal $nu_out.2 ($sb | path join ".cargo/bin")
        assert equal $nu_out.3 "a/~/b"
        assert equal $nu_out.4 "$OTHER/x"

        let conf_raw = (open --raw $conf_file)
        assert ($conf_raw | str contains $"TILDE_SUB=\"($sb)/.kube/config\"")
        assert ($conf_raw | str contains "OTHER_VAR=\"\\$OTHER/x\"")
    }
}

export def test_missing_secret_keys_audit [] {
    with-temp-ygg { |home|
        let tmpl = ($home | path join "secrets.example.toml")
        let sec = ($home | path join "secrets.toml")
        "# KEY_COMMENTED = \"x\"\n[env]\nKEY_PRESENT = \"placeholder\"\nKEY_EMPTY = \"placeholder\"\nKEY_MISSING = \"placeholder\"\n" | save -f $tmpl
        "[env]\nKEY_PRESENT = \"super_secret_val\"\nKEY_EMPTY = \"\"\n" | save -f $sec

        let missing = (missing-secret-keys $tmpl $sec)
        assert ("KEY_EMPTY" in $missing)
        assert ("KEY_MISSING" in $missing)
        assert (not ("KEY_PRESENT" in $missing))
        assert (not ("KEY_COMMENTED" in $missing))
    }
}
