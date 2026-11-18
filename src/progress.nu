# src/progress.nu
# Потоковый однострочный живой прогресс в stderr (RFC-060)

export def is-tty-progress []: nothing -> bool {
    (is-terminal --stderr) and (($env.TERM? | default "") != "dumb") and (($env.NO_COLOR? | default "") == "")
}

export def term-columns []: nothing -> int {
    try { [(term size).columns, 20] | math max } catch { 80 }
}

export def sanitize-log-line [line: string]: nothing -> string {
    $line
    | str replace --all "\t" " "
    | ansi strip
    | str replace --all --regex '[\x00-\x1f\x7f]' ""
    | str trim
}

export def read-last-log-line [path: string]: nothing -> string {
    if not ($path | path exists) { return "" }
    let raw_bytes = try { open --raw $path | into binary } catch { return "" }
    let total = ($raw_bytes | bytes length)
    if $total == 0 { return "" }

    let tail_bytes = if $total > 4096 {
        let slice = ($raw_bytes | bytes at (-4096)..)
        # Пропустить до 3 ведущих UTF-8 continuation-байтов (0x80..0xBF)
        mut skip = 0
        while $skip < 3 and $skip < ($slice | bytes length) {
            let b = ($slice | bytes at $skip..$skip | into int)
            if $b >= 128 and $b <= 191 {
                $skip = $skip + 1
            } else {
                break
            }
        }
        if $skip > 0 { $slice | bytes at $skip.. } else { $slice }
    } else {
        $raw_bytes
    }

    let text = try { $tail_bytes | decode utf-8 } catch { $tail_bytes | into string }
    # Сплит строго до ansi strip, чтобы не потерять \r-перезаписи без \n
    let lines = (
        $text
        | split row --regex '[\r\n]+'
        | each { |l| sanitize-log-line $l }
        | where { |l| $l != "" }
    )
    if ($lines | is-empty) { "" } else { $lines | last }
}

export def read-progress-tail [err_path: string, out_path: string]: nothing -> string {
    let has_err = ($err_path != "") and ($err_path | path exists)
    let has_out = ($out_path != "") and ($out_path | path exists)
    if not $has_err and not $has_out { return "" }

    if $has_err and $has_out {
        let err_m = (ls -D $err_path | get -o 0.modified)
        let out_m = (ls -D $out_path | get -o 0.modified)
        if ($out_m != null) and ($err_m != null) and ($out_m > $err_m) {
            let out_line = (read-last-log-line $out_path)
            if $out_line != "" { return $out_line }
            return (read-last-log-line $err_path)
        }
        let err_line = (read-last-log-line $err_path)
        if $err_line != "" { return $err_line }
        return (read-last-log-line $out_path)
    }

    if $has_err { read-last-log-line $err_path } else { read-last-log-line $out_path }
}

export def progress-clear-line []: nothing -> nothing {
    if (is-tty-progress) {
        print -e -n "\r\x1b[2K"
    }
}

export def format-progress-line [
    spinner: string
    label: string
    tail: string
    elapsed_sec: int
    width: int
]: nothing -> string {
    let max_w = ([$width, 20] | math max)
    let prefix = $"($spinner) ($label) \(($elapsed_sec)s\)"
    let prefix_len = ($prefix | str length --grapheme-clusters)

    if $tail == "" {
        if $prefix_len <= $max_w { return $prefix }
        let cut = ([($max_w - 3), 0] | math max)
        return (($prefix | str substring --grapheme-clusters 0..<$cut) + "...")
    }

    let sep = " | "
    let avail = $max_w - $prefix_len - ($sep | str length --grapheme-clusters)
    if $avail <= 3 {
        if $prefix_len <= $max_w { return $prefix }
        let cut = ([($max_w - 3), 0] | math max)
        return (($prefix | str substring --grapheme-clusters 0..<$cut) + "...")
    }

    let clean_tail = if ($tail | str length --grapheme-clusters) > $avail {
        let cut = ([($avail - 3), 0] | math max)
        (($tail | str substring --grapheme-clusters 0..<$cut) + "...")
    } else {
        $tail
    }
    $"($prefix)($sep)($clean_tail)"
}

export def format-progress-done [
    status: string
    label: string
    elapsed_sec: float
]: nothing -> string {
    let secs = ($elapsed_sec | math round --precision 1 | into string)
    let formatted_secs = if ($secs | str contains ".") { $secs } else { $"($secs).0" }
    $"[($status)] ($label) \(($formatted_secs)s\)"
}

export def progress-step [phase: string, msg: string]: nothing -> nothing {
    progress-clear-line
    print -e $"[($phase)] ($msg)"
}

# Collect per-key warning records from failed link hooks (RFC-061 #8)
export def hook-warnings [hooks: list<record>]: nothing -> list<record<source: string, module: string, item: string, message: string>> {
    mut out = []
    for h in ($hooks | where { |it| ($it.status? | default "") == "failed" }) {
        let first_line = ($h.stderr? | default "" | lines | where { |l| ($l | str trim) != "" } | get -o 0 | default "" | str trim)
        let mod = ($h.module? | default "")
        for k in ($h.keys? | default []) {
            $out = ($out | append { source: "on_change", module: $mod, item: $k, message: $first_line })
        }
    }
    $out
}

# Format the final stdout/stderr summary for `apply-plan` (RFC-061 #8)
export def format-apply-summary [
    mod_count: int
    warnings: list<record>
    --added-module: string = ""
]: nothing -> record<stdout: string, stderr: string> {
    if ($warnings | is-empty) {
        return {
            stdout: ("Applied " + ($mod_count | into string) + " module(s).")
            stderr: ""
        }
    }
    let k = ($warnings | length)
    let stdout = ("Applied " + ($mod_count | into string) + " module(s) with " + ($k | into string) + " warning(s).")
    let bullets = ($warnings | each { |w|
        "  - " + $w.source + " '" + $w.item + "' (" + $w.module + "): " + $w.message
    } | str join "\n")
    let rollback = if ($added_module != "") {
        " · `ygg remove " + $added_module + "` to roll back"
    } else {
        ""
    }
    let next_line = "[ygg] Next: `ygg apply` re-runs failed hooks · `ygg doctor` to diagnose" + $rollback
    let stderr = "[ygg] Warnings:\n" + $bullets + "\n" + $next_line
    { stdout: $stdout, stderr: $stderr }
}

# Format the backup summary printed to stderr at the end of a mutating run (RFC-063)
export def format-backup-summary [
    run: record
    --limit: int = 10
]: nothing -> string {
    let entries = ($run.entries? | default [])
    let total = ($entries | length)
    if $total == 0 {
        return ""
    }
    let dir = ($run.dir? | default "")
    let header = "[ygg] Backed up " + ($total | into string) + " path(s) -> " + $dir + ":"
    let shown = ($entries | first $limit | each { |e| "  - " + ($e.target? | default "") })
    let lines = if $total > $limit {
        let rest = $total - $limit
        $shown | append ("  ... and " + ($rest | into string) + " more")
    } else {
        $shown
    }
    $header + "\n" + ($lines | str join "\n")
}
