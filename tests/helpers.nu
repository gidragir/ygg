# tests/helpers.nu
# Helper functions for ygg test suites

export def with-temp-ygg [action: closure]: nothing -> nothing {
    let tmp = if ($nu.os-info.family == "windows") {
        let base = ($env.RUNNER_TEMP? | default ($env.TEMP? | default ($env.TMP? | default "C:\\Temp")))
        let rand_suffix = (random chars --length 8)
        let dir = ($base | path join $"ygg-test-($rand_suffix)")
        mkdir $dir
        $dir | path expand
    } else {
        ^mktemp -d -t ygg-test.XXXXXX | str trim | path expand
    }

    let ygg_home = ($tmp | path join "ygg-home")
    let ygg_sandbox = ($tmp | path join "ygg-sb")
    mkdir $ygg_home
    mkdir $ygg_sandbox

    try {
        with-env {
            YGG_HOME: $ygg_home,
            YGG_SANDBOX: $ygg_sandbox,
            YGG_MOCK_PKG_LOG: ""
        } {
            do $action $ygg_home
        }
        rm -rf $tmp
    } catch { |e|
        rm -rf $tmp
        error make { msg: $e.msg }
    }
}

export def stat-inode [p: string]: nothing -> string {
    if ($nu.os-info.name == "macos") {
        ^stat -f "%i" $p | str trim
    } else {
        ^stat -c "%i" $p | str trim
    }
}

export def stat-mode [p: string]: nothing -> string {
    if ($nu.os-info.name == "macos") {
        ^stat -f "%Lp" $p | str trim
    } else {
        ^stat -c "%a" $p | str trim
    }
}

export def test-link-dir [src: string, dest: string]: nothing -> nothing {
    if ($nu.os-info.family == "windows") {
        let win_dest = ($dest | path expand -n | str replace --all "/" "\\")
        let win_src = ($src | path expand -n | str replace --all "/" "\\")
        let res = (^cmd /c mklink /J $win_dest $win_src | complete)
        if $res.exit_code != 0 {
            error make { msg: $"mklink /J failed: ($res.stdout) ($res.stderr)" }
        }
    } else {
        ^ln -s $src $dest
    }
}

export def test-dangling-link [target: string, dest: string]: nothing -> nothing {
    if ($nu.os-info.family == "windows") {
        mkdir $target
        test-link-dir $target $dest
        rm -rf $target
    } else {
        ^ln -s $target $dest
    }
}

export def safe-glob [pattern: string]: nothing -> list<string> {
    glob ($pattern | str replace --all '\' '/')
}
