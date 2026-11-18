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
