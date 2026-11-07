# tests/helpers.nu
# Helper functions for ygg test suites

export def with-temp-ygg [action: closure]: nothing -> nothing {
    let tmp = if ($nu.os-info.family == "windows") {
        let base = ($env.TEMP? | default ($env.TMP? | default "C:\\Temp"))
        let rand_suffix = (random chars --length 8)
        let dir = ($base | path join $"ygg-test-($rand_suffix)")
        mkdir $dir
        $dir
    } else {
        ^mktemp -d -t ygg-test.XXXXXX | str trim
    }

    let ygg_home = ($tmp | path join "ygg-home")
    let ygg_sandbox = ($tmp | path join "ygg-sb")
    mkdir $ygg_home
    mkdir $ygg_sandbox

    try {
        with-env {
            YGG_HOME: $ygg_home,
            YGG_SANDBOX: $ygg_sandbox
        } {
            do $action $ygg_home
        }
        rm -rf $tmp
    } catch { |e|
        rm -rf $tmp
        error make { msg: $e.msg }
    }
}
