# План реализации Фазы 3: Отказоустойчивость, Экосистема и Безопасность движка `ygg` (RFC-026 — RFC-040)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Реализовать спецификацию Фазы 3 (`RFC-026` — `RFC-040`): устранить гонки и неатомарность хоста, внедрить кроссплатформенный CI, расширить пакетные провайдеры (macOS Homebrew, Linux `apt`/`dnf`), добавить граф зависимостей модулей (`depends_on`), воспроизводимый `ygg.lock`, внешние секреты, декларативные сервисы и режим `doctor --fix`.

**Architecture:** Поэтапное расширение модулей `src/{state,manifest,link,pkg,env,sdk,git,doctor}.nu`, добавление кроссплатформенной CI-матрицы в `.github/workflows/ci.yml` и обновление CLI-роутера `bin/ygg.nu`. Каждая задача выполняется по строгому TDD-циклу: написание падающего теста в изолированной песочнице `/tmp/ygg-test-*`, проверка его падения, минимальная реализация по контракту спецификации, прогон регрессионного набора `rtk just test` и атомарный коммит по правилам Conventional Commits.

**Tech Stack:** Nushell `>= 0.116.1`, TOML, Git, GitHub Actions, `just`, `rtk`.

**Spec:** [`docs/specs/2026-11-08-ygg-phase3-resilience-and-ecosystem.md`](../specs/2026-11-08-ygg-phase3-resilience-and-ecosystem.md) и базовая спецификация улучшений ядра [`docs/specs/2026-11-08-ygg-engine-improvements-and-hardening.md`](../specs/2026-11-08-ygg-engine-improvements-and-hardening.md). При любых разночтениях спецификация приоритетнее плана.

## Global Constraints

- **Рабочая директория:** строго репозиторий `ygg` (`/home/gidragir/projects/ygg`).
- **ZERO HOST MUTATION:** Ни один тест и ни один отладочный запуск не имеют права модифицировать реальные `~/.ygg`, `~/.config` или `$HOME`. Все тесты выполняются строго внутри изолированных временных каталогов `/tmp/ygg-test-*` с явно заданными `YGG_HOME`, `YGG_SANDBOX` и `YGG_MOCK_PKG_LOG`.
- **Чистота ядра от личных репозиториев:** В коде `src/*.nu` и `bin/*` категорически запрещены захардкоженные пути разработчика (`/data/projects/...`) и имена персональных модулей (`omni-dotfiles`, `ai-dotfiles`).
- **Zero-Data-Loss:** Физические файлы и каталоги при замене или удалении всегда архивируются в `$YGG_HOME/.state/backups/<timestamp>/` через `backup-with-notice`.
- **Терминал и утилиты:** Все команды в терминале выполняются с префиксом `rtk`. Поиск кода и файлов строго через `rtk fd` и `rtk rg` (без флага `-E`). GNU `find` и `grep` запрещены.
- **Идиомы Nushell 0.116+ (`.agents/skills/nushell-ygg-dev/SKILL.md`):**
  - Использовать `get -o` (не устаревший `get -i`).
  - В замыканиях `where` явно объявлять параметр: `where { |it| ... }`.
  - Для внешних команд использовать `| complete` (не `do -i`).
  - Строки с квадратными скобками собирать конкатенацией через `+`, а не через `$"..."`.
- **Коммиты:** Строго через локальный `rtk oco -y` (Conventional Commits на английском языке).

## Review Focus

1. **Изоляция и самовосстановление блокировки (`RFC-026`):** При аварийном падении предыдущего процесса `ygg` с сохранением `ygg.lock` следующий запуск обязан проверить PID через `kill -0` (Unix) или `tasklist` (Win), признать блокировку устаревшей (stale), перехватить её с предупреждением и успешно выполнить операцию.
2. **Crash-восстановление по журналу (`RFC-027`):** Прерывание `apply` на шаге `setup.nu` оставляет `.state/journal.json`; повторный вызов `apply` или `doctor` не должен оставлять хост в рассинхронизированном состоянии.
3. **Строгая топологическая сортировка DAG (`RFC-031`):** Наличие зависимостей `C -> B -> A` гарантирует запуск `setup.nu` строго в порядке `A -> B -> C`. При наличии цикла `A -> B -> A` или отсутствующего модуля операция прерывается до вызова пакетных менеджеров и создания ссылок.
4. **Непрерывность работы без TTY и на сторонних дистрибутивах (`RFC-029`):** На Ubuntu/Debian/Fedora вызовы пакетных менеджеров транслируются в `apt-get` / `dnf`, а на macOS — в `brew install` без интерактивных зависаний.
5. **Безопасность внешних секретов (`RFC-034`):** Расшифровка секретов схем `op://`, `bw://`, `pass:`, `eval:` выполняется strictly in-memory и никогда не сбрасывает плейнтекст на диск в постоянные файлы `.state/env/*`.

---

## Этап 3.1: Инфраструктура и P0 Безопасность

### Task 1: Изоляция тестов ядра и кроссплатформенный конвейер CI (RFC-040)

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `tests/test_phase2_modules.nu:7-45,456-498`
- Modify: `tests/run.nu:4-35`
- Test: `tests/run.nu`

**Interfaces:**
- Consumes: существующий раннер тестов `tests/run.nu`.
- Produces: изолированный прогон тестов без зависимости от `/data/projects` и рабочий GitHub Actions workflow для `ubuntu-latest`, `windows-latest`, `macos-latest`.

- [ ] **Step 1: Оградить `tests/test_phase2_modules.nu` проверкой окружения.**
В начале `tests/test_phase2_modules.nu` внедрить проверку: если путь `/data/projects/worktree/ygg-phase2` не существует или не выставлен `YGG_RUN_HOST_E2E=1`, выводить информативное сообщение и завершать выполнение с кодом 0 (`SKIP`).
- [ ] **Step 2: Проверить запуск `tests/run.nu`.**
Выполнить: `rtk nu tests/run.nu`
Ожидается: 100% PASS, отсутствие ошибок поиска внешних репозиториев.
- [ ] **Step 3: Создать `.github/workflows/ci.yml`.**
Создать файл с матрицей тестирования на Linux, Windows и macOS с установкой `just` и `nushell`.
- [ ] **Step 4: Проверить валидность синтаксиса CI workflow.**
Выполнить: `rtk git status`
- [ ] **Step 5: Закоммитить изменения.**
Выполнить: `rtk git add tests/test_phase2_modules.nu .github/workflows/ci.yml tests/run.nu && rtk oco -y`

---

### Task 2: Кроссплатформенная межпроцессная блокировка хоста (RFC-026)

**Files:**
- Modify: `src/state.nu`
- Modify: `bin/ygg.nu`
- Test: `tests/test_state.nu`

**Interfaces:**
- Produces in `src/state.nu`:
  - `export def acquire-host-lock [ygg_home: string, command: string, --no-lock: bool = false]: nothing -> string`
  - `export def release-host-lock [lock_file: string]: nothing -> nothing`
  - `def check-process-alive [pid: int]: nothing -> bool`
- Consumes in `bin/ygg.nu`:
  - Вызов `acquire-host-lock` в начале мутирующих команд (`apply`, `add`, `remove`, `update`, `save`, `clean`) и гарантированное освобождение в блоке `try ... catch`.

- [ ] **Step 1: Написать падающий тест для блокировки хоста в `tests/test_state.nu`.**
```nushell
export def test_host_lock_prevents_concurrent_runs_and_cleans_stale [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let lock_file = (acquire-host-lock $home "apply")
        assert ($lock_file | path exists) "Lock file must be created"
        # Попытка захватить блокировку вторым процессом с живым PID должна падать
        let res = (try { acquire-host-lock $home "add" } catch { |e| { err: $e.msg } })
        assert ($res.err? != null) "Expected lock conflict error"
        release-host-lock $lock_file
        assert (not ($lock_file | path exists)) "Lock file must be removed"
    }
}
```
- [ ] **Step 2: Запустить тест и убедиться в падении.**
Выполнить: `rtk nu tests/run.nu --filter test_host_lock`
Ожидается: FAIL с "command not found: acquire-host-lock".
- [ ] **Step 3: Реализовать функции блокировки в `src/state.nu` и обернуть команды в `bin/ygg.nu`.**
Реализовать создание `$YGG_HOME/.state/ygg.lock` с проверкой `check-process-alive` (`kill -0` на Unix и `tasklist` на Windows) и снятием зависших блокировок. В `bin/ygg.nu` добавить флаг `--no-lock` и вызовы блокировки.
- [ ] **Step 4: Запустить тесты и убедиться в прохождении.**
Выполнить: `rtk nu tests/run.nu --filter test_host_lock`
Ожидается: PASS.
- [ ] **Step 5: Закоммитить изменения.**
Выполнить: `rtk git add src/state.nu bin/ygg.nu tests/test_state.nu && rtk oco -y`

---

### Task 3: Пакетные провайдеры Homebrew (macOS) и дистрибутивы Linux (RFC-029)

**Files:**
- Modify: `src/pkg.nu`
- Modify: `src/state.nu`
- Test: `tests/test_pkg_git.nu`

**Interfaces:**
- Updates in `src/pkg.nu`:
  - `allowed-package-managers`: возвращает `["brew", ...]` для `macos`, `["apt", ...]` для `debian`/`ubuntu`, `["dnf", ...]` для `fedora`/`rhel`.
  - `pkg-argv-list`: генерация `[brew install ...$pkgs]`, `[sudo apt-get install -y --no-install-recommends ...$pkgs]`, `[sudo dnf install -y ...$pkgs]`.
  - `default-pkg-timeout`: 300 с для `brew`, `apt`, `dnf`.

- [ ] **Step 1: Написать падающий тест для Homebrew и Linux дистрибутивов в `tests/test_pkg_git.nu`.**
```nushell
export def test_package_providers_macos_and_linux_distros [] {
    with-env { YGG_MOCK_PKG_LOG: "/tmp/mock.log", YGG_HOST_OS_OVERRIDE: "macos" } {
        let plan = { packages: { brew: ["ripgrep", "fd"] } }
        let res = (install-packages "/tmp" $plan --dry-run)
        assert ($res.executed | any { |c| $c =~ "brew install ripgrep fd" }) "Expected brew install"
    }
    with-env { YGG_MOCK_PKG_LOG: "/tmp/mock.log", YGG_HOST_OS_OVERRIDE: "ubuntu" } {
        let plan = { packages: { apt: ["curl", "git"] } }
        let res = (install-packages "/tmp" $plan --dry-run)
        assert ($res.executed | any { |c| $c =~ "apt-get install" }) "Expected apt-get install"
    }
}
```
- [ ] **Step 2: Запустить тест и убедиться в падении.**
Выполнить: `rtk nu tests/run.nu --filter test_package_providers_macos_and_linux_distros`
Ожидается: FAIL.
- [ ] **Step 3: Реализовать провайдеры `brew`, `apt`, `dnf`, `zypper` в `src/pkg.nu`.**
Обновить функции `allowed-package-managers`, `pkg-argv-list`, `default-pkg-timeout`.
- [ ] **Step 4: Запустить тесты и убедиться в прохождении.**
Выполнить: `rtk nu tests/run.nu --filter test_package_providers_macos_and_linux_distros`
Ожидается: PASS.
- [ ] **Step 5: Закоммитить изменения.**
Выполнить: `rtk git add src/pkg.nu src/state.nu tests/test_pkg_git.nu && rtk oco -y`

---

## Этап 3.2: Надежность данных, транзакции и аудит безопасности

### Task 4: Транзакционный журнал (WAL) и восстановление после сбоев (RFC-027)

**Files:**
- Modify: `src/state.nu`
- Modify: `bin/ygg.nu`
- Modify: `src/doctor.nu`
- Test: `tests/test_state.nu`, `tests/test_doctor.nu`

**Interfaces:**
- Produces in `src/state.nu`:
  - `export def begin-journal-transaction [ygg_home: string, plan: record]: nothing -> string`
  - `export def record-journal-step [ygg_home: string, step_name: string, status: string]: nothing -> nothing`
  - `export def commit-journal-transaction [ygg_home: string]: nothing -> nothing`
  - `export def check-pending-journal [ygg_home: string]: nothing -> record`
- Updates in `src/doctor.nu`:
  - Проверка `journal`: возвращает `finding "journal_incomplete" "error"` при наличии незавершенного `.state/journal.json`.

- [ ] **Step 1: Написать падающий тест для журнала в `tests/test_state.nu` и `tests/test_doctor.nu`.**
```nushell
export def test_journal_transaction_lifecycle_and_doctor_detection [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        begin-journal-transaction $home { modules: ["m1"] }
        record-journal-step $home "links" "IN_PROGRESS"
        let status = (check-pending-journal $home)
        assert ($status.incomplete == true) "Expected incomplete journal"
        commit-journal-transaction $home
        assert (not ($home | path join ".state" "journal.json" | path exists)) "Journal must be deleted on commit"
    }
}
```
- [ ] **Step 2: Запустить тест и проверить падение.**
Выполнить: `rtk nu tests/run.nu --filter test_journal_transaction`
Ожидается: FAIL.
- [ ] **Step 3: Реализовать транзакционный журнал в `src/state.nu`, `bin/ygg.nu` и проверку в `src/doctor.nu`.**
- [ ] **Step 4: Запустить тесты и убедиться в прохождении.**
Выполнить: `rtk nu tests/run.nu --filter test_journal_transaction`
Ожидается: PASS.
- [ ] **Step 5: Закоммитить изменения.**
Выполнить: `rtk git add src/state.nu bin/ygg.nu src/doctor.nu tests/test_state.nu tests/test_doctor.nu && rtk oco -y`

---

### Task 5: Ротация бэкапов и сборщик мусора стейта (RFC-028)

**Files:**
- Modify: `src/state.nu`
- Modify: `bin/ygg.nu`
- Test: `tests/test_state.nu`, `tests/test_cli_e2e.nu`

**Interfaces:**
- Produces in `src/state.nu`:
  - `export def rotate-backups [ygg_home: string, --max-count: int = 20, --max-age-days: int = 30]: nothing -> list<string>`
  - `export def gc-state-hashes [ygg_home: string, active_keys: list<string>]: nothing -> int`
- Produces in `bin/ygg.nu`:
  - Подкоманда `ygg clean [--backups] [--hashes] [--dry-run]`

- [ ] **Step 1: Написать падающий тест для ротации бэкапов и GC хэшей в `tests/test_state.nu`.**
```nushell
export def test_rotate_backups_and_gc_state_hashes [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        # Создаем 25 фиктивных каталогов бэкапов
        for i in 1..25 {
            mkdir ($home | path join ".state" "backups" $"2026110($i)_120000_000000")
        }
        let removed = (rotate-backups $home --max-count 20)
        assert (($removed | length) == 5) "Expected 5 old backups rotated"
        
        # Проверяем GC хэшей
        save-state $home { links: {}, copies: {}, hashes: { keep_me: "hash1", orphan_me: "hash2" } }
        let purged = (gc-state-hashes $home ["keep_me"])
        assert ($purged == 1) "Expected 1 orphan hash removed"
        let st = (load-state $home)
        assert ("orphan_me" not-in ($st.hashes | columns)) "Orphan hash must be purged"
    }
}
```
- [ ] **Step 2: Запустить тест и проверить падение.**
Выполнить: `rtk nu tests/run.nu --filter test_rotate_backups_and_gc_state_hashes`
Ожидается: FAIL.
- [ ] **Step 3: Реализовать `rotate-backups` и `gc-state-hashes` в `src/state.nu`, интегрировать в `apply-plan` и добавить команду `ygg clean`.**
- [ ] **Step 4: Запустить тесты и убедиться в прохождении.**
Выполнить: `rtk nu tests/run.nu --filter test_rotate_backups_and_gc_state_hashes`
Ожидается: PASS.
- [ ] **Step 5: Закоммитить изменения.**
Выполнить: `rtk git add src/state.nu bin/ygg.nu tests/test_state.nu tests/test_cli_e2e.nu && rtk oco -y`

---

### Task 6: Аудит безопасности прав доступа и ACL на Windows (RFC-035)

**Files:**
- Modify: `src/doctor.nu`
- Test: `tests/test_doctor.nu`

**Interfaces:**
- Updates in `src/doctor.nu`:
  - `check-perms`: на Windows вызывает `icacls` для проверки `$YGG_HOME/secrets.toml`, `.state/env/env.ps1` и файлов из `private_files`; генерирует `finding "perm" "error"` при наличии прав чтения у `Users`/`Everyone`.

- [ ] **Step 1: Написать падающий тест для Windows ACL в `tests/test_doctor.nu`.**
```nushell
export def test_doctor_windows_acl_audit_generates_perm_error [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        "" | save -f ($home | path join "secrets.toml")
        with-env { YGG_MOCK_WINDOWS_INSECURE_ACL: "1", YGG_HOST_OS_OVERRIDE: "windows" } {
            let res = (check-perms $home { modules: [] } "")
            assert ($res | any { |f| ($f.check == "perm") and ($f.severity == "error") }) "Expected Windows ACL perm finding"
        }
    }
}
```
- [ ] **Step 2: Запустить тест и проверить падение.**
Выполнить: `rtk nu tests/run.nu --filter test_doctor_windows_acl_audit`
Ожидается: FAIL.
- [ ] **Step 3: Реализовать парсер ACL `icacls` в `src/doctor.nu` с мок-гардом для кроссплатформенных тестов.**
- [ ] **Step 4: Запустить тесты и убедиться в прохождении.**
Выполнить: `rtk nu tests/run.nu --filter test_doctor_windows_acl_audit`
Ожидается: PASS.
- [ ] **Step 5: Закоммитить изменения.**
Выполнить: `rtk git add src/doctor.nu tests/test_doctor.nu && rtk oco -y`

---

## Этап 3.3: Модель оркестрации, воспроизводимость и скоупы

### Task 7: Декларативные зависимости модулей `depends_on` и топологический DAG (RFC-031)

**Files:**
- Modify: `src/manifest.nu`
- Modify: `src/link.nu`
- Modify: `bin/ygg.nu`
- Test: `tests/test_manifest.nu`

**Interfaces:**
- Produces in `src/manifest.nu`:
  - `def sort-modules-dag [modules: list<record>]: nothing -> list<record>`
- Updates in `src/link.nu`:
  - `preflight-check`: проверяет наличие всех модулей из `depends_on` в активном плане и отсутствие циклических зависимостей.

- [ ] **Step 1: Написать падающий тест топологической сортировки DAG в `tests/test_manifest.nu`.**
```nushell
export def test_manifest_module_dependencies_dag_and_cycle_detection [] {
    let mods = [
        { name: "hyprland", depends_on: ["waybar", "core"] },
        { name: "waybar", depends_on: ["core"] },
        { name: "core", depends_on: [] }
    ]
    let sorted = (sort-modules-dag $mods)
    let names = ($sorted | get name)
    assert ($names == ["core", "waybar", "hyprland"]) "Expected topological order [core, waybar, hyprland]"
    
    # Циклическая зависимость должна выбрасывать структурированную ошибку
    let cyclic = [
        { name: "A", depends_on: ["B"] },
        { name: "B", depends_on: ["A"] }
    ]
    let err = (try { sort-modules-dag $cyclic } catch { |e| $e.msg })
    assert ($err =~ "Cyclic module dependency") "Expected cyclic dependency error"
}
```
- [ ] **Step 2: Запустить тест и проверить падение.**
Выполнить: `rtk nu tests/run.nu --filter test_manifest_module_dependencies_dag`
Ожидается: FAIL.
- [ ] **Step 3: Реализовать алгоритм Кана в `src/manifest.nu` и валидацию в `preflight-check`.**
- [ ] **Step 4: Запустить тесты и убедиться в прохождении.**
Выполнить: `rtk nu tests/run.nu --filter test_manifest_module_dependencies_dag`
Ожидается: PASS.
- [ ] **Step 5: Закоммитить изменения.**
Выполнить: `rtk git add src/manifest.nu src/link.nu bin/ygg.nu tests/test_manifest.nu && rtk oco -y`

---

### Task 8: Фиксация версий модулей и воспроизводимый `ygg.lock` (RFC-032)

**Files:**
- Modify: `src/git.nu`
- Modify: `src/manifest.nu`
- Modify: `bin/ygg.nu`
- Test: `tests/test_pkg_git.nu`

**Interfaces:**
- Produces in `src/git.nu`:
  - `export def generate-ygg-lock [ygg_home: string, plan: record]: nothing -> record`
  - `export def verify-ygg-lock [ygg_home: string, plan: record]: nothing -> list<string>`
- Updates in `bin/ygg.nu`:
  - `ygg apply --locked` — завершается с кодом 1 при несовпадении коммитов клонов с `ygg.lock`.
  - `ygg update` — пропускает модули с `pin = true`.

- [ ] **Step 1: Написать падающий тест для `ygg.lock` и `pin = true` в `tests/test_pkg_git.nu`.**
```nushell
export def test_ygg_lock_generation_and_pinned_modules [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        # Имитируем git-модуль
        let mod_dir = ($home | path join "modules" "pinned-mod")
        mkdir $mod_dir
        ^git -C $mod_dir init | complete | ignore
        ^git -C $mod_dir config user.name "Test" | complete | ignore
        ^git -C $mod_dir config user.email "test@example.com" | complete | ignore
        "name = 'pinned-mod'\nos = ['linux']\n" | save -f ($mod_dir | path join "ygg.toml")
        ^git -C $mod_dir add . | complete | ignore
        ^git -C $mod_dir commit -m "initial" | complete | ignore
        
        let plan = { modules: [{ name: "pinned-mod", dir: $mod_dir, pin: true }] }
        let lock = (generate-ygg-lock $home $plan)
        assert ($home | path join "ygg.lock" | path exists) "ygg.lock must be created"
        assert (($lock.modules | first).name == "pinned-mod") "Expected module in lockfile"
    }
}
```
- [ ] **Step 2: Запустить тест и проверить падение.**
Выполнить: `rtk nu tests/run.nu --filter test_ygg_lock_generation`
Ожидается: FAIL.
- [ ] **Step 3: Реализовать генерацию/проверку `ygg.lock` и соблюдение `pin` в `src/git.nu` и `bin/ygg.nu`.**
- [ ] **Step 4: Запустить тесты и убедиться в прохождении.**
Выполнить: `rtk nu tests/run.nu --filter test_ygg_lock_generation`
Ожидается: PASS.
- [ ] **Step 5: Закоммитить изменения.**
Выполнить: `rtk git add src/git.nu src/manifest.nu bin/ygg.nu tests/test_pkg_git.nu && rtk oco -y`

---

### Task 9: Логические составные скоупы (RFC-033)

**Files:**
- Modify: `src/manifest.nu`
- Test: `tests/test_manifest.nu`

**Interfaces:**
- Produces in `src/manifest.nu`:
  - `def eval-scope-expression [expr: string, active_scopes: list<string>]: nothing -> bool`

- [ ] **Step 1: Написать падающий тест составных скоупов в `tests/test_manifest.nu`.**
```nushell
export def test_eval_scope_expressions [] {
    let scopes = ["linux", "pc", "cachyos"]
    assert (eval-scope-expression "linux and pc" $scopes) "Expected true for 'linux and pc'"
    assert (eval-scope-expression "linux and !work" $scopes) "Expected true for 'linux and !work'"
    assert (not (eval-scope-expression "windows or work" $scopes)) "Expected false for 'windows or work'"
    assert (eval-scope-expression "(cachyos or arch) and !windows" $scopes) "Expected true for complex condition"
}
```
- [ ] **Step 2: Запустить тест и проверить падение.**
Выполнить: `rtk nu tests/run.nu --filter test_eval_scope_expressions`
Ожидается: FAIL.
- [ ] **Step 3: Реализовать парсер и вычислитель логических выражений скоупов в `src/manifest.nu`.**
- [ ] **Step 4: Запустить тесты и убедиться в прохождении.**
Выполнить: `rtk nu tests/run.nu --filter test_eval_scope_expressions`
Ожидается: PASS.
- [ ] **Step 5: Закоммитить изменения.**
Выполнить: `rtk git add src/manifest.nu tests/test_manifest.nu && rtk oco -y`

---

## Этап 3.4: Экосистема, сервисы, очистка пакетов и DX

### Task 10: In-Memory резолверы внешних секретов (RFC-034)

**Files:**
- Modify: `src/env.nu`
- Test: `tests/test_env.nu`

**Interfaces:**
- Updates in `src/env.nu`:
  - `resolve-secret-value [raw: string]: nothing -> string`: поддерживает префиксы `op://`, `bw://`, `pass:`, `eval:` с strictly in-memory получением значений.

- [ ] **Step 1: Написать падающий тест для внешних секретов в `tests/test_env.nu`.**
```nushell
export def test_external_secret_resolvers_in_memory [] {
    let resolved = (resolve-secret-value "eval:echo hello-secret")
    assert ($resolved == "hello-secret") "Expected resolved in-memory secret"
}
```
- [ ] **Step 2: Запустить тест и проверить падение.**
Выполнить: `rtk nu tests/run.nu --filter test_external_secret_resolvers`
Ожидается: FAIL.
- [ ] **Step 3: Реализовать резолверы в `src/env.nu`.**
- [ ] **Step 4: Запустить тесты и убедиться в прохождении.**
Выполнить: `rtk nu tests/run.nu --filter test_external_secret_resolvers`
Ожидается: PASS.
- [ ] **Step 5: Закоммитить изменения.**
Выполнить: `rtk git add src/env.nu tests/test_env.nu && rtk oco -y`

---

### Task 11: Поддержка Fish Shell в компиляторе окружения (RFC-036)

**Files:**
- Modify: `src/env.nu`
- Test: `tests/test_env.nu`

**Interfaces:**
- Updates in `src/env.nu`:
  - `compile-environment`: генерирует `.state/env/env.fish` и `.state/env/aliases.fish`.

- [ ] **Step 1: Написать падающий тест генерации файлов Fish Shell в `tests/test_env.nu`.**
```nushell
export def test_env_compiles_fish_shell_files [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let plan = { env: { EDITOR: "nvim" }, aliases: { g: "git status" } }
        compile-environment $home $plan
        let env_fish = (open --raw ($home | path join ".state" "env" "env.fish"))
        assert ($env_fish =~ "set -gx EDITOR 'nvim'") "Expected Fish env definition"
        let alias_fish = (open --raw ($home | path join ".state" "env" "aliases.fish"))
        assert ($alias_fish =~ "alias g 'git status'") "Expected Fish alias definition"
    }
}
```
- [ ] **Step 2: Запустить тест и проверить падение.**
Выполнить: `rtk nu tests/run.nu --filter test_env_compiles_fish_shell_files`
Ожидается: FAIL.
- [ ] **Step 3: Реализовать генерацию `env.fish` и `aliases.fish` в `src/env.nu`.**
- [ ] **Step 4: Запустить тесты и убедиться в прохождении.**
Выполнить: `rtk nu tests/run.nu --filter test_env_compiles_fish_shell_files`
Ожидается: PASS.
- [ ] **Step 5: Закоммитить изменения.**
Выполнить: `rtk git add src/env.nu tests/test_env.nu && rtk oco -y`

---

### Task 12: Декларативное управление демонами и сервисами (RFC-037)

**Files:**
- Modify: `src/manifest.nu`
- Modify: `src/sdk.nu`
- Modify: `bin/ygg.nu`
- Test: `tests/test_sdk.nu`

**Interfaces:**
- Produces in `src/sdk.nu`:
  - `export def run-service-actions [ygg_home: string, plan: record, ops: table, --dry-run]: nothing -> list<record>`

- [ ] **Step 1: Написать падающий тест для декларативных сервисов в `tests/test_sdk.nu`.**
```nushell
export def test_declarative_services_reload_on_change [] {
    let plan = {
        services: {
            systemd: {
                user: {
                    reload_on_change: { "waybar.service": ["config.jsonc"] }
                }
            }
        }
    }
    let ops = [{ op: "LINK", dest: "~/.config/waybar/config.jsonc", key: "config.jsonc" }]
    let actions = (run-service-actions "/tmp" $plan $ops --dry-run)
    assert (($actions | length) > 0) "Expected reload action for waybar"
    assert (($actions | first).service == "waybar.service") "Expected waybar service action"
}
```
- [ ] **Step 2: Запустить тест и проверить падение.**
Выполнить: `rtk nu tests/run.nu --filter test_declarative_services`
Ожидается: FAIL.
- [ ] **Step 3: Реализовать `run-service-actions` в `src/sdk.nu`, парсер в `src/manifest.nu` и интегрировать в шаг 5 `apply-plan`.**
- [ ] **Step 4: Запустить тесты и убедиться в прохождении.**
Выполнить: `rtk nu tests/run.nu --filter test_declarative_services`
Ожидается: PASS.
- [ ] **Step 5: Закоммитить изменения.**
Выполнить: `rtk git add src/manifest.nu src/sdk.nu bin/ygg.nu tests/test_sdk.nu && rtk oco -y`

---

### Task 13: Режим автоисправления дефектов `ygg doctor --fix` (RFC-038)

**Files:**
- Modify: `src/doctor.nu`
- Modify: `bin/ygg.nu`
- Test: `tests/test_doctor.nu`

**Interfaces:**
- Updates in `src/doctor.nu`:
  - `export def doctor-fix [ygg_home: string, findings: list<record>]: nothing -> list<record>`

- [ ] **Step 1: Написать падающий тест для `ygg doctor --fix` в `tests/test_doctor.nu`.**
```nushell
export def test_doctor_fix_resolves_perms_and_orphan_links [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sec = ($home | path join "secrets.toml")
        "" | save -f $sec
        ^chmod 644 $sec | complete | ignore
        
        let fixed = (doctor-fix $home [{ check: "perm", target: $sec, detail: "0644" }])
        assert (($fixed | length) == 1) "Expected 1 fixed finding"
        let mode = (ls -lD $sec | get -o 0.mode | default "")
        assert ($mode =~ 'rw-------') "Expected 0600 mode after fix"
    }
}
```
- [ ] **Step 2: Запустить тест и проверить падение.**
Выполнить: `rtk nu tests/run.nu --filter test_doctor_fix`
Ожидается: FAIL.
- [ ] **Step 3: Реализовать функцию `doctor-fix` в `src/doctor.nu` и подключить флаг `--fix` в `bin/ygg.nu`.**
- [ ] **Step 4: Запустить тесты и убедиться в прохождении.**
Выполнить: `rtk nu tests/run.nu --filter test_doctor_fix`
Ожидается: PASS.
- [ ] **Step 5: Закоммитить изменения.**
Выполнить: `rtk git add src/doctor.nu bin/ygg.nu tests/test_doctor.nu && rtk oco -y`

---

### Task 14: Декларативная очистка неиспользуемых пакетов (RFC-030)

**Files:**
- Modify: `src/pkg.nu`
- Modify: `bin/ygg.nu`
- Test: `tests/test_pkg_git.nu`

**Interfaces:**
- Updates in `src/pkg.nu`:
  - `export def prune-unused-packages [ygg_home: string, current_plan: record, --dry-run]: nothing -> list<string>`

- [ ] **Step 1: Написать падающий тест очистки пакетов в `tests/test_pkg_git.nu`.**
```nushell
export def test_prune_unused_packages_isolated_providers [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        save-state $home { links: {}, copies: {}, hashes: {}, packages: { uv: ["ruff", "black"] } }
        let plan = { packages: { uv: ["ruff"] } }
        let cmds = (prune-unused-packages $home $plan --dry-run)
        assert ($cmds | any { |c| $c =~ "uv tool uninstall black" }) "Expected black uninstallation"
    }
}
```
- [ ] **Step 2: Запустить тест и проверить падение.**
Выполнить: `rtk nu tests/run.nu --filter test_prune_unused_packages`
Ожидается: FAIL.
- [ ] **Step 3: Реализовать `prune-unused-packages` в `src/pkg.nu` и добавить флаг `--prune-packages` в `bin/ygg.nu`.**
- [ ] **Step 4: Запустить тесты и убедиться в прохождении.**
Выполнить: `rtk nu tests/run.nu --filter test_prune_unused_packages`
Ожидается: PASS.
- [ ] **Step 5: Закоммитить изменения.**
Выполнить: `rtk git add src/pkg.nu bin/ygg.nu tests/test_pkg_git.nu && rtk oco -y`

---

### Task 15: Генерация автодополнений шеллов `ygg completions` (RFC-039)

**Files:**
- Modify: `bin/ygg.nu`
- Test: `tests/test_cli_e2e.nu`

**Interfaces:**
- Produces in `bin/ygg.nu`:
  - Подкоманда `ygg completions <shell: string>`: генерирует скрипты автодополнения для `nu`, `zsh`, `bash`, `fish`, `ps1`.

- [ ] **Step 1: Написать падающий тест для генерации completions в `tests/test_cli_e2e.nu`.**
```nushell
export def test_cli_completions_generation [] {
    let nu_comp = (^nu bin/ygg.nu completions nu | complete)
    assert ($nu_comp.exit_code == 0) "Completions generation for nu must exit 0"
    assert ($nu_comp.stdout =~ "export extern ygg") "Expected extern ygg definition"
}
```
- [ ] **Step 2: Запустить тест и проверить падение.**
Выполнить: `rtk nu tests/run.nu --filter test_cli_completions`
Ожидается: FAIL.
- [ ] **Step 3: Реализовать подкоманду `ygg completions` в `bin/ygg.nu`.**
- [ ] **Step 4: Запустить тесты и убедиться в прохождении.**
Выполнить: `rtk nu tests/run.nu --filter test_cli_completions`
Ожидается: PASS.
- [ ] **Step 5: Закоммитить изменения.**
Выполнить: `rtk git add bin/ygg.nu tests/test_cli_e2e.nu && rtk oco -y`

---

## 4. Завершающий регрессионный аудит и валидация

- [ ] **Step 1: Запустить полный набор тестов проекта.**
Выполнить: `rtk just test`
Ожидается: PASS (все тесты набора проходят без ошибок).
- [ ] **Step 2: Проверить архитектурный дрейф базы знаний.**
Выполнить: `rtk context-init check --compact` (или `context_check`). При наличии изменений обновить: `rtk context-init update . --compact`.
- [ ] **Step 3: Проверить статус Git репозитория.**
Выполнить: `rtk git status`
Ожидается: чистый репозиторий, отсутствие незакоммиченных и неотслеживаемых файлов.
