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
