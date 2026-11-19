# tests/test_lint.nu
# Unit tests for static analysis stages (L1-L4, compose) in src/lint.nu
# regression: #23

use std/assert
use ../src/lint.nu *
use ../src/manifest.nu [load-module-manifest]
use helpers.nu [with-temp-ygg, test-dangling-link]

const SRC_DIR = (path self | path dirname | path dirname | path join "src")

def mk-mod [home: string, name: string]: nothing -> string {
    let d = ($home | path join "modules" $name)
    mkdir $d
    $"name = \"($name)\"\nos = [\"linux\", \"windows\", \"macos\"]\n" | save -f ($d | path join "ygg.toml")
    $d
}

# regression: #23
export def test_lint_l1_schemas_and_unknown_keys [] {
    with-temp-ygg { |home|
        # 1. Missing mod_dir must not throw uncaught exception
        let missing_res = (lint-schemas ($home | path join "does-not-exist"))
        assert equal $missing_res.manifest null
        assert (($missing_res.findings | where check == "schema" and severity == "error" | length) >= 1)

        # 2. Broken ygg.toml must not throw uncaught exception
        let broken_dir = ($home | path join "modules" "broken-ygg")
        mkdir $broken_dir
        "name = [unclosed\n" | save -f ($broken_dir | path join "ygg.toml")
        let broken_res = (lint-schemas $broken_dir)
        assert equal $broken_res.manifest null
        assert equal ($broken_res.findings | where check == "schema" and severity == "error" | get target) ["ygg.toml"]

        # 3. Unknown top-level key ([scopes.x] -> warn), broken links.toml & secrets.example.toml -> error,
        #    unknown OS "freebsd" -> error, unknown pkg manager "aptget" -> error
        let d = ($home | path join "modules" "bad-schema")
        mkdir $d
        ([
            'name = "bad-schema"'
            'os = ["linux", "freebsd"]'
            '[scopes.x]'
            'foo = "bar"'
            '[scope.linux.packages]'
            'aptget = ["curl"]'
        ] | str join "\n") | save -f ($d | path join "ygg.toml")
        "[links\nbroken = true\n" | save -f ($d | path join "links.toml")
        "[env\nSECRET = \"\"\n" | save -f ($d | path join "secrets.example.toml")

        let res = (lint-schemas $d)
        assert equal $res.manifest null
        let warns = ($res.findings | where severity == "warn")
        let errs = ($res.findings | where severity == "error")
        assert ($warns | any { |f| ($f.target == "ygg.toml scopes") and ($f.check == "schema") })
        assert ($errs | any { |f| $f.target == "links.toml" })
        assert ($errs | any { |f| $f.target == "secrets.example.toml" })
        assert ($errs | any { |f| $f.detail | str contains "freebsd" })
        assert ($errs | any { |f| $f.detail | str contains "aptget" })

        # 4. Valid module returns empty findings and loaded manifest
        let good = (mk-mod $home "good-mod")
        "pacman = [\"git\"]\n" | save -f ($good | path join "packages.toml")
        let good_res = (lint-schemas $good)
        assert equal $good_res.findings []
        assert ($good_res.manifest != null)
        assert equal $good_res.manifest.name "good-mod"
    }
}

# regression: #23
export def test_lint_l2_sources_inactive_scope_and_save [] {
    with-temp-ygg { |home|
        let d = ($home | path join "modules" "src-check")
        mkdir $d
        mkdir ($d | path join "scripts")
        mkdir ($d | path join "cfg")
        "hello\n" | save -f ($d | path join "scripts" "ok.sh")
        "a = 1\n" | save -f ($d | path join "cfg" "one.toml")
        "not a dir\n" | save -f ($d | path join "regular.txt")
        "services: {}\n" | save -f ($d | path join "compose.yml")

        ([
            'name = "src-check"'
            'os = ["linux", "windows"]'
            '[links]'
            '"scripts/*" = "~/.local/bin/*"'
            '"cfg/*.toml" = "~/.config/cfg/"'
            '"regular.txt" = { target = "~/.config/regdir", mode = "dir" }'
            '"missing/*.toml" = "~/.config/missing/"'
            '[save]'
            '"missing-save.json" = "~/.config/save.json"'
            '[scope.work.containers]'
            'files = ["infra/work-compose.yml"]'
        ] | str join "\n") | save -f ($d | path join "ygg.toml")

        ([
            '[scope.work]'
            'opencode = "~/.config/opencode"'
        ] | str join "\n") | save -f ($d | path join "links.toml")

        let findings = (lint-sources $d)
        assert ($findings | all { |f| ($f.check == "source") and ($f.severity == "error") })

        let targets = ($findings | get target)
        assert ("links.toml [scope.work] opencode" in $targets)
        assert ("ygg.toml [links] regular.txt" in $targets)
        assert ("ygg.toml [links] missing/*.toml" in $targets)
        assert ("ygg.toml [save] missing-save.json" in $targets)
        assert ("ygg.toml [scope.work.containers] infra/work-compose.yml" in $targets)
        # Valid entries must not produce findings
        assert (not ("ygg.toml [links] scripts/*" in $targets))
        assert (not ("ygg.toml [links] cfg/*.toml" in $targets))
    }
}

# regression: #23
export def test_lint_l2_broken_root_compose_symlink [] {
    with-temp-ygg { |home|
        let d = (mk-mod $home "broken-compose-link")
        test-dangling-link ($home | path join "nonexistent-target") ($d | path join "compose.yml")
        let findings = (lint-sources $d)
        assert equal ($findings | length) 1
        assert equal $findings.0.severity "error"
        assert equal $findings.0.target "compose.yml"
    }
}

# regression: #23
export def test_lint_l3_invalid_scope_expression [] {
    with-temp-ygg { |home|
        let d = ($home | path join "modules" "bad-scope")
        mkdir $d
        ([
            'name = "bad-scope"'
            'os = ["linux"]'
            '[scope."work and ("]'
            'links = {}'
            '[scope."linux and !windows"]'
            'links = {}'
        ] | str join "\n") | save -f ($d | path join "ygg.toml")

        let manifest = (load-module-manifest $d)
        let findings = (lint-scopes $manifest)
        assert equal ($findings | length) 1
        assert equal $findings.0.check "scope"
        assert equal $findings.0.severity "error"
        assert ($findings.0.target | str contains "work and (")
    }
}

# regression: #23
export def test_lint_l4_setup_syntax_and_spaces [] {
    with-temp-ygg { |home|
        # No setup.nu -> []
        let no_setup = (mk-mod $home "no-setup")
        assert equal (lint-setup $no_setup $SRC_DIR) []

        # Directory with spaces + valid setup.nu importing sdk.nu -> []
        let valid_dir = ($home | path join "modules" "valid with space")
        mkdir $valid_dir
        "name = \"valid-space\"\nos = [\"linux\", \"windows\", \"macos\"]\n" | save -f ($valid_dir | path join "ygg.toml")
        "use sdk.nu *\nonchange \"k\" [\"cfg/*\"] {\n    let x = 1\n}\n" | save -f ($valid_dir | path join "setup.nu")
        assert equal (lint-setup $valid_dir $SRC_DIR) []

        # Directory with spaces + syntax error in setup.nu -> error
        let bad_dir = ($home | path join "modules" "mod with spaces")
        mkdir $bad_dir
        "name = \"bad-space\"\nos = [\"linux\", \"windows\", \"macos\"]\n" | save -f ($bad_dir | path join "ygg.toml")
        "use sdk.nu *\nlet broken = [1 2\n" | save -f ($bad_dir | path join "setup.nu")
        let findings = (lint-setup $bad_dir $SRC_DIR)
        assert equal ($findings | length) 1
        assert equal $findings.0.check "setup"
        assert equal $findings.0.severity "error"
        assert equal $findings.0.target "setup.nu"
        assert (($findings.0.detail | str trim) != "")
    }
}

# regression: #23
export def test_lint_compose_no_runtime_info [] {
    with-temp-ygg { |home|
        let mock_log = ($home | path join "pkg.log")

        # 1. Module with no compose files -> [] and does NOT probe runtime
        let empty_mod = (mk-mod $home "no-compose")
        let empty_manifest = (load-module-manifest $empty_mod)
        with-env { YGG_MOCK_PKG_LOG: $mock_log, YGG_MOCK_CONTAINER_STATUS: "no_runtime" } {
            assert equal (lint-compose $empty_mod $empty_manifest) []
        }
        assert (not ($mock_log | path exists))

        # 2. Module with compose.yml + no_runtime -> info
        let d = (mk-mod $home "with-compose")
        "services:\n  app:\n    image: alpine:latest\n" | save -f ($d | path join "compose.yml")
        let manifest = (load-module-manifest $d)
        with-env { YGG_MOCK_PKG_LOG: $mock_log, YGG_MOCK_CONTAINER_STATUS: "no_runtime" } {
            let findings = (lint-compose $d $manifest)
            assert equal ($findings | length) 1
            assert equal $findings.0.check "compose"
            assert equal $findings.0.severity "info"
            assert equal $findings.0.target "compose.yml"
        }
    }
}

# regression: #23
export def test_lint_compose_valid_and_invalid_mock [] {
    with-temp-ygg { |home|
        let mock_log = ($home | path join "pkg.log")
        let d = (mk-mod $home "compose-check")
        mkdir ($d | path join "infra")
        "services:\n  web:\n    image: nginx:alpine\n" | save -f ($d | path join "infra" "compose.yml")
        ([
            'name = "compose-check"'
            'os = ["linux"]'
            '[scope.work.containers]'
            'files = ["infra/compose.yml"]'
        ] | str join "\n") | save -f ($d | path join "ygg.toml")
        let manifest = (load-module-manifest $d)

        # Valid mock compose -> []
        with-env { YGG_MOCK_PKG_LOG: $mock_log, YGG_MOCK_CONTAINER_STATUS: "ok", YGG_MOCK_CONTAINER_FAIL: "" } {
            let ok_findings = (lint-compose $d $manifest)
            assert equal $ok_findings []
        }
        let logged = (open --raw $mock_log)
        assert ($logged | str contains "compose -f")
        assert ($logged | str contains "config -q")

        # Invalid mock compose -> error
        let fail_needle = ("infra" | path join "compose.yml")
        with-env { YGG_MOCK_PKG_LOG: $mock_log, YGG_MOCK_CONTAINER_STATUS: "ok", YGG_MOCK_CONTAINER_FAIL: $fail_needle } {
            let bad_findings = (lint-compose $d $manifest)
            assert equal ($bad_findings | length) 1
            assert equal $bad_findings.0.check "compose"
            assert equal $bad_findings.0.severity "error"
            assert equal $bad_findings.0.target "infra/compose.yml"
        }
    }
}

# regression: #23
export def test_lint_read_only_and_no_temp_artifacts [] {
    with-temp-ygg { |home|
        let tmp_sub = ($home | path join "subtmp")
        mkdir $tmp_sub
        let d = (mk-mod $home "ro-mod")
        "use sdk.nu *\nlet x = 1\n" | save -f ($d | path join "setup.nu")

        let res = (with-env {
            TMPDIR: $tmp_sub,
            TEMP: $tmp_sub,
            TMP: $tmp_sub,
            YGG_TEST_MOD: $d,
            YGG_TEST_SRC: $SRC_DIR
        } {
            ^nu -I $SRC_DIR -c 'use lint.nu *; use manifest.nu [load-module-manifest]; let s = (lint-schemas $env.YGG_TEST_MOD); let _ = (lint-sources $env.YGG_TEST_MOD); let _ = (lint-scopes $s.manifest); let _ = (lint-setup $env.YGG_TEST_MOD $env.YGG_TEST_SRC); let _ = (lint-compose $env.YGG_TEST_MOD $s.manifest)' | complete
        })
        assert equal $res.exit_code 0
        assert equal ($res.stderr | str trim) ""
        assert (not (($home | path join ".state") | path exists))
        assert (not (($home | path join "host.toml") | path exists))
        assert equal (ls $tmp_sub | where { |f| ($f.name | path basename) starts-with "ygg-proc-" } | length) 0
    }
}
