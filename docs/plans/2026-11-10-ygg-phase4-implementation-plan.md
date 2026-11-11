# План реализации Фазы 4: Корректность, безопасность и приведение Фазы 3 к контракту (RFC-041 — RFC-058)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Устранить дефекты ревью 2026-11-10 (5 критичных, 9 высоких) и привести реализацию Фазы 3 к контракту спецификации Фазы 4.

**Architecture:** Точечные правки существующих модулей `src/{state,env,pkg,doctor,git,manifest,sdk,link}.nu` и роутера `bin/ygg.nu` без новых файлов ядра. Первой задачей тесты делаются герметичными, чтобы все последующие TDD-циклы давали достоверный результат. Каждая задача — падающий тест, минимальная реализация по сигнатуре из спеки, полный прогон, один коммит.

**Tech Stack:** Nushell `>= 0.116.1`, TOML, Git, GitHub Actions, `rtk`.

**Spec:** [`docs/specs/2026-11-10-ygg-phase4-correctness-and-security-hardening.md`](../specs/2026-11-10-ygg-phase4-correctness-and-security-hardening.md). При разночтениях спецификация приоритетнее плана. Точные форматы, сигнатуры и значения — в спеке; план их не дублирует, а ссылается на пункт RFC.

## Global Constraints

- **Рабочий каталог:** корень репозитория `ygg`.
- **ZERO HOST MUTATION:** тесты и отладочные запуски не читают и не изменяют реальные `~/.ygg`, `~/.config`, `$HOME`. Любой ручной запуск `bin/ygg.nu` — только с `YGG_HOME` и `YGG_SANDBOX` во временном каталоге.
- **Чистота ядра:** в `src/*.nu`, `bin/*` нет абсолютных путей разработчика и имён личных модулей. Purity-шаг CI запрещает в ядре токены сторонних утилит из инварианта §2.2 AGENTS.md — не использовать их даже в комментариях.
- **Команды:** с префиксом `rtk`; поиск — `rtk fd`, `rtk rg`.
- **Полный прогон:** `rtk nu tests/run.nu` → последняя строка `PASS (N tests passed)`.
- **Один тест:** `rtk nu -I src -c 'use tests/<файл>.nu *; <имя_теста>'` → код возврата 0.
- **Идиомы Nushell 0.116:** `get -o`; внешние команды через `| complete`; `where { |it| … }`; строки с `[`/`]` — конкатенацией; `path expand -n` там, где нельзя разыменовывать ссылки.
- **Тесты, использующие мок-бинарь в `PATH`** (shell-скрипт), начинаются с `if $nu.os-info.family == "windows" { return }`.
- **CLI-тесты** задают `YGG_HOST_OS_OVERRIDE: "cachyos"` и `ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)`.
- **Коммиты:** `rtk oco -y`, одна строка Conventional Commits на английском.
- **Навигация:** `context_pack <subsystem>`; перед сдачей каждой задачи, меняющей структуру, — `rtk context-init check --compact`.

## Review Focus

1. **Секрет с кавычкой или `$` в ссылке** (`op://v/it'em/f`): строка в `env.zsh`/`env.fish`/`env.nu` остаётся синтаксически валидной и не исполняет вложенную подстановку → тест в Task 5.
2. **`apply`, убитый сигналом между шагами** (журнал `in_progress`, PID мёртв): следующий `apply` восстанавливается, а `doctor` сообщает `journal_interrupted`, не `journal_failed` → тест в Task 6.
3. **Блокировка, оставленная на другом хосте** (общий `$YGG_HOME` по сети): не перехватывается молча → тест в Task 7.
4. **`ygg diff` на хосте, где `ygg` ни разу не запускался** (нет `.state`): отрабатывает без ошибки и без создания каталогов → тест в Task 2.
5. **`--prune-packages` после смены набора скоупов**: пакеты выключенного скоупа удаляются только у менеджеров из `--pkg` и только безопасных без `--force-system-prune` → тест в Task 3.

---

## Этап 4.1: Безопасность (P0)

### Task 1: Герметичные тесты (RFC-051 п.1–4)

**Files:**
- Modify: `tests/run.nu:28-44`, `tests/helpers.nu:20-24`
- Modify: `tests/test_pkg_git.nu:35-52`
- Test: `tests/test_state.nu`

**Interfaces:**
- Produces: `with-temp-ygg` задаёт `YGG_HOME`, `YGG_SANDBOX`, `YGG_MOCK_PKG_LOG = ""`; `run.nu` скрывает унаследованные `YGG_*`, кроме `YGG_RUN_HOST_E2E`.

- [ ] **Step 1: Воспроизвести падение**

Run: `YGG_MOCK_PKG_LOG=/nonexistent/x rtk nu -I src -c 'use tests/test_pkg_git.nu *; test_sandbox_without_mock_skips_installation'`
Expected: FAIL `These are not equal`.

- [ ] **Step 2: Написать мета-тест в `tests/test_state.nu`**

```nu
export def test_tests_have_no_literal_tmp_paths [] {
    let tests_dir = ($env.FILE_PWD)
    let hits = (glob ($tests_dir | path join "*.nu") | each { |f|
        open --raw $f | lines | enumerate
        | where { |l| ($l.item | str contains '"/tmp/') and not ($l.item | str contains "str contains") }
        | each { |l| $"($f | path basename):($l.index + 1)" }
    } | flatten)
    assert equal $hits []
}
```

Run → FAIL (перечисляет `test_pkg_git.nu:45`, `:46`).

- [ ] **Step 3: `with-temp-ygg` — добавить `YGG_MOCK_PKG_LOG: ""` в `with-env`; `run.nu` — перед `^nu` обернуть вызов в `with-env`, обнуляющий все `$env` с именем `YGG_*`, кроме `YGG_RUN_HOST_E2E`** (`hide-env` внутри `do { }` либо запуск через `^env -u` на Unix и `with-env { K: null }` — выбрать вариант, работающий на Windows).

- [ ] **Step 4: Заменить `/tmp/sb` в `test_sandbox_without_mock_skips_installation` на `($home | path join "sb")`; исправить остальные находки мета-теста.**

- [ ] **Step 5: Проверить**

Run: `YGG_MOCK_PKG_LOG=/nonexistent/x YGG_HOME=/nonexistent/y rtk nu tests/run.nu`
Expected: `PASS`, 0 failed.

- [ ] **Step 6: Commit** — `rtk oco -y` (`test(tests): make test suite hermetic against inherited YGG_* env`).

---

### Task 2: Контракт read-only и `setup.nu` в dry-run (RFC-045)

**Files:**
- Modify: `bin/ygg.nu:207-232` (`main apply`), `:238-330` (`apply-plan`, dry-run ветка), `:516-527` (`main status`)
- Modify: `src/manifest.nu:123-135` (`load-module-manifest`: поле `setup`)
- Modify: `src/sdk.nu:290-336` (`run-module-setup`)
- Test: `tests/test_cli_e2e.nu`

**Interfaces:**
- Produces: `manifest.setup.dry_run_safe: bool` (default `false`); в dry-run `run-module-setup` для модуля без флага печатает `[ygg] (dry-run) SETUP <name> (skipped)` и возвращается.

- [ ] **Step 1: Написать падающие тесты**

```nu
def tree-snapshot [root: string]: nothing -> list<string> {
    glob ($root | path join "**" "*") | sort | each { |p| $"($p)|(ls -D $p | get 0.modified)" }
}

export def test_readonly_commands_do_not_touch_fresh_home [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb"); mkdir $sb
        "modules = []\n" | save -f ($home | path join "host.toml")
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let before = (tree-snapshot $home)
            for cmd in [["diff"], ["status"], ["doctor"], ["apply", "--dry-run"]] {
                ^nu $ygg_bin ...$cmd | complete | ignore
                assert equal (tree-snapshot $home) $before $"($cmd | str join ' ') mutated YGG_HOME"
            }
            assert (not ($home | path join ".state" | path exists))
        }
    }
}

export def test_dry_run_skips_setup_unless_dry_run_safe [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb"); mkdir $sb
        let m = ($home | path join "modules" "m"); mkdir $m
        let marker = ($home | path join "marker")
        "name = \"m\"\nos = [\"linux\"]\n" | save -f ($m | path join "ygg.toml")
        $"touch '($marker)'\n" | save -f ($m | path join "setup.nu")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let res = (^nu $ygg_bin diff | complete)
            assert (not ($marker | path exists))
            assert ($res.stdout | str contains "SETUP m (skipped)")
            "\n[setup]\ndry_run_safe = true\n" | save --append ($m | path join "ygg.toml")
            ^nu $ygg_bin diff | complete | ignore
            assert ($marker | path exists)
        }
    }
}
```

Замечание: в первом тесте `host.toml` с пустым списком модулей может упираться в guard «Plan contains 0 modules» — тогда в тест добавляется один пустой модуль, расположенный **вне** `$home` (`path = …` в соседнем `mktemp`-каталоге недопустим: использовать `($home | path dirname | path join "ext-mod")`, который `with-temp-ygg` удаляет вместе с `$tmp`).

- [ ] **Step 2: Run → FAIL** (`.state` создан; маркер создан).

- [ ] **Step 3: Реализация.** В `main apply`, `apply-plan`, `main add` вызывать `ensure-ygg-dirs` только при `not $dry_run`; удалить вызов из `main status`. В `acquire-host-lock` вызов `ensure-ygg-dirs` остаётся (до него доходит только мутирующий путь). `load-module-manifest` возвращает `setup: { dry_run_safe: ($raw.setup?.dry_run_safe? | default false) }`. `run-module-setup` — условие из блока Interfaces.

- [ ] **Step 4: Run обоих тестов → PASS; полный прогон → PASS.**

- [ ] **Step 5: Commit** — `fix(cli): keep diff/status/dry-run read-only and skip setup.nu in dry-run`.

---

### Task 3: Безопасный `--prune-packages` (RFC-044)

**Files:**
- Modify: `src/pkg.nu:340-400` (ветки записи `state.packages`), `:415-521`
- Modify: `bin/ygg.nu:300-345` (вызовы prune: передать `--pkg`, `--sandbox`; шаг журнала добавляется в Task 6)
- Test: `tests/test_pkg_git.nu`

**Interfaces:**
- Produces: `prune-unused-packages [ygg_home, current_plan, --dry-run, --force-system-prune, --pkg: string = "", --sandbox: string = ""]: nothing -> record<executed: list<string>, failed: list<string>, skipped: list<string>>`; `pkg-uninstall-argv [mgr: string, pkg: string]: nothing -> list<string>`.

- [ ] **Step 1: Написать падающие тесты**

```nu
def seed-pkg-state [home: string, pkgs: record] {
    ensure-ygg-dirs $home
    save-state $home { links: {}, copies: {}, hashes: {}, packages: $pkgs }
}

export def test_prune_in_sandbox_without_mock_executes_nothing [] {
    with-temp-ygg { |home|
        seed-pkg-state $home { cargo: ["ripgrep", "stale-crate"] }
        let plan = { packages: { cargo: ["ripgrep"] }, modules: [] }
        let res = (prune-unused-packages $home $plan --sandbox ($home | path join "sb"))
        assert equal $res.executed []
        assert equal (load-state $home).packages.cargo ["ripgrep", "stale-crate"]
    }
}

export def test_prune_history_survives_plain_apply [] {
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        with-env { YGG_MOCK_PKG_LOG: $log, YGG_HOST_OS_OVERRIDE: "cachyos" } {
            install-packages $home { packages: { cargo: ["a", "b"] }, modules: [] } | ignore
            install-packages $home { packages: { cargo: ["a"] }, modules: [] } | ignore
            install-packages $home { packages: { cargo: ["a"] }, modules: [] } | ignore   # cached branch
            assert ("b" in (load-state $home).packages.cargo)
            let res = (prune-unused-packages $home { packages: { cargo: ["a"] }, modules: [] })
            assert ($res.executed | any { |c| $c | str contains "b" })
            assert equal (load-state $home).packages.cargo ["a"]
        }
    }
}

export def test_prune_respects_pkg_filter_and_system_guard [] {
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        seed-pkg-state $home { cargo: ["x"], pnpm: ["y"], pacman: ["z"] }
        with-env { YGG_MOCK_PKG_LOG: $log, YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let res = (prune-unused-packages $home { packages: {}, modules: [] } --pkg "cargo")
            assert equal ($res.executed | length) 1
            assert ($res.executed.0 | str contains "x")
            let st = (load-state $home).packages
            assert equal $st.pnpm ["y"]
            assert equal $st.pacman ["z"]
        }
    }
}

export def test_pkg_uninstall_argv_keeps_spaces_intact [] {
    # через мок-лог: пакет с пробелом в имени не распадается на аргументы
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        seed-pkg-state $home { cargo: ["odd name"] }
        with-env { YGG_MOCK_PKG_LOG: $log } {
            let res = (prune-unused-packages $home { packages: {}, modules: [] })
            assert ($res.executed.0 | str ends-with "odd name")
        }
    }
}
```

- [ ] **Step 2: Run → FAIL** (тип возврата — list; история теряется).

- [ ] **Step 3: Реализация по RFC-044 п.1–8.** Существующие тесты `test_prune_unused_packages_*` перевести на новый тип возврата (`$res.executed`).

- [ ] **Step 4: Run новых тестов и полный прогон → PASS.**

- [ ] **Step 5: Commit** — `fix(pkg): guard package prune in sandbox, keep prune history, honor --pkg`.

---

### Task 4: Схемы секретов только из `secrets.toml` (RFC-041)

**Files:**
- Modify: `src/env.nu:91-170` (рядом с `resolve-secret-value`), `:216-224`
- Modify: `src/link.nu` (`preflight-check`, блок после проверки `depends_on` ~`:941`) либо `bin/ygg.nu` перед `preflight-check` — там, где собираются `problems`
- Test: `tests/test_env.nu`

**Interfaces:**
- Produces: `classify-secret-value [raw: string]: nothing -> record<kind: string, ref: string>`; `validate-secret-providers [ygg_home: string]: nothing -> list<string>`; внутренняя `load-secrets-env [ygg_home: string]: nothing -> record` (вынести из `compile-environment` шаг 1).
- Consumes (Task 5): обе функции.

- [ ] **Step 1: Написать падающие тесты**

```nu
export def test_classify_secret_value [] {
    assert equal (classify-secret-value "plain") { kind: "literal", ref: "plain" }
    assert equal (classify-secret-value "op://v/i/f") { kind: "op", ref: "op://v/i/f" }
    assert equal (classify-secret-value "bw://item") { kind: "bw", ref: "bw://item" }
    assert equal (classify-secret-value "pass:mail/x") { kind: "pass", ref: "mail/x" }
    assert equal (classify-secret-value "eval:echo 1") { kind: "eval", ref: "echo 1" }
    assert equal (classify-secret-value "literal:pass:abc") { kind: "literal", ref: "pass:abc" }
}

export def test_module_env_scheme_is_literal_and_not_executed [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = ($home | path join "sb"); mkdir $sb
        let marker = ($home | path join "pwned")
        let m = ($home | path join "modules" "m"); mkdir $m
        $"name = \"m\"\nos = [\"linux\"]\n[env]\nX = \"eval:touch ($marker)\"\n" | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            compile-environment $home (resolve-effective-plan $home) --sandbox $sb
        }
        assert (not ($marker | path exists))
        assert (open --raw ($home | path join ".state" "env" "env.zsh") | str contains $"export X='eval:touch ($marker)'")
    }
}

export def test_validate_secret_providers_reports_missing_cli [] {
    with-temp-ygg { |home|
        "K = \"op://v/i/f\"\nL = \"plain\"\n" | save -f ($home | path join "secrets.toml")
        let empty_bin = ($home | path join "empty-bin"); mkdir $empty_bin
        with-env { PATH: [$empty_bin] } {
            let errs = (validate-secret-providers $home)
            assert equal ($errs | length) 1
            assert ($errs.0 | str contains "op")
        }
    }
}
```

CLI-тест в `tests/test_cli_e2e.nu`: `secrets.toml` с `op://`, `PATH` без `op` (сохранить в `PATH` каталог `nu`: `($nu.current-exe | path dirname)`), модуль с `[packages] cargo = ["x"]`, `YGG_MOCK_PKG_LOG` задан → `apply` возвращает ненулевой код, файл лога не существует.

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Реализация.** В `compile-environment` значения `plan.env` идут мимо резолвера; значения `secrets.toml` классифицируются. Резолвинг в этой задаче остаётся прежним (материализация) — меняется в Task 5. `validate-secret-providers` подключается до шага пакетов и в dry-run.

- [ ] **Step 4: Run → PASS; полный прогон → PASS.**

- [ ] **Step 5: Commit** — `fix(env): interpret secret schemes only from secrets.toml and validate providers in preflight`.

---

### Task 5: Внешние секреты без материализации (RFC-042, RFC-049 п.4)

**Files:**
- Modify: `src/state.nu` (новая `restrict-file-access`)
- Modify: `src/env.nu:175-392`
- Modify: `src/doctor.nu` (находка `secrets_materialized`, функция `check-secrets` `:226`)
- Test: `tests/test_env.nu`, `tests/test_doctor.nu`

**Interfaces:**
- Consumes: `classify-secret-value`, `load-secrets-env` (Task 4).
- Produces: `restrict-file-access [path: string]: nothing -> bool` в `src/state.nu`; `secret-provider-argv [kind: string, ref: string]: nothing -> list<string>` в `src/env.nu` (argv из таблицы RFC-042 п.2); режим читается как `load-host-config $ygg_home | get -o ygg.secrets.materialize | default false`.

- [ ] **Step 1: Написать падающие тесты**

```nu
def write-mock-op [dir: string] {
    mkdir $dir
    "#!/bin/sh\necho S3CRET\n" | save -f ($dir | path join "op")
    ^chmod +x ($dir | path join "op")
}

def setup-secret-home [home: string, materialize: bool] {
    ensure-ygg-dirs $home
    let m = ($home | path join "modules" "m"); mkdir $m
    "name = \"m\"\nos = [\"linux\"]\n" | save -f ($m | path join "ygg.toml")
    $"[[modules]]\nname = \"m\"\n\n[ygg.secrets]\nmaterialize = ($materialize)\n" | save -f ($home | path join "host.toml")
    "K = \"op://v/i/f\"\nQ = \"op://v/it'em/$(id)\"\nP = \"plain\"\n" | save -f ($home | path join "secrets.toml")
}

export def test_external_secret_is_lazy_by_default [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        let sb = ($home | path join "sb"); mkdir $sb
        let bin = ($home | path join "mock-bin"); write-mock-op $bin
        setup-secret-home $home false
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", PATH: ($env.PATH | prepend $bin) } {
            compile-environment $home (resolve-effective-plan $home) --sandbox $sb
        }
        let leaked = (glob ($home | path join "**" "*") | where { |p| ($p | path type) == "file" and not ($p | str contains "mock-bin") }
            | where { |p| open --raw $p | str contains "S3CRET" })
        assert equal $leaked []
        let zsh = (open --raw ($home | path join ".state" "env" "env.zsh"))
        assert ($zsh | str contains "export K=\"$(op read 'op://v/i/f')\"")
        assert ($zsh | str contains "export P='plain'")
        # Review Focus 1: кавычка и $( ) в ссылке не ломают файл и не исполняются
        let chk = (^zsh -n ($home | path join ".state" "env" "env.zsh") | complete)
        if (which zsh | is-not-empty) { assert equal $chk.exit_code 0 }
        assert (not ($zsh | str contains "$(id)\"")) "ref must stay inside single quotes"
        let env_nu = ($home | path join ".state" "env" "env.nu")
        assert equal (^nu -c $"source '($env_nu)'; $env.K" | complete | get stdout | str trim) "S3CRET"
    }
}

export def test_external_secret_materialized_on_opt_in [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        let sb = ($home | path join "sb"); mkdir $sb
        let bin = ($home | path join "mock-bin"); write-mock-op $bin
        setup-secret-home $home true
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", PATH: ($env.PATH | prepend $bin) } {
            compile-environment $home (resolve-effective-plan $home) --sandbox $sb
        }
        let f = ($home | path join ".state" "env" "env.zsh")
        assert (open --raw $f | str contains "export K='S3CRET'")
        assert equal (ls -l $f | get 0.mode) "rw-------"
    }
}
```

`tests/test_doctor.nu`: при `materialize = true` и внешней ссылке в `secrets.toml` `run-doctor` возвращает находку `check == "secrets_materialized"`, `severity == "warn"`; при `false` — нет.

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Реализация по RFC-042 п.2–5.** Генераторы четырёх шелл-файлов получают на вход список `{ key, kind, value_or_argv }`. Статические приёмники (`99-ygg.conf`, `import-environment`, Windows-скрипт) фильтруют `kind != "literal"` и печатают предупреждение. Все `chmod 0600` в `env.nu` заменить на `restrict-file-access`.

- [ ] **Step 4: Run → PASS; полный прогон → PASS** (существующие тесты RFC-034, ожидавшие плейнтекст, перевести на `materialize = true`).

- [ ] **Step 5: Commit** — `feat(env): emit lazy provider calls for external secrets instead of plaintext`.

---

### Task 6: Журнал v2 и roll-forward (RFC-043)

**Files:**
- Modify: `src/state.nu:322-395`
- Modify: `bin/ygg.nu:286-408` (`apply-plan`)
- Modify: `src/doctor.nu:259-276` (`check-journal`)
- Test: `tests/test_state.nu`, `tests/test_cli_e2e.nu`, `tests/test_doctor.nu`

**Interfaces:**
- Consumes: `restrict-file-access` (Task 5), `check-process-alive`.
- Produces: сигнатуры RFC-043 п.2. `check-pending-journal` больше не возвращает поле `incomplete` — все потребители переходят на `state`.

- [ ] **Step 1: Переписать `test_journal_transaction_lifecycle` и добавить тесты**

```nu
export def test_journal_v2_states [] {
    with-temp-ygg { |home|
        assert equal (check-pending-journal $home).state "none"
        begin-journal-transaction $home { modules: [], env: { A: "secret-ish" } }
        let j = (open ($home | path join ".state" "journal.json"))
        assert equal $j.version 2
        assert ("plan" not-in ($j | columns))
        assert equal $j.pid $nu.pid
        assert equal (check-pending-journal $home).state "active"

        record-journal-step $home "packages" "COMMITTED"
        record-journal-step $home "links" "IN_PROGRESS"
        fail-journal-transaction $home "boom"
        let st = (check-pending-journal $home)
        assert equal $st.state "failed"
        assert equal $st.failed_step "links"
        assert equal $st.error "boom"

        commit-journal-transaction $home
        assert equal (check-pending-journal $home).state "none"
    }
}

export def test_journal_dead_pid_is_interrupted [] {
    with-temp-ygg { |home|
        begin-journal-transaction $home { modules: [] }
        let jf = ($home | path join ".state" "journal.json")
        open $jf | upsert pid 2147483646 | to json | save -f $jf
        assert equal (check-pending-journal $home).state "interrupted"
        "{\"timestamp\":\"x\",\"steps\":{}}" | save -f $jf     # v1
        assert equal (check-pending-journal $home).state "interrupted"
    }
}
```

CLI (`tests/test_cli_e2e.nu`), `test_apply_failure_marks_journal_failed_and_recovers`: модуль с одной ссылкой и `setup.nu` = `exit 3`. Assertions после первого `apply`: код ≠ 0; `journal.status == "failed"`; `journal.failed_step == "setup"`; `journal.steps.links == "COMMITTED"`; `doctor --json` содержит запись с `check == "journal_failed"` и `severity == "warn"`. Затем `setup.nu` заменяется на пустой: второй `apply` — код 0, stderr содержит `Recovering:`, `journal.json` отсутствует. Отдельно (Review Focus 2): PID в журнале заменён на `2147483646` → `doctor --json` содержит `journal_interrupted` с `severity == "error"`.

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Реализация `src/state.nu`** по RFC-043 п.1–2.

- [ ] **Step 4: Реализация `apply-plan`.** Тело от `begin-journal-transaction` до `commit-journal-transaction` — в `try`; в `catch` — `fail-journal-transaction $ygg_home $e.msg` и повторный `error make`. Шаги `prune_packages`, `services`, `finalize` получают `record-journal-step`. Сообщение `Recovering:` и принудительный refresh — по п.5.

- [ ] **Step 5: `check-journal`** по п.6; обновить `test_journal_transaction_lifecycle_and_doctor_detection`.

- [ ] **Step 6: Run → PASS; полный прогон → PASS.**

- [ ] **Step 7: Commit** — `fix(state): journal v2 with failure status and roll-forward recovery`.

---

## Этап 4.2: Надёжность (P1)

### Task 7: Атомарная блокировка `host.lock` (RFC-046)

**Files:**
- Modify: `src/state.nu:260-320`
- Test: `tests/test_state.nu`

**Interfaces:**
- Produces: те же сигнатуры `acquire-host-lock`, `release-host-lock`, `check-process-alive`; файл — `.state/host.lock`; payload с полем `host`.

- [ ] **Step 1: Написать падающие тесты**

```nu
export def test_host_lock_is_exclusive_under_race [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let src = ($env.FILE_PWD | path join "../src" | path expand)
        let script = $"use state.nu *; try { acquire-host-lock '($home)' 'apply' | ignore; sleep 2sec; print WON } catch { print LOST }"
        let outs = (1..8 | par-each { |_| ^nu -I $src -c $script | complete | get stdout | str trim })
        assert equal ($outs | where { |o| $o == "WON" } | length) 1
    }
}

export def test_host_lock_foreign_live_pid_and_foreign_host [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let lf = ($home | path join ".state" "host.lock")
        let me = (sys host | get hostname)
        { pid: 1, timestamp: "x", command: "apply", user: "root", host: $me } | to json | save -f $lf
        let r1 = (try { acquire-host-lock $home "apply"; "taken" } catch { "refused" })
        assert equal $r1 "refused"                       # EPERM = жив
        { pid: 2147483646, timestamp: "x", command: "apply", user: "u", host: "other-host" } | to json | save -f $lf
        let r2 = (try { acquire-host-lock $home "apply"; "taken" } catch { |e| $e.msg })
        assert ($r2 | str contains "other-host")         # Review Focus 3
        { pid: 2147483646, timestamp: "x", command: "apply", user: "u", host: $me } | to json | save -f $lf
        let l3 = (acquire-host-lock $home "apply")
        assert equal (open $lf | get pid) $nu.pid        # stale перехвачен
        release-host-lock $l3
        assert (not ($lf | path exists))
    }
}

export def test_release_host_lock_ignores_foreign_owner [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let lf = ($home | path join ".state" "host.lock")
        { pid: 1, host: (sys host | get hostname) } | to json | save -f $lf
        release-host-lock $lf
        assert ($lf | path exists)
    }
}
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Реализация по RFC-046 п.1–7.** Существующие тесты блокировки перевести на имя `host.lock`.

- [ ] **Step 4: Run → PASS (гоночный тест запустить 5 раз подряд); полный прогон → PASS.**

- [ ] **Step 5: Commit** — `fix(state): acquire host lock atomically via hard link and rename to host.lock`.

---

### Task 8: Windows ACL по SID (RFC-049 п.1–3)

**Files:**
- Modify: `src/doctor.nu:106-175`
- Test: `tests/test_doctor.nu:433-500`

**Interfaces:**
- Consumes: `restrict-file-access` (Task 5).
- Produces: `is-windows-acl-insecure [acl_lines: string]: nothing -> bool` (вход — строки `SID|Rights|Type`); внутренняя `read-windows-acl [path: string]: nothing -> string`.

- [ ] **Step 1: Заменить три теста парсера**

```nu
export def test_windows_acl_sid_parser [] {
    assert (is-windows-acl-insecure "S-1-5-32-545|ReadAndExecute, Synchronize|Allow")
    assert (is-windows-acl-insecure "S-1-5-21-1-2-3-1001|FullControl|Allow\r\nS-1-1-0|Read|Allow")
    assert (is-windows-acl-insecure "S-1-5-11|Modify|Allow")
    assert (not (is-windows-acl-insecure "S-1-5-21-1-2-3-1001|FullControl|Allow\nS-1-5-18|FullControl|Allow"))
    assert (not (is-windows-acl-insecure "S-1-1-0|FullControl|Deny"))
    assert (not (is-windows-acl-insecure ""))
}
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Реализация;** `check-perms` на Windows проверяет список из RFC-049 п.3; существующий мок вывода (`YGG_MOCK_*` в тестах `:433`, `:472`) перевести на формат `SID|Rights|Type`.

- [ ] **Step 4: Run → PASS; полный прогон → PASS.**

- [ ] **Step 5: Commit** — `fix(doctor): audit Windows ACL by SID instead of localized group names`.

---

### Task 9: Безопасный `doctor --fix` (RFC-047)

**Files:**
- Modify: `src/doctor.nu:58-95`, `:327-406`, заголовочный комментарий `:1-15`
- Modify: `bin/ygg.nu:528-585`
- Test: `tests/test_doctor.nu`

**Interfaces:**
- Produces: `doctor-fix [ygg_home: string, findings: list<record>, --sandbox: string = ""]: nothing -> list<record>`; находка `orphan_link` с полем `owned: bool`; неуправляемые — `severity: "info"`.

- [ ] **Step 1: Написать падающие тесты**

```nu
export def test_doctor_fix_leaves_foreign_dangling_links [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = ($home | path join "sb"); mkdir ($sb | path join ".config")
        let m = ($home | path join "modules" "m"); mkdir $m
        "name = \"m\"\nos = [\"linux\"]\n" | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")
        let foreign = ($sb | path join ".config" "foreign")
        let owned = ($sb | path join ".config" "owned")
        ^ln -s ($home | path dirname | path join "unmounted" "x") $foreign
        ^ln -s ($m | path join "gone.conf") $owned
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let findings = (run-doctor $home --sandbox $sb)
            let f = ($findings | where check == "orphan_link")
            assert equal ($f | where target == $foreign | get 0.owned) false
            assert equal ($f | where target == $foreign | get 0.severity) "info"
            doctor-fix $home $findings --sandbox $sb | ignore
        }
        assert (($foreign | path type) == "symlink")
        assert (not ($owned | path exists -n))
    }
}

export def test_doctor_fix_state_orphan_removes_link_too [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = ($home | path join "sb"); mkdir $sb
        let dest = ($sb | path join "old-link")
        ^ln -s ($home | path join "host.toml") $dest
        "modules = []\n" | save -f ($home | path join "host.toml")
        save-state $home { links: { ($dest): { module: "removed-mod", src: "x" } }, copies: {}, hashes: {}, packages: {} }
        let findings = [{ check: "state_orphan", severity: "warn", target: $dest, detail: "", fix: "" }]
        doctor-fix $home $findings --sandbox $sb | ignore
        assert (not ($dest | path exists -n))
        assert equal ((load-state $home).links | columns) []
    }
}
```

Сигнатуру `run-doctor` (`:278`) сверить по `context_pack src_doctor` и привести вызов в тесте к фактической. CLI-тест: `doctor --fix` при удерживаемой чужой блокировке (payload с `pid: 1`) завершается с ошибкой `Host is locked`.

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Реализация по RFC-047 п.1–5.**

- [ ] **Step 4: Run → PASS; полный прогон → PASS** (`test_doctor_fix_resolves_perms_and_orphan_links` — проверить, что его битая ссылка относится к `owned`).

- [ ] **Step 5: Commit** — `fix(doctor): run --fix under host lock and only remove ygg-owned dangling links`.

---

### Task 10: Системные менеджеры без TTY (RFC-048)

**Files:**
- Modify: `src/pkg.nu:22-55`, `:104-136`, `:167-192`, `:340-400`
- Test: `tests/test_pkg_git.nu`

**Interfaces:**
- Produces: `const SUDO_MGRS = ["pacman", "apt", "dnf", "zypper"]`; `missing-pkgs [mgr: string, pkgs: list<string>]: nothing -> list<string>` (заменяет `missing-native-pkgs`); `pkg-env [mgr: string]: nothing -> record` (переменные п.2).
- Consumes (Task 3 п.5): `sudo-available` в `prune-unused-packages` для `SUDO_MGRS`.

- [ ] **Step 1: Написать падающие тесты**

Существующий механизм принудительного отказа sudo в мок-режиме найти через `rtk rg -n 'sudo' tests/test_pkg_git.nu src/pkg.nu` и переиспользовать; если его нет — добавить переменную `YGG_MOCK_SUDO_FAIL=1`, читаемую `sudo-available`.

```nu
export def test_apt_requires_passwordless_sudo [] {
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        with-env { YGG_MOCK_PKG_LOG: $log, YGG_HOST_OS_OVERRIDE: "ubuntu", YGG_MOCK_SUDO_FAIL: "1" } {
            let res = (install-packages $home { packages: { apt: ["curl"] }, modules: [] })
            assert ("apt" in ($res.failed | each { |f| $f.mgr? | default $f }))
            assert (not ($log | path exists)) "install must not start without sudo"
        }
    }
}

export def test_noninteractive_env_and_timeouts [] {
    assert equal (pkg-env "apt").DEBIAN_FRONTEND "noninteractive"
    assert equal (pkg-env "brew").HOMEBREW_NO_AUTO_UPDATE "1"
    assert equal (pkg-env "brew").NONINTERACTIVE "1"
    assert equal (pkg-env "cargo") {}
}
```

Форму элементов `res.failed` сверить с существующими тестами и поправить выражение в первом assert. `pkg-env` экспортировать (`export def`).

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Реализация по RFC-048 п.1–5.**

- [ ] **Step 4: Run → PASS; полный прогон → PASS.**

- [ ] **Step 5: Commit** — `fix(pkg): precheck sudo and force non-interactive mode for apt, dnf, zypper, brew`.

---

### Task 11: `ref`/`rev`, детерминированный `ygg.lock`, код возврата `update` (RFC-050)

**Files:**
- Modify: `src/git.nu:104-172`, `:198-291`, `:395-491`
- Modify: `bin/ygg.nu:286-330` (не вызывать `generate-ygg-lock` в dry-run — проверить), `:421-442`
- Test: `tests/test_pkg_git.nu`

**Interfaces:**
- Produces: `checkout-module-ref [mod_path: string, ref: string, rev: string]: nothing -> record<status: string, message: string, head: string>`.

- [ ] **Step 1: Написать падающие тесты**

```nu
def make-origin [root: string]: nothing -> record<origin: string, first: string, second: string> {
    let origin = ($root | path join "origin"); mkdir $origin
    let g = { |...a| ^git -C $origin -c user.email=t@t -c user.name=t ...$a | complete | ignore }
    do $g init -q -b main
    "name = \"m\"\nos = [\"linux\"]\n" | save -f ($origin | path join "ygg.toml")
    do $g add -A; do $g commit -q -m one
    let first = (^git -C $origin rev-parse HEAD | str trim)
    "x" | save -f ($origin | path join "f"); do $g add -A; do $g commit -q -m two
    do $g tag v1 $first
    { origin: $origin, first: $first, second: (^git -C $origin rev-parse HEAD | str trim) }
}

export def test_checkout_module_ref_rev_tag_and_dirty [] {
    with-temp-ygg { |home|
        let o = (make-origin $home)
        let clone = ($home | path join "modules" "m")
        mkdir ($home | path join "modules")
        ^git clone -q $o.origin $clone | complete | ignore
        assert equal (checkout-module-ref $clone "" "").status "skipped"
        let r = (checkout-module-ref $clone "" $o.first)
        assert equal $r.status "ok"; assert equal $r.head $o.first
        assert equal (checkout-module-ref $clone "main" "").head $o.second
        assert equal (checkout-module-ref $clone "v1" "").head $o.first
        "dirty" | save -f ($clone | path join "f")
        assert equal (checkout-module-ref $clone "main" "").status "error"
    }
}

export def test_ygg_lock_is_deterministic_and_detects_dirty [] {
    with-temp-ygg { |home|
        let o = (make-origin $home)
        let clone = ($home | path join "modules" "m")
        mkdir ($home | path join "modules")
        ^git clone -q $o.origin $clone | complete | ignore
        let plan = { modules: [{ name: "m", dir: $clone }] }
        generate-ygg-lock $home $plan | ignore
        let lf = ($home | path join "ygg.lock")
        let a = (open --raw $lf); let m1 = (ls $lf | get 0.modified)
        sleep 1100ms
        generate-ygg-lock $home $plan | ignore
        assert equal (open --raw $lf) $a
        assert equal (ls $lf | get 0.modified) $m1
        assert equal (verify-ygg-lock $home $plan) []
        "dirty" | save -f ($clone | path join "f")
        assert ((verify-ygg-lock $home $plan) | any { |e| $e | str contains "uncommitted changes" })
    }
}
```

CLI-тесты: (a) `host.toml` с `rev = <first>` → `ygg update` → `HEAD == first`; (b) расходящиеся правки одного файла в клоне (закоммичены) и в origin → `ygg update` возвращает код 1.

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Реализация по RFC-050 п.1–7.**

- [ ] **Step 4: Run → PASS; полный прогон → PASS.**

- [ ] **Step 5: Commit** — `feat(git): honor ref/rev pins, write deterministic ygg.lock, fail update on conflicts`.

---

## Этап 4.3: Качество (P2–P3)

### Task 12: Устойчивость состояния и GC хэшей (RFC-053)

**Files:**
- Modify: `src/state.nu:38-72`, `:465-521`
- Modify: `src/sdk.nu:77-122` (`onchange`), `:312-320` (`run-module-setup`: `YGG_MODULE_NAME`)
- Modify: `bin/ygg.nu:399-400`, `:470-510` (вызовы GC)
- Test: `tests/test_state.nu`, `tests/test_sdk.nu`

**Interfaces:**
- Produces: `gc-state-hashes [ygg_home: string, active_keys: list<string>, active_modules: list<string>, --dry-run]: nothing -> int`; ключ `onchange` — `setup:<module>:<key>`; `.state/state.json.bak`.

- [ ] **Step 1: Написать падающие тесты**

```nu
export def test_load_state_refuses_corrupted_file [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sf = ($home | path join ".state" "state.json")
        "{broken" | save -f $sf
        let r = (try { load-state $home; "loaded" } catch { |e| $e.msg })
        assert ($r | str contains "Cannot parse")
        assert equal (open --raw $sf) "{broken"
    }
}

export def test_save_state_keeps_bak [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        save-state $home { links: {}, copies: {}, hashes: { a: "1" }, packages: {} }
        save-state $home { links: {}, copies: {}, hashes: { a: "2" }, packages: {} }
        assert equal (open ($home | path join ".state" "state.json.bak")).hashes.a "1"
    }
}

export def test_gc_hashes_by_prefix [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        save-state $home { links: {}, copies: {}, packages: {}, hashes: {
            "pkg:cargo": "h", "pkg:pnpm": "h", "on_change:m:k": "h", "svc:systemd-user:x": "enabled",
            "setup:m:build.v2:x": "h", "setup:gone:k": "h", "legacy-key": "h" } }
        let n = (gc-state-hashes $home ["pkg:cargo"] ["m"])
        assert equal $n 4
        assert equal ((load-state $home).hashes | columns | sort) ["legacy-key", "pkg:cargo", "setup:m:build.v2:x"]
    }
}
```

`tests/test_sdk.nu`, `test_onchange_namespaces_and_migrates_key`: при `YGG_MODULE_NAME=m` и существующем `state.hashes.build` с актуальным хэшем `onchange "build" …` возвращает `false` (не исполняет), после вызова в state есть `setup:m:build`.

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Реализация по RFC-053 п.1–4.** `collect-active-hash-keys`: удалить блок 3 (regex), добавить ключи `svc:*` из `plan.services` (используются в Task 14).

- [ ] **Step 4: Run → PASS; полный прогон → PASS.**

- [ ] **Step 5: Commit** — `fix(state): refuse corrupted state.json and GC hashes by namespace`.

---

### Task 13: Стабильный порядок DAG (RFC-054)

**Files:**
- Modify: `src/manifest.nu:369-414`
- Modify: `docs/specs/2026-11-08-ygg-phase3-resilience-and-ecosystem.md` (RFC-031: правило п.2)
- Test: `tests/test_manifest.nu`

- [ ] **Step 1: Написать падающий тест**

```nu
export def test_dag_sort_is_stable_to_host_order [] {
    let mods = [{ name: "a" }, { name: "b", depends_on: ["c"] }, { name: "c" }, { name: "d" }]
    assert equal (sort-modules-dag $mods | get name) ["a", "c", "b", "d"]
    let plain = [{ name: "z" }, { name: "y" }, { name: "x" }]
    assert equal (sort-modules-dag $plain | get name) ["z", "y", "x"]
    let cyc = [{ name: "a" }, { name: "p", depends_on: ["q"] }, { name: "q", depends_on: ["p"] }]
    let msg = (try { sort-modules-dag $cyc; "" } catch { |e| $e.msg })
    assert ($msg | str contains "p"); assert ($msg | str contains "q")
    assert (not ($msg =~ '\ba\b'))
}
```

- [ ] **Step 2: Run → FAIL** (`[a, c, d, b]`).

- [ ] **Step 3: Реализация:** на каждой итерации брать первый по исходному индексу узел с пустыми `deps`.

- [ ] **Step 4: Run → PASS; полный прогон → PASS.**

- [ ] **Step 5: Commit** — `fix(manifest): keep host.toml order in dependency sort`.

---

### Task 14: Ужесточение `[services]` (RFC-055, RFC-057 п.4)

**Files:**
- Modify: `src/sdk.nu:503-704`
- Modify: `src/link.nu` (`preflight-check` ~`:941`)
- Modify: `bin/ygg.nu:370-392` (сбой сервиса → `$errors`)
- Test: `tests/test_sdk.nu`, `tests/test_link.nu`

**Interfaces:**
- Consumes: `SUDO_MGRS`-проверка (Task 10), префикс `svc:` в GC (Task 12), шаг журнала `services` (Task 6).
- Produces: `const SERVICE_MANAGERS = ["systemd-user", "systemd-system", "launchd", "windows"]`; `run-service-actions` получает `--force`.

- [ ] **Step 1: Написать падающие тесты**

```nu
export def test_service_enable_runs_once_and_triggers_are_exact [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let log = ($home | path join "svc.log")
        let plan = { services: { systemd: { user: {
            enable: ["a.service"], restart_on_change: { "b.service": ["waybar/config"] } } } } }
        with-env { YGG_MOCK_PKG_LOG: $log } {
            run-service-actions $home $plan [] | ignore
            run-service-actions $home $plan [] | ignore
            assert equal (open --raw $log | lines | where { |l| $l | str contains "enable a.service" } | length) 1
            let other = [{ op: "LINK", key: "foot/config", dest: ($home | path join "sb/.config/foot/config"), src: "x" }]
            assert equal (run-service-actions $home $plan $other | where action == "restart") []
            let hit = [{ op: "RELINK", key: "waybar/config", dest: "d", src: "s" }]
            assert equal (run-service-actions $home $plan $hit | where action == "restart" | length) 1
            assert equal (run-service-actions $home $plan [] --force | where action == "enable" | length) 1
        }
    }
}
```

`tests/test_link.nu`: `preflight-check` для плана с `services: { rm: { enable: ["x"] } }` возвращает проблему с `key == "services"`; для `enable: ["a; b"]` — тоже.

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Реализация по RFC-055 п.1–6.**

- [ ] **Step 4: Run → PASS; полный прогон → PASS.**

- [ ] **Step 5: Commit** — `fix(services): whitelist managers, cache enable, match triggers exactly`.

---

### Task 15: `PATH` и валидация имён (RFC-056)

**Files:**
- Modify: `src/env.nu` (генераторы nu/zsh/fish, `aliases.nu`)
- Modify: `src/link.nu` (`preflight-check`)
- Test: `tests/test_env.nu`, `tests/test_link.nu`

- [ ] **Step 1: Написать падающие тесты**

`tests/test_env.nu`, `test_path_entries_reach_all_shells`: модуль с `path = ["~/.local/bin"]`; после `compile-environment … --sandbox $sb` и `let p = ($sb | path join ".local" "bin")`:

```nu
assert (open --raw ($env_dir | path join "env.fish") | str contains $"fish_add_path -g ($p)")
assert (open --raw ($env_dir | path join "env.zsh") | str contains $"path=\(($p) $path\)")
assert (open --raw ($env_dir | path join "env.zsh") | str contains "typeset -U path")
assert ((^nu -c $"source '($env_dir | path join env.nu)'; $env.PATH | first" | complete).stdout | str trim) == $p
```

`tests/test_link.nu`, `test_preflight_rejects_invalid_env_and_alias_names`: план с `env: { "A; rm -rf ~": "x" }` → проблема `key == "env"`; `aliases: { "k x": "y" }` → проблема `key == "aliases"`; `env: { GOOD_1: "x" }`, `aliases: { "g.st-1": "y" }` → проблем нет.

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Реализация по RFC-056 п.1–3.**

- [ ] **Step 4: Run → PASS; полный прогон → PASS.**

- [ ] **Step 5: Commit** — `feat(env): export PATH entries to nu, zsh, fish and validate env/alias names`.

---

### Task 16: Completions из единой таблицы (RFC-052)

**Files:**
- Modify: `bin/ygg.nu:587-972` (пять генераторов), комментарии флагов во всех `def "main …"`
- Test: `tests/test_cli_e2e.nu`

**Interfaces:**
- Produces: `cli-signature-table []` по RFC-052 п.1.

- [ ] **Step 1: Написать падающие тесты**

```nu
export def test_completions_nu_parse_and_match_cli [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let out = ($home | path join "c.nu")
        ^nu $ygg_bin completions nu | save -f $out
        assert equal (^nu -c $"source '($out)'" | complete).exit_code 0
        let apply_flags = (^nu -c $"source '($out)'; scope externs | where name == 'ygg apply' | get 0.signatures | values | flatten | where parameter_type in [switch named] | get parameter_name | to json" | from json)
        for f in ["dry-run", "force", "sandbox", "locked", "prune-packages", "no-lock"] { assert ($f in $apply_flags) $f }
        let add_flags = (^nu -c $"source '($out)'; scope externs | where name == 'ygg add' | get 0.signatures | values | flatten | get parameter_name | to json" | from json)
        assert ("force-system-prune" not-in $add_flags)
    }
}

export def test_completions_other_shells_share_flags [] {
    let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
    for sh in ["zsh", "bash", "fish", "ps1"] {
        let txt = (^nu $ygg_bin completions $sh)
        assert ($txt | str contains "sandbox") $sh
        assert (not ($txt | str contains "older than 7 days")) $sh
    }
}
```

Если `scope externs` в 0.116 отдаёт сигнатуры иначе — заменить выборку флагов на разбор текста `export extern "ygg apply" [ … ]`; утверждения остаются теми же. Тест для `nu-complete ygg-modules`: `host.toml` с двумя `[[modules]]` → функция возвращает `["m1", "m2"]`.

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Реализация по RFC-052 п.1–4.** Добавить комментарий-описание каждому флагу `main *` (тест: в таблице нет пустых `description`).

- [ ] **Step 4: Run → PASS; полный прогон → PASS.**

- [ ] **Step 5: Commit** — `fix(cli): generate all shell completions from the real command signatures`.

---

### Task 17: Мелкие исправления, CI, документы (RFC-057 п.1–3, RFC-051 п.5–7, RFC-058)

**Files:**
- Modify: `bin/ygg.nu:182-198` (`main remove`), `src/doctor.nu:176-190` (`check-tools`), `src/manifest.nu:625` (комментарий)
- Modify: `.github/workflows/ci.yml`
- Modify: `docs/specs/2026-11-08-ygg-phase3-resilience-and-ecosystem.md`, `docs/plans/2026-11-08-ygg-phase3-implementation-plan.md`, `AGENTS.md`
- Test: `tests/test_cli_e2e.nu`, `tests/test_doctor.nu`

- [ ] **Step 1: Тесты.** `test_remove_refuses_real_home_under_sandbox`: повторить сценарий существующего теста `assert-sandbox-home` для `apply` (найти через `rtk rg -n 'assert-sandbox-home|Refusing' tests/`), заменив команду на `remove x`; ожидается та же ошибка. `check-tools`: версия `1.0.0` не даёт находки, `0.115.0` — даёт (вынести сравнение в `export def nu-version-ok [ver: string]: nothing -> bool` и тестировать её).

- [ ] **Step 2: Run → FAIL → реализация → PASS.**

- [ ] **Step 3: CI.** `actions/checkout@v5`; для `nushell/setup-nu` и `extractions/setup-just` выбрать последние major-версии, чьи `action.yml` объявляют `using: node24` (проверить в репозиториях actions; если такой версии нет — оставить текущую и записать это в описание коммита). Purity-шаг — по RFC-051 п.6. Добавить шаг проверки nu-completions по п.7.

- [ ] **Step 4: Документы по RFC-058 п.1–5.** SHA для статусов Фазы 3 взять из `rtk git log --oneline 3eb8cb0^..ac486e8`.

- [ ] **Step 5: Финальная проверка**

Run: `rtk nu tests/run.nu` → `PASS`, 0 failed.
Run: `rtk context-init update` затем `rtk context-init check --compact` → без дрейфа.

- [ ] **Step 6: Commit** — `chore(docs,ci): sync phase 3 docs with implementation and move CI to node24 actions`.

---

## Self-Review (выполнено при составлении)

| RFC | Задача |
| :--- | :--- |
| 041 | 4 |
| 042 | 5 |
| 043 | 6 |
| 044 | 3 |
| 045 | 2 |
| 046 | 7 |
| 047 | 9 |
| 048 | 10 |
| 049 | 5 (п.4), 8 (п.1–3) |
| 050 | 11 |
| 051 | 1 (п.1–4), 17 (п.5–7) |
| 052 | 16 |
| 053 | 12 |
| 054 | 13 |
| 055 | 14 |
| 056 | 15 |
| 057 | 14 (п.4), 17 (п.1–3) |
| 058 | 17 |

Зависимости между задачами: 5 ← 4; 6 ← 5 (`restrict-file-access`); 8, 9 ← 5; 3 п.5 ← 10 (до Task 10 проверка sudo в prune использует существующую `sudo-available` для `pacman`); 14 ← 6, 10, 12. Остальные независимы.

Номера строк в блоках **Files** соответствуют `ac486e8` и сдвигаются по мере выполнения — перед правкой сверять через `rtk rg -n`.
