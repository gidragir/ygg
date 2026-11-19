# tests/test_lint.nu
# Unit tests for static analysis stages (L1-L4, compose) in src/lint.nu
# regression: #23

use std/assert
use ../src/lint.nu *
use ../src/manifest.nu [load-module-manifest]
use helpers.nu [with-temp-ygg, test-dangling-link, snapshot-tree]

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

# regression: #23
export def test_lint_l5_cross_os_conflict [] {
    with-temp-ygg { |home|
        let d = ($home | path join "modules" "cross-mod")
        mkdir ($d | path join "app")
        "base = 1\n" | save -f ($d | path join "app" "base.conf")
        "sub = 1\n" | save -f ($d | path join "sub.conf")
        ([
            'name = "cross-mod"'
            'os = ["linux", "windows"]'
            '[links]'
            '"app" = "~/.config/app"'
            '[scope."windows and work".links]'
            '"sub.conf" = "~/.config/app/sub.conf"'
        ] | str join "\n") | save -f ($d | path join "ygg.toml")

        let findings = (run-lint $d --src-dir $SRC_DIR)
        let errs = ($findings | where check == "plan" and severity == "error")
        assert (($errs | length) >= 1)
        let win_err = ($errs | where os == "windows" | first)
        assert equal $win_err.scopes ["work"]
        assert equal $win_err.target "cross-mod: sub.conf"
        assert ($errs | where os == "linux" | is-empty)
        if $nu.os-info.family != "windows" {
            assert equal $win_err.cross_os true
            assert ($win_err.detail | str contains "план для windows построен на")
        } else {
            assert equal $win_err.cross_os false
        }
        # Mixed L1-L4 + L5 schema serializes cleanly to JSON and expands as table
        let json_out = ($findings | to json --raw)
        assert (($json_out | from json | length) == ($findings | length))
        let _ = ($findings | table --expand)
        # --os filter restricts L5 simulation to matching targets
        let linux_only = (run-lint $d --os ["linux"] --src-dir $SRC_DIR)
        assert ($linux_only | where check == "plan" and severity == "error" | is-empty)
    }
}

# regression: #23
export def test_lint_l5_depends_on_without_and_with_fixture [] {
    with-temp-ygg { |home|
        let app_dir = ($home | path join "modules" "app-mod")
        mkdir $app_dir
        "app = 1\n" | save -f ($app_dir | path join "app.conf")
        ([
            'name = "app-mod"'
            'os = ["linux"]'
            'depends_on = ["dep-mod"]'
            '[links]'
            '"app.conf" = "~/.config/shared.conf"'
        ] | str join "\n") | save -f ($app_dir | path join "ygg.toml")

        # 1. Without fixture: L5 runs, missing_dependency downgraded to warn, 0 errors
        let no_fx = (run-lint $app_dir --src-dir $SRC_DIR)
        assert equal ($no_fx | where severity == "error" | length) 0
        let warns = ($no_fx | where check == "plan" and severity == "warn")
        assert ($warns | any { |f| ($f.target == "app-mod: depends_on") and ($f.detail | str contains "dep-mod") })

        # 2. With ci/hosts/default.toml and local relative dependency colliding on destination
        let dep_dir = ($home | path join "modules" "dep-mod")
        mkdir $dep_dir
        "dep = 1\n" | save -f ($dep_dir | path join "dep.conf")
        ([
            'name = "dep-mod"'
            'os = ["linux"]'
            '[links]'
            '"dep.conf" = "~/.config/shared.conf"'
        ] | str join "\n") | save -f ($dep_dir | path join "ygg.toml")

        mkdir ($app_dir | path join "ci" "hosts")
        ([
            '[[modules]]'
            'name = "app-mod"'
            ''
            '[[modules]]'
            'name = "dep-mod"'
            'source = "../dep-mod"'
        ] | str join "\n") | save -f ($app_dir | path join "ci" "hosts" "default.toml")

        let with_fx = (run-lint $app_dir --src-dir $SRC_DIR)
        assert ($with_fx | where target =~ "depends_on" | is-empty)
        let col_errs = ($with_fx | where check == "plan" and severity == "error")
        assert (($col_errs | length) >= 1)
        assert ($col_errs | any { |f| ($f.detail | str contains "shared.conf") and ($f.detail | str contains "dep-mod") })
    }
}

# regression: #23
export def test_lint_l5_fixture_git_clone_and_error [] {
    with-temp-ygg { |home|
        let dep_repo = ($home | path join "repos" "dep-git")
        mkdir $dep_repo
        "dep = 1\n" | save -f ($dep_repo | path join "dep.conf")
        ([
            'name = "dep-git"'
            'os = ["linux"]'
            '[links]'
            '"dep.conf" = "~/.config/git-shared.conf"'
        ] | str join "\n") | save -f ($dep_repo | path join "ygg.toml")

        let init_res = (^git -C $dep_repo init -b v1 | complete)
        assert equal $init_res.exit_code 0
        let add_res = (^git -C $dep_repo add -A | complete)
        assert equal $add_res.exit_code 0
        let commit_res = (^git -C $dep_repo -c user.name=Test -c user.email=test@example.com commit -m "init" | complete)
        assert equal $commit_res.exit_code 0

        let url_path = ($dep_repo | str replace --all "\\" "/")
        let git_url = if ($url_path | str starts-with "/") { $"file://($url_path)" } else { $"file:///($url_path)" }
        let missing_url = if ($url_path | str starts-with "/") { $"file://($url_path)-missing" } else { $"file:///($url_path)-missing" }

        let app_dir = ($home | path join "modules" "app-git")
        mkdir $app_dir
        "app = 1\n" | save -f ($app_dir | path join "app.conf")
        ([
            'name = "app-git"'
            'os = ["linux"]'
            'depends_on = ["dep-git"]'
            '[links]'
            '"app.conf" = "~/.config/git-shared.conf"'
        ] | str join "\n") | save -f ($app_dir | path join "ygg.toml")

        mkdir ($app_dir | path join "ci" "hosts")
        ([
            '[[modules]]'
            'name = "dep-git"'
            $'source = "($git_url)"'
            'ref = "v1"'
        ] | str join "\n") | save -f ($app_dir | path join "ci" "hosts" "git-dep.toml")
        ([
            '[[modules]]'
            'name = "dep-missing"'
            $'source = "($missing_url)"'
        ] | str join "\n") | save -f ($app_dir | path join "ci" "hosts" "bad-url.toml")

        let findings = (run-lint $app_dir --src-dir $SRC_DIR)
        assert ($findings | any { |f| ($f.check == "plan") and ($f.severity == "error") and ($f.detail | str contains "git-shared.conf") })
        assert ($findings | any { |f| ($f.check == "fixture") and ($f.severity == "error") and ($f.target == "ci/hosts/bad-url.toml") })
    }
}

# regression: #23
export def test_lint_l5_distro_targets_and_expr_scopes [] {
    with-temp-ygg { |home|
        let d = ($home | path join "modules" "scope-expr-mod")
        mkdir $d
        ([
            'name = "scope-expr-mod"'
            'os = ["linux"]'
            '[scope.cachyos]'
            'links = {}'
            '[scope."work and not headless"]'
            'links = {}'
        ] | str join "\n") | save -f ($d | path join "ygg.toml")

        let manifest = (load-module-manifest $d)
        let targets = (compute-lint-targets $manifest)
        assert ("linux" in $targets)
        assert ("cachyos" in $targets)
        assert equal (compute-lint-targets $manifest ["cachyos"]) ["cachyos"]

        let sets = (compute-scope-sets $manifest)
        assert ([] in $sets)
        assert (["work"] in $sets)
        assert (["headless"] in $sets)
        assert (not (["and"] in $sets))
        assert (not (["not"] in $sets))
        assert (not (["cachyos"] in $sets))
    }
}

# regression: #23
export def test_lint_l6_packages_and_no_override_leak [] {
    with-temp-ygg { |home|
        # 1. Real host OS without caller override: L5 tests cross-OS without leaking into L6 or external mock log
        let d1 = ($home | path join "modules" "pkg-mod-real")
        mkdir $d1
        ([
            'name = "pkg-mod-real"'
            'os = ["linux", "windows", "macos"]'
            '[packages]'
            'cargo = ["fd-find", "bad-crate"]'
            '[scope.windows.packages]'
            'winget = ["Git.Git"]'
            '[scope.linux.packages]'
            'apt = ["curl"]'
        ] | str join "\n") | save -f ($d1 | path join "ygg.toml")

        let mock_log1 = ($home | path join "l6-real.log")
        let f1 = (with-env { YGG_MOCK_PKG_LOG: $mock_log1, YGG_MOCK_PKG_UNKNOWN: "bad-crate" } {
            run-lint $d1 --packages --src-dir $SRC_DIR
        })
        assert ($mock_log1 | path exists)
        let logged1 = (open --raw $mock_log1)
        assert ($logged1 | str contains "probe cargo fd-find")
        assert ($f1 | any { |f| ($f.check == "packages") and ($f.severity == "error") and ($f.target == "cargo: bad-crate") })
        assert (not ($f1 | any { |f| ($f.check == "packages") and ($f.target == "cargo: fd-find") }))
        if $nu.os-info.family == "windows" {
            assert ($f1 | any { |f| ($f.check == "packages") and ($f.severity == "info") and ($f.target == "apt: curl") })
        } else {
            assert ($f1 | any { |f| ($f.check == "packages") and ($f.severity == "info") and ($f.target == "winget: Git.Git") })
        }

        # 2. Caller override "cachyos": L5 runs windows override, L6 still sees "cachyos"
        let d2 = ($home | path join "modules" "pkg-mod-cachyos")
        mkdir $d2
        ([
            'name = "pkg-mod-cachyos"'
            'os = ["linux", "windows"]'
            '[packages]'
            'pacman = ["ripgrep", "bad-pkg"]'
            '[scope.windows.packages]'
            'winget = ["Git.Git"]'
        ] | str join "\n") | save -f ($d2 | path join "ygg.toml")

        let mock_log2 = ($home | path join "l6-cachyos.log")
        let f2 = (with-env { YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: $mock_log2, YGG_MOCK_PKG_UNKNOWN: "bad-pkg" } {
            run-lint $d2 --packages --src-dir $SRC_DIR
        })
        assert ($f2 | any { |f| ($f.check == "packages") and ($f.severity == "error") and ($f.target == "pacman: bad-pkg") })
        assert (not ($f2 | any { |f| ($f.check == "packages") and ($f.target == "pacman: ripgrep") }))
        assert ($f2 | any { |f| ($f.check == "packages") and ($f.severity == "info") and ($f.target == "winget: Git.Git") })
    }
}

# regression: #23
export def test_lint_readonly_and_tmp_cleanup [] {
    with-temp-ygg { |home|
        let tmp_sub = ($home | path join "subtmp")
        mkdir $tmp_sub
        let d = ($home | path join "modules" "ro-full")
        mkdir $d
        "cfg = 1\n" | save -f ($d | path join "app.conf")
        ([
            'name = "ro-full"'
            'os = ["linux", "windows"]'
            '[links]'
            '"app.conf" = "~/.config/ro-app.conf"'
        ] | str join "\n") | save -f ($d | path join "ygg.toml")
        "use sdk.nu *\nlet x = 1\n" | save -f ($d | path join "setup.nu")
        mkdir ($d | path join "ci" "hosts")
        "[[modules\nbroken = \n" | save -f ($d | path join "ci" "hosts" "broken.toml")

        let home_before = (snapshot-tree $home)
        let sb_before = (snapshot-tree $env.YGG_SANDBOX)

        let res = (with-env {
            TMPDIR: $tmp_sub,
            TEMP: $tmp_sub,
            TMP: $tmp_sub,
            YGG_TEST_MOD: $d
        } {
            ^nu -I $SRC_DIR -c 'use lint.nu *; let f = (run-lint $env.YGG_TEST_MOD); print ($f | to json -r)' | complete
        })

        assert equal $res.exit_code 0
        assert equal ($res.stderr | str trim) ""
        let findings = ($res.stdout | from json)
        assert ($findings | where check == "setup" | is-empty)
        assert ($findings | any { |f| ($f.check == "fixture") and ($f.severity == "error") and ($f.target == "ci/hosts/broken.toml") })
        assert (not (($home | path join ".state") | path exists))
        assert (not (($home | path join "host.toml") | path exists))
        assert equal (snapshot-tree $home) $home_before
        assert equal (snapshot-tree $env.YGG_SANDBOX) $sb_before
        assert equal (ls $tmp_sub | length) 0
    }
}
