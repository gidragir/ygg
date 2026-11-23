# Изоляция тестов (`tests/helpers.nu`)

Общие правила изоляции (ZERO HOST MUTATION, очищенное окружение `tests/run.nu`) — в AGENTS.md §2.1. Здесь — как это устроено в коде.

Каждый тест работает внутри `with-temp-ygg`: он создаёт уникальную папку через `mktemp -d -t ygg-test.XXXXXX`, выставляет `YGG_HOME` и `YGG_SANDBOX` в `with-env` и гарантированно удаляет папку в блоке `try { ... } catch { |e| rm -rf $tmp; error make { msg: $e.msg } }`.

## Моки пакетов и видимость функций

* `with-temp-ygg` выставляет `YGG_SANDBOX` и `YGG_MOCK_PKG_LOG = ""`. При пустом `YGG_MOCK_PKG_LOG` функции `install-packages` и шаг контейнеров выходят сразу (защита песочницы). Любой юнит- или E2E-тест, который должен дойти до логики `install-packages` (включая `YGG_MOCK_ACTIVE_RUNTIME` или `YGG_MOCK_PKG_FAIL` в `ygg apply`), обязан явно задать `YGG_MOCK_PKG_LOG` внутри своего временного каталога.
* Импорт в тестах (`use ... [...]`) работает только для `export def`. Приватные `def` нельзя вызвать из `tests/*.nu` напрямую — либо экспортируй хелпер, либо тестируй через публичную функцию.

## Параллелизм (`par-each --threads 4`) и `$nu.temp-dir`

`mktemp -t` использует `$nu.temp-dir`, который кешируется при старте `nu`. Не проверяй глобальный `$nu.temp-dir` на отсутствие `ygg-proc-*` — запускай тестируемую команду в дочернем `^nu` с `TMPDIR`/`TEMP`/`TMP`, указывающими на каталог `with-temp-ygg`:

```nushell
# ✅ ПРАВИЛЬНО: изолированный temp-dir для проверки очистки временных файлов
with-temp-ygg { |tmp|
    with-env { TMPDIR: $tmp, TEMP: $tmp, TMP: $tmp } {
        ^nu -I $src_dir -c '...' | complete
        assert equal (ls $tmp | where { |f| ($f.name | path basename) starts-with "ygg-proc-" } | length) 0
    }
}
```

## Кроссплатформенные моки и реальные контракты (копипаст-рецепты, ADR-05)

### 1. Мок внешнего CLI без отключения Windows (`write-mock-cli`)
Запрещено писать `if ($nu.os-info.family == "windows") { return }` из-за `#!/bin/sh`-заглушек или проверки прав `0600` (на Windows проверяй ACL через `read-windows-acl`), даже если такой `return` остался в соседних старых тестах файла. Пробрасывай `$bin_dir` одновременно в `PATH` и `Path`:

```nushell
# ✅ КОПИПАСТ-РЕЦЕПТ: кроссплатформенный мок бинарника в $bin_dir
def write-mock-cli [bin_dir: string, name: string, sh_body: string, cmd_body: string] {
    mkdir $bin_dir
    let sh_path = ($bin_dir | path join $name)
    $"#!/bin/sh\n($sh_body)\n" | save -f $sh_path
    if $nu.os-info.family != "windows" { ^chmod +x $sh_path }
    $"@echo off\r\nsetlocal\r\n($cmd_body)\r\n" | save -f $"($sh_path).cmd"
}

# При спавне дочернего ^nu на Windows передавай PATH и Path строкой через (char esep):
let sub_path = (($env.PATH? | default $env.Path? | default []) | prepend $bin_dir | str join (char esep))
with-env { PATH: $sub_path, Path: $sub_path } { ^($nu.current-exe) ... }
```

### 2. Тестирование контракта «продюсер → потребитель»
Запрещено тестировать функции-потребители (`run-service-actions`, `run-link-hooks`, `format-apply-summary`) только на синтетических `record` с угаданными полями (например, выдуманный `op: "COPY_UPDATE"` — реальный `compute-link-ops` / `plan-copy-sync` возвращает `op: "COPY"` с `detail: "pushed_to_host" | "seeded_host"` и обязательным полем `key`):

```nushell
# ❌ ЗАПРЕЩЕНО: угаданный op ("COPY_UPDATE" вместо реального "COPY") — тест зелёный, а в продакшене триггеры мертвы
# let res = (run-service-actions $home $plan [{ op: "COPY_UPDATE", dest: $conf, module: "app" }] --sandbox $sb)

# ✅ КОПИПАСТ-РЕЦЕПТ: реальный выход продюсера подаётся напрямую в потребитель
let resolved = (resolve-link-targets $plan --sandbox $sb)
let ops = (compute-link-ops $home $resolved --sandbox $sb)
let actions = (run-service-actions $home $plan $ops --sandbox $sb)
```

### 3. `Post-Apply Invariant Gate` и проверка `.ps1` в реальном `^pwsh`
После успешного `ygg apply` в E2E-тестах проверяй инвариант чистого состояния, а генерируемые `env.ps1`, `aliases.ps1` и `completions ps1` (включая пути песочницы с пробелом и кириллицей) прогоняй через реальный `^pwsh`:

```nushell
# ✅ КОПИПАСТ-РЕЦЕПТ: инвариант чистого состояния после успешного ygg apply
assert equal ((^nu $ygg_bin diff --sandbox $sb | complete).exit_code) 0
assert equal ((^nu $ygg_bin doctor --sandbox $sb | complete).exit_code) 0
assert equal (($home | path join ".state" "host.lock" | path type)) null
assert equal (($home | path join ".state" "journal.json" | path type)) null

# ✅ КОПИПАСТ-РЕЦЕПТ: валидация сгенерированного .ps1 в реальном pwsh
if (which pwsh | is-not-empty) {
    let esc_ps1 = ($ps1_path | str replace --all "'" "''")
    let ps_res = (^pwsh -NoProfile -NonInteractive -Command $". '($esc_ps1)'" | complete)
    assert equal $ps_res.exit_code 0
}
```
