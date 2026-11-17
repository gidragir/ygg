# tests/test_progress.nu
# Юнит-тесты для модуля src/progress.nu

use std/assert
use ../src/mod.nu *
use helpers.nu *

export def test_progress_sanitize_and_split [] {
    # Проверка очистки ANSI, табов и управляющих символов
    let raw = "\x1b[32mDownloading\tfile.tar.gz\x1b[0m \x1b[2K 50%"
    let clean = (sanitize-log-line $raw)
    assert equal $clean "Downloading file.tar.gz  50%"
}

export def test_progress_read_last_log_line_edge_cases [] {
    with-temp-ygg { |tmp|
        # 1. Несуществующий файл
        assert equal (read-last-log-line ($tmp | path join "missing.log")) ""

        # 2. Пустой файл
        let empty_log = ($tmp | path join "empty.log")
        "" | save -f $empty_log
        assert equal (read-last-log-line $empty_log) ""

        # 3. Многострочный файл
        let multi_log = ($tmp | path join "multi.log")
        "line 1\nline 2\n  \x1b[33mlast line\x1b[0m  \n\n" | save -f $multi_log
        assert equal (read-last-log-line $multi_log) "last line"

        # 4. \r-only поток (git --progress / curl) — сплит до ansi strip
        let cr_log = ($tmp | path join "cr.log")
        "Receiving objects:  10%\r\x1b[KReceiving objects:  50%\r\x1b[KReceiving objects: 100% (done)" | save -f $cr_log
        assert equal (read-last-log-line $cr_log) "Receiving objects: 100% (done)"

        # 5. >5 КБ файл с многобайтовым UTF-8 (кириллица/эмодзи) на границе 4096 байт
        let big_log = ($tmp | path join "big.log")
        let prefix = (1..2500 | each { "я" } | str join "") # ~5000 байт
        $"($prefix)\nфинальная строка 🚀" | save -f $big_log
        assert equal (read-last-log-line $big_log) "финальная строка 🚀"
    }
}

export def test_progress_format_and_narrow_width [] {
    let line = (format-progress-line "⠋" "[pkg] install" "downloading package" 14 80)
    assert ($line | str starts-with "⠋ [pkg] install (14s) | downloading package")
    assert (($line | str length) <= 80)

    # Обрезка длинного хвоста под width: 40 (включая кириллицу и эмодзи без битого UTF-8)
    let long_tail = (1..60 | each { "a" } | str join "")
    let truncated = (format-progress-line "⠋" "[pkg]" $long_tail 5 40)
    assert (($truncated | str length --grapheme-clusters) <= 40)
    assert ($truncated | str ends-with "...")

    let utf8_tail = (1..25 | each { "я🚀" } | str join "")
    let utf8_line = (format-progress-line "⠋" "[pkg] тест" $utf8_tail 5 40)
    assert (($utf8_line | str length --grapheme-clusters) <= 40)
    assert ($utf8_line | str ends-with "...")
    assert not ($utf8_line | str contains "\u{fffd}")

    # Сверх-узкий терминал (width: 15) — без отрицательного среза и падений
    let narrow = (format-progress-line "⠋" "[pkg] very-long-label" "tail" 120 15)
    assert (($narrow | str length --grapheme-clusters) <= 20)

    # Финальная строка [ok] / [fail]
    let done_ok = (format-progress-done "ok" "[pkg] install" 18.42)
    assert equal $done_ok "[ok] [pkg] install (18.4s)"
    let done_fail = (format-progress-done "fail" "[pkg] install" 2.0)
    assert equal $done_fail "[fail] [pkg] install (2.0s)"
}

export def test_progress_is_tty_env_guards [] {
    with-env { NO_COLOR: "1" } {
        assert equal (is-tty-progress) false
    }
    with-env { TERM: "dumb", NO_COLOR: "" } {
        assert equal (is-tty-progress) false
    }
}

export def test_run_with_timeout_label_streams_and_exit_codes [] {
    # Раздельные stdout и stderr при exit_code == 0
    let ok = (run-with-timeout ["nu" "-c" "print 'out-ok'; print -e 'err-ok'"] 10 --label "[test] ok" --no-tty-progress)
    assert equal $ok.exit_code 0
    assert equal $ok.timed_out false
    assert ($ok.stdout | str contains "out-ok")
    assert ($ok.stderr | str contains "err-ok")
    assert not ($ok.stdout | str contains "err-ok")

    # Раздельные stdout и stderr при ненулевом коде (имитация WINGET_OK_CODES)
    let nonzero = (run-with-timeout ["nu" "-c" "print 'out-nz'; print -e 'err-nz'; exit 42"] 10 --label "[test] nz" --no-tty-progress)
    assert equal $nonzero.exit_code 42
    assert equal $nonzero.timed_out false
    assert ($nonzero.stdout | str contains "out-nz")
    assert ($nonzero.stderr | str contains "err-nz")
}

export def test_run_with_timeout_label_missing_bin [] {
    let res = (run-with-timeout ["nonexistent-ygg-bin-12345" "--version"] 5 --label "[test] missing" --no-tty-progress)
    assert equal $res.exit_code 127
    assert equal $res.timed_out false
    assert ($res.stderr != "")
}

export def test_run_with_timeout_label_plain_and_no_color [] {
    let src_dir = if ("src/mod.nu" | path exists) { "src" } else { "../src" }
    let sub = (^nu -I $src_dir -c 'use mod.nu *; with-env { NO_COLOR: "1" } { run-with-timeout ["nu" "-c" "print hello"] 10 --label "[pkg] demo" | ignore }' | complete)
    assert equal $sub.exit_code 0
    assert ($sub.stderr | str contains "[pkg] demo...")
    assert ($sub.stderr | str contains "[ok] [pkg] demo (")
    assert not ($sub.stderr | str contains "\r")
    assert not ($sub.stderr | str contains "\x1b[")
}

# regression: #9
export def test_run_with_timeout_soft_fail_prints_warn [] {
    let src_dir = if ("src/mod.nu" | path exists) { "src" } else { "../src" }
    let sub = (^nu -I $src_dir -c 'use mod.nu *; with-env { NO_COLOR: "1" } { let r = (run-with-timeout ["nu" "-c" "exit 1"] 10 --label "[hooks] demo" --soft-fail); print $r.exit_code }' | complete)
    assert ($sub.stderr | str contains "[warn] [hooks] demo (")
    assert not ($sub.stderr | str contains "[fail]")
    assert equal ($sub.stdout | str trim) "1"
}

export def test_hook_warnings_first_line_and_per_key [] {
    let hooks = [
        { module: "hm", keys: ["a", "b"], cmd: "x", status: "failed", stderr: "boom\nsecond line" }
        { module: "hm", keys: ["c"], cmd: "y", status: "ok", stderr: "" }
    ]
    let w = (hook-warnings $hooks)
    assert equal ($w | length) 2
    assert equal ($w | get item) ["a", "b"]
    assert ($w | all { |r| $r.message == "boom" and $r.source == "on_change" and $r.module == "hm" })
}

export def test_format_apply_summary_variants [] {
    assert equal (format-apply-summary 2 []) { stdout: "Applied 2 module(s).", stderr: "" }
    let w = [{ source: "on_change", module: "hm", item: "a", message: "boom" }]
    let s = (format-apply-summary 1 $w)
    assert equal $s.stdout "Applied 1 module(s) with 1 warning(s)."
    assert ($s.stderr | str contains "[ygg] Warnings:\n  - on_change 'a' (hm): boom")
    assert not ($s.stderr | str contains "ygg remove")
    let s2 = (format-apply-summary 1 $w --added-module "hm")
    assert ($s2.stderr | str ends-with "`ygg remove hm` to roll back")
}

export def test_run_with_timeout_label_cr_stream_and_no_timeout [] {
    # timeout_sec = 0 с --label != "" должен работать через job spawn без таймаута
    let res = (run-with-timeout ["nu" "-c" "print -e -n 'step 1\rstep 2\rstep 3\n'"] 0 --label "[git] clone" --no-tty-progress)
    assert equal $res.exit_code 0
    assert equal $res.timed_out false
    assert ($res.stderr | str contains "step 3")
}

export def test_run_with_timeout_label_after_caught_error [] {
    try { error make { msg: "prior-caught-error" } } catch { }
    let res = (run-with-timeout ["nu" "-c" "print 'ok-after-error'"] 10 --label "[test] after-err" --no-tty-progress)
    assert equal $res.exit_code 0
    assert equal $res.timed_out false
    assert ($res.stdout | str contains "ok-after-error")
}

export def test_run_with_timeout_label_timeout_and_cleanup [] {
    with-temp-ygg { |tmp|
        let src_dir = if ("src/mod.nu" | path exists) { "src" } else { "../src" }
        with-env { TMPDIR: $tmp, TEMP: $tmp, TMP: $tmp } {
            let sub = (^nu -I $src_dir -c 'use mod.nu *; let r = (run-with-timeout ["nu" "-c" "print -e partial-err; sleep 5sec"] 1 --label "[test] slow" --no-tty-progress); $r | to json -r' | complete)
            assert equal $sub.exit_code 0 $sub.stderr
            let res = ($sub.stdout | from json)
            assert equal $res.exit_code 124
            assert equal $res.timed_out true
            assert ($res.stderr | str contains "partial-err")
            assert ($res.stderr | str contains "timed out after 1s")
            let leftover = (ls $tmp | where { |f| ($f.name | path basename) starts-with "ygg-proc-" } | length)
            assert equal $leftover 0
        }
    }
}
