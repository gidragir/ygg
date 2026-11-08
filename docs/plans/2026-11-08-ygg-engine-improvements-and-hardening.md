# Ygg Engine Improvements & Hardening — Implementation Plan (RFC-001..025)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Реализовать согласованные доработки движка `ygg` (`RFC-001` — `RFC-025`, кроме отложенной части `mode = "merge"` в `RFC-021`) в строгом соответствии с порядком этапов 0–4 раздела 4.1 спецификации.

**Architecture:** Поэтапная эволюция модулей `src/{state,manifest,link,pkg,env,sdk,git}.nu`, создание модуля диагностики `src/doctor.nu` (экспортируемого из `src/mod.nu`) и расширение CLI-маршрутизатора `bin/ygg.nu` и Windows-шимма `bin/ygg.cmd`. Каждая задача начинается с написания падающих тестов в `tests/test_*.nu` (TDD), проверки их падения в изолированной песочнице `/tmp/ygg-test-*`, минимальной реализации по контракту спецификации, прогона полного набора `rtk just test` и атомарного коммита.

**Tech Stack:** Nushell 0.116+, TOML, `git`, `just`, `rtk`.

**Spec:** [docs/specs/2026-11-08-ygg-engine-improvements-and-hardening.md](../specs/2026-11-08-ygg-engine-improvements-and-hardening.md) и базовая спецификация [docs/specs/2026-11-07-modular-omni-architecture-design.md](../specs/2026-11-07-modular-omni-architecture-design.md). При любых разночтениях спецификация приоритетнее плана.

**Покрытие:**
- **Этап 0 (Защита данных):** `RFC-020` (базовый `preflight-check` по источникам ссылок до пакетов и модификаций), `RFC-011` (требование 5: `onchange`, `merge-json`, `export-secrets` соблюдают `YGG_DRY_RUN=true`).
- **Этап 1 (Независимые исправления):** `RFC-001` (защита Win32 API от wildcard-масок в `onchange`), `RFC-007` (`--version` / `-v` и `ygg version`), `RFC-008` (`to-win32-path` с `path expand -n`), `RFC-018` (`ensure-executable` с проверкой `^...x` и подавлением stderr), `RFC-019` (`bin/ygg.cmd`: `setlocal` и пути `Program Files` / `scoop`), `RFC-016` (разворачивание ведущего `~` и `$HOME` в `compile-environment`), `RFC-024` (аудит `secrets.example.toml` и предупреждения `export-secrets --keys`), `RFC-002` (проверка `which $mgr` и `YGG_MOCK_PKG_MISSING`).
- **Этап 2 (Ядро ссылок):** `RFC-003` (1-to-N списки целей в `links` и `save`), `RFC-010` (`resolve-link-targets`, 5 правил приоритета, межмодульные коллизии и `nesting_conflicts`), `RFC-009` + `RFC-006` (`link-literal-target`, `link-target-matches`, `swap-symlink-atomic`, идемпотентный `OK`, fallback `mklink /J` → `/D` → `cp -r` `dir_copy`), `RFC-011` (`plan-copy-sync`, `compute-link-ops`, `PRUNE` первыми, `backup-with-notice`, `--all`, `ygg diff`), `RFC-021` + полный `RFC-020` (`shadowed-files`, `mode = "dir"`, единый `preflight-check`), `RFC-012` (`ygg add --dry-run` / `--force`, защита от потери незакоммиченных изменений в модуле), `RFC-023` (`safe-link` в SDK и CLI).
- **Этап 3 (Пакеты):** `RFC-022` (`missing-native-pkgs` через `pacman -T`, `sudo-available` при отсутствии TTY / `YGG_NONINTERACTIVE=1`), `RFC-005` + `RFC-013` (поштучный `pkg-argv-list` для `winget`/`scoop`/`uv`, `WINGET_OK_CODES`, `kill-job-tree` с чтением `pids` до `job kill`, `run-with-timeout`, `prepare-provider-environment` для `mise trust`, флаги `--pkg` и `--pkg-timeout`), `RFC-014` (кэш `pkg:<mgr>` в `state.hashes` и `--refresh-packages`).
- **Этап 4 (Наблюдаемость и реакция):** `RFC-004` (`sync_conflicts`, `pending_save`, `target`, точный `links_ok`, `ygg status --json`), `RFC-025` (проверка кода выхода `mklink` в `add-module`, `warn-if-not-canonicalizable`, уточнение базовой спеки), `RFC-017` (`src/doctor.nu`, 11 read-only проверок, `[doctor] private_files`, `ygg doctor [--json] [--sandbox]`), `RFC-015` (`hash-watch-set` и `run-link-hooks` после `setup.nu`).

**Вне плана (раздел 4.3 спецификации):**
- Рекурсивный режим `mode = "merge"` (`RFC-021`) и секция `[rel-links]` (`REP-007.3`) — отложены.
- Правки пользовательских репозиториев `omni-dotfiles` (`cutover-chezmoi`, `nushell/env.nu`) и `ai-dotfiles` (`setup.nu` с `safe-link`, `secrets.example.toml`) выполняются отдельно в соответствующих репозиториях.

## Global Constraints

- Работать в `/data/projects/ygg` (симлинк на `/home/gidragir/projects/ygg`), без создания новых worktree.
- **ZERO HOST MUTATION:** Ни один тест и ни один пробный запуск не имеют права читать или модифицировать реальные `~/.ygg`, `~/.config` или `$HOME`. Все запуски выполняются строго во временных каталогах `/tmp/ygg-test-*` с явно заданными `YGG_HOME`, `YGG_SANDBOX` и `YGG_MOCK_PKG_LOG`.
- **Чистота ядра:** В `src/*.nu` и `bin/*` запрещены захардкоженные имена пользовательских репозиториев или инструментов (`omni-dotfiles`, `ai-dotfiles`, `chezmoi`, `sops` и т.п.).
- **Zero-Data-Loss:** `remove-link-only` удаляет только симлинк/Junction; физические файлы и каталоги при замене или удалении (`dir_copy`, отредактированный `copy`) всегда перемещаются в `$YGG_HOME/.state/backups/<timestamp>/` через `backup-with-notice`.
- **Терминал и поиск:** Все команды с префиксом `rtk`; поиск файлов и кода строго через `rtk fd` и `rtk rg` (без флага `-E`); GNU `find` и `grep` запрещены.
- **Идиомы Nushell 0.116+ (`.agents/skills/nushell-ygg-dev/SKILL.md`):**
  - Использовать `get -o` (не `get -i`).
  - В замыканиях `where` явно объявлять параметр `where { |it| ... }`.
  - Для внешних команд использовать `| complete` (не `do -i`).
  - Не вставлять литеральные квадратные скобки `[` внутрь интерполируемых строк `$"..."` — собирать такие строки конкатенацией через `+`.
- Запуск одного теста: `rtk nu tests/run.nu --filter <имя>`; весь тестовый набор: `rtk just test`.

## Review Focus

1. **Абсолютная неизменность хоста и `state.json` при `--dry-run` / `ygg diff` / `ygg add -n` / `ygg doctor`:** снимок файловой системы песочницы и `YGG_HOME` до и после вызова обязан совпадать побайтово (`onchange`, `merge-json`, `export-secrets` и `run-link-hooks` не пишут на диск и не обновляют `state.hashes`, временные клоны `.state/tmp/clone-*` удаляются).
2. **Порядок `PRUNE` перед проверкой владения и созданием ссылок:** переход модуля с ссылки на каталог `"X" = "~/.config/X"` на глоб `"X/*" = "~/.config/X/*"` снимает старую управляемую ссылку первым шагом и не падает с `Shared directory ownership conflict`, тогда как неуправляемая сторонняя ссылка на `~/.config/X` блокируется на `preflight-check`.
3. **Завершение дерева процессов в `kill-job-tree` (RFC-013):** `pids` извлекаются из `job list | where id == $jid` строго **до** вызова `job kill $jid`, чтобы дочерние процессы (`^nu -c` в `on_change`, `.cmd`-шиммы на Windows) гарантированно уничтожались и не оставались сиротами.
4. **Двухшаговое сравнение целей в `link-target-matches` (RFC-009):** шаг 1 сравнивает лексически нормализованную литеральную цель (`ls -lD` или PowerShell `(Get-Item -Force).Target` для NTFS Junction), шаг 2 проверяет существование обеих сторон (`($dest | path exists) and ($src | path exists)`) перед сравнением `path expand`, чтобы две битые ссылки на одну несуществующую цель никогда не давали `OK`.
5. **Барьер `preflight-check` (RFC-020, RFC-021):** запускается до пакетных менеджеров; отсутствие любого источника в `plan.links` или затенение непустого каталога хоста без `mode = "dir"` / `--force` завершает `apply` и `add` с кодом `1` без единого вызова пакетного менеджера и без модификации `host.toml`.

---

### Task 1: Этап 0 — Базовая предварительная проверка источников (RFC-020) и соблюдение `YGG_DRY_RUN` в SDK (RFC-011 п. 5)

**Files:**
- Modify: `src/sdk.nu:16-100,103-186,191-241`
- Modify: `src/link.nu` (добавить базовый `preflight-check` и `format-preflight-errors`)
- Modify: `bin/ygg.nu:127-149`
- Test: `tests/test_sdk.nu`, `tests/test_cli_e2e.nu`

**Interfaces:**
- Produces in `src/link.nu`:
  - `export def preflight-check [ygg_home: string, plan: record, resolved?: record, ops?: table, --force, --sandbox: string = ""]: nothing -> list<record<module: string, key: string, reason: string, detail: string>>` (на Этапе 0 проверяет `plan.links` на `missing_source`; на Этапе 2 расширяется проверками `invalid_mode_source`, `nesting_conflict`, `ownership_conflict` и `shadowed_files`).
  - `export def format-preflight-errors [problems: list<record>]: nothing -> string`
- Updates in `src/sdk.nu`:
  - `onchange`, `merge-json`, `export-secrets` проверяют `(($env.YGG_DRY_RUN? | default "false") == "true")` до записи файлов и обновления `state.json`.

- [ ] **Step 1: Написать падающие тесты.**
В `tests/test_sdk.nu` добавить тест `test_sdk_functions_respect_ygg_dry_run`:
```nushell
export def test_sdk_functions_respect_ygg_dry_run [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let mod_dir = ($home | path join "modules" "m")
        mkdir $mod_dir
        let src = ($mod_dir | path join "cfg.yaml")
        let out = ($home | path join "built.yaml")
        let frag = ($mod_dir | path join "frag.json")
        let dest_json = ($home | path join "target.json")
        let dest_env = ($home | path join ".env")
        "v1" | save -f $src
        '{"a": 1}' | save -f $frag
        "[env]\nAPI_KEY = \"sec\"\n" | save -f ($home | path join "secrets.toml")

        with-env { YGG_HOME: $home, YGG_MODULE_DIR: $mod_dir, YGG_DRY_RUN: "true", YGG_FORCE: "false" } {
            let r_dry = (onchange "build_dry" ["cfg.yaml"] --target $out { cp $src $out })
            assert equal $r_dry false
            assert (not ($out | path exists))
            assert equal ((load-state $home).hashes | get -o "build_dry" | default "") ""

            merge-json $frag $dest_json
            assert (not ($dest_json | path exists))

            export-secrets $dest_env --keys ["API_KEY"]
            assert (not ($dest_env | path exists))
        }

        # Последующий реальный запуск выполняет onchange
        with-env { YGG_HOME: $home, YGG_MODULE_DIR: $mod_dir, YGG_DRY_RUN: "false", YGG_FORCE: "false" } {
            let r_real = (onchange "build_dry" ["cfg.yaml"] --target $out { cp $src $out })
            assert equal $r_real true
            assert ($out | path exists)
        }
    }
}
```
В `tests/test_cli_e2e.nu` добавить `test_preflight_blocks_missing_link_source_before_packages`:
```nushell
export def test_preflight_blocks_missing_link_source_before_packages [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let pkg_log = ($home | path join "pkg.log")
        let mod_src = ($home | path join "bad-mod")
        mkdir $mod_src
        mkdir ($sb | path join ".config" "ollama")
        "host_model_state" | save -f ($sb | path join ".config" "ollama" "models.txt")

        'name = "bad-mod"
os = ["linux", "cachyos"]
[packages]
pacman = ["curl"]
[links]
"configs/ollama" = "~/.config/ollama"
"missing/glob/*" = "~/.config/glob/*"
' | save -f ($mod_src | path join "ygg.toml")

        mkdir ($home | path join "modules")
        ^ln -s $mod_src ($home | path join "modules" "bad-mod")
        "[[modules]]\nname = \"bad-mod\"\n" | save -f ($home | path join "host.toml")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let res = (with-env {
            YGG_HOME: $home,
            YGG_SANDBOX: $sb,
            YGG_HOST_OS_OVERRIDE: "cachyos",
            YGG_MOCK_PKG_LOG: $pkg_log
        } { ^nu $ygg_bin apply --force --sandbox $sb | complete })

        assert ($res.exit_code != 0)
        assert ($res.stderr | str contains "configs/ollama")
        assert ($res.stderr | str contains "missing/glob/*")
        assert (not ($pkg_log | path exists))
        assert equal (open --raw ($sb | path join ".config" "ollama" "models.txt")) "host_model_state"
    }
}
```

- [ ] **Step 2: Запустить новые тесты и убедиться в падении.**
Выполнить:
`rtk nu tests/run.nu --filter test_sdk_functions_respect_ygg_dry_run`
`rtk nu tests/run.nu --filter test_preflight_blocks_missing_link_source_before_packages`
Ожидается: `FAIL`.

- [ ] **Step 3: Реализовать соблюдение `YGG_DRY_RUN` в `src/sdk.nu` и базовый `preflight-check` в `src/link.nu` + `bin/ygg.nu`.**
1. В `src/sdk.nu`:
   - В `onchange` перед `do $block` (после проверки `if (not $is_force) and $target_exists ...`):
     ```nushell
     let is_dry = (($env.YGG_DRY_RUN? | default "false") == "true")
     if $is_dry {
         print $"[ygg] dry-run: onchange '($key)' would run"
         return false
     }
     ```
   - В `merge-json` после валидации `$fragment` и `$existing_record`, перед созданием каталога/записью `$tmp_file` (и не вызывая `mkdir $dest_dir` при dry-run):
     ```nushell
     let is_dry = (($env.YGG_DRY_RUN? | default "false") == "true")
     if $is_dry {
         print $"[ygg] dry-run: merge-json would write '($dest)'"
         return
     }
     ```
   - В `export-secrets` перед `mkdir $dest_dir` и `$content | save -f $dest`:
     ```nushell
     let is_dry = (($env.YGG_DRY_RUN? | default "false") == "true")
     if $is_dry {
         print $"[ygg] dry-run: export-secrets would write '($dest)'"
         return
     }
     ```
2. В `src/link.nu` добавить экспортируемые функции `preflight-check` и `format-preflight-errors`:
   ```nushell
   export def preflight-check [
       ygg_home: string,
       plan: record,
       resolved: record = {},
       ops: table = [],
       --force,
       --sandbox: string = ""
   ]: nothing -> list<record<module: string, key: string, reason: string, detail: string>> {
       mut problems = []
       for link in ($plan.links? | default []) {
           if not ($link.src_path | path exists) {
               $problems = ($problems | append {
                   module: $link.module,
                   key: $link.key,
                   reason: "missing_source",
                   detail: $"Source path '($link.src_path)' does not exist"
               })
           }
       }
       $problems
   }

   export def format-preflight-errors [problems: list<record>]: nothing -> string {
       let lines = ($problems | each { |p| $"  - [($p.module)] '($p.key)' \(($p.reason)\): ($p.detail)" })
       "Pre-flight check failed:\n" + ($lines | str join "\n")
   }
   ```
3. В `bin/ygg.nu` в `main apply` сразу после проверки пустых модулей (перед `install-packages`) вызвать `preflight-check`:
   ```nushell
   let problems = (preflight-check $ygg_home $plan --force=$force --sandbox=$effective_sandbox)
   if ($problems | is-not-empty) {
       error make { msg: (format-preflight-errors $problems) }
   }
   ```
   Также проверить существующие тесты в `tests/test_*.nu`, где в `ygg.toml` объявлены `[links]` и вызывается `ygg apply` через CLI: убедиться, что исходные файлы в тестах существуют.

- [ ] **Step 4: Запустить весь тестовый набор.**
Выполнить: `rtk just test`
Ожидается: `PASS`.

- [ ] **Step 5: Сделать коммит.**
Выполнить:
`rtk git add src/sdk.nu src/link.nu bin/ygg.nu tests/test_sdk.nu tests/test_cli_e2e.nu && rtk git commit -m "fix(safety): add preflight source check and enforce YGG_DRY_RUN in SDK"`

---

### Task 2: Этап 1A — Платформенные основы и CLI (`RFC-001`, `RFC-007`, `RFC-008`, `RFC-018`, `RFC-019`)

**Files:**
- Modify: `src/sdk.nu:27-62`
- Modify: `src/state.nu` (добавить `to-win32-path`)
- Modify: `src/link.nu:4,18-22,60-71,321-325,358-360,388-392,427-429`
- Modify: `src/git.nu:6,38-41`
- Modify: `bin/ygg.nu:1-23`
- Modify: `bin/ygg.cmd`
- Test: `tests/test_sdk.nu`, `tests/test_state.nu`, `tests/test_link.nu`, `tests/test_cli_e2e.nu`

**Interfaces:**
- Produces in `src/state.nu`: `export def to-win32-path [p: string]: nothing -> string`
- Produces in `src/link.nu`: `def ensure-executable [p: string]: nothing -> nothing`
- Produces in `bin/ygg.nu`: `const YGG_VERSION = "0.1.0"`, `def "main version" []`, `def main [--version (-v)]`

- [ ] **Step 1: Написать падающие тесты.**
1. В `tests/test_sdk.nu` — `test_onchange_wildcard_pattern_does_not_call_path_exists_on_glob`:
   ```nushell
   export def test_onchange_wildcard_pattern_does_not_call_path_exists_on_glob [] {
       with-temp-ygg { |home|
           ensure-ygg-dirs $home
           let mod_dir = ($home | path join "modules" "m")
           mkdir ($mod_dir | path join "cfg")
           "a: 1\n" | save -f ($mod_dir | path join "cfg" "one.yaml")
           with-env { YGG_HOME: $home, YGG_MODULE_DIR: $mod_dir, YGG_FORCE: "false" } {
               let r1 = (onchange "globs" ["cfg/*.yaml", "nonexistent/*.yaml"] { })
               assert equal $r1 true
               let r2 = (onchange "globs" ["cfg/*.yaml", "nonexistent/*.yaml"] { })
               assert equal $r2 false
           }
       }
   }
   ```
2. В `tests/test_state.nu` — `test_to_win32_path_preserves_symlink_and_replaces_slashes`:
   ```nushell
   export def test_to_win32_path_preserves_symlink_and_replaces_slashes [] {
       with-temp-ygg { |home|
           let real_dir = ($home | path join "real_dir")
           let link_dir = ($home | path join "lnk")
           mkdir $real_dir
           ^ln -s $real_dir $link_dir

           let win_p = (to-win32-path $link_dir)
           assert (not ($win_p | str contains "/"))
           assert ($win_p | str ends-with "\\lnk")
           assert (not ($win_p | str ends-with "\\real_dir"))
       }
   }
   ```
3. В `tests/test_link.nu` — `test_ensure_executable_sets_mode_and_suppresses_stderr`:
   ```nushell
   export def test_ensure_executable_sets_mode_and_suppresses_stderr [] {
       with-temp-ygg { |home|
           let sb = ($home | path join "sb")
           let m = ($home | path join "modules" "m")
           mkdir ($m | path join "bin")
           let s = ($m | path join "bin" "tool.sh")
           "#!/bin/sh\necho ok\n" | save -f $s
           ^chmod 0644 $s
           'name = "m"
   os = ["linux"]
   [links]
   "bin/tool.sh" = "~/.local/bin/tool.sh"
   ' | save -f ($m | path join "ygg.toml")
           "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")

           apply-links $home (resolve-effective-plan $home) --sandbox $sb
           let mode = (ls -lD $s | get 0.mode)
           assert ($mode =~ '^...x')
       }
   }
   ```
4. В `tests/test_cli_e2e.nu` — `test_cli_version_flag_and_subcommand` и `test_ygg_cmd_shim_search_paths_and_setlocal`:
   ```nushell
   export def test_cli_version_flag_and_subcommand [] {
       let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
       let v1 = (^nu $ygg_bin --version | complete)
       let v2 = (^nu $ygg_bin -v | complete)
       let v3 = (^nu $ygg_bin version | complete)
       assert equal $v1.exit_code 0
       assert ($v1.stdout | str starts-with "ygg 0.1.0")
       assert equal ($v1.stdout | str trim) ($v2.stdout | str trim)
       assert equal ($v1.stdout | str trim) ($v3.stdout | str trim)
   }

   export def test_ygg_cmd_shim_search_paths_and_setlocal [] {
       let cmd_file = ($env.FILE_PWD | path join "../bin/ygg.cmd" | path expand)
       let raw = (open --raw $cmd_file)
       let pos_setlocal = ($raw | str index-of "setlocal")
       let pos_path = ($raw | str index-of "set \"PATH=")
       assert ($pos_setlocal >= 0)
       assert ($pos_setlocal < $pos_path)

       let p1 = ($raw | str index-of "%USERPROFILE%\\.local\\bin\\nu.exe")
       let p2 = ($raw | str index-of "%LOCALAPPDATA%\\Programs\\nu\\bin\\nu.exe")
       let p3 = ($raw | str index-of "%LOCALAPPDATA%\\Microsoft\\WinGet\\Links\\nu.exe")
       let p4 = ($raw | str index-of "%ProgramFiles%\\nu\\bin\\nu.exe")
       let p5 = ($raw | str index-of "%USERPROFILE%\\scoop\\shims\\nu.exe")
       assert (($p1 < $p2) and ($p2 < $p3) and ($p3 < $p4) and ($p4 < $p5))
   }
   ```

- [ ] **Step 2: Запустить новые тесты и убедиться в падении.**
Выполнить:
`rtk nu tests/run.nu --filter test_to_win32_path`
`rtk nu tests/run.nu --filter test_cli_version_flag`
`rtk nu tests/run.nu --filter test_ygg_cmd_shim`
Ожидается: `FAIL`.

- [ ] **Step 3: Реализовать `RFC-001`, `RFC-007`, `RFC-008`, `RFC-018`, `RFC-019`.**
1. В `src/sdk.nu` (RFC-001): вычислять `has_wildcard` до `path exists` / `path type`:
   ```nushell
   let has_wildcard = ($resolved_pattern | str contains "*") or ($resolved_pattern | str contains "?")
   let is_exact = if not $has_wildcard {
       try { ($resolved_pattern | path exists) or (($resolved_pattern | path type) != null) } catch { false }
   } else {
       false
   }
   ```
2. В `src/state.nu` (RFC-008): добавить `export def to-win32-path [p: string]: nothing -> string { $p | path expand -n | str replace -a "/" "\\" }`. Импортировать и применить `to-win32-path` в `src/link.nu` (`is-link-or-junction`, `remove-link-only`, `apply-links`) и `src/git.nu` (`add-module`).
3. В `src/link.nu` (RFC-018): добавить `ensure-executable`:
   ```nushell
   def ensure-executable [p: string]: nothing -> nothing {
       let mode = (try { ls -lD $p | get -o 0.mode | default "" } catch { "" })
       if ($mode != "") and not ($mode =~ '^...x') {
           try { ^chmod +x $p | complete | ignore } catch { }
       }
   }
   ```
   и заменить `try { ^chmod +x ... }` на `ensure-executable`.
4. В `bin/ygg.nu` (RFC-007): добавить `const YGG_VERSION = "0.1.0"`, `def "main version" []` и флаг `--version (-v)` в `def main`.
5. В `bin/ygg.cmd` (RFC-019): перенести `setlocal` на строку 3 (сразу после `@echo off`) и добавить ветки `%ProgramFiles%\nu\bin\nu.exe` и `%USERPROFILE%\scoop\shims\nu.exe`.

- [ ] **Step 4: Запустить весь тестовый набор.**
Выполнить: `rtk just test`
Ожидается: `PASS`.

- [ ] **Step 5: Сделать коммит.**
Выполнить:
`rtk git add src/sdk.nu src/state.nu src/link.nu src/git.nu bin/ygg.nu bin/ygg.cmd tests/test_sdk.nu tests/test_state.nu tests/test_link.nu tests/test_cli_e2e.nu && rtk git commit -m "fix(core): harden wildcard guard, to-win32-path, chmod, version CLI and ygg.cmd"`

---

### Task 3: Этап 1B — Окружение, аудит секретов и отсутствующие менеджеры пакетов (`RFC-016`, `RFC-024`, `RFC-002`)

**Files:**
- Modify: `src/env.nu:57-100`
- Modify: `src/sdk.nu:191-241`
- Modify: `src/pkg.nu:63-95`
- Test: `tests/test_env.nu`, `tests/test_sdk.nu`, `tests/test_pkg_git.nu`

**Interfaces:**
- Produces in `src/env.nu`:
  - `def resolve-env-value [v: string, sb: string]: nothing -> string`
  - `export def missing-secret-keys [template: string, secrets: string]: nothing -> list<string>`
- Updates in `src/sdk.nu`:
  - `export-secrets` выводит предупреждение в `stderr` для каждого запрошенного в `--keys`, но отсутствующего или пустого ключа (включая случай отсутствующего `secrets.toml`, когда `--keys` не пуст).
- Updates in `src/pkg.nu`:
  - Проверка `which $mgr` и поддержка `$env.YGG_MOCK_PKG_MISSING`.

- [ ] **Step 1: Написать падающие тесты.**
1. В `tests/test_env.nu` — `test_env_expands_leading_tilde_and_home_only` и `test_missing_secret_keys_audit`:
   ```nushell
   export def test_env_expands_leading_tilde_and_home_only [] {
       with-temp-ygg { |home|
           ensure-ygg-dirs $home
           let sb = ($home | path join "sb")
           let m1 = ($home | path join "modules" "core")
           mkdir $m1
           'name = "core"
   os = ["linux"]' | save -f ($m1 | path join "ygg.toml")
           'TILDE_ONLY = "~"
   TILDE_SUB = "~/.kube/config"
   HOME_SUB = "$HOME/.cargo/bin"
   MID_TILDE = "a/~/b"
   OTHER_VAR = "$OTHER/x"
   ' | save -f ($m1 | path join "env.toml")
           "[[modules]]\nname = \"core\"" | save -f ($home | path join "host.toml")

           let plan = (resolve-effective-plan $home)
           compile-environment $home $plan --sandbox $sb

           let env_nu = ($home | path join ".state/env/env.nu")
           let env_zsh = ($home | path join ".state/env/env.zsh")
           let conf_file = ($sb | path join ".config/environment.d/99-ygg.conf")

           let nu_out = (^nu -c $"source ($env_nu); [$env.TILDE_ONLY, $env.TILDE_SUB, $env.HOME_SUB, $env.MID_TILDE, $env.OTHER_VAR] | to json -r") | from json
           assert equal $nu_out.0 $sb
           assert equal $nu_out.1 ($sb | path join ".kube/config")
           assert equal $nu_out.2 ($sb | path join ".cargo/bin")
           assert equal $nu_out.3 "a/~/b"
           assert equal $nu_out.4 "$OTHER/x"

           let conf_raw = (open --raw $conf_file)
           assert ($conf_raw | str contains $"TILDE_SUB=\"($sb)/.kube/config\"")
           assert ($conf_raw | str contains "OTHER_VAR=\"\\$OTHER/x\"")
       }
   }

   export def test_missing_secret_keys_audit [] {
       with-temp-ygg { |home|
           let tmpl = ($home | path join "secrets.example.toml")
           let sec = ($home | path join "secrets.toml")
           "# KEY_COMMENTED = \"x\"\n[env]\nKEY_PRESENT = \"placeholder\"\nKEY_EMPTY = \"placeholder\"\nKEY_MISSING = \"placeholder\"\n" | save -f $tmpl
           "[env]\nKEY_PRESENT = \"super_secret_val\"\nKEY_EMPTY = \"\"\n" | save -f $sec

           let missing = (missing-secret-keys $tmpl $sec)
           assert ("KEY_EMPTY" in $missing)
           assert ("KEY_MISSING" in $missing)
           assert (not ("KEY_PRESENT" in $missing))
           assert (not ("KEY_COMMENTED" in $missing))
       }
   }
   ```
2. В `tests/test_sdk.nu` — `test_export_secrets_warns_on_missing_requested_keys`:
   ```nushell
   export def test_export_secrets_warns_on_missing_requested_keys [] {
       with-temp-ygg { |home|
           let dest = ($home | path join ".env")
           "[env]\nPRESENT_KEY = \"val123\"\nEMPTY_KEY = \"\"\n" | save -f ($home | path join "secrets.toml")
           let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
           let res = (with-env { YGG_HOME: $home } {
               ^nu $ygg_bin export-secrets $dest --keys "PRESENT_KEY,EMPTY_KEY,MISSING_KEY" | complete
           })
           assert equal $res.exit_code 0
           assert ($res.stderr | str contains "EMPTY_KEY")
           assert ($res.stderr | str contains "MISSING_KEY")
           assert (not ($res.stderr | str contains "val123"))
           let written = (open --raw $dest)
           assert ($written | str contains "PRESENT_KEY='val123'")
       }
   }
   ```
3. В `tests/test_pkg_git.nu` — `test_missing_package_manager_warns_and_skips_without_failing`:
   ```nushell
   export def test_missing_package_manager_warns_and_skips_without_failing [] {
       with-temp-ygg { |home|
           let log = ($home | path join "pkg.log")
           let m1 = ($home | path join "modules" "m")
           mkdir $m1
           'name = "m"
   os = ["windows"]
   [packages]
   winget = ["Git.Git"]
   scoop = ["neovim"]' | save -f ($m1 | path join "ygg.toml")
           "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")

           with-env {
               YGG_HOST_OS_OVERRIDE: "windows",
               YGG_MOCK_PKG_LOG: $log,
               YGG_MOCK_PKG_MISSING: "scoop"
           } {
               let res = (install-packages (resolve-effective-plan $home))
               assert equal $res.failed []
               let lines = (open --raw $log)
               assert ($lines | str contains "winget")
               assert (not ($lines | str contains "scoop"))
           }
       }
   }
   ```

- [ ] **Step 2: Запустить новые тесты и убедиться в падении.**
Выполнить:
`rtk nu tests/run.nu --filter test_env_expands_leading_tilde`
`rtk nu tests/run.nu --filter test_missing_secret_keys_audit`
`rtk nu tests/run.nu --filter test_export_secrets_warns`
`rtk nu tests/run.nu --filter test_missing_package_manager_warns`
Ожидается: `FAIL`.

- [ ] **Step 3: Реализовать `RFC-016`, `RFC-024`, `RFC-002`.**
1. В `src/env.nu`:
   - Добавить `resolve-env-value`:
     ```nushell
     def resolve-env-value [v: string, sb: string]: nothing -> string {
         if ($v == "~") or ($v | str starts-with "~/") or ($v | str starts-with "~\\") {
             expand-target-path $v --sandbox $sb
         } else if ($v == "$HOME") or ($v | str starts-with "$HOME/") or ($v | str starts-with "$HOME\\") {
             expand-target-path ("~" + ($v | str substring 5..)) --sandbox $sb
         } else {
             $v
         }
     }
     ```
     и применить его при сборке `clean_env` в `compile-environment`.
   - Добавить `secret-keys` и `export def missing-secret-keys [template: string, secrets: string]: nothing -> list<string>` по контракту RFC-024, а в `compile-environment` проверять каждый модуль `$plan.modules` на наличие `($mod_entry.dir | path join "secrets.example.toml")` и выводить:
     `print -e $"[ygg] Warning: module '($mod_entry.name)' is missing secrets: ($missing | str join ', ')"`.
2. В `src/sdk.nu` в `export-secrets`:
   - Если `not ($sec_file | path exists)`: если `($keys | is-not-empty)`, вывести `print -e $"[ygg] Warning: export-secrets: secrets.toml not found, missing requested keys: ($keys | str join ', ')"`, затем `return`.
   - Если `($keys | is-not-empty)`: найти ключи из `$keys`, которых нет в `$available_keys` или значение которых пустое (`(($sec_env | get -o $k | default "") | into string) == ""`), и для каждого (или списком) вывести предупреждение в `stderr`, исключив пустые ключи из `$target_keys`.
3. В `src/pkg.nu` (RFC-002): перед формированием/запуском команды менеджера проверить `YGG_MOCK_PKG_MISSING` / `which $mgr | is-empty`, вывести предупреждение в `stderr` и выполнить `continue`.

- [ ] **Step 4: Запустить весь тестовый набор.**
Выполнить: `rtk just test`
Ожидается: `PASS`.

- [ ] **Step 5: Сделать коммит.**
Выполнить:
`rtk git add src/env.nu src/sdk.nu src/pkg.nu tests/test_env.nu tests/test_sdk.nu tests/test_pkg_git.nu && rtk git commit -m "feat(env,pkg): expand leading tilde in env, audit missing secrets, skip missing pkg managers"`

---

### Task 4: Этап 2A — 1-to-N кандидаты, разрешение приоритетов (`resolve-link-targets`) и идемпотентные атомарные ссылки (`RFC-003`, `RFC-010`, `RFC-009`, `RFC-006`)

**Files:**
- Modify: `src/manifest.nu:162-182,259-452`
- Modify: `src/link.nu`
- Modify: `tests/test_manifest.nu:6-46`
- Test: `tests/test_manifest.nu`, `tests/test_link.nu`

**Interfaces:**
- Produces in `src/manifest.nu`:
  - `def to-string-list [value: any]: nothing -> list<string>`
  - `def normalize-link-value [key: string, value: any]: nothing -> record<targets: list<string>, on_change: string, mode: string>`
  - `def merge-link-entries [base: table, scoped: table]: nothing -> table`
  - `resolve-effective-plan` сохраняет всех кандидатов в `$plan.links` (с полями `module`, `module_rank`, `origin_rank`, `key_order`, `key`, `src_rel`, `src_path`, `dest_raw`, `is_glob`, `on_change`, `mode`) и в `$plan.save` (с `module`, `module_rank`, `origin_rank`, `key_order`, `key`, `src_rel`, `src_path`, `dest_raw`).
- Produces in `src/link.nu`:
  - `def normalize-case [p: string]: nothing -> string`
  - `def link-literal-target [dest: string]: nothing -> string`
  - `export def link-target-matches [dest: string, src: string]: nothing -> bool`
  - `def swap-symlink-atomic [src: string, dest: string]: nothing -> nothing`
  - `def create-windows-dir-link [src: string, dest: string]: nothing -> record<ok: bool, type: string, stderr: string>` (реализует цепочку `mklink /J` → `mklink /D` → `cp -r` с `type: "dir_copy"`, RFC-006)
  - `export def resolve-link-targets [plan: record, --sandbox: string = ""]: nothing -> record<targets: table, save_targets: table, collisions: table, nesting_conflicts: list<record>>`

- [ ] **Step 1: Написать падающие тесты.**
1. В `tests/test_manifest.nu`:
   - Обновить `test_scope_isolation_and_last_module_wins` (проверять, что оба кандидата `~/.config/starship.toml` присутствуют в `$plan.links` с `module_rank` 0 и 1).
   - Добавить `test_manifest_1_to_n_and_table_link_forms`:
     ```nushell
     export def test_manifest_1_to_n_and_table_link_forms [] {
         with-temp-ygg { |home|
             let m = ($home | path join "modules" "m")
             mkdir $m
             'name = "m"
     os = ["linux"]
     [links]
     "glazewm" = ["~/.config/glazewm", "~/.glzr/glazewm"]
     [links."niri/cfg/*"]
     target = "~/.config/niri/cfg/*"
     on_change = "niri msg action reload-config"
     [links."openrgb"]
     target = "~/.config/OpenRGB"
     mode = "dir"
     [save]
     "settings.json" = ["~/.config/app/s.json", "~/.local/share/app/s.json"]
     ' | save -f ($m | path join "ygg.toml")
             "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")

             let plan = (resolve-effective-plan $home)
             assert equal ($plan.links | where key == "glazewm" | length) 2
             let niri_entry = ($plan.links | where key == "niri/cfg/*" | first)
             assert equal $niri_entry.on_change "niri msg action reload-config"
             let orgb_entry = ($plan.links | where key == "openrgb" | first)
             assert equal $orgb_entry.mode "dir"
             assert equal ($plan.save | where key == "settings.json" | length) 2
         }
     }

     export def test_manifest_rejects_invalid_link_table_and_mode [] {
         with-temp-ygg { |home|
             let m = ($home | path join "modules" "m")
             mkdir $m
             # 1. Table without target
             "name = \"m\"\nos = [\"linux\"]\n[links.a]\non_change = \"echo 1\"\n" | save -f ($m | path join "ygg.toml")
             "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")
             assert (try { resolve-effective-plan $home; false } catch { true })

             # 2. Unknown mode (e.g. merge)
             "name = \"m\"\nos = [\"linux\"]\n[links.a]\ntarget = \"~/a\"\nmode = \"merge\"\n" | save -f ($m | path join "ygg.toml")
             assert (try { resolve-effective-plan $home; false } catch { true })

             # 3. mode with /*
             "name = \"m\"\nos = [\"linux\"]\n[links.\"a/*\"]\ntarget = \"~/a/*\"\nmode = \"dir\"\n" | save -f ($m | path join "ygg.toml")
             assert (try { resolve-effective-plan $home; false } catch { true })
         }
     }
     ```
2. В `tests/test_link.nu` добавить тесты для `RFC-010`, `RFC-009`, `RFC-003`:
   - `test_resolve_link_targets_priority_rules_and_collisions`:
     - явная ссылка из `[scope.pc.links]` раннего модуля сильнее глоба `/*` более позднего модуля;
     - внутри одного модуля ключ из `[scope.pc.links]`, переопределивший ключ базы, сильнее глоба `zz/*` базы;
     - коллизия между двумя модулями попадает в `resolved.collisions`, внутри одного модуля — нет;
     - вложенность целевых путей (родитель с `is_dir == true` и дочерняя ссылка внутри него) попадает в `resolved.nesting_conflicts`.
   - `test_link_target_matches_and_idempotent_inode`:
     - повторный `apply-links` не меняет inode симлинка (`^stat -c "%i" $dest`), а `res.applied` при втором запуске пуст;
     - смена источника атомарно обновляет ссылку (`swap-symlink-atomic`), не оставляя `.ygg-tmp-*` ни рядом с целью, ни внутри старого каталога;
     - перенацеливание симлинка модуля `~/.ygg/modules/<name>` на другую папку с тем же файлом даёт `link-target-matches == true` и не меняет inode ссылки;
     - две битые ссылки на один несуществующий путь с разной литеральной записью (например, через симлинк модуля) не считаются валидным совпадением.

- [ ] **Step 2: Запустить новые тесты и убедиться в падении.**
Выполнить:
`rtk nu tests/run.nu --filter test_manifest_1_to_n`
`rtk nu tests/run.nu --filter test_resolve_link_targets`
`rtk nu tests/run.nu --filter test_link_target_matches`
Ожидается: `FAIL`.

- [ ] **Step 3: Реализовать `RFC-003`, `RFC-010`, `RFC-009`, `RFC-006`.**
1. В `src/manifest.nu`:
   - Добавить `to-string-list`, `normalize-link-value` и `merge-link-entries`.
   - В `resolve-effective-plan` собирать базовые ссылки модуля с `origin_rank: 0`, а ссылки каждого активного скоупа (в порядке `$active_scopes`) — с `origin_rank: 1..N` через `merge-link-entries` (так, чтобы переопределённый в скоупе ключ получал `origin_rank` скоупа и не зависел от позиции ключа в базовом `[links]`). Аналогично для `save`.
   - Разворачивать `spec.targets` в отдельные записи `$plan_links` / `$plan_save` с монотонным `key_order` и `module_rank`.
2. В `src/link.nu`:
   - Реализовать `normalize-case`, `link-literal-target`, `link-target-matches`, `swap-symlink-atomic` строго по контракту RFC-009.
   - Реализовать `create-windows-dir-link` по контракту RFC-006 (`mklink /J` → `mklink /D` → `cp -r` с `type: "dir_copy"`), а в `prune` и `unlink-module` обрабатывать записи с `type == "dir_copy"` через `backup-existing`.
   - Реализовать `resolve-link-targets`:
     - разворачивать глобы (`ls -a $src_path`, без `.` / `..` и `.git`) с `specificity: 0, is_glob_child: true, glob_dest_dir: $dest_dir`, а явные ссылки — с `specificity: 1, is_glob_child: false, glob_dest_dir: ""`;
     - сортировать кандидатов по `specificity`, `module_rank`, `origin_rank`, `key_order` и группировать по `normalize-case $dest`;
     - записывать межмодульные коллизии в `collisions` (выводя `[ygg] Collision: destination '($dest)' claimed by '($loser.module)' is overridden by '($winner.module)'` в `stderr` один раз на путь при `apply-links` или `compute-link-ops`);
     - проверять вложенность целей: если победитель с `is_dir == true` является родительским префиксом другого победителя (`($child_norm | str starts-with ($parent_norm + $sep))`), добавлять запись в `nesting_conflicts`.

- [ ] **Step 4: Запустить весь тестовый набор.**
Выполнить: `rtk just test`
Ожидается: `PASS`.

- [ ] **Step 5: Сделать коммит.**
Выполнить:
`rtk git add src/manifest.nu src/link.nu tests/test_manifest.nu tests/test_link.nu && rtk git commit -m "feat(link): implement 1-to-N links, priority resolution, atomic swap and junction fallback"`

---

### Task 5: Этап 2B — Единый план операций `compute-link-ops`, `ygg diff`, защита от затенения и полный `preflight-check` (`RFC-011`, `RFC-021`, `RFC-020`)

**Files:**
- Modify: `src/link.nu`
- Modify: `bin/ygg.nu`
- Test: `tests/test_link.nu`, `tests/test_cli_e2e.nu`

**Interfaces:**
- Produces in `src/link.nu`:
  - `def plan-copy-sync [state: record, module_name: string, src: string, dest: string, force: bool]: nothing -> record<op: string, detail: string, copy_record: record>`
  - `export def compute-link-ops [ygg_home: string, resolved: record, --force, --sandbox: string = ""]: nothing -> table<op: string, dest: string, src: string, module: string, key: string, detail: string>`
  - `def backup-with-notice [ygg_home: string, target: string]: nothing -> string`
  - `export def shadowed-files [dest: string, src: string]: nothing -> list<string>`
  - Полный `preflight-check` (включающий `missing_source`, `invalid_mode_source`, `nesting_conflict`, `ownership_conflict` с учётом `PRUNE` и `shadowed_files` при отсутствии `mode == "dir"` и `--force`).
  - `apply-links` возвращает `{ applied: list<string>, pruned: list<string>, copies: list<string>, failed: list<record<dest: string, src: string, module: string, stderr: string>> }` и выполняет `PRUNE` **первыми**.
- Produces in `bin/ygg.nu`:
  - `def "main apply" [--dry-run (-n), --force (-f), --all (-a), --skip-packages (-S), --sandbox: string = ""]`
  - `def "main diff" [--all (-a), --skip-packages (-S), --pkg: string = "", --sandbox: string = ""]`

- [ ] **Step 1: Написать падающие тесты.**
1. В `tests/test_link.nu`:
   - `test_compute_link_ops_and_prune_first_on_dir_to_glob_transition`:
     - модуль сначала линкует `"OpenRGB" = { target = "~/.config/OpenRGB", mode = "dir" }`, затем меняет манифест на `"OpenRGB/*" = "~/.config/OpenRGB/*"`;
     - повторный `apply-links` сначала выполняет `PRUNE` старого симлинка `~/.config/OpenRGB`, затем создаёт реальный каталог и симлинк `off.orp` без ошибки `ownership conflict`;
     - если же `~/.config/OpenRGB` — неуправляемый симлинк (отсутствует в `state.links`), `preflight-check` и `apply-links` возвращают ошибку `ownership_conflict`.
   - `test_shadowed_files_blocks_unconfirmed_dir_replacement`:
     - на хосте в `~/.config/OpenRGB` лежат `off.orp` и лишний runtime-файл `profile.orp` (и скрытый `.calib`);
     - обычная ссылка `"OpenRGB" = "~/.config/OpenRGB"` блокируется в `preflight-check` с `reason == "shadowed_files"`, каталог на хосте не тронут;
     - с `mode = "dir"` или `--force` проверка проходит с предупреждением в `stderr`, а старый каталог перемещается в `.state/backups/` с выводом `[ygg] Backed up existing ...`.
2. В `tests/test_cli_e2e.nu`:
   - `test_ygg_diff_and_dry_run_plan_output`:
     - `ygg diff` и `ygg apply --dry-run` выводят операции `LINK` / `BACKUP_REPLACE` и итоговую строку `Plan: <N> change(s), <M> unchanged across <K> module(s). No changes made.`;
     - при повторном `ygg diff` после `apply` `OK`-строки скрыты по умолчанию и видны с `ygg diff --all`;
     - снимок песочницы и `state.json` до и после `ygg diff` совпадает.

- [ ] **Step 2: Запустить новые тесты и убедиться в падении.**
Выполнить:
`rtk nu tests/run.nu --filter test_compute_link_ops_and_prune_first`
`rtk nu tests/run.nu --filter test_shadowed_files_blocks`
`rtk nu tests/run.nu --filter test_ygg_diff_and_dry_run`
Ожидается: `FAIL`.

- [ ] **Step 3: Реализовать `RFC-011`, `RFC-021` и полный `RFC-020`.**
1. В `src/link.nu`:
   - Добавить `backup-with-notice` и заменить все вызовы `backup-existing` в `link.nu` (включая `prune-copy` и `dir_copy`) на `backup-with-notice`.
   - Разделить `sync-single-file` на чистую функцию чтения `plan-copy-sync` и функцию исполнения `run-copy-sync`.
   - Реализовать `relative-files` (`glob --no-dir --no-symlink ($dir | path join "**" "*")`) и `export def shadowed-files [dest: string, src: string]: nothing -> list<string>`.
   - Реализовать `export def compute-link-ops`:
     - сначала формировать строки `PRUNE` для записей `state.links` и `state.copies`, отсутствующих в `resolved.targets` / `resolved.save_targets`;
     - затем классифицировать каждую цель `resolved.targets` (`OK`, `LINK`, `RELINK`, `BACKUP_REPLACE`, `COPY`, `CONFLICT`) и `resolved.save_targets` (`OK`, `COPY`, `CONFLICT`).
   - Расширить `preflight-check`:
     - проверка `missing_source` и `invalid_mode_source` (`link.mode == "dir"` при `($link.src_path | path type) != "dir"`);
     - проверка `resolved.nesting_conflicts`;
     - проверка `ownership_conflict`: для каждого уникального `glob_dest_dir` из `resolved.targets`, если `is-link-or-junction $glob_dest_dir` и этот путь не помечен операцией `PRUNE` в `ops`;
     - проверка `shadowed_files`: для целей с `is_dir == true` и операцией `BACKUP_REPLACE` на реальном каталоге (`($dest | path type) == "dir"` и `not (is-link-or-junction $dest)`), если `shadowed-files $dest $src` не пуст: без `mode == "dir"` и без `--force` добавлять ошибку `shadowed_files` (с перечислением до 20 файлов и 3 способов решения), а при `mode == "dir"` или `--force` — выводить предупреждение в `stderr`.
   - Переписать `apply-links` поверх `resolve-link-targets` и `compute-link-ops` (с выполнением `PRUNE` первыми, единым циклом по `targets`, вызовом `ensure-executable` для файлов в `bin/` в том числе при `OK` и сбором ошибок создания ссылок в `failed`).
2. В `bin/ygg.nu`:
   - В `main apply` вызывать `resolve-link-targets`, `compute-link-ops`, `preflight-check`; при `--dry-run` печатать таблицу запланированных операций (скрывая `OK`, если не передан `--all`), `PKG`-команды, `SETUP` и итоговую строку `Plan: ($changes) change\(s\), ($unchanged) unchanged across ($mod_count) module\(s\). No changes made.`.
   - Добавить `def "main diff"`.

- [ ] **Step 4: Запустить весь тестовый набор.**
Выполнить: `rtk just test`
Ожидается: `PASS`.

- [ ] **Step 5: Сделать коммит.**
Выполнить:
`rtk git add src/link.nu bin/ygg.nu tests/test_link.nu tests/test_cli_e2e.nu && rtk git commit -m "feat(link,cli): unify compute-link-ops, add ygg diff and directory shadowing guard"`

---

### Task 6: Этап 2C — `ygg add --dry-run` / `--force` и SDK `safe-link` (`RFC-012`, `RFC-023`)

**Files:**
- Modify: `src/manifest.nu:259-275` (`--extra-modules` в `resolve-effective-plan`)
- Modify: `src/git.nu:8-115` (`add-module` с `--dry-run` и `--force`, защита от удаления грязного модуля)
- Modify: `src/sdk.nu` (`export def safe-link`)
- Modify: `bin/ygg.nu:18-23,66-101,217-228` (`main add` и `main safe-link`)
- Test: `tests/test_pkg_git.nu`, `tests/test_sdk.nu`, `tests/test_cli_e2e.nu`

**Interfaces:**
- Updates in `src/manifest.nu`:
  - `export def resolve-effective-plan [ygg_home: string, --modules-filter: list<string> = [], --extra-modules: list<record> = []]: nothing -> record`
- Updates in `src/git.nu`:
  - `export def add-module [ygg_home: string, source: string, --scopes: list<string> = [], --dry-run, --force]: nothing -> record<name: string, path: string, scopes: list<string>, tmp_clone: string>`
- Produces in `src/sdk.nu`:
  - `export def safe-link [src: string, dest: string]: nothing -> nothing`
- Produces in `bin/ygg.nu`:
  - `def "main safe-link" [src: string, dest: string]`

- [ ] **Step 1: Написать падающие тесты.**
1. В `tests/test_pkg_git.nu` — `test_add_module_dirty_guard_and_dry_run_clone_cleanup`:
   - повторный `add-module` поверх клонированного модуля с незакоммиченными изменениями бросает ошибку `uncommitted changes` без `--force` и проходит с `--force`;
   - `add-module --dry-run` для локального bare-репозитория возвращает `tmp_clone`, не меняет `host.toml` и не создаёт `modules/<name>`.
2. В `tests/test_cli_e2e.nu` — `test_cli_add_dry_run_and_preflight_rollback`:
   - `ygg add <path> --dry-run` показывает план (`LINK`), но `host.toml`, `modules/` и sandbox остаются неизменными;
   - `ygg add <bad_mod>` с отсутствующим источником ссылки падает на `preflight-check`, а `host.toml` и `modules/` остаются чистыми (модуль не регистрируется).
3. В `tests/test_sdk.nu` — `test_safe_link_backs_up_real_dir_and_preserves_relative_src`:
   - если `dest` — реальный каталог с файлом, `safe-link "../../plugins" "~/.hermes/profiles/coder/plugins"` перемещает каталог в `.state/backups/` (с уведомлением) и создаёт симлинк с буквальной относительной целью `../../plugins` (а не ссылку внутри каталога);
   - повторный вызов не меняет inode;
   - отсутствующий источник бросает ошибку;
   - при `YGG_DRY_RUN=true` файловая система не меняется;
   - статическая проверка: `open --raw ($env.FILE_PWD | path join "../src/sdk.nu")` не содержит `rm -rf`.

- [ ] **Step 2: Запустить новые тесты и убедиться в падении.**
Выполнить:
`rtk nu tests/run.nu --filter test_add_module_dirty_guard`
`rtk nu tests/run.nu --filter test_cli_add_dry_run`
`rtk nu tests/run.nu --filter test_safe_link_`
Ожидается: `FAIL`.

- [ ] **Step 3: Реализовать `RFC-012` и `RFC-023`.**
1. В `src/manifest.nu`: добавить `--extra-modules: list<record> = []` в `resolve-effective-plan`. Если в `$extra_modules` есть запись с тем же `name`, что в `host.toml`, она замещает запись из `host.toml` (или добавляется в конец).
2. В `src/git.nu` и `bin/ygg.nu`:
   - В `add-module` проверять незакоммиченные изменения существующего реального каталога `$mod_dest` (как в `remove-module`) и без `--force` бросать ошибку.
   - При `--dry-run` (или на этапе подготовки до `preflight-check` в `main add`) не модифицировать `modules/<name>` и `host.toml`, возвращая `{ name: $manifest.name, path: $staging_path, scopes: $scopes, tmp_clone: $tmp_clone }`.
   - В `main add` сначала вызывать `add-module --dry-run` (или стадию подготовки), строить эффективный план с `--extra-modules [{ name: $prep.name, path: $prep.path, scopes: $all_scopes }]` и запускать `preflight-check` (всегда убирая `$prep.tmp_clone` в `catch`). При `--dry-run` выводить план `main apply --dry-run` с этим виртуальным модулем и удалять `$prep.tmp_clone`; при реальном запуске после успешного `preflight-check` завершать регистрацию в `modules/` и `host.toml` и вызывать `main apply`.
3. В `src/sdk.nu` и `bin/ygg.nu`:
   - Экспортировать из `src/link.nu` нужные хелперы (`link-target-matches`, `swap-symlink-atomic`, `create-windows-dir-link`, `backup-with-notice`) и реализовать `export def safe-link [src: string, dest: string]` строго по контракту RFC-023.
   - Добавить `def "main safe-link" [src: string, dest: string]` в `bin/ygg.nu`.

- [ ] **Step 4: Запустить весь тестовый набор.**
Выполнить: `rtk just test`
Ожидается: `PASS`.

- [ ] **Step 5: Сделать коммит.**
Выполнить:
`rtk git add src/manifest.nu src/git.nu src/link.nu src/sdk.nu bin/ygg.nu tests/test_pkg_git.nu tests/test_sdk.nu tests/test_cli_e2e.nu && rtk git commit -m "feat(git,sdk): add dry-run/force to ygg add and implement safe-link helper"`

---

### Task 7: Этап 3 — Пакетный движок (`RFC-022`, `RFC-005`, `RFC-013`, `RFC-014`)

**Files:**
- Modify: `src/pkg.nu`
- Modify: `bin/ygg.nu`
- Test: `tests/test_pkg_git.nu`, `tests/test_cli_e2e.nu`

**Interfaces:**
- Produces in `src/pkg.nu`:
  - `const WINGET_OK_CODES = [0, -1978335135, -1978335189]`
  - `def pkg-argv-list [mgr: string, pkgs: list<string>]: nothing -> list<list<string>>`
  - `def kill-job-tree [jid: int]: nothing -> nothing`
  - `export def run-with-timeout [argv: list<string>, timeout_sec: int]: nothing -> record`
  - `def missing-native-pkgs [pkgs: list<string>]: nothing -> list<string>`
  - `def sudo-available []: nothing -> bool`
  - `def pkg-set-hash [pkgs: list<string>]: nothing -> string`
  - `export def install-packages` (поддерживает вызов как `install-packages $ygg_home $plan ...`, так и `install-packages $plan ...` через `get-ygg-home` для обратной совместимости с существующими юнит-тестами; флаги `--dry-run`, `--skip-packages (-S)`, `--pkg: string = ""`, `--pkg-timeout: int = -1`, `--refresh-packages`, `--sandbox: string = ""`).
- Updates in `bin/ygg.nu`:
  - Флаги `--pkg: string = ""`, `--pkg-timeout: int = -1`, `--refresh-packages` в `main apply` (и `--pkg` в `main add`, `main diff`).

- [ ] **Step 1: Написать падающие тесты.**
В `tests/test_pkg_git.nu` добавить:
1. `test_pacman_precheck_and_noninteractive_sudo_guard` (RFC-022):
   - при `YGG_MOCK_PKG_INSTALLED="curl,git"` и пакетах `["curl", "git"]` `pacman` не вызывается вовсе (лог пуст);
   - при `YGG_MOCK_PKG_INSTALLED="curl"` и пакетах `["curl", "ripgrep"]` в лог пишется только `sudo pacman -S --needed --noconfirm ripgrep`;
   - при `YGG_MOCK_SUDO_DENIED="1"` для `pacman` команда не вызывается, а `res.failed` содержит запись `{ mgr: "pacman", pkg: "ripgrep", reason: "sudo_required", ... }`.
2. `test_per_package_providers_and_isolated_failure` (RFC-005):
   - для `winget`, `scoop` и `uv` с 2 пакетами в лог пишутся 2 отдельные команды (для `winget` — с `--disable-interactivity`);
   - при `YGG_MOCK_PKG_FAIL="winget:Bad.Pkg"` первый пакет падает в `res.failed` (`pkg: "Bad.Pkg", reason: "error"`), а второй пакет `Good.Pkg` успешно записывается в лог.
3. `test_pkg_filter_mise_trust_and_timeout_kills_child_tree` (RFC-013):
   - `--pkg mise` выполняет только `mise` (с предварительной строкой `mise trust --yes` для существующего `~/.config/mise/config.toml` в sandbox);
   - одновременная передача `--pkg mise --skip-packages` бросает ошибку;
   - `run-with-timeout ["nu", "-c", "^sleep 30"] 1` завершается с `timed_out == true` и `exit_code == 124`, дочерний процесс `sleep 30` убит, а следующий вызов `run-with-timeout ["nu", "-c", "print ok"] 5` возвращает `"ok"` (не получая устаревшее сообщение от первого задания).
4. `test_package_set_hash_cache_and_refresh` (RFC-014):
   - для кэшируемого менеджера (`cargo` / `mise` / `winget`) первый запуск пишет команду в лог и сохраняет `state.hashes."pkg:<mgr>"`;
   - второй запуск с тем же планом пропускает менеджер (`res.skipped` содержит `<mgr>`, лог пуст);
   - запуск с `--refresh-packages` или `--pkg <mgr>` либо после добавления нового пакета в манифест снова выполняет установку;
   - сбой установки не сохраняет хеш в `state.hashes`.

- [ ] **Step 2: Запустить новые тесты и убедиться в падении.**
Выполнить:
`rtk nu tests/run.nu --filter test_pacman_precheck`
`rtk nu tests/run.nu --filter test_per_package_providers`
`rtk nu tests/run.nu --filter test_pkg_filter_mise_trust`
`rtk nu tests/run.nu --filter test_package_set_hash_cache`
Ожидается: `FAIL`.

- [ ] **Step 3: Реализовать `RFC-022`, `RFC-005`, `RFC-013`, `RFC-014`.**
1. В `src/pkg.nu`:
   - Реализовать `kill-job-tree` (извлекая `pids` из `job list | where id == $jid` строго до `job kill $jid`) и `export def run-with-timeout`.
   - Реализовать `missing-native-pkgs` (с поддержкой `$env.YGG_MOCK_PKG_INSTALLED`) и `sudo-available` (с поддержкой `$env.YGG_MOCK_SUDO_DENIED`).
   - Реализовать `pkg-argv-list`, `default-pkg-timeout` (`winget`, `scoop`, `uv`, `mise`, `pnpm` → `300`; `cargo`, `paru`, `pacman` → `0`), `prepare-provider-environment` (`mise trust --yes` для существующих `~/.config/mise/config.toml` и `config.local.toml`).
   - Реализовать кэш `pkg-set-hash` в `state.hashes` для менеджеров кроме `pacman` и `paru` (проверять до запуска, записывать только если по менеджеру не было ни одного сбоя/таймаута, не `dry_run` и не sandbox без mock-лога; обходить при `--refresh-packages` или явном `--pkg`).
2. В `bin/ygg.nu`:
   - Пробросить `--pkg`, `--pkg-timeout`, `--refresh-packages` в `main apply`, `main add`, `main diff`; выводить имена сбойных пакетов из `$pkg_res.failed` в итоговом сообщении об ошибке.

- [ ] **Step 4: Запустить весь тестовый набор.**
Выполнить: `rtk just test`
Ожидается: `PASS`.

- [ ] **Step 5: Сделать коммит.**
Выполнить:
`rtk git add src/pkg.nu bin/ygg.nu tests/test_pkg_git.nu tests/test_cli_e2e.nu && rtk git commit -m "feat(pkg): add pre-sudo check, per-package argv runner, tree timeout and hash cache"`

---

### Task 8: Этап 4 — Расширенный `ygg status`, нелокальные тома, `ygg doctor` и хуки `on_change` (`RFC-004`, `RFC-025`, `RFC-017`, `RFC-015`)

**Files:**
- Modify: `src/git.nu:38-45,223-276`
- Modify: `src/manifest.nu:87-100` (сохранять поле `doctor: ($raw.doctor? | default {})` в `load-module-manifest`)
- Create: `src/doctor.nu`
- Modify: `src/mod.nu` (добавить `export use doctor.nu *`)
- Modify: `src/sdk.nu` (`hash-watch-set` и `run-link-hooks`)
- Modify: `bin/ygg.nu` (`main status --json`, `main doctor [--json] [--sandbox]`, вызов `run-link-hooks` в `main apply`)
- Modify: `docs/specs/2026-11-07-modular-omni-architecture-design.md:41`
- Create: `tests/test_doctor.nu`
- Test: `tests/test_pkg_git.nu`, `tests/test_sdk.nu`, `tests/test_cli_e2e.nu`, `tests/test_doctor.nu`

**Interfaces:**
- Updates in `src/git.nu`:
  - `modules-status` возвращает колонки `name`, `scopes`, `path`, `target`, `branch`, `dirty`, `links_ok`, `sync_conflicts`, `pending_save`.
  - `warn-if-not-canonicalizable [path: string]` и проверка кода выхода `mklink /J` в `add-module`.
- Produces in `src/doctor.nu`:
  - `export def run-doctor [ygg_home: string, --sandbox: string = ""]: nothing -> table<check: string, severity: string, target: string, detail: string, fix: string>`
- Produces in `src/sdk.nu`:
  - `export def hash-watch-set [watch_globs: list<string>, base_dir: string]: nothing -> string`
  - `export def run-link-hooks [ygg_home: string, targets: table, ops: table, --dry-run, --force, --sandbox: string = ""]: nothing -> list<record<module: string, keys: list<string>, cmd: string, status: string, stderr: string>>`

- [ ] **Step 1: Написать падающие тесты.**
1. В `tests/test_pkg_git.nu`:
   - `test_modules_status_columns_and_accurate_links_ok`: проверяет `target` (разрешённый симлинк модуля), `sync_conflicts`, `pending_save`, а также `links_ok == false`, когда симлинк битый или заменён обычным файлом.
   - `test_add_module_warns_on_non_canonicalizable_volume`: при `YGG_MOCK_NO_CANONICALIZE="1"` `add-module` выводит предупреждение о томе без канонизации и регистрирует модуль.
2. В `tests/test_doctor.nu` (новый файл):
   - Тесты на проверки `run-doctor`: `link` (битая ссылка / файл на месте ссылки → `error`), `link_pending` (`warn`), `orphan_link` (`warn`), `state_orphan` (`warn`), `sync` (`warn`), `perm` (файл из `[doctor] private_files` или `secrets.toml` с правами `0644` → `error`), `collision` (`warn`), `shadow` (лишний файл в последнем `.state/backups/<ts>/...` → `warn`), `secrets` (`warn`), `canonical` (`YGG_MOCK_NO_CANONICALIZE="1"` → `warn`).
   - Проверка неизменности снимка файловой системы до и после `run-doctor` и кодов выхода CLI `ygg doctor` (`1` при `error`, `0` при только `warn`, валидный JSON при `--json`).
   - Статическая проверка чистоты ядра: `src/doctor.nu` не содержит подстрок `chezmoi` и `sops`.
3. В `tests/test_sdk.nu`:
   - `test_run_link_hooks_lifecycle_dedup_and_failure_recovery`:
     - хук `on_change` срабатывает при первом запуске (пишет `hook: <cmd>` в `YGG_MOCK_PKG_LOG` и сохраняет `state.hashes."on_change:<mod>:<key>"`);
     - повторный запуск без изменений не вызывает хук;
     - одинаковая команда `on_change` на двух ключах выполняется ровно один раз за `apply`, обновляя хеши обоих ключей;
     - при сбое команды хука `apply` не падает (выводится предупреждение), хеш не обновляется, и следующий запуск повторяет хук;
     - исключённая через `exclude` ссылка не запускает свой хук.
4. В `tests/test_cli_e2e.nu`:
   - `test_status_json_output_in_pipe`: `^nu $ygg_bin status --json | complete` разбирается через `from json` и содержит все 9 колонок.

- [ ] **Step 2: Запустить новые тесты и убедиться в падении.**
Выполнить:
`rtk nu tests/run.nu --filter test_modules_status_columns`
`rtk nu tests/run.nu --filter test_doctor`
`rtk nu tests/run.nu --filter test_run_link_hooks`
`rtk nu tests/run.nu --filter test_status_json_output`
Ожидается: `FAIL`.

- [ ] **Step 3: Реализовать `RFC-004`, `RFC-025`, `RFC-017`, `RFC-015`.**
1. В `src/git.nu`:
   - В `add-module` проверять `exit_code` вызова `^cmd /c mklink /J` и вызывать `warn-if-not-canonicalizable $source`.
   - В `modules-status` добавить вычисление `target`, `sync_conflicts`, `pending_save` и обновить проверку `links_ok` через `link-target-matches $dest $entry.src and ($dest | path exists)` для симлинков/Junction и `($dest | path exists)` для `copy` / `dir_copy`.
2. В `docs/specs/2026-11-07-modular-omni-architecture-design.md:41`: уточнить формулировку «на любом локальном NTFS-томе» согласно RFC-025 п. 5.
3. В `src/manifest.nu`: добавить `doctor: ($raw.doctor? | default {})` в возвращаемую запись `load-module-manifest`.
4. Создать `src/doctor.nu` с функцией `export def run-doctor` (реализующей все 11 проверок таблицы RFC-017 строго в режиме чтения) и подключить `export use doctor.nu *` в `src/mod.nu`.
5. В `src/sdk.nu`: выделить `export def hash-watch-set` из `onchange` и реализовать `export def run-link-hooks` с вызовом `run-with-timeout ["nu", "-c", $cmd] 30` из `src/pkg.nu`.
6. В `bin/ygg.nu`:
   - Добавить `--json` в `main status` и подкоманду `def "main doctor" [--json, --sandbox: string = ""]`.
   - В `main apply` после цикла `run-module-setup` вызывать `run-link-hooks` (а при `--dry-run` включать строки `HOOK` в отчёт плана).

- [ ] **Step 4: Запустить весь тестовый набор и Stage 2 E2E.**
Выполнить:
`rtk just test`
`rtk nu tests/test_phase2_modules.nu`
Ожидается: `PASS` по всем юнит-, интеграционным и Stage 2 тестам.

- [ ] **Step 5: Обновить статус в спецификации и сделать коммит.**
В `docs/specs/2026-11-08-ygg-engine-improvements-and-hardening.md` обновить строку статуса на `Реализовано (Linux; пункты Windows/macOS ожидают проверки на целевых ОС)`.
Выполнить:
`rtk git add src/ bin/ tests/ docs/specs/ docs/plans/ && rtk git commit -m "feat(doctor,sdk,status): add ygg doctor, link on_change hooks, status JSON and canonical checks"`
