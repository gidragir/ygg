#!/usr/bin/env nu
# tests/run.nu — Test runner for ygg test suite

def clean-ygg-env []: nothing -> record {
    $env | columns
    | where { |k| ($k starts-with "YGG_") and ($k != "YGG_RUN_HOST_E2E") }
    | reduce -f {} { |k, acc| $acc | insert $k null }
}

def main [--filter: string = ""] {
    let tests_dir = $env.FILE_PWD
    let test_files = (glob (($tests_dir | path join "test_*.nu") | str replace --all '\' '/') | sort)

    if ($test_files | is-empty) {
        print $"No test files found in ($tests_dir)"
        exit 0
    }

    mut all_tests = []
    mut compile_failures = []

    print $"Running ygg test suite...\n"

    for file in $test_files {
        let file_name = ($file | path basename)
        if $file_name == "test_phase2_modules.nu" and (($env.YGG_RUN_HOST_E2E? | default "0") != "1") {
            print $"  ⏭️  SKIP: ($file_name) \(requires YGG_RUN_HOST_E2E=1\)"
            continue
        }
        cd $tests_dir

        # Try to discover tests in the file
        let disc = (with-env (clean-ygg-env) {
            ^nu -I $tests_dir -c $"use ($file_name) *; scope commands | where name starts-with 'test_' | select name | to json" | complete
        })
        if $disc.exit_code != 0 {
            print $"❌ FAIL: ($file_name) \(failed to compile or import\)"
            print $disc.stderr
            $compile_failures = ($compile_failures | append { file: $file_name, test: "<compile>", error: $disc.stderr })
            continue
        }

        let test_list = ($disc.stdout | from json)
        for item in $test_list {
            let test_fn = $item.name
            if ($filter != "") and not ($test_fn | str contains $filter) {
                continue
            }
            $all_tests = ($all_tests | append { file: $file_name, test: $test_fn })
        }
    }

    cd $tests_dir
    let results = ($all_tests | par-each --threads 4 { |entry|
        let run_res = (with-env (clean-ygg-env) {
            ^nu -I $tests_dir -c $"use ($entry.file) *; ($entry.test)" | complete
        })
        {
            file: $entry.file,
            test: $entry.test,
            ok: ($run_res.exit_code == 0),
            stderr: $run_res.stderr
        }
    })

    for r in $results {
        if $r.ok {
            print $"  ✅ PASS: ($r.test)"
        } else {
            print $"  ❌ FAIL: ($r.test)"
            print $r.stderr
        }
    }

    let total_passed = ($results | where ok | length)
    let total_failed = (($results | where { |r| not $r.ok } | length) + ($compile_failures | length))

    print $"\n----------------------------------------"
    if $total_failed == 0 {
        print $"PASS \(($total_passed) tests passed\)"
        exit 0
    } else {
        print $"FAIL \(($total_failed) failed, ($total_passed) passed\)"
        exit 1
    }
}
