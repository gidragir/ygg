# Честный итог apply и Windows-исправления — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Закрыть issues #19, #9, #8, #21, #22: `doctor` без ложных `acl_unreadable`, итог `apply` печатается последним и отражает исход, ошибки preflight указывают на манифест, занятые цели на Windows ловятся до первой мутации.

**Architecture:** Четыре независимых PR от `main`. Логика вывода и классификации вынесена в чистые экспортируемые функции (`select-powershell`, `hook-warnings`, `format-apply-summary`, `classify-fs-error`), которые тестируются юнитами. Проба блокировок — отдельная функция `probe-locked-targets`, вызываемая из `apply-plan` и `add` после `preflight-check`; сам `preflight-check` остаётся read-only.

**Tech Stack:** Nushell `>= 0.116`, `std/assert`, раннер `nu tests/run.nu --filter <name>`, `mise run test`.

**Spec:** [docs/specs/2026-11-17-ygg-apply-output-and-windows-fixes-design.md](../../specs/2026-11-17-ygg-apply-output-and-windows-fixes-design.md)

## Global Constraints

- Перед правкой любого `.nu` прочитать навык `.agents/skills/nushell-ygg-dev/SKILL.md`.
- Nushell `>= 0.116`; Linux / Windows Non-Admin / macOS. PowerShell и проба rename — только Windows (`fs-windows`), на Unix no-op; исключение — мок `YGG_MOCK_LOCKED_PATHS`, под которым проба работает на любой ОС.
- ZERO HOST MUTATION: все тесты внутри `with-temp-ygg`, пути только от его `home`, новые ветки управляются моками `YGG_MOCK_*`.
- Статус и предупреждения — в stderr; строка `Applied ...` — в stdout. Правила stderr/TTY/`NO_COLOR` из AGENTS.md §2.1 не нарушаются.
- `doctor`, `diff`, `status`, `--dry-run` не вызывают пробу; `doctor` не использует `run-with-timeout`/`--label`/`--progress`.
- Семантика сбоев не меняется: что обрывает apply сейчас, обрывает и дальше.
- DoD каждого issue: регрессионный тест с комментарием `# regression: #N` и коммит с футером `Fixes #N` (не в заголовке). Каждый коммит заканчивается строкой `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Ветки: `fix/19-doctor-acl-pwsh`, `fix/8-apply-summary`, `fix/21-preflight-module-paths`, `fix/22-locked-targets`, каждая от актуального `main`. `CHANGELOG.md` руками не правится.
- Перед сдачей каждого PR: `mise run test` зелёный и `rtk context-init check --compact` без дрейфа (при новых функциях — `context-init update` и коммит базы в том же PR).

## Review Focus

1. Упавший хук с многострочным stderr: в итоге показывается только первая строка (тест в Task 3, `test_hook_warnings_first_line_and_per_key`).
2. Одна команда хука на несколько ключей упала: предупреждение считается на каждый ключ, `K` = число ключей (тот же тест).
3. Несколько занятых целей: проба сообщает все, а не первую (Task 6, `test_probe_locked_targets_mock`).
4. Записи в `YGG_MOCK_LOCKED_PATHS` с пробелами вокруг и пустыми элементами: обрезаются, пустые игнорируются (тот же тест).
5. `shadowed_files`, когда `t.src` не удаётся сделать относительным к каталогу модуля (модуль-ссылка, другой регистр пути): сообщение строится с откатом на абсолютный `t.src`, без падения (Task 4, `test_preflight_shadowed_files_module_relative`).

---

## PR 1 — #19 (`fix/19-doctor-acl-pwsh`)

### Task 1: `select-powershell` и запуск `Get-Acl` без унаследованного `PSModulePath`

**Files:**
- Modify: `src/doctor.nu:143-160` (`read-windows-acl`), `src/doctor.nu:207` (сообщение `acl_unreadable`)
- Test: `tests/test_doctor.nu`

**Interfaces:**
- Produces: `export def select-powershell [has_pwsh: bool, has_winps: bool]: nothing -> record<bin: string, hide_module_path: bool>`; `read-windows-acl` возвращает `record<ok: bool, out: string, err: string>` (`err` — первая строка stderr PowerShell или `""`).

- [ ] **Step 1: Написать падающий тест**

```nu
# regression: #19
export def test_select_powershell_prefers_pwsh_and_hides_module_path_for_winps [] {
    assert equal (select-powershell true true) { bin: "pwsh", hide_module_path: false }
    assert equal (select-powershell true false) { bin: "pwsh", hide_module_path: false }
    assert equal (select-powershell false true) { bin: "powershell.exe", hide_module_path: true }
    assert equal (select-powershell false false) { bin: "", hide_module_path: false }
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `nu tests/run.nu --filter test_select_powershell`
Expected: FAIL — `select-powershell` не определена.

- [ ] **Step 3: Реализовать**

`select-powershell` — чистая функция по таблице из теста. В `read-windows-acl`: `let sel = (select-powershell (which pwsh | is-not-empty) (which powershell.exe | is-not-empty))`; при `bin == ""` вернуть `{ok: false, out: "", err: "PowerShell not found"}`. Вызов обернуть в `do { if $sel.hide_module_path { hide-env -i PSModulePath }; with-env { YGG_ACL_PATH: $win } { ^($sel.bin) -NoProfile -NonInteractive -Command $script | complete } }`. Мок `YGG_MOCK_WINDOWS_ACL_FAIL` возвращает `err: ""`. В `check-perms` сообщение находки: `"cannot read Windows ACL (PowerShell failed or unavailable)"` + `$": ($r.err)"`, если `err` не пуст.

- [ ] **Step 4: Прогнать тесты**

Run: `nu tests/run.nu --filter test_select_powershell` и `nu tests/run.nu --filter test_doctor_windows_acl`
Expected: PASS (существующий `test_doctor_windows_acl_unreadable_warns` тоже зелёный).

- [ ] **Step 5: Ручная проверка на Windows (этот хост)**

Run (из pwsh 7): `nu -c 'hide-env -i PSModulePath; ^powershell.exe -NoProfile -NonInteractive -Command "(Get-Acl -LiteralPath $env:USERPROFILE).Owner"'`
Expected: exit 0, выведен владелец. Затем `nu bin/ygg.nu doctor --sandbox <tmp>` с временным `YGG_HOME` — ни одной `acl_unreadable`. Если `hide-env` не убирает переменную у дочернего процесса (регистр имени на Windows), остановиться и сообщить, а не подбирать обход.

- [ ] **Step 6: Коммит**

```bash
git switch -c fix/19-doctor-acl-pwsh main
git add src/doctor.nu tests/test_doctor.nu
git commit -m "fix(doctor): read Windows ACL without inherited pwsh PSModulePath" -m "Fixes #19"
```

---

## PR 2 — #9 + #8 (`fix/8-apply-summary`)

### Task 2: `run-with-timeout --soft-fail`, хуки помечаются `[warn]` (#9)

**Files:**
- Modify: `src/pkg.nu:87-92` (сигнатура), `src/pkg.nu:215` (выбор статуса)
- Modify: `src/sdk.nu:503` (вызов из `run-link-hooks`)
- Test: `tests/test_progress.nu`

**Interfaces:**
- Produces: `run-with-timeout [argv timeout_sec --label --no-tty-progress --soft-fail]` — при `--soft-fail` и ненулевом коде (не таймаут) строка завершения `[warn] <label> (Ns)`. Возвращаемый record без изменений.

- [ ] **Step 1: Написать падающий тест** (по образцу `test_run_with_timeout_label_plain_and_no_color`, в дочернем `^nu -I $src_dir`)

```nu
# regression: #9
export def test_run_with_timeout_soft_fail_prints_warn [] {
    let src_dir = if ("src/mod.nu" | path exists) { "src" } else { "../src" }
    let sub = (^nu -I $src_dir -c 'use mod.nu *; with-env { NO_COLOR: "1" } { let r = (run-with-timeout ["nu" "-c" "exit 1"] 10 --label "[hooks] demo" --soft-fail); print $r.exit_code }' | complete)
    assert ($sub.stderr | str contains "[warn] [hooks] demo (")
    assert not ($sub.stderr | str contains "[fail]")
    assert equal ($sub.stdout | str trim) "1"
}
```

- [ ] **Step 2: Убедиться, что падает** — `nu tests/run.nu --filter test_run_with_timeout_soft_fail`, FAIL (неизвестный флаг).
- [ ] **Step 3: Реализовать** флаг; в `run-link-hooks` добавить `--soft-fail` к вызову `run-with-timeout`. Строка `[ygg] Warning: on_change for ...` остаётся.
- [ ] **Step 4: Прогнать** `nu tests/run.nu --filter test_run_with_timeout` и `--filter test_run_link_hooks` — PASS.
- [ ] **Step 5: Коммит**

```bash
git switch -c fix/8-apply-summary main
git add src/pkg.nu src/sdk.nu tests/test_progress.nu
git commit -m "fix(hooks): mark failed on_change hooks as [warn]" -m "Fixes #9"
```

### Task 3: итог apply последним, с подсчётом предупреждений и next steps (#8)

**Files:**
- Modify: `src/progress.nu` (две новые функции)
- Modify: `bin/ygg.nu:354-369` (флаг `--added-module`), `bin/ygg.nu:206` (передача из `add`), `bin/ygg.nu:524-595` (сбор хуков и перенос итога)
- Test: `tests/test_progress.nu`, `tests/test_cli_e2e.nu`

**Interfaces:**
- Consumes: результат `run-link-hooks` — `list<record<module: string, keys: list<string>, cmd: string, status: string, stderr: string>>`.
- Produces:
  - `export def hook-warnings [hooks: list<record>]: nothing -> list<record<source: string, module: string, item: string, message: string>>` — по записи на каждый ключ каждого хука со `status == "failed"`; `source: "on_change"`, `item: <key>`, `message: <первая строка stderr>`.
  - `export def format-apply-summary [mod_count: int, warnings: list<record>, --added-module: string = ""]: nothing -> record<stdout: string, stderr: string>`.
  - `apply-plan ... --added-module: string = ""`.

Точный текст итога (спека §5.2):
- без предупреждений: `stdout = "Applied N module(s)."`, `stderr = ""`;
- с предупреждениями: `stdout = "Applied N module(s) with K warning(s)."`, `stderr`:

```text
[ygg] Warnings:
  - <source> '<item>' (<module>): <message>
[ygg] Next: `ygg apply` re-runs failed hooks · `ygg doctor` to diagnose · `ygg remove <module>` to roll back
```

сегмент ` · \`ygg remove <added_module>\` to roll back` — только при непустом `--added-module`.

- [ ] **Step 1: Написать падающие юнит-тесты**

```nu
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
```

- [ ] **Step 2: Написать падающие e2e** в `tests/test_cli_e2e.nu` (модуль `hm` с `[links."cfg/a.conf"] target = "~/.config/hm/a.conf", on_change = "reload-a"`, `YGG_HOME`, `YGG_SANDBOX`, `YGG_MOCK_PKG_LOG = $home/pkg.log`, `YGG_MOCK_HOOK_FAIL = "reload-a"`):

```nu
# regression: #8
export def test_apply_summary_is_last_and_counts_hook_warnings [] {
    # ygg add <mod_src>, stdout и stderr слиты: ^nu $ygg_bin add $mod_src o+e>| complete
    # assert exit_code == 0
    # let out = ($res.stdout | lines)
    # let i_fin = индекс строки, содержащей "[finalize]"
    # let i_app = индекс строки == "Applied 1 module(s) with 1 warning(s)."
    # assert $i_fin < $i_app
    # assert (вывод содержит "  - on_change 'cfg/a.conf' (hm): mock hook failure")
    # assert (вывод содержит "`ygg remove hm` to roll back")
    # затем ^nu $ygg_bin apply | complete:
    # assert (($res2.stdout | lines | last) == "Applied 1 module(s) with 1 warning(s).")   # хук перезапущен
    # assert not ($res2.stderr | str contains "ygg remove")
}

export def test_apply_link_error_prints_no_applied [] {
    # тот же модуль без on_change; в песочнице $sb/.config — обычный файл, mkdir родителя цели падает
    # ^nu $ygg_bin apply --sandbox $sb | complete
    # assert exit_code != 0
    # assert ($res.stderr | str contains "[ygg] Error: failed to link")
    # assert not ($res.stdout | str contains "Applied")
}
```

- [ ] **Step 3: Убедиться, что падают** — `nu tests/run.nu --filter test_hook_warnings`, `--filter test_format_apply_summary`, `--filter test_apply_summary_is_last`, `--filter test_apply_link_error_prints_no_applied`: FAIL.
- [ ] **Step 4: Реализовать** функции в `src/progress.nu`; в `apply-plan`: `let hooks = (run-link-hooks ...)` вместо `| ignore`; удалить `print $"Applied ..."` со строки 549; после `commit-journal-transaction`: `progress-clear-line`, `let s = (format-apply-summary $mod_count (hook-warnings $hooks) --added-module $added_module)`, `print $s.stdout`, при непустом `$s.stderr` — `print -e $s.stderr`. В `add` передать `--added-module $add_res.name`; `apply`/`update` не передают.
- [ ] **Step 5: Прогнать** четыре теста из Step 3 и `nu tests/run.nu --filter test_cli` — PASS.
- [ ] **Step 6: Коммит**

```bash
git add src/progress.nu bin/ygg.nu tests/test_progress.nu tests/test_cli_e2e.nu
git commit -m "fix(cli): print apply summary last with warning count and next steps" -m "Fixes #8"
```

---

## PR 3 — #21 (`fix/21-preflight-module-paths`)

### Task 4: сообщения preflight относительно модуля

**Files:**
- Modify: `src/link.nu:982-1004` (`missing_source`, `invalid_mode_source`), `src/link.nu:1033-1062` (`shadowed_files`)
- Test: `tests/test_cli_e2e.nu`

**Interfaces:**
- Consumes: запись плана `{module, key, src_rel, src_path, dest_raw, mode}`; `plan.modules[].dir`.
- Produces: тексты `detail` (формат `format-preflight-errors` не меняется).

Решения:
- `base_rel` вычисляется в preflight: `$link.src_rel | str replace --regex '/\*$' ''` (поле в план не добавляется).
- git-модуль: `($mod.dir | path join ".git" | path exists)` по `plan.modules` с тем же `name`; модуль не найден → не git.
- `missing_source`: `source '<base_rel>' not found in module (links: '<key>' -> '<dest_raw>')`, для git-модуля + `; check that it is committed and pushed to the module's git repo`.
- `invalid_mode_source`: `mode = "dir" requires a directory source, but '<base_rel>' in module is a <type>`.
- `shadowed_files`: `'($t.src)'` → `<module>/<rel>`, где `rel = (try { $t.src | path relative-to $mod.dir } catch { null })`; при `null` — прежний абсолютный `t.src`. `dest` остаётся абсолютным.

- [ ] **Step 1: Написать падающие тесты** (рядом с `test_preflight_blocks_missing_link_source_before_packages`, той же фикстурой)

```nu
# regression: #21
export def test_preflight_missing_source_points_to_manifest [] {
    # фикстура bad-mod из соседнего теста; ^nu $ygg_bin apply --force --sandbox $sb | complete
    # assert ($res.stderr | str contains "source 'configs/ollama' not found in module (links: 'configs/ollama' -> '~/.config/ollama')")
    # assert not ($res.stderr | str contains ($home | path join "modules" "bad-mod"))
    # assert not ($res.stderr | str contains $mod_src)
    # assert not ($res.stderr | str contains "committed and pushed")
    # затем mkdir ($mod_src | path join ".git"), повторный apply:
    # assert ($res2.stderr | str contains "committed and pushed")
}

export def test_preflight_shadowed_files_module_relative [] {
    # модуль m с каталогом cfg/app (один файл) -> "~/.config/app"; в $sb/.config/app лежит лишний файл
    # ^nu $ygg_bin apply --sandbox $sb | complete  (без --force)
    # assert ($res.stderr | str contains "(shadowed_files)")
    # assert ($res.stderr | str contains "not present in 'm/cfg/app'")
}
```

- [ ] **Step 2: Убедиться, что падают** — `nu tests/run.nu --filter test_preflight_` : новые FAIL, старый PASS.
- [ ] **Step 3: Реализовать** по решениям выше.
- [ ] **Step 4: Прогнать** `nu tests/run.nu --filter preflight` и `nu tests/run.nu --filter test_link` — PASS (найти и обновить существующие ассерты на старый текст `Source path '...' does not exist`, если есть).
- [ ] **Step 5: Коммит**

```bash
git switch -c fix/21-preflight-module-paths main
git add src/link.nu tests/
git commit -m "fix(link): report preflight problems relative to the module manifest" -m "Fixes #21"
```

---

## PR 4 — #22 (`fix/22-locked-targets`)

### Task 5: `classify-fs-error` и подсказка в сбоях линков

**Files:**
- Modify: `src/link.nu` (новая функция рядом с `apply-links`; места записи `$failed` на строках 617, 668, 722, 748)
- Test: `tests/test_link.nu`

**Interfaces:**
- Produces: `export def classify-fs-error [msg: string, --dir-target]: nothing -> record<kind: string, hint: string>` — `kind: "locked" | "other"`; при `locked` `hint = "is in use by another process — close it and re-run ygg apply"`, иначе `""`. `locked`: `os error 32`, `os error 33`, `being used by another process` (без учёта регистра); `os error 5` — только с `--dir-target`.

В `apply-links` перед операцией над целью запомнить `let dir_target = $is_windows and (($dest | path type) == "dir") and not (is-link-or-junction $dest)`; при записи в `$failed` и `kind == "locked"` к `stderr` дописать `"\n    '<dest>' <hint>"`.

- [ ] **Step 1: Написать падающий тест**

```nu
# regression: #22
export def test_classify_fs_error_locked_samples [] {
    assert equal (classify-fs-error "The process cannot access the file because it is being used by another process. (os error 32)").kind "locked"
    assert equal (classify-fs-error "lock violation (os error 33)").kind "locked"
    assert equal (classify-fs-error "Access is denied. (os error 5)").kind "other"
    assert equal (classify-fs-error "Access is denied. (os error 5)" --dir-target).kind "locked"
    assert equal (classify-fs-error "No such file or directory (os error 2)") { kind: "other", hint: "" }
    assert ((classify-fs-error "(os error 32)").hint | str contains "re-run ygg apply")
}
```

- [ ] **Step 2: Убедиться, что падает** — `nu tests/run.nu --filter test_classify_fs_error`, FAIL.
- [ ] **Step 3: Реализовать** функцию и дописывание подсказки в `apply-links`.
- [ ] **Step 4: Прогнать** `nu tests/run.nu --filter test_classify_fs_error` и `--filter test_link` — PASS.
- [ ] **Step 5: Коммит** (без `Fixes`, issue закрывает Task 6)

```bash
git switch -c fix/22-locked-targets main
git add src/link.nu tests/test_link.nu
git commit -m "fix(link): explain locked targets in link failures" -m "Refs #22"
```

### Task 6: `probe-locked-targets` до первой мутации

**Files:**
- Modify: `src/link.nu` (новая функция)
- Modify: `bin/ygg.nu:405-407` (`apply-plan`, после проверки `$problems`), `bin/ygg.nu:193-196` (`add`, после своего preflight, внутри того же `try`)
- Test: `tests/test_link.nu`, `tests/test_cli_e2e.nu`

**Interfaces:**
- Consumes: `ops` из `compute-link-ops` (поля `op`, `dest`, `module`, `key`), `normalize-case`, `is-link-or-junction`, `fs-windows`, `format-preflight-errors`.
- Produces: `export def probe-locked-targets [ops: table]: nothing -> list<record<module: string, key: string, reason: string, detail: string>>`.

Поведение:
- Кандидаты: `op == "BACKUP_REPLACE"` и `dest` — реальный файл/каталог (`path type` в `["file", "dir"]` и не `is-link-or-junction`).
- `YGG_MOCK_LOCKED_PATHS` непуст → ни одного `mv`; список через запятую, элементы `str trim`, пустые отброшены, сравнение `normalize-case`; совпавшие кандидаты → проблема. Работает на любой ОС.
- Иначе, если не `fs-windows` → `[]`.
- Иначе для каждого кандидата: `let probe = $"($dest).ygg-probe-(random chars --length 8)"`; `mv $dest $probe` упал → проблема; успех → `mv $probe $dest`, при сбое — `error make` с текстом `lock probe: '<dest>' is now at '<probe>' and could not be moved back (<err>); restore it manually: move "<probe>" "<dest>"`.
- Проблема: `{module, key, reason: "target_locked", detail: "'<dest>' is in use by another process (<первая строка ошибки mv>) — close the program using it and re-run ygg apply"}`; под моком `(<...>)` = `(mock)`.
- Вызовы: в `apply-plan` только при `not $dry_run`; в `add` — до `register-staged-module` (ветка `--dry-run` в `add` выходит раньше). Непустой результат → `error make { msg: (format-preflight-errors $locked) }` (в `add` — через существующий `catch` с `discard-staged-module`).

- [ ] **Step 1: Написать падающие юнит-тесты**

```nu
# regression: #22
export def test_probe_locked_targets_mock [] {
    with-temp-ygg { |home|
        let a = ($home | path join "a"); mkdir $a
        let b = ($home | path join "b.txt"); "x" | save -f $b
        let c = ($home | path join "c"); mkdir $c
        let ops = [
            { op: "BACKUP_REPLACE", dest: $a, module: "m", key: "ka" }
            { op: "BACKUP_REPLACE", dest: $b, module: "m", key: "kb" }
            { op: "BACKUP_REPLACE", dest: $c, module: "m", key: "kc" }
            { op: "LINK", dest: ($home | path join "none"), module: "m", key: "kn" }
        ]
        let res = (with-env { YGG_MOCK_LOCKED_PATHS: $" ($a) ,,($b),($home | path join 'none')" } { probe-locked-targets $ops })
        assert equal ($res | get key | sort) ["ka", "kb"]
        assert ($res | all { |p| $p.reason == "target_locked" })
        assert ($a | path exists) and ($b | path exists)
        assert (ls $home | where name =~ 'ygg-probe' | is-empty)
    }
}

export def test_probe_locked_targets_real_rename_restores [] {
    with-temp-ygg { |home|
        let d = ($home | path join "d"); mkdir $d; "keep" | save -f ($d | path join "f.txt")
        let res = (with-env { YGG_HOST_OS_OVERRIDE: "windows" } { probe-locked-targets [{ op: "BACKUP_REPLACE", dest: $d, module: "m", key: "k" }] })
        assert equal $res []
        assert equal (open --raw ($d | path join "f.txt")) "keep"
        assert (ls $home | where name =~ 'ygg-probe' | is-empty)
    }
}
```

- [ ] **Step 2: Написать падающие e2e** в `tests/test_cli_e2e.nu` (модуль с `[packages] pacman = ["curl"]` и каталогом `cfg/app` -> `~/.config/app`; в `$sb/.config/app/host.txt` лежит `host_state`; `YGG_HOST_OS_OVERRIDE: "cachyos"`, `YGG_MOCK_PKG_LOG`, `YGG_MOCK_LOCKED_PATHS = ($sb | path join ".config" "app")`):

```nu
# regression: #22
export def test_apply_locked_target_aborts_before_mutations [] {
    # ^nu $ygg_bin apply --force --sandbox $sb | complete
    # assert exit_code != 0; stderr содержит "(target_locked)" и "re-run ygg apply"
    # assert not ($pkg_log | path exists)
    # assert equal (open --raw ($sb | path join ".config" "app" "host.txt")) "host_state"
    # ^nu $ygg_bin apply --force --dry-run --sandbox $sb | complete
    # assert exit_code == 0; not (stderr содержит "target_locked")
}

export def test_add_locked_target_does_not_register_module [] {
    # тот же модуль вне modules/, ^nu $ygg_bin add $mod_src --force | complete
    # assert exit_code != 0; stderr содержит "(target_locked)"
    # assert not (host.toml существует и содержит имя модуля)
    # assert not ($pkg_log | path exists)
}
```

- [ ] **Step 3: Убедиться, что падают** — `nu tests/run.nu --filter probe_locked`, `--filter locked_target`: FAIL.
- [ ] **Step 4: Реализовать** функцию и оба вызова.
- [ ] **Step 5: Прогнать** `nu tests/run.nu --filter locked`, затем `mise run test` — PASS.
- [ ] **Step 6: Коммит**

```bash
git add src/link.nu bin/ygg.nu tests/test_link.nu tests/test_cli_e2e.nu
git commit -m "fix(link): probe Windows targets for locks before mutating the host" -m "Fixes #22"
```

---

## Порядок и сдача

1. Task 1 → PR 1. 2. Task 2, Task 3 → PR 2. 3. Task 4 → PR 3. 4. Task 5, Task 6 → PR 4.

Push и создание PR — после подтверждения пользователя; описание PR заканчивается строкой `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
