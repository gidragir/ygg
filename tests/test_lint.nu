# tests/test_lint.nu
# Unit tests for static analysis stages (L1-L4, compose) in src/lint.nu
# regression: #23

use std/assert
use ../src/lint.nu *
use ../src/manifest.nu [load-module-manifest]
use helpers.nu [with-temp-ygg, test-dangling-link, snapshot-tree]

const SRC_DIR = (path self | path dirname | path dirname | path join "src")
const REPO_ROOT = (path self | path dirname | path dirname)
const YGG_BIN = ($REPO_ROOT | path join "bin" "ygg.nu")

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

# regression: #23
export def test_lint_cli_json_and_exit_codes [] {
    with-temp-ygg { |home|
        let sb = $env.YGG_SANDBOX

        # 1. Clean module -> exit 0, valid JSON [], empty stderr, default "." works, no host mutation or tmp leaks
        let clean_dir = ($home | path join "modules" "cli-clean")
        mkdir $clean_dir
        "cfg = 1\n" | save -f ($clean_dir | path join "app.conf")
        ([
            'name = "cli-clean"'
            'os = ["linux", "windows", "macos"]'
            '[links]'
            '"app.conf" = "~/.config/cli-clean.conf"'
        ] | str join "\n") | save -f ($clean_dir | path join "ygg.toml")

        let tmp_sub = ($home | path join "cli-tmp")
        mkdir $tmp_sub
        let home_before = (snapshot-tree $home)
        let sb_before = (snapshot-tree $sb)

        let res_clean = (with-env { TMPDIR: $tmp_sub, TEMP: $tmp_sub, TMP: $tmp_sub } {
            ^nu $YGG_BIN lint $clean_dir --json | complete
        })
        assert equal $res_clean.exit_code 0 $res_clean.stderr
        assert equal ($res_clean.stderr | str trim) ""
        assert equal ($res_clean.stdout | from json) []
        assert equal (snapshot-tree $home) $home_before
        assert equal (snapshot-tree $sb) $sb_before
        assert equal (ls $tmp_sub | length) 0

        # Default path "." when invoked from module directory
        let res_dot = (with-env { YGG_LINT_TARGET: $clean_dir, YGG_LINT_BIN: $YGG_BIN } {
            ^nu -c 'cd $env.YGG_LINT_TARGET; ^nu $env.YGG_LINT_BIN lint --json' | complete
        })
        assert equal $res_dot.exit_code 0 $res_dot.stderr
        assert equal ($res_dot.stderr | str trim) ""
        assert equal ($res_dot.stdout | from json) []

        # 2. Warn-only module ([scopes.x]) -> exit 0, JSON contains warn finding, empty stderr
        let warn_dir = ($home | path join "modules" "cli-warn")
        mkdir $warn_dir
        ([
            'name = "cli-warn"'
            'os = ["linux", "windows", "macos"]'
            '[scopes.x]'
            'foo = "bar"'
        ] | str join "\n") | save -f ($warn_dir | path join "ygg.toml")

        let res_warn = (^nu $YGG_BIN lint $warn_dir --json | complete)
        assert equal $res_warn.exit_code 0 $res_warn.stderr
        assert equal ($res_warn.stderr | str trim) ""
        let parsed_warn = ($res_warn.stdout | from json)
        assert (($parsed_warn | length) >= 1)
        assert ($parsed_warn | all { |f| $f.severity != "error" })
        assert ($parsed_warn | any { |f| ($f.check == "schema") and ($f.severity == "warn") and ($f.target == "ygg.toml scopes") })

        # 3. Error module (missing source) -> exit 1, JSON has {check, severity, target, detail, fix}, empty stderr
        let err_dir = ($home | path join "modules" "cli-err")
        mkdir $err_dir
        ([
            'name = "cli-err"'
            'os = ["linux", "windows", "macos"]'
            '[links]'
            '"missing.conf" = "~/.config/missing.conf"'
        ] | str join "\n") | save -f ($err_dir | path join "ygg.toml")

        let res_err = (^nu $YGG_BIN lint $err_dir --json | complete)
        assert equal $res_err.exit_code 1
        assert equal ($res_err.stderr | str trim) ""
        let parsed_err = ($res_err.stdout | from json)
        let first_err = ($parsed_err | where severity == "error" | first)
        for col in ["check", "severity", "target", "detail", "fix"] {
            assert ($col in ($first_err | columns)) $"Missing column ($col)"
        }
        assert equal $first_err.check "source"
        assert equal $first_err.target "ygg.toml [links] missing.conf"

        # 4. Broken ygg.toml with --json -> exit 1, valid JSON array, empty stderr
        let broken_dir = ($home | path join "modules" "cli-broken")
        mkdir $broken_dir
        "name = [unclosed\n" | save -f ($broken_dir | path join "ygg.toml")

        let res_broken = (^nu $YGG_BIN lint $broken_dir --json | complete)
        assert equal $res_broken.exit_code 1
        assert equal ($res_broken.stderr | str trim) ""
        let parsed_broken = ($res_broken.stdout | from json)
        assert (($parsed_broken | length) >= 1)
        assert ($parsed_broken | any { |f| ($f.check == "schema") and ($f.severity == "error") and ($f.target == "ygg.toml") })
    }
}

# regression: #23
export def test_lint_cli_human_output_stdout_only [] {
    with-temp-ygg { |home|
        # 1. Clean module -> stdout summary, empty stderr, exit 0
        let clean_dir = (mk-mod $home "cli-human-clean")
        let res_clean = (^nu $YGG_BIN lint $clean_dir | complete)
        assert equal $res_clean.exit_code 0 $res_clean.stderr
        assert equal ($res_clean.stderr | str trim) ""
        assert ($res_clean.stdout | str contains "Lint: 0 error(s), 0 warning(s).")

        # 2. Mixed L1 5-col warn + L5 8-col error renders table & summary cleanly to stdout, empty stderr, exit 1
        let mixed_dir = ($home | path join "modules" "cli-human-mixed")
        mkdir ($mixed_dir | path join "app")
        "base = 1\n" | save -f ($mixed_dir | path join "app" "base.conf")
        "sub = 1\n" | save -f ($mixed_dir | path join "sub.conf")
        ([
            'name = "cli-human-mixed"'
            'os = ["linux", "windows"]'
            '[scopes.x]'
            'foo = "bar"'
            '[links]'
            '"app" = "~/.config/app"'
            '[scope."windows and work".links]'
            '"sub.conf" = "~/.config/app/sub.conf"'
        ] | str join "\n") | save -f ($mixed_dir | path join "ygg.toml")

        let res_mixed = (^nu $YGG_BIN lint $mixed_dir | complete)
        assert equal $res_mixed.exit_code 1
        assert equal ($res_mixed.stderr | str trim) ""
        assert ($res_mixed.stdout | str contains "schema")
        assert ($res_mixed.stdout | str contains "plan")
        assert ($res_mixed.stdout | str contains "Lint: 1 error(s), 1 warning(s).")

        # 3. --os flag filters L5 plan checks via CLI
        let os_dir = ($home | path join "modules" "cli-os-filter")
        mkdir ($os_dir | path join "app")
        "base = 1\n" | save -f ($os_dir | path join "app" "base.conf")
        "sub = 1\n" | save -f ($os_dir | path join "sub.conf")
        ([
            'name = "cli-os-filter"'
            'os = ["linux", "windows"]'
            '[links]'
            '"app" = "~/.config/app"'
            '[scope."windows and work".links]'
            '"sub.conf" = "~/.config/app/sub.conf"'
        ] | str join "\n") | save -f ($os_dir | path join "ygg.toml")

        let res_linux = (^nu $YGG_BIN lint $os_dir --os linux --json | complete)
        assert equal $res_linux.exit_code 0 $res_linux.stderr
        assert equal ($res_linux.stderr | str trim) ""
        assert equal ($res_linux.stdout | from json) []

        let res_win = (^nu $YGG_BIN lint $os_dir --os windows --json | complete)
        assert equal $res_win.exit_code 1
        assert equal ($res_win.stderr | str trim) ""
        let parsed_win = ($res_win.stdout | from json)
        assert ($parsed_win | any { |f| ($f.check == "plan") and ($f.severity == "error") and ($f.os == "windows") })

        # 4. --packages flag triggers L6 package probing via CLI
        let pkg_dir = ($home | path join "modules" "cli-pkgs")
        mkdir $pkg_dir
        ([
            'name = "cli-pkgs"'
            'os = ["linux", "windows", "macos"]'
            '[packages]'
            'cargo = ["fd-find", "bad-crate"]'
        ] | str join "\n") | save -f ($pkg_dir | path join "ygg.toml")

        let mock_log = ($home | path join "cli-pkg-probe.log")
        let res_pkg = (with-env { YGG_MOCK_PKG_LOG: $mock_log, YGG_MOCK_PKG_UNKNOWN: "bad-crate" } {
            ^nu $YGG_BIN lint $pkg_dir --packages --json | complete
        })
        assert equal $res_pkg.exit_code 1
        assert equal ($res_pkg.stderr | str trim) ""
        assert ($mock_log | path exists)
        assert ((open --raw $mock_log) | str contains "probe cargo fd-find")
        let parsed_pkg = ($res_pkg.stdout | from json)
        assert ($parsed_pkg | any { |f| ($f.check == "packages") and ($f.severity == "error") and ($f.target == "cargo: bad-crate") })
        assert (not ($parsed_pkg | any { |f| ($f.check == "packages") and ($f.target == "cargo: fd-find") }))
    }
}

# regression: #35
export def test_lint_cli_no_phase2_modules_legacy [] {
    with-temp-ygg { |_home|
        assert (not ($REPO_ROOT | path join "tests" "test_phase2_modules.nu" | path exists))
        let mise_txt = (open --raw ($REPO_ROOT | path join "mise.toml"))
        assert (not ($mise_txt | str contains "test-phase2"))
        assert (not ($mise_txt | str contains "test_phase2_modules"))
        let runner_txt = (open --raw ($REPO_ROOT | path join "tests" "run.nu"))
        assert (not ($runner_txt | str contains "test_phase2_modules"))
    }
}

# regression: #23
export def test_lint_non_record_containers_and_bad_fixture_types [] {
    with-temp-ygg { |home|
        # 1. containers = true (base and [scope.work]) must not crash collect-compose-files or --json
        let d_base = ($home | path join "modules" "bad-containers-base")
        mkdir $d_base
        ([
            'name = "bad-containers-base"'
            'os = ["linux"]'
            'containers = true'
        ] | str join "\n") | save -f ($d_base | path join "ygg.toml")

        assert equal (lint-compose $d_base { name: "bad-containers-base", containers: true, scope: { work: { containers: true } } }) []
        let f_base = (run-lint $d_base --src-dir $SRC_DIR)
        assert ($f_base | any { |f| ($f.check == "schema") and ($f.severity == "error") and ($f.target == "[containers]") })

        let r_base = (^nu $YGG_BIN lint $d_base --json | complete)
        assert equal $r_base.exit_code 1 $r_base.stderr
        assert equal ($r_base.stderr | str trim) ""
        let j_base = ($r_base.stdout | from json)
        assert ($j_base | any { |f| ($f.check == "schema") and ($f.severity == "error") and ($f.target == "[containers]") })

        let d_scope = ($home | path join "modules" "bad-containers-scope")
        mkdir $d_scope
        ([
            'name = "bad-containers-scope"'
            'os = ["linux"]'
            '[scope.work]'
            'containers = true'
        ] | str join "\n") | save -f ($d_scope | path join "ygg.toml")

        let r_scope = (^nu $YGG_BIN lint $d_scope --json | complete)
        assert equal $r_scope.exit_code 1 $r_scope.stderr
        assert equal ($r_scope.stderr | str trim) ""
        let j_scope = ($r_scope.stdout | from json)
        assert ($j_scope | any { |f| ($f.check == "schema") and ($f.severity == "error") and ($f.target == "[scope.work.containers]") })

        let d_files = ($home | path join "modules" "bad-containers-files")
        mkdir $d_files
        ([
            'name = "bad-containers-files"'
            'os = ["linux"]'
            '[containers]'
            'files = { bad = 1 }'
        ] | str join "\n") | save -f ($d_files | path join "ygg.toml")
        let r_files = (^nu $YGG_BIN lint $d_files --json | complete)
        assert equal $r_files.exit_code 1 $r_files.stderr
        assert equal ($r_files.stderr | str trim) ""
        let j_files = ($r_files.stdout | from json)
        assert ($j_files | any { |f| ($f.check == "schema") and ($f.severity == "error") and ($f.target == "[containers] files") })

        # 2. Non-string name/source/ref in ci/hosts/*.toml must emit fixture error via --json and clean temp dir
        let d_fx = ($home | path join "modules" "bad-fixture-types")
        mkdir ($d_fx | path join "ci" "hosts")
        ([
            'name = "bad-fixture-types"'
            'os = ["linux"]'
        ] | str join "\n") | save -f ($d_fx | path join "ygg.toml")
        ([
            '[[modules]]'
            'name = ["a"]'
            '[[modules]]'
            'name = "dep-obj-src"'
            'source = { x = 1 }'
            '[[modules]]'
            'name = "dep-arr-ref"'
            'source = "https://example.com/dep.git"'
            'ref = []'
        ] | str join "\n") | save -f ($d_fx | path join "ci" "hosts" "bad-types.toml")

        let tmp_sub = ($home | path join "fx-tmp")
        mkdir $tmp_sub
        let r_fx = (with-env { TMPDIR: $tmp_sub, TEMP: $tmp_sub, TMP: $tmp_sub } {
            ^nu $YGG_BIN lint $d_fx --json | complete
        })
        assert equal $r_fx.exit_code 1 $r_fx.stderr
        assert equal ($r_fx.stderr | str trim) ""
        let j_fx = ($r_fx.stdout | from json)
        let fx_errs = ($j_fx | where check == "fixture" and severity == "error" and target == "ci/hosts/bad-types.toml")
        assert equal ($fx_errs | length) 3
        assert ($fx_errs | any { |f| $f.detail | str contains "'name'" })
        assert ($fx_errs | any { |f| $f.detail | str contains "'source'" })
        assert ($fx_errs | any { |f| $f.detail | str contains "'ref'" })
        assert equal (ls $tmp_sub | length) 0
    }
}

# regression: #23
export def test_lint_l6_ignores_unknown_manager_reported_in_l1 [] {
    with-temp-ygg { |home|
        let d = ($home | path join "modules" "unknown-mgr-mod")
        mkdir $d
        ([
            'name = "unknown-mgr-mod"'
            'os = ["linux"]'
            '[packages]'
            'aptget = ["curl"]'
            'cargo = ["fd-find"]'
        ] | str join "\n") | save -f ($d | path join "ygg.toml")

        let mock_log = ($home | path join "l6-unknown-mgr.log")
        let findings = (with-env { YGG_MOCK_PKG_LOG: $mock_log } {
            run-lint $d --packages --src-dir $SRC_DIR
        })
        assert ($findings | any { |f| ($f.check == "schema") and ($f.severity == "error") and ($f.target == "[packages] aptget") })
        assert (not ($findings | any { |f| ($f.check == "packages") and ($f.target | str contains "aptget") }))
        assert ((open --raw $mock_log) | str contains "probe cargo fd-find")
        assert (not ((open --raw $mock_log) | str contains "aptget"))
    }
}

# regression: #38
export def test_lint_module_check_workflow_matrix_handles_malformed_packages_and_unix_os [] {
    with-temp-ygg { |home|
        let wf = (open --raw ($REPO_ROOT | path join ".github" "workflows" "module-check.yml") | from yaml)
        let step_run = ($wf.jobs.matrix.steps | where { |s| ($s.id? | default "") == "plan" } | first | get run)
        let parsed_script = ($step_run | parse --regex "(?s)r#'(?<inner>.*)'#")
        assert (($parsed_script | length) == 1)
        let inner_script = ($parsed_script | first | get inner)

        # 1. packages = "oops"
        let d_str = ($home | path join "modules" "wf-pkg-str")
        mkdir $d_str
        "name = \"wf-pkg-str\"\nos = [\"linux\"]\npackages = \"oops\"\n" | save -f ($d_str | path join "ygg.toml")
        let out_str = ($home | path join "gh-out-str.txt")
        "" | save -f $out_str
        let r_str = (with-env { YGG_MATRIX_MOD_DIR: $d_str, YGG_OS_INPUT: "", GITHUB_OUTPUT: $out_str } {
            ^nu -I $SRC_DIR -c $inner_script | complete
        })
        assert equal $r_str.exit_code 0 $r_str.stderr
        assert ((open --raw $out_str) | str contains "has-mise=false")

        # 2. [packages.mise] bad = 1 (record instead of list/string)
        let d_rec = ($home | path join "modules" "wf-mise-rec")
        mkdir $d_rec
        "name = \"wf-mise-rec\"\nos = [\"linux\"]\n[packages.mise]\nbad = 1\n" | save -f ($d_rec | path join "ygg.toml")
        let out_rec = ($home | path join "gh-out-rec.txt")
        "" | save -f $out_rec
        let r_rec = (with-env { YGG_MATRIX_MOD_DIR: $d_rec, YGG_OS_INPUT: "", GITHUB_OUTPUT: $out_rec } {
            ^nu -I $SRC_DIR -c $inner_script | complete
        })
        assert equal $r_rec.exit_code 0 $r_rec.stderr
        assert ((open --raw $out_rec) | str contains "has-mise=false")

        # 3. [[packages.mise]] bad = 1 (table instead of list/string) and scoped malformed packages
        let d_tbl = ($home | path join "modules" "wf-mise-tbl")
        mkdir $d_tbl
        "name = \"wf-mise-tbl\"\nos = [\"linux\"]\n[[packages.mise]]\nbad = 1\n[scope.work]\npackages = \"oops\"\n" | save -f ($d_tbl | path join "ygg.toml")
        let out_tbl = ($home | path join "gh-out-tbl.txt")
        "" | save -f $out_tbl
        let r_tbl = (with-env { YGG_MATRIX_MOD_DIR: $d_tbl, YGG_OS_INPUT: "", GITHUB_OUTPUT: $out_tbl } {
            ^nu -I $SRC_DIR -c $inner_script | complete
        })
        assert equal $r_tbl.exit_code 0 $r_tbl.stderr
        assert ((open --raw $out_tbl) | str contains "has-mise=false")

        # 4. Valid mise package list sets has-mise=true and os = ["unix"] maps to ubuntu-latest without Unknown OS warning
        let d_unix = ($home | path join "modules" "wf-unix")
        mkdir $d_unix
        "name = \"wf-unix\"\nos = [\"unix\"]\n[packages]\nmise = [\"node@22\"]\n" | save -f ($d_unix | path join "ygg.toml")
        let out_unix = ($home | path join "gh-out-unix.txt")
        "" | save -f $out_unix
        let r_unix = (with-env { YGG_MATRIX_MOD_DIR: $d_unix, YGG_OS_INPUT: "", GITHUB_OUTPUT: $out_unix } {
            ^nu -I $SRC_DIR -c $inner_script | complete
        })
        assert equal $r_unix.exit_code 0 $r_unix.stderr
        assert (not ($r_unix.stdout | str contains "Unknown OS"))
        let out_txt = (open --raw $out_unix)
        assert ($out_txt | str contains '"os":"unix","runner":"ubuntu-latest"')
        assert ($out_txt | str contains "has-mise=true")
    }
}
