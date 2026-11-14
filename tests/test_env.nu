use std/assert
use ../src/state.nu *
use ../src/manifest.nu *
use ../src/env.nu *
use ../src/sdk.nu [export-secrets]
use helpers.nu [with-temp-ygg, stat-mode]

export def test_env_special_chars_escaping [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "core")
        mkdir $m1
        "name = \"core\"\nos = [\"linux\", \"windows\", \"macos\"]" | save -f ($m1 | path join "ygg.toml")
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
        let expected_secret = ("pa$$w0rd=\"foo\" & 'bar'=1")
        assert equal $nu_val $expected_secret
        if (which zsh | is-not-empty) {
            let zsh_cmd = ("source " + $env_zsh + "; printf '%s' \"$WEIRD_SECRET\"")
            let zsh_val = (^zsh -c $zsh_cmd)
            assert equal $zsh_val $expected_secret
        }

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
            assert equal (stat-mode $env_nu) "600"
            assert equal (stat-mode $conf_file) "600"
        }
    }
}

export def test_env_aliases_powershell_recursion_guard [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "core")
        mkdir $m1
        "name = \"core\"\nos = [\"linux\", \"windows\", \"macos\"]" | save -f ($m1 | path join "ygg.toml")
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
        "name = \"core\"\nos = [\"linux\", \"windows\", \"macos\"]" | save -f ($m1 | path join "ygg.toml")
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
        if (which zsh | is-not-empty) {
            let zsh_run = (^zsh -c $"setopt aliases; source ($aliases_zsh); eval ll")
            assert equal ($zsh_run | str trim) "test_ok"
        }
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
        "name = \"core\"\nos = [\"linux\", \"windows\", \"macos\"]" | save -f ($m1 | path join "ygg.toml")
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
        "name = \"core\"\nos = [\"linux\", \"windows\", \"macos\"]" | save -f ($m1 | path join "ygg.toml")
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

        if (which zsh | is-not-empty) {
            let zsh_cmd = ("source " + $env_zsh + "; printf '%s' \"$PUB_VAR\"")
            let zsh_val = (^zsh -c $zsh_cmd)
            assert equal $zsh_val "hello_world"
        }
    }
}

export def test_env_dry_run_no_files_written [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "core")
        mkdir $m1
        "name = \"core\"\nos = [\"linux\", \"windows\", \"macos\"]" | save -f ($m1 | path join "ygg.toml")
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
os = ["linux", "windows", "macos"]' | save -f ($m1 | path join "ygg.toml")
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
        assert equal ($nu_out.1 | str replace --all "\\" "/") ($"($sb)/.kube/config" | str replace --all "\\" "/")
        assert equal ($nu_out.2 | str replace --all "\\" "/") ($"($sb)/.cargo/bin" | str replace --all "\\" "/")
        assert equal $nu_out.3 "a/~/b"
        assert equal $nu_out.4 "$OTHER/x"

        let conf_raw = (open --raw $conf_file)
        assert (($conf_raw | str replace --all "\\\\" "/" | str replace --all "\\" "/") | str contains ($"TILDE_SUB=\"($sb)/.kube/config\"" | str replace --all "\\" "/"))
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

export def test_external_secret_resolvers_in_memory [] {
    let resolved = (resolve-secret-value "eval:echo hello-secret")
    assert ($resolved == "hello-secret") "Expected resolved in-memory secret"
    let literal = (resolve-secret-value "my-regular-token")
    assert ($literal == "my-regular-token") "Expected literal value unchanged"

    # Test error handling when eval fails
    let err_caught = (try {
        resolve-secret-value "eval:nonexistent_cmd_xyz_123"
        false
    } catch { |e|
        assert ($e.msg | str contains "Failed to resolve eval secret")
        true
    })
    assert $err_caught "Expected error when eval: command fails"

    # Test error handling for external CLI resolvers when CLI fails or item not found
    let op_failed = (try { resolve-secret-value "op://nonexistent/vault/field"; false } catch { true })
    assert $op_failed "Expected failure on op secret resolution failure"
    let bw_failed = (try { resolve-secret-value "bw://nonexistent/password"; false } catch { true })
    assert $bw_failed "Expected failure on bw secret resolution failure"
    let pass_failed = (try { resolve-secret-value "pass:nonexistent-entry"; false } catch { true })
    assert $pass_failed "Expected failure on pass secret resolution failure"

    # Test integration with compile-environment
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "core")
        mkdir $m1
        'name = "core"
os = ["linux", "windows", "macos"]' | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"core\"" | save -f ($home | path join "host.toml")
        "[env]\nDYNAMIC_SECRET = \"eval:echo in-memory-token\"\nLITERAL_SECRET = \"literal-val\"" | save -f ($home | path join "secrets.toml")

        let plan = (resolve-effective-plan $home)
        compile-environment $home $plan --sandbox $sb

        let env_nu = ($home | path join ".state/env/env.nu")
        assert ($env_nu | path exists)
        let nu_cmd = $"source ($env_nu); print --raw $env.DYNAMIC_SECRET"
        let nu_val = (^nu -c $nu_cmd)
        assert equal $nu_val "in-memory-token"

        let nu_literal_cmd = $"source ($env_nu); print --raw $env.LITERAL_SECRET"
        let nu_literal_val = (^nu -c $nu_literal_cmd)
        assert equal $nu_literal_val "literal-val"
    }

    # Test compile-environment aborts and does NOT write env files when resolver fails
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "core")
        mkdir $m1
        'name = "core"
os = ["linux", "windows", "macos"]' | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"core\"\n\n[ygg.secrets]\nmaterialize = true\n" | save -f ($home | path join "host.toml")
        "[env]\nBROKEN_SECRET = \"eval:exit 42\"" | save -f ($home | path join "secrets.toml")

        let plan = (resolve-effective-plan $home)
        let failed = (try {
            compile-environment $home $plan --sandbox $sb
            false
        } catch {
            true
        })
        assert $failed "compile-environment must fail on broken external resolver"
        let env_nu = ($home | path join ".state/env/env.nu")
        assert (not ($env_nu | path exists)) "env.nu must not be written if resolver fails"
    }

    # Test integration with export-secrets (src/sdk.nu)
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        "[env]\nRESOLVED_API_KEY = \"eval:echo exported-token-123\"" | save -f ($home | path join "secrets.toml")
        let dest = ($home | path join "test.env")
        with-env { YGG_HOME: $home } {
            export-secrets $dest --keys ["RESOLVED_API_KEY"]
        }
        assert ($dest | path exists)
        let content = (open --raw $dest)
        assert ($content | str contains "RESOLVED_API_KEY='exported-token-123'")
    }
}

export def test_env_compiles_fish_shell_files [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let plan = {
            env: {
                EDITOR: "nvim",
                WEIRD_VAR: "it's a \\backslash\\ and 'quotes' test",
            },
            aliases: {
                g: "git status",
                ll: "echo 'hello \\ world'",
            }
        }
        compile-environment $home $plan
        let env_fish = ($home | path join ".state" "env" "env.fish")
        let alias_fish = ($home | path join ".state" "env" "aliases.fish")

        assert ($env_fish | path exists) "Expected env.fish to exist"
        assert ($alias_fish | path exists) "Expected aliases.fish to exist"

        let env_content = (open --raw $env_fish)
        assert ($env_content | str contains "set -gx EDITOR 'nvim'") "Expected Fish env definition"
        assert ($env_content | str contains "set -gx WEIRD_VAR 'it\\'s a \\\\backslash\\\\ and \\'quotes\\' test'") "Expected Fish env escaping"

        let alias_content = (open --raw $alias_fish)
        assert ($alias_content | str contains "alias g 'git status'") "Expected Fish alias definition"
        assert ($alias_content | str contains "alias ll 'echo \\'hello \\\\ world\\''") "Expected Fish alias escaping"

        # If fish is available, verify actual syntax and variable loading
        let fish_bin = (which fish | get -o path.0)
        if ($fish_bin != null) and ($fish_bin | path exists) {
            let fish_env_res = (^fish -c $"source ($env_fish); printf '%s' \"$WEIRD_VAR\"" | complete)
            assert equal $fish_env_res.exit_code 0
            assert equal $fish_env_res.stdout "it's a \\backslash\\ and 'quotes' test"

            let fish_alias_res = (^fish -c $"source ($alias_fish); ll" | complete)
            assert equal $fish_alias_res.exit_code 0
            assert equal ($fish_alias_res.stdout | str trim) "hello \\ world"
        }

        # Check permissions on Unix
        if ($nu.os-info.family != "windows") {
            assert equal (stat-mode $env_fish) "600"
            assert equal (stat-mode $alias_fish) "600"
        }
    }
}

export def test_classify_secret_value [] {
    assert equal (classify-secret-value "plain") { kind: "literal", ref: "plain" }
    assert equal (classify-secret-value "op://v/i/f") { kind: "op", ref: "op://v/i/f" }
    assert equal (classify-secret-value "bw://item") { kind: "bw", ref: "bw://item" }
    assert equal (classify-secret-value "pass:mail/x") { kind: "pass", ref: "mail/x" }
    assert equal (classify-secret-value "eval:echo 1") { kind: "eval", ref: "echo 1" }
    assert equal (classify-secret-value "literal:pass:abc") { kind: "literal", ref: "pass:abc" }
}

export def test_module_env_scheme_is_literal_and_not_executed [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = ($home | path join "sb"); mkdir $sb
        let marker = ($home | path join "pwned")
        let marker_lit = ($marker | str replace --all "\\" "/")
        let m = ($home | path join "modules" "m"); mkdir $m
        $"name = \"m\"\nos = [\"linux\", \"windows\", \"macos\"]\n[env]\nX = \"eval:touch ($marker_lit)\"\n" | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            compile-environment $home (resolve-effective-plan $home) --sandbox $sb
        }
        assert (not ($marker | path exists))
        assert (open --raw ($home | path join ".state" "env" "env.zsh") | str contains $"export X='eval:touch ($marker_lit)'")
    }
}

export def test_validate_secret_providers_reports_missing_cli [] {
    with-temp-ygg { |home|
        "K = \"op://v/i/f\"\nL = \"plain\"\n" | save -f ($home | path join "secrets.toml")
        let empty_bin = ($home | path join "empty-bin"); mkdir $empty_bin
        with-env { PATH: [$empty_bin] } {
            let errs = (validate-secret-providers $home)
            assert equal ($errs | length) 1
            assert ($errs.0 | str contains "op")
        }
    }
}

def write-mock-op [dir: string] {
    mkdir $dir
    "#!/bin/sh\necho S3CRET\n" | save -f ($dir | path join "op")
    ^chmod +x ($dir | path join "op")
}

def setup-secret-home [home: string, materialize: bool] {
    ensure-ygg-dirs $home
    let m = ($home | path join "modules" "m"); mkdir $m
    "name = \"m\"\nos = [\"linux\", \"windows\", \"macos\"]\n" | save -f ($m | path join "ygg.toml")
    $"[[modules]]\nname = \"m\"\n\n[ygg.secrets]\nmaterialize = ($materialize)\n" | save -f ($home | path join "host.toml")
    "K = \"op://v/i/f\"\nQ = \"op://v/it'em/$(id)\"\nP = \"plain\"\n" | save -f ($home | path join "secrets.toml")
}

export def test_secret_provider_argv [] {
    assert equal (secret-provider-argv "op" "op://v/i/f") ["op", "read", "op://v/i/f"]
    assert equal (secret-provider-argv "bw" "bw://item/field") ["bw", "get", "field", "item"]
    assert equal (secret-provider-argv "bw" "bw://item") ["bw", "get", "password", "item"]
    assert equal (secret-provider-argv "pass" "foo/bar") ["pass", "show", "foo/bar"]
    assert equal (secret-provider-argv "eval" "echo 1") ["nu", "-c", "echo 1"]
}

export def test_restrict_file_access [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        let p = ($home | path join "secret.txt")
        "secret" | save -f $p
        assert (restrict-file-access $p)
        assert equal (ls -l $p | get 0.mode) "rw-------"
    }
}

export def test_external_secret_is_lazy_by_default [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        let sb = ($home | path join "sb"); mkdir $sb
        let bin = ($home | path join "mock-bin"); write-mock-op $bin
        setup-secret-home $home false
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", PATH: ($env.PATH | prepend $bin) } {
            compile-environment $home (resolve-effective-plan $home) --sandbox $sb
            let leaked = (glob (($home | path join "**" "*") | str replace --all '\' '/') | where { |p| ($p | path type) == "file" and not ($p | str contains "mock-bin") }
                | where { |p| open --raw $p | str contains "S3CRET" })
            assert equal $leaked []
            let zsh = (open --raw ($home | path join ".state" "env" "env.zsh"))
            assert ($zsh | str contains "export K=\"$(op read 'op://v/i/f')\"")
            assert ($zsh | str contains "export P='plain'")
            # Review Focus 1: кавычка и $( ) в ссылке не ломают файл и не исполняются
            if (which zsh | is-not-empty) {
                let chk = (^zsh -n ($home | path join ".state" "env" "env.zsh") | complete)
                assert equal $chk.exit_code 0
            }
            assert (not ($zsh | str contains "$(id)\"")) "ref must stay inside single quotes"
            let env_nu = ($home | path join ".state" "env" "env.nu")
            assert equal (^nu -c $"source '($env_nu)'; $env.K" | complete | get stdout | str trim) "S3CRET"
        }
    }
}

export def test_external_secret_materialized_on_opt_in [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        let sb = ($home | path join "sb"); mkdir $sb
        let bin = ($home | path join "mock-bin"); write-mock-op $bin
        setup-secret-home $home true
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", PATH: ($env.PATH | prepend $bin) } {
            compile-environment $home (resolve-effective-plan $home) --sandbox $sb
        }
        let f = ($home | path join ".state" "env" "env.zsh")
        assert (open --raw $f | str contains "export K='S3CRET'")
        assert equal (ls -l $f | get 0.mode) "rw-------"
    }
}




export def test_path_entries_reach_all_shells [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "core")
        mkdir $m1
        "name = \"core\"\nos = [\"linux\", \"windows\", \"macos\"]\npath = [\"~/.local/bin\"]" | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"core\"" | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        compile-environment $home $plan --sandbox $sb
        let env_dir = ($home | path join ".state" "env")
        let p = ($sb | path join ".local" "bin")
        if $nu.os-info.family != "windows" {
            assert (open --raw ($env_dir | path join "env.fish") | str contains $"fish_add_path -g ($p)")
            assert (open --raw ($env_dir | path join "env.zsh") | str contains $"path=\(($p) $path\)")
        } else {
            let p_fish = ($p | str replace --all '\' '\\')
            assert (open --raw ($env_dir | path join "env.fish") | str contains $"fish_add_path -g '($p_fish)'")
            assert (open --raw ($env_dir | path join "env.zsh") | str contains $"path=\('($p)' $path\)")
        }
        assert (open --raw ($env_dir | path join "env.zsh") | str contains "typeset -U path")
        assert equal ((^nu -c $"source '($env_dir | path join env.nu)'; $env.PATH | first" | complete).stdout | str trim) $p
    }
}

def compile-with-paths [home: string, paths: list<string>]: nothing -> string {
    ensure-ygg-dirs $home
    let sb = ($home | path join "sb")
    compile-environment $home { modules: [], env: {}, aliases: {}, path: $paths } --sandbox $sb
    $home | path join ".state" "env"
}

export def test_path_order_is_same_in_all_shells [] {
    with-temp-ygg { |home|
        let a = ($home | path join "pa")
        let b = ($home | path join "pb")
        mkdir $a $b
        let env_dir = (compile-with-paths $home [$a, $b])
        if $nu.os-info.family != "windows" {
            assert (open --raw ($env_dir | path join "env.fish") | str contains $"fish_add_path -g ($a) ($b)")
            assert (open --raw ($env_dir | path join "env.zsh") | str contains $"path=\(($a) ($b) $path\)")
        } else {
            let af = ($a | str replace --all '\' '\\')
            let bf = ($b | str replace --all '\' '\\')
            assert (open --raw ($env_dir | path join "env.fish") | str contains $"fish_add_path -g '($af)' '($bf)'")
            assert (open --raw ($env_dir | path join "env.zsh") | str contains $"path=\('($a)' '($b)' $path\)")
        }
        if (which fish | is-not-empty) {
            let out = (^fish -c $"set -gx PATH /usr/bin; source '($env_dir | path join env.fish)'; printf '%s\\n' $PATH[1] $PATH[2]" | lines)
            assert equal $out [$a, $b]
        }
    }
}

export def test_path_quoting_and_empty [] {
    if $nu.os-info.family != "windows" {
        with-temp-ygg { |home|
            let env_dir = (compile-with-paths $home ["/opt/my dir/it's$x"])
            assert (open --raw ($env_dir | path join "env.zsh") | str contains "path=('/opt/my dir/it'\\''s$x' $path)")
            assert (open --raw ($env_dir | path join "env.fish") | str contains "fish_add_path -g '/opt/my dir/it\\'s$x'")
        }
    }
    with-temp-ygg { |home|
        let env_dir = (compile-with-paths $home [])
        assert (not (open --raw ($env_dir | path join "env.zsh") | str contains "path="))
        assert (not (open --raw ($env_dir | path join "env.fish") | str contains "fish_add_path"))
        assert (not (open --raw ($env_dir | path join "env.nu") | str contains "PATH"))
    }
}

export def test_lazy_provider_quotes_every_argv_element [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb"); mkdir $sb
        setup-secret-home $home false
        cd $home  # the relative marker must land inside the temp home, never in the caller's cwd
        let marker = "YGG_INJECT_MARK"
        ("B = \"bw://my item/fld$(touch " + $marker + ")\"\n") | save -f ($home | path join "secrets.toml")
        let bin = ($home | path join "mock-bin"); mkdir $bin
        "#!/bin/sh\necho S3CRET\n" | save -f ($bin | path join "bw")
        ^chmod +x ($bin | path join "bw")
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", PATH: ($env.PATH | prepend $bin) } {
            compile-environment $home (resolve-effective-plan $home) --sandbox $sb
        }
        let env_dir = ($home | path join ".state" "env")
        let field = ("fld$(touch " + $marker + ")")
        let zsh = (open --raw ($env_dir | path join "env.zsh"))
        assert ($zsh | str contains $"bw get '($field)' 'my item'") $zsh
        assert ((open --raw ($env_dir | path join "env.fish")) | str contains $"bw get '($field)' 'my item'")
        assert ((open --raw ($env_dir | path join "env.ps1")) | str contains $"bw get '($field)' 'my item'")
        assert ((open --raw ($env_dir | path join "env.nu")) | str contains $"^bw get '($field)' 'my item' | str trim")
        if (which zsh | is-not-empty) {
            assert equal (^zsh -n ($env_dir | path join "env.zsh") | complete | get exit_code) 0
        }
        assert (not ($marker | path exists))
    }
}

# BUG-1: an argv element holding both ' and " must round-trip through every generated env file
# and never execute when the file is loaded.
export def test_lazy_provider_quotes_mixed_quotes_round_trip [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        let sb = ($home | path join "sb"); mkdir $sb
        setup-secret-home $home false
        # bw:// splits item/field on '/', so the payload is slash-free and runs with cwd = home
        cd $home
        let marker = ($home | path join "pwned")
        let field = "x'\"; touch pwned; \"a\\b$(id)"
        ({ B: $"bw://my item/($field)" } | to toml) | save -f ($home | path join "secrets.toml")
        let bin = ($home | path join "mock-bin"); mkdir $bin
        "#!/bin/sh\nprintf '%s' \"$2\"\n" | save -f ($bin | path join "bw")
        ^chmod +x ($bin | path join "bw")
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", PATH: ($env.PATH | prepend $bin) } {
            compile-environment $home (resolve-effective-plan $home) --sandbox $sb
            let env_dir = ($home | path join ".state" "env")
            let nu_res = (^$nu.current-exe -n -c $"source '($env_dir | path join "env.nu")'; print -n $env.B" | complete)
            assert equal $nu_res.exit_code 0 $nu_res.stderr
            assert equal $nu_res.stdout $field
            if (which zsh | is-not-empty) {
                let zsh_res = (^zsh -f -c $"source '($env_dir | path join "env.zsh")'; printf '%s' \"$B\"" | complete)
                assert equal $zsh_res.exit_code 0 $zsh_res.stderr
                assert equal $zsh_res.stdout $field
            }
            if (which fish | is-not-empty) {
                let fish_res = (^fish --no-config -c $"source '($env_dir | path join "env.fish")'; printf '%s' \"$B\"" | complete)
                assert equal $fish_res.exit_code 0 $fish_res.stderr
                assert equal $fish_res.stdout $field
            }
        }
        assert (not ($marker | path exists))
    }
}
