# Ygg Phase 2 — Engine Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Устранить дефекты движка `ygg` и слепые зоны Stage 2 из финального ревью Фазы 2, чтобы затем чинить модули на надёжном основании.

**Architecture:** Точечные правки `src/*.nu` и `bin/ygg.nu` без изменения структуры модулей; каждая находка закрепляется тестом Этапа 1 в `tests/test_*.nu`. Последней задачей `tests/test_phase2_modules.nu` усиливается так, чтобы ловить исправленные классы дефектов на реальных модулях. На Windows код не запускается: файлы на Windows теперь копируются реально и под `YGG_HOST_OS_OVERRIDE=windows`, поэтому логика копий проверяется на Linux.

**Tech Stack:** Nushell 0.116+, TOML, `just`, `rtk`.

**Spec:** `docs/specs/2026-11-07-modular-omni-architecture-design.md` (разделы 5.4, 5.5, 5.6, 6). Спецификация приоритетнее плана. Находки: `.superpowers/sdd/2026-11-08-ygg-phase2-modules-migration/final-review.md` (ID ниже — оттуда).

**Покрытие:** C1, C2, I1, I18 (часть `sdk.nu:91`), I34, I38, I42, I46 (движок), I47–I53, M27, M43, M45–M48, M52, M54 и новая находка о потере правок при prune копий.

**Вне плана:**
- I2 (`YGG_HOME` в nu) и I3 (XDG): ждут решения пользователя (вопросы 1–2 отчёта).
- Все находки модулей, включая `ai-dotfiles` `.no-bundled-skills` и `config.env`. Это следующий план.
- M20 (сборка модулей через `git archive`): упадёт на незакоммиченном `config.env`, включать после починки модулей.
- M44, M49–M51, M53, M55–M57: низкий приоритет, не блокируют Этап 3.

## Global Constraints

- Ветка `fix/ygg-engine-phase2` от `main` в `/data/projects/ygg`. Не сливать в `main` и не пушить.
- Запрещено менять файлы, ветки и индекс в `/data/projects/{omni-dotfiles,dotfiles,ai-dotfiles,win-dotfiles}` и в `/data/projects/worktree/ygg-phase2/*`; из worktrees только чтение и запуск harness.
- Любой запуск `ygg` и тестов: `HOME`, `YGG_HOME`, `YGG_SANDBOX`, `YGG_MOCK_PKG_LOG` в `/tmp/...`. Реальные `~/.ygg`, `~/.config`, `~/.hermes`, `~/.gemini`, `~/.claude`, сервисы не трогать.
- Все команды с префиксом `rtk`; `rtk fd`, `rtk rg` (без `-E`), без GNU `find`/`grep`.
- Идиомы `.agents/skills/nushell-ygg-dev/SKILL.md`: `get -o`, `where { |it| }`, `| complete`, конкатенация через `+` для строк с `[`.
- В `src/` и `bin/` нет имён пользовательских модулей.
- `unlink`/`prune` удаляют только ссылку; заменяемые файлы уходят в `$YGG_HOME/.state/backups/<timestamp>/`.
- Windows: без админ-прав и Developer Mode.
- Коммиты: `<type>(<scope>): <subject>` на английском, одна строка. `Makefile` не создавать.

Запуск тестов одного имени: `rtk nu tests/run.nu --filter <имя>` из корня `ygg`; весь набор: `rtk just test`.

## Review Focus

1. Правка копии на хосте, удалённой из модуля или ставшей неактивной при смене скоупа: правка не должна исчезнуть, файл уходит в backups (Task 3).
2. Ссылка копии сменила тип: файл в модуле стал каталогом (`file → dir`): старая копия уходит в backups, создаётся Junction (Task 3).
3. Пустой, отсутствующий или битый `host.toml` при непустом `state.links`: ссылки не снимаются без `--force` (Task 1).
4. `ygg add` при битом `host.toml`: ошибка, файл не перезаписан (Task 1).
5. `merge-json` при JSON-массиве в цели и при битом симлинке: первое — ошибка без изменения файла, второе — физический файл из фрагмента (Task 6).

---

### Task 1: Защита от снятия всех ссылок при битом `host.toml` (I52)

**Files:**
- Modify: `src/manifest.nu:7-22`, `bin/ygg.nu:107-138`
- Test: `tests/test_manifest.nu`, `tests/test_cli_e2e.nu`

**Interfaces:**
- Produces: `load-host-config` бросает ошибку на нечитаемом `host.toml`; отсутствующий файл по-прежнему даёт `{modules: []}` (закреплено `test_load_and_save_host_config`).

- [ ] **Step 1: Написать падающие тесты.** В `test_manifest.nu`:

```nushell
export def test_load_host_config_rejects_broken_toml [] {
    with-temp-ygg { |home|
        "[[modules\nname = bad\n" | save -f ($home | path join "host.toml")
        let failed = (try { load-host-config $home; false } catch { true })
        assert $failed
    }
}
```

В `test_cli_e2e.nu` тест `test_apply_refuses_prune_all_without_force`: через `^nu $ygg_bin apply --sandbox $sb | complete` применить модуль с одной ссылкой, затем проверить три случая:
- битый `host.toml` → `exit_code != 0`, ссылка на месте, `state.links` не изменён;
- `modules = []` → `exit_code != 0`, ссылка на месте, в `stderr` есть `--force`;
- `modules = []` + `apply --force` → `exit_code == 0`, ссылка снята.

И тест `test_add_does_not_overwrite_broken_host_toml`: `^nu $ygg_bin add <путь модуля>` при битом файле → `exit_code != 0`, байты `host.toml` прежние.

- [ ] **Step 2: Запустить, убедиться в падении.** `rtk nu tests/run.nu --filter host_config`, `--filter prune_all`, `--filter broken_host`. Ожидается FAIL.

- [ ] **Step 3: Реализовать.**
  - `load-host-config`: в `catch` — `error make { msg: $"Cannot parse ($host_file): ... Refusing to continue." }` с текстом исходной ошибки.
  - `main apply`: сразу после `resolve-effective-plan`: если план без модулей, `state.links` не пуст и нет `--force` — `error make` с подсказкой про `--force`. Проверка до установки пакетов и до любых записей. Нужен `load-state`.

- [ ] **Step 4: Запустить тесты.** `rtk just test`. Ожидается PASS. `ygg remove` последнего модуля не затронут: `unlink-module` очищает state до `apply`.

- [ ] **Step 5: Коммит.** `fix(manifest): refuse to prune all links on unreadable or empty host config`

---

### Task 2: Запрет `--sandbox` без `YGG_HOME` (I42)

**Files:**
- Modify: `src/state.nu`, `bin/ygg.nu:67-73,107-113,157-159`
- Modify: `docs/specs/2026-11-07-modular-omni-architecture-design.md:298`
- Test: `tests/test_cli_e2e.nu`

**Interfaces:**
- Produces: `export def assert-sandbox-home [sandbox: string]: nothing -> nothing` в `state.nu`.

- [ ] **Step 1: Написать падающий тест** `test_sandbox_without_ygg_home_is_refused`. Запуск строго с `HOME` во временном каталоге, чтобы регрессия не могла задеть реальный `~/.ygg`:

```nushell
let res = (with-env { HOME: $fake_home, YGG_HOME: "", YGG_SANDBOX: $sb } { ^nu $ygg_bin apply --sandbox $sb | complete })
assert ($res.exit_code != 0)
assert ($res.stderr | str contains "YGG_HOME")
assert (not (($fake_home | path join ".ygg") | path exists))
```

- [ ] **Step 2: Убедиться в падении.** `rtk nu tests/run.nu --filter sandbox_without`.

- [ ] **Step 3: Реализовать.** `assert-sandbox-home`: если sandbox непустой и `$env.YGG_HOME` пуст — `error make`. Вызывать первой строкой в `main apply`, `main add`, `main save` с эффективным sandbox (аргумент или `$env.YGG_SANDBOX`), до `ensure-ygg-dirs`.

- [ ] **Step 4: Обновить спеку.** В заголовке этапа 2 (строка 298) вместо `--sandbox /tmp/preview` указать `YGG_HOME=/tmp/preview/.ygg ygg apply --sandbox /tmp/preview`.

- [ ] **Step 5: Запустить `rtk just test`.** Ожидается PASS.

- [ ] **Step 6: Коммит.** `fix(cli): require explicit YGG_HOME when running under sandbox`

---

### Task 3: Копии файлов на Windows: глоб, повтор `apply`, prune (C1, C2, Review Focus 1–2)

**Files:**
- Modify: `src/link.nu`
- Test: `tests/test_link.nu`

**Interfaces:**
- Produces (приватные в `link.nu`):
  - `def write-cmd-shim [dest: string]: nothing -> string` — создаёт шим для `.nu`/`.ps1` в каталоге `bin`, возвращает путь или `""`; заменяет дублирующийся код строк 268–279 и 351–362.
  - `def prune-copy [ygg_home: string, dest: string, last_synced_hash: string]: nothing -> nothing` — работает только при `($dest | path type) == "file"`: удаляет копию, если её хеш равен `last_synced_hash`, иначе `backup-existing`. Ссылку, Junction, каталог и отсутствующий путь не трогает.
  - `def prepare-dest [state: record, ygg_home: string, dest: string, keeps_copy: bool, force: bool]: nothing -> nothing` — ссылку снимает; обычный файл оставляет только при `keeps_copy and not force` и наличии `dest` в `state.copies`; иначе `backup-existing`.

- [ ] **Step 1: Написать падающие тесты.** Все под `with-env { YGG_HOST_OS_OVERRIDE: "windows" }`, через `apply-links $home (resolve-effective-plan $home) --sandbox $sb`.

```nushell
export def test_windows_glob_file_copies_survive_repeated_apply [] {
    # "cfg/*" = "~/.config/app/*", файл cfg/a.yaml = "v1", два apply
    assert equal ($target | path type) "file"
    assert equal (open --raw $target) "v1"
    assert ($target in (open $state_json).copies)
}

export def test_windows_single_file_link_survives_repeated_apply [] {
    # "app.toml" = "~/.config/app.toml", три apply подряд без ошибок
    assert equal (open --raw $target) "v1"
    assert (glob ($home | path join ".state" "backups" "**" "app.toml") | is-empty)
}

export def test_windows_copy_three_way_for_link_and_glob [] {
    # для обоих видов ссылок (одиночная и "cfg/*"):
    # правка хоста → apply → модуль обновлён
    # правка модуля → apply → хост обновлён
    # обе стороны разные → apply → хост и модуль без изменений
    # затем --force → хост = модуль, прежняя версия хоста в backups
}

export def test_windows_stale_copy_with_host_edit_goes_to_backups [] {
    # глоб-файл; правка на хосте; файл удалён из модуля; apply
    assert (not ($target | path exists))
    assert equal (glob ($home | path join ".state" "backups" "**" "a.yaml") | length) 1
}

export def test_windows_stale_unedited_copy_is_removed_without_backup [] {
    assert (not ($target | path exists))
    assert (glob ($home | path join ".state" "backups" "**" "a.yaml") | is-empty)
}

export def test_windows_copy_turned_directory_is_backed_up [] {
    # "item" = "~/.config/item": сначала файл, затем каталог; второй apply без ошибки
    assert equal ($target | path type) "symlink"   # Junction на настоящей Windows
    assert equal (glob ($home | path join ".state" "backups" "**" "item") | length) 1
}
```

- [ ] **Step 2: Убедиться в падении.** `rtk nu tests/run.nu --filter test_windows_`. Ожидается FAIL; C2 падает с `io::not_found`.

- [ ] **Step 3: Реализовать.**
  - Глоб-ветка, файлы при `$is_windows`: убрать `cp -f`/`ln -sfn` (строки 281–285) и вычисление хеша (305–311), вызывать `sync-single-file`, как в одиночной ветке (строки 364–369), и добавлять цель в `$active_copies`. Проверка `$nu.os-info.family` для файлов исчезает: копия реальна и под override. Для каталогов остаётся как есть.
  - Обе ветки: заменить снятие ссылки и бэкап на `prepare-dest`, `keeps_copy` равен `$is_windows and not <источник-каталог>`.
  - Prune (строки 435–437, 453–455) и `unlink-module` (551–553): удалять копии через `prune-copy` с `last_synced_hash` из `state.copies`.
  - Сообщения о конфликте (366, 419): добавить `Run 'ygg apply --force' to take the module version or 'ygg save --force' to keep the host version.`

- [ ] **Step 4: Запустить `rtk just test`.** Ожидается PASS, включая `test_windows_cmd_shim_generation_and_cleanup` и `test_three_way_copy_sync_preserves_host_gui_edits`.

- [ ] **Step 5: Коммит.** `fix(link): keep Windows file copies across applies and back up edited stale copies`

---

### Task 4: `ygg save` не затирает модуль при конфликте без baseline (I46, часть движка)

**Files:**
- Modify: `src/link.nu:473-500`, `bin/ygg.nu:157-165`
- Test: `tests/test_link.nu`

**Interfaces:**
- Consumes: сообщение о конфликте из Task 3 ссылается на `ygg save --force`.
- Produces: `save-copied-files [ygg_home, plan, --sandbox: string = "", --force]`; `ygg save [--sandbox] [--force]`.

- [ ] **Step 1: Написать падающий тест** `test_save_skips_conflict_without_baseline`: `[save]`-файл, хост и модуль различаются, `apply` без `--force` (`last_synced_hash == ""`).

```nushell
let saved = (save-copied-files $home $plan)
assert equal $saved []
assert equal (open --raw $repo_file) $module_content
let forced = (save-copied-files $home $plan --force)
assert equal (open --raw $repo_file) $host_content
```

- [ ] **Step 2: Убедиться в падении.** `rtk nu tests/run.nu --filter save_skips`.

- [ ] **Step 3: Реализовать.** В цикле по `state.copies`: при пустом `last_synced_hash` и без `--force` — предупреждение в stderr с именем файла и `continue`. Цикл по `plan.save` не трогать: он обрабатывает только записи, ещё не отслеживаемые. `test_save_copied_files` остаётся зелёным: там baseline есть.

- [ ] **Step 4: Запустить `rtk just test`.** Ожидается PASS.

- [ ] **Step 5: Коммит.** `fix(link): skip baseline-less conflicts in ygg save unless forced`

---

### Task 5: Пакетный драйвер: коды выхода, mock в sandbox, `mise` (I53, I1, основа для I50 и M52)

**Files:**
- Modify: `src/pkg.nu`, `bin/ygg.nu:123-137`
- Test: `tests/test_pkg_git.nu`, `tests/test_cli_e2e.nu`

**Interfaces:**
- Produces: `install-packages` возвращает `record<executed: list<string>, failed: list<record<mgr: string, stderr: string>>>`.
- Produces: `YGG_MOCK_PKG_FAIL` — список менеджеров через запятую, которые в mock-режиме считаются упавшими. Только для тестов.
- Produces: mock-режим работает и под sandbox; без mock под sandbox пакеты не трогаются.

Проверено: `mise use --path ~/.config/mise/config.local.toml` пишет в этот файл, а `mise config ls` его загружает. Шаблон `*.local.*` в `.gitignore` `omni-dotfiles` его покрывает.

- [ ] **Step 1: Написать падающие тесты и обновить существующие.**
  - `test_mock_pkg_sandbox_skips_installation` переименовать в `test_sandbox_without_mock_skips_installation`: без `YGG_MOCK_PKG_LOG` под sandbox `res.executed == []`.
  - `test_mock_pkg_runs_under_sandbox`: `--sandbox` + mock → лог содержит `pacman`.
  - `test_mock_pkg_dry_run_returns_cmds_without_logging`: читать `$res.executed`.
  - `test_pkg_failure_is_reported`: `YGG_MOCK_PKG_FAIL: "pacman"` → `res.failed.0.mgr == "pacman"`, остальные менеджеры в логе есть.
  - `test_mise_writes_local_config`:

```nushell
assert ($lines | str contains "mise use --path ~/.config/mise/config.local.toml ripgrep")
assert (not ($lines | str contains "mise use -g"))
```

  - В `test_cli_e2e.nu` `test_apply_fails_after_completing_when_package_manager_fails`: `YGG_MOCK_PKG_FAIL` + модуль со ссылкой → `exit_code != 0`, `stderr` содержит имя менеджера, ссылка создана.

- [ ] **Step 2: Убедиться в падении.** `rtk nu tests/run.nu --filter pkg`, `--filter mise_writes`, `--filter apply_fails`.

- [ ] **Step 3: Реализовать.**
  - Ранний выход: `if ($env.YGG_MOCK_PKG_LOG? == null) and (($sandbox != "") or ($env_sb != ""))`, возвращает `{executed: [], failed: []}`.
  - При ошибке менеджера: печать и добавление в `failed`, цикл продолжается.
  - `main apply`: сохранить результат, выполнить все шаги, в конце при непустом `failed` — `error make` с перечнем менеджеров. Сводка `Applied N module(s).` печатается до этого.

- [ ] **Step 4: Запустить `rtk just test`.** Ожидается PASS.

- [ ] **Step 5: Коммит.** `fix(pkg): report package manager failures and keep mise state out of tracked config`

---

### Task 6: SDK: транзакционность `onchange`, безопасный `merge-json`, формат `.env` (I18, I34, M27, Review Focus 5)

**Files:**
- Modify: `src/sdk.nu:91,133-154,195-200`, `.agents/skills/nushell-ygg-dev/SKILL.md:85`
- Test: `tests/test_sdk.nu`

**Interfaces:**
- Produces: `.env` от `export-secrets` в формате `KEY='value'`, где `\` → `\\`, `'` → `\'`.

Проверено на nu 0.116.1: `do $b | ignore` не падает на `{ ^false }`, отдельный оператор `do $b` падает; вывод внешней команды виден. Проверено на python-dotenv из `/opt/hermes-agent/venv`: одинарные кавычки сохраняют `$$`, разбирают `\'` и `\\`, а `\$` в двойных кавычках оставляет лишний `\`. Ограничение: `${VAR}` интерполируется и в одинарных кавычках; для секретов с такой подстрокой отметить в комментарии над функцией.

- [ ] **Step 1: Написать падающие тесты.**

```nushell
export def test_onchange_external_failure_does_not_record_hash [] {
    let failed = (try { onchange "k" ["cfg.yaml"] { ^false }; false } catch { true })
    assert $failed
    let r = (onchange "k" ["cfg.yaml"] { })
    assert equal $r true
}

export def test_merge_json_invalid_host_json_is_preserved [] {
    "{broken" | save -f $dest
    let failed = (try { merge-json $frag $dest; false } catch { true })
    assert $failed
    assert equal (open --raw $dest) "{broken"
}

export def test_merge_json_non_record_host_json_is_preserved [] {
    "[1,2]" | save -f $dest
    # та же проверка
}

export def test_merge_json_dangling_symlink_becomes_file [] {
    ^ln -s "/nonexistent/ygg-x" $dest
    merge-json $frag $dest
    assert equal ($dest | path type) "file"
}

export def test_merge_json_leaves_no_temp_files [] {
    assert equal (ls -a ($dest | path dirname) | where { |it| ($it.name | path basename) =~ 'tmp' } | length) 0
    assert equal (ls -l $dest | get 0.mode) "rw-------"
}
```

В `test_export_secrets_soft_skip_and_filtering` заменить ожидания на `API_KEY='sk-12345'` и `TOKEN='pa$$w0rd="x"&y=1'`, добавить значение с `'` и `\` (`K='it\'s'`, `P='a\\b'`).

- [ ] **Step 2: Убедиться в падении.** `rtk nu tests/run.nu --filter onchange_external`, `--filter merge_json`, `--filter export_secrets`.

- [ ] **Step 3: Реализовать.**
  - `onchange`: `do $block` отдельным оператором.
  - `merge-json`: чтение через `open --raw | from json`, ошибка разбора или не-record → `error make` до любых изменений. Пустой файл и битый симлинк дают `{}`. Симлинк снимается только перед записью. Запись в `$"($dest).tmp.(random chars --length 8)"` в том же каталоге, `chmod`, затем `mv -f`.
  - `export-secrets`: новый формат.
  - В SKILL.md строка 85 разделить: `environment.d` — двойные кавычки как раньше; `.env` — одинарные с `\\` и `\'`.

- [ ] **Step 4: Проверить формат настоящим парсером на временном файле.**

Run: `rtk proxy /opt/hermes-agent/venv/bin/python -I -c "import dotenv,sys;print(dict(dotenv.dotenv_values(sys.argv[1])))" <tmp.env>`
Expected: значения совпадают с исходными (`$`, `'`, `\`).

- [ ] **Step 5: Запустить `rtk just test`.** Ожидается PASS. `test_onchange_skips_recovers...` и `test_cli_e2e` (onchange) остаются зелёными.

- [ ] **Step 6: Коммит.** `fix(sdk): make onchange transactional, merge-json atomic and dotenv quoting literal`

---

### Task 7: Пользовательский `Path` на Windows (I38)

**Files:**
- Modify: `src/manifest.nu`, `src/env.nu:177-183`
- Modify: `docs/specs/2026-11-07-modular-omni-architecture-design.md` (5.3 и 5.6)
- Test: `tests/test_env.nu`, `tests/test_manifest.nu`

**Interfaces:**
- Produces (манифест): `path = ["~/.local/bin", "C:/abs"]` на верхнем уровне `env.toml` и в `[scope.<name>]`.
- Produces: `plan.path: list<string>` — порядок модулей, внутри модуля база, затем активные скоупы, без дублей.
- Produces: `export def format-windows-env-script [clean_env: record, path_entries: list<string>, user_home: string]: nothing -> string`.

Решение: `SetEnvironmentVariable(..., 'User')` сам рассылает `WM_SETTINGCHANGE` (документация .NET), поэтому отдельный P/Invoke не нужен; подтвердить на VM 2. `%VAR%` в записях запрещён: .NET пишет `REG_SZ`, и переменная не раскроется.

- [ ] **Step 1: Написать падающие тесты.**

```nushell
export def test_plan_collects_path_from_modules_and_scopes [] {
    # m1: path = ["~/a"], [scope.work] path = ["~/b"]; m2: path = ["~/a", "~/c"]; активен work
    assert equal $plan.path ["~/a", "~/b", "~/c"]
}

export def test_plan_rejects_percent_in_path [] {
    # path = ["%JAVA_HOME%/bin"]
    let failed = (try { resolve-effective-plan $home; false } catch { true })
    assert $failed
}

export def test_windows_env_script_escapes_and_merges_path [] {
    let s = (format-windows-env-script { K: "it's" } ["~/a", "C:/b"] "C:/Users/u")
    assert ($s | str contains "$ErrorActionPreference = 'Stop'")
    assert ($s | str contains "SetEnvironmentVariable('K', 'it''s', 'User')")
    assert ($s | str contains "GetEnvironmentVariable('Path', 'User')")
    assert ($s | str contains "'C:\\Users\\u\\a'")
    assert ($s | str contains "-notcontains")
}

export def test_windows_env_script_skips_path_block_when_empty [] {
    let s = (format-windows-env-script { K: "v" } [] "C:/Users/u")
    assert (not ($s | str contains "'Path'"))
}
```

- [ ] **Step 2: Убедиться в падении.** `rtk nu tests/run.nu --filter path`, `--filter windows_env_script`.

- [ ] **Step 3: Реализовать.**
  - `manifest.nu`: читать `path` из `env.toml` и скоупов, накапливать в `plan.path` с `uniq`; запись с `%` → `error make`.
  - `format-windows-env-script`: `~/` раскрывается через `user_home`, разделитель приводится к `\`; строки собираются через `+` из-за `[`. Блок `Path`:

```powershell
$want = @('C:\Users\u\a', 'C:\b')
$cur = [Environment]::GetEnvironmentVariable('Path', 'User')
$items = @(if ($cur) { $cur -split ';' | Where-Object { $_ } })
$new = @($want + ($items | Where-Object { $want -notcontains $_ }))
[Environment]::SetEnvironmentVariable('Path', ($new -join ';'), 'User')
```

  - `compile-environment`, строки 177–183: при `$host_os.os == "windows"`, `$nu.os-info.family == "windows"` и пустом sandbox один вызов `^powershell -NoProfile -Command $script | complete`; ненулевой код → `error make` со `stderr`. Запись на настоящей Windows тестом не покрыта, проверяется на VM 2.
  - Спека: в 5.3 описать ключ `path`, в 5.6 указать механизм и запрет `%VAR%`.

- [ ] **Step 4: Запустить `rtk just test`.** Ожидается PASS.

- [ ] **Step 5: Коммит.** `feat(env): manage Windows user Path from module manifests`

---

### Task 8: Усиление Stage 2 и итоговый гейт (I47–I51, M43, M45–M48, M52, M54)

**Files:**
- Modify: `tests/test_phase2_modules.nu`

**Interfaces:**
- Consumes: mock под sandbox из Task 5; реальные копии под override из Task 3.

Worktrees не менять: под override второй `apply` без правок хоста не пишет в модуль; это проверяется.

- [ ] **Step 1: Переписать проверку пакетов (I50, M52).** Удалить `effective-packages` с `hide-env` и константу `YGG_SRC`. Читать `open --raw $sb.pkg_log` после `apply`; лог очищать перед каждым `apply`. Утверждения остаются те же.

- [ ] **Step 2: Windows-тест (I47, M43, C1, C2).** Переименовать в `test-windows-work-repeat-apply`, добавить:

```nushell
assert-no-broken-links $sb.home
assert (not ($ps_aliases | str contains "function k {")) "Unix DevOps aliases leaked"
assert (not ($ps_aliases | str contains "function tf {"))
# второй apply с тем же окружением
assert ($res2.exit_code == 0) $"second apply failed: ($res2.stderr)"
assert equal (($sb.home | path join ".config" "git" "config") | path type) "file"
assert equal (($sb.home | path join ".config" "glazewm" "cfg" "general.yaml") | path type) "file"
```

Удалить вакуумную проверку `function kubectl`.

- [ ] **Step 3: Linux-тест (I48, I49, M45).** Добавить:
  - Перед переключением: `cooler.zsh` существует на `@pc`; после: `disp_asus` содержит `eDP-1`.
  - Цикл по 7 профилям (`idea-receiver`, `idea-refiner`, `gemini`, `thinker`, `sysops`, `formatter`, `coder`): `guard_cnt >= 2`.
  - Режим `rw-------` у `.gemini/config/config.json`, `.claude/settings.json`, `.hermes/.env`. Ключ `plugins` в `config.json`, `GEMINI_API_KEY` в `.env`.
  - Существуют: `.gemini/config/plugins/superpowers`, `.hermes/config.yaml`, `.hermes/plugins/{grill-tab,hindsight,rtk-rewrite,skill-retrieval}`, `.config/Hermes`, `.config/ollama`, `.opencommit`.
  - Новый тест `test-linux-asus-clean`: чистый `@asus` без `@pc`; ссылок OpenRGB и cooler нет, `eDP-1` есть; множества ключей `state.links` `@pc` и `@asus` содержат свои scope-only цели и не содержат чужих (сравнить с результатом `@pc` в отдельном sandbox).
  - Повторный `apply` на `@pc` с exit 0.

- [ ] **Step 4: Omni-тест (I51).** Второй запуск `nu` с теми же файлами профиля, но `YGG_HOME` и `HOME` без `.ygg` → exit 0. Добавить: `config.nu` < 50 строк; `env.nu`, `conf.d/integrations.nu`, `config.nu` содержат `else { null }`.

- [ ] **Step 5: Надёжность (M46, M47, M48, M54).**
  - `assert-no-broken-links`: `fd -H -I`.
  - `test-zero-legacy-artifacts`: `infra/stow` отсутствует; `^git -C $wt ls-files` не содержит путей с компонентом `dot_*` или `executable_*`.
  - `main`: неизвестная цель → `error make`.
  - `cleanup-sandbox`: при оставшемся каталоге после повторной попытки — предупреждение в stderr.
  - Новый финальный шаг `main` при `all`: `^git -C <wt> status --porcelain` пуст для 4 worktrees, иначе `error make`.

- [ ] **Step 6: Запустить итоговый гейт.**

Run: `rtk proxy just --justfile /data/projects/ygg/justfile test` и `rtk proxy just --justfile /data/projects/ygg/justfile test-phase2 all`
Expected: exit 0 у обоих.

Если падение указывает на дефект модуля, а не движка: модуль не править, зафиксировать в отчёте и пометить ассерт как `# blocked by module fix: <ID>` с временным отключением только этого ассерта. Отключённые ассерты перечислить пользователю.

- [ ] **Step 7: Проверить хост.**

Run: `rtk fd -H 'ygg-stage2-' /tmp --max-depth 1`, `rtk proxy ls -d ~/.ygg`, `rtk git status` в 4 первичных репозиториях.
Expected: 0 каталогов; `~/.ygg` отсутствует; первичные на `main`, dirty 11/19/17/0, состав не изменился.

- [ ] **Step 8: Коммит.** `test(phase2): strengthen stage 2 gate with repeat apply and full focus coverage`
