use std/assert
use ../src/state.nu [ensure-ygg-dirs]
use ../src/link.nu [is-link-or-junction]
use ../scripts/release.nu [read-ygg-version]
use helpers.nu [with-temp-ygg, test-link-dir, test-dangling-link]

def extern-flags [text: string, cmd: string]: nothing -> list<string> {
    let head = ('export extern "ygg ' + $cmd + '" [')
    let lines = ($text | lines)
    let start = ($lines | enumerate | where { |r| $r.item | str starts-with $head } | get -o 0.index)
    if $start == null { return [] }
    let body = ($lines | skip ($start + 1) | take while { |l| not ($l | str starts-with "]") })
    $body | each { |l| $l | parse --regex '^\s*--([A-Za-z0-9-]+)' | get -o capture0.0 } | compact
}

export def test_cli_completions_generation [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb } {
            let nu_comp = (^nu $ygg_bin completions nu | complete)
            assert equal $nu_comp.exit_code 0 $nu_comp.stderr
            assert ($nu_comp.stdout | str contains "export extern ygg") "Expected extern ygg definition"
            # Verify generated nushell script parses without error
            let nu_parse = (^nu -c $nu_comp.stdout | complete)
            assert equal $nu_parse.exit_code 0 $nu_parse.stderr

            let zsh_comp = (^nu $ygg_bin completions zsh | complete)
            assert equal $zsh_comp.exit_code 0 $zsh_comp.stderr
            assert ($zsh_comp.stdout | str contains "#compdef ygg") "Expected zsh compdef"

            let bash_comp = (^nu $ygg_bin completions bash | complete)
            assert equal $bash_comp.exit_code 0 $bash_comp.stderr
            assert ($bash_comp.stdout | str contains "complete -F") "Expected bash complete -F"

            let fish_comp = (^nu $ygg_bin completions fish | complete)
            assert equal $fish_comp.exit_code 0 $fish_comp.stderr
            assert ($fish_comp.stdout | str contains "complete -c ygg") "Expected fish complete"

            let ps1_comp = (^nu $ygg_bin completions ps1 | complete)
            assert equal $ps1_comp.exit_code 0 $ps1_comp.stderr
            assert ($ps1_comp.stdout | str contains "Register-ArgumentCompleter") "Expected ps1 Register-ArgumentCompleter"

            let pwsh_comp = (^nu $ygg_bin completions powershell | complete)
            assert equal $pwsh_comp.exit_code 0 $pwsh_comp.stderr
            assert ($pwsh_comp.stdout | str contains "Register-ArgumentCompleter") "Expected powershell alias support"

            let invalid_comp = (^nu $ygg_bin completions invalid | complete)
            assert ($invalid_comp.exit_code != 0) "Expected error for invalid shell"
        }
    }
}

export def test_completions_nu_parse_and_match_cli [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let out = ($home | path join "c.nu")
        ^nu $ygg_bin completions nu | save -f $out
        assert equal (^nu -c $"source '($out)'" | complete).exit_code 0
        let text = (open --raw $out)
        let apply_flags = (extern-flags $text "apply")
        for f in ["dry-run", "force", "sandbox", "locked", "prune-packages", "no-lock", "force-system-prune", "refresh-packages"] {
            assert ($f in $apply_flags) $f
        }
        let add_flags = (extern-flags $text "add")
        assert ("force-system-prune" not-in $add_flags)
        assert ("sandbox" in $add_flags)
        assert ("force" in (extern-flags $text "save"))
        assert ("sandbox" in (extern-flags $text "doctor"))
        assert (not ($text | str contains "older than 7 days"))
    }
}

export def test_completions_flags_equal_scope_commands [] {
    let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
    let text = (^nu $ygg_bin completions nu)
    let real = (^nu -I ($ygg_bin | path dirname | path dirname | path join "src") -c $"source '($ygg_bin)'; scope commands | where { |c| $c.name | str starts-with 'main ' } | each { |c| { name: \($c.name | str replace 'main ' ''\), flags: \($c.signatures | values | first | where parameter_type in [switch named] | get parameter_name\) } } | to json" | from json)
    # SDK subcommands = those `ygg` (no args) lists under "SDK Subcommands", not a copy of the generator literal
    let sdk = (^nu $ygg_bin | lines | skip until { |l| $l | str starts-with "SDK Subcommands" } | skip 1 | each { |l| $l | parse --regex '^\s+ygg ([a-z-]+)' | get -o capture0.0 } | compact)
    assert (($sdk | length) >= 4) "SDK subcommands not found in help"
    assert (("onchange" in $sdk) and ("safe-link" in $sdk))
    for r in ($real | where { |r| $r.name not-in $sdk }) {
        assert equal (extern-flags $text $r.name | sort) ($r.flags | sort) $r.name
    }
    for s in $sdk { assert ($s not-in ($text | parse --regex 'export extern "ygg ([a-z-]+)"' | get capture0)) $s }
}

export def test_completions_table_has_no_empty_descriptions [] {
    let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
    let src = ($ygg_bin | path dirname | path dirname | path join "src")
    let rows = (^nu -I $src -c $"source '($ygg_bin)'; cli-signature-table | to json" | from json)
    assert (($rows | length) >= 12)
    for r in $rows {
        assert ($r.description | str trim | is-not-empty) $"command ($r.command) has no description"
        for f in $r.flags {
            assert ($f.description | str trim | is-not-empty) $"($r.command) --($f.long) has no description"
        }
    }
}

export def test_completions_other_shells_share_flags [] {
    let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
    for sh in ["zsh", "bash", "fish", "ps1"] {
        let txt = (^nu $ygg_bin completions $sh)
        assert ($txt | str contains "sandbox") $sh
        assert (not ($txt | str contains "older than 7 days")) $sh
    }
    let bash = (^nu $ygg_bin completions bash)
    let add_branch = ($bash | split row "add)" | get 1 | split row ";;" | get 0)
    assert ($add_branch | str contains "--sandbox")
    assert (not ($add_branch | str contains "--force-system-prune"))
    let apply_branch = ($bash | split row "apply)" | get 1 | split row ";;" | get 0)
    assert ($apply_branch | str contains "--force-system-prune")
}

export def test_completions_nu_complete_modules_reads_names [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let out = ($home | path join "c.nu")
        ^nu $ygg_bin completions nu | save -f $out
        "[[modules]]\nname = \"m1\"\n\n[[modules]]\nname = \"m2\"\n" | save -f ($home | path join "host.toml")
        let names = (^nu -c $"source '($out)'; nu-complete ygg-modules | to json" | from json)
        assert equal $names ["m1", "m2"]
        "modules = []\n" | save -f ($home | path join "host.toml")
        assert equal (^nu -c $"source '($out)'; nu-complete ygg-modules | to json" | from json) []
    }
}

export def test_completions_ps1_has_no_case_colliding_keys [] {
    # pwsh is not available in CI here: the generated ps1 text is checked structurally instead.
    let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
    let txt = (^nu $ygg_bin completions ps1)
    # flags are pair objects, never `'-x' = '...'` hashtable entries (PowerShell keys are case-insensitive)
    assert (not ($txt | str contains "'-s' = ")) "flag emitted as hashtable key"
    assert (not ($txt | lines | any { |l| $l =~ "^\\s*'--?[A-Za-z]" and ($l | str contains "' = '") })) "flag hashtable key"
    assert ($txt | str contains "[pscustomobject]@{ N = '-s'")
    assert ($txt | str contains "[pscustomobject]@{ N = '-S'")
    # within one command, hashtable literal keys must be unique case-insensitively
    let blocks = ($txt | split row "$flags = @{" | get 1 | split row "$values = @{" | get 0)
    let keys = ($blocks | lines | each { |l| $l | parse --regex "^        '([a-z-]+)' = @" | get -o capture0.0 } | compact)
    assert equal ($keys | str lowercase | uniq | length) ($keys | length)
    # the `-s` / `-S` pair exists in `add`, proving the collision case is exercised
    let add_block = ($blocks | split row "'apply' = @(" | get 0)
    let names = ($add_block | lines | each { |l| $l | parse --regex "N = '([^']+)'" | get -o capture0.0 } | compact)
    assert (("-s" in $names) and ("-S" in $names))
}

export def test_completions_zsh_escape_covers_specials [] {
    let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
    let src = ($ygg_bin | path dirname | path dirname | path join "src")
    let bt = (char -u '60')
    let input = ("a" + $bt + "b$c[d]\"e")
    let script = ("source '" + $ygg_bin + "'; zsh-escape ($env.IN) | to json")
    let out = (with-env { IN: $input } { ^nu -I $src -c $script } | from json)
    assert ($out | str contains ("\\" + $bt)) "backtick not escaped"
    assert ($out | str contains "\\$c") "dollar not escaped"
    assert ($out | str contains "\\[d\\]") "brackets not escaped"
}

export def test_completions_nu_complete_modules_record_is_empty [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let out = ($home | path join "c.nu")
        ^nu $ygg_bin completions nu | save -f $out
        "[modules.a]\npath = \"x\"\n" | save -f ($home | path join "host.toml")
        assert equal (^nu -c $"source '($out)'; nu-complete ygg-modules | to json" | from json) []
    }
}

