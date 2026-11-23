# RFC-062: Module Lint (`ygg lint`) & Reusable CI Workflow (`module-check.yml`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить в ядро `ygg` read-only команду `ygg lint [path]` для полной проверки модулей до установки (схемы, источники во всех scopes, выражения scopes, `setup.nu`, план `apply` с фикстурами, compose и опциональные пробы пакетов), удалить устаревший `tests/test_phase2_modules.nu` (#35) и опубликовать тонкий reusable GitHub Actions workflow `.github/workflows/module-check.yml` (#38).

**Architecture:** Вся логика проверок живёт в новом `src/lint.nu` и переиспользует существующие функции ядра (`load-module-manifest`, `eval-scope-expression`, `resolve-effective-plan --extra-modules`, `resolve-link-targets`, `compute-link-ops`, `preflight-check`, `detect-container-runtime`), дополненные `list-module-scopes` в `src/manifest.nu` и `PROBE_ARGVS`/`probe-packages` в `src/pkg.nu`. Временные `YGG_HOME`, `YGG_SANDBOX` и `mock_pkg.log` создаются в одном `mktemp -d` и гарантированно удаляются при любом исходе; `module-check.yml` только поднимает окружение и вызывает `nu <engine>/bin/ygg.nu lint`.

**Tech Stack:** Nushell `0.116.1`, TOML, Git, GitHub Actions (`workflow_call`), `mise`.

**Spec:** [docs/specs/2026-11-17-ygg-module-lint-and-ci-design.md](../../specs/2026-11-17-ygg-module-lint-and-ci-design.md) (`Issues: #23, #38`, связано `#35`).

## Global Constraints

- Nushell `>= 0.116` (`0.116.1` в CI); без внешних утилит в ядре, кроме самих пакетных менеджеров для L6, `docker`/`podman` для compose и `git` для клонирования зависимостей фикстур.
- Read-only инвариант (`AGENTS.md` §2.1): `ygg lint` не вызывает `ensure-ygg-dirs`, не пишет в реальные `YGG_HOME`/`$HOME`, не берёт `host.lock`, не выводит прогресс в `stderr` и не создаёт `ygg-proc-*.log`.
- Временный каталог `lint` создаётся через `mktemp -d` и удаляется в `try/catch` при любом исходе (успех и ошибка).
- Кроссплатформенность (`AGENTS.md` §2.4): работает на Linux, Windows 11/Server (Non-Admin) и macOS; `src/link.nu` и `src/state.nu` ради `lint` не меняются.
- Чистота ядра (`AGENTS.md` §2.2): никаких захардкоженных имён личных модулей, путей `/home/...`, `C:\Users\...`, `chezmoi`, `sops`.
- Формат находок строго совместим с `doctor --json` (`{check, severity, target, detail, fix}`); у L5 добавляются `{os, scopes, cross_os}`. Код выхода `1` только при `severity == "error"`; `warn` и `info` дают `0`.
- `YGG_HOST_OS_OVERRIDE` из L5 не должен протекать в L4 (`setup.nu`), L6 (`probe-packages`) и `compose`.
- Перед правкой любых `.nu` файлов читать `.agents/skills/nushell-ygg-dev/SKILL.md`.
- Коммиты по Conventional Commits; регрессионные тесты помечаются `# regression: #23`, `# regression: #35`, `# regression: #38`; финальные коммиты/PR закрывают `#23`, `#35`, `#38` футерами `Fixes #N`.
- Рекомендуемое разбиение на PR (§9 спеки): PR 1 — Tasks 1–5 (`ygg lint` #23 + удаление `test_phase2_modules.nu` #35), PR 2 — Tasks 6–7 (`module-check.yml` #38 + `scripts/release.nu` + документация).

## Review Focus

1. **Несуществующий `path` или битый `ygg.toml` при `--json`:** `ygg lint` не должен падать с необработанным исключением Nushell — обязан вернуть находку L1 (`severity: "error"`) валидным JSON и выйти с кодом `1`.
2. **Пути с пробелами / обратными слэшами Windows в L4 (`nu-check`):** передача пути строковой интерполяцией внутрь `-c` ломается на пробелах и `\`; путь к `setup.nu` передаётся через `with-env { YGG_LINT_SETUP: $setup_path }` и `^nu -I $src_dir -c 'nu-check $env.YGG_LINT_SETUP'`.
3. **Изоляция `YGG_HOST_OS_OVERRIDE` и временного `YGG_MOCK_PKG_LOG` между L5 и L6/compose:** после прогона L5 с `YGG_HOST_OS_OVERRIDE: "windows"` L6 и `compose` обязаны видеть реальную ОС хоста и исходный (внешний) `YGG_MOCK_PKG_LOG`, а не временный лог L5.
4. **Сложные булевы выражения в `[scope."..."]` (`work and not headless`, `linux or macos`):** `compute-scope-sets` и `compute-lint-targets` обязаны извлекать отдельные идентификаторы-токены (отбрасывая операторы `and`, `or`, `not`, скобки), а не трактовать всё выражение как одно имя scope.
5. **Очистка `mktemp -d` при битой фикстуре `ci/hosts/*.toml`:** синтаксическая ошибка в фикстуре даёт находку `error` (не крэш) и гарантированно удаляет временный каталог `lint`.

## File Structure

- Modify: `src/manifest.nu` — экспорт констант `YGG_MANIFEST_KEYS`, `KNOWN_OS_VALUES`, `DISTRO_AUTO_SCOPES` и функции `list-module-scopes`.
- Modify: `src/pkg.nu` — экспорт `KNOWN_PKG_MANAGERS`, таблица `PROBE_ARGVS` и функция `probe-packages`.
- Create: `src/lint.nu` — стадии L1–L6, `compose`, парсер фикстур `ci/hosts/*.toml`, оркестратор `run-lint`.
- Modify: `bin/ygg.nu` — подкоманда `main lint`, строка помощи в `main`.
- Delete: `tests/test_phase2_modules.nu` (#35).
- Modify: `mise.toml`, `tests/run.nu` — удаление `[tasks.test-phase2]` и спец-пропуска `test_phase2_modules.nu`.
- Create: `tests/test_lint.nu` — все 10 сценариев §6 + 5 сценариев Review Focus.
- Create: `.github/workflows/module-check.yml` — reusable workflow `on: workflow_call`.
- Create: `tests/fixtures/module-sample/` — минимальный кроссплатформенный модуль-фикстура (Linux + Windows) для проверки `module-check.yml` в CI движка.
- Modify: `.github/workflows/ci.yml` — job `module-check` на коде PR.
- Modify: `scripts/release.nu`, `tests/test_release.nu` — автообновление `ygg-version` по умолчанию в `.github/workflows/module-check.yml`.
- Modify: `README.md`, `.agents/skills/ygg-module-verification/SKILL.md` — документация `ygg lint`, pre-push hook и workflow.

---

### Task 1: Константы манифеста в `src/manifest.nu` и пробы пакетов `PROBE_ARGVS` в `src/pkg.nu`

**Files:**
- Modify: `src/manifest.nu:88-150`
- Modify: `src/pkg.nu:24-35, 290-305`
- Test: `tests/test_manifest.nu`, `tests/test_pkg_git.nu`

**Interfaces:**
- Consumes: `detect-host-os` (`src/state.nu`), `allowed-package-managers` (`src/pkg.nu`), `run-with-timeout` (`src/pkg.nu`), `is-mock-mode` / `csv-env` (`src/pkg.nu`).
- Produces:
  - `src/manifest.nu`:
    - `export const YGG_MANIFEST_KEYS = ["name", "os", "depends_on", "description", "config", "packages", "links", "save", "services", "env", "aliases", "path", "scope", "doctor", "containers", "setup"]`
    - `export const KNOWN_OS_VALUES = ["linux", "windows", "macos", "darwin", "unix", "arch", "cachyos", "ubuntu", "debian", "pop", "mint", "fedora", "rhel", "centos", "opensuse", "sles", "opensuse-tumbleweed", "opensuse-leap"]`
    - `export const DISTRO_AUTO_SCOPES = ["arch", "cachyos", "ubuntu", "debian", "pop", "mint", "fedora", "rhel", "centos", "opensuse", "sles", "opensuse-tumbleweed", "opensuse-leap"]`
    - `export def list-module-scopes [manifest: record]: nothing -> list<string>`
  - `src/pkg.nu`:
    - `export const KNOWN_PKG_MANAGERS = ["winget", "scoop", "pacman", "paru", "apt", "dnf", "zypper", "brew", "mise", "cargo", "pnpm", "uv"]`
    - `export def probe-packages [pkgs_by_mgr: record, --host-os: record = {}]: nothing -> list<record<mgr: string, pkg: string, status: string, detail: string>>`

- [ ] **Step 1: Write failing tests for `list-module-scopes` and `probe-packages`**

В `tests/test_manifest.nu` добавить тест `test_list_module_scopes_without_activation`: загружает модуль с `[scope.work]`, `[scope.cachyos]` и `[scope."work and not headless"]` в `ygg.toml` + `[scope.gaming]` в `links.toml`, вызывает `list-module-scopes $m` и проверяет наличие всех 4 ключей (в т.ч. неактивных).

В `tests/test_pkg_git.nu` добавить тест `test_probe_packages_mock_and_os_info`:
```nushell
# regression: #23
export def test_probe_packages_mock_and_os_info [] {
    with-temp-ygg { |home|
        let log = ($home | path join "probe.log")
        let res = (with-env {
            YGG_HOST_OS_OVERRIDE: "cachyos",
            YGG_MOCK_PKG_LOG: $log,
            YGG_MOCK_PKG_UNKNOWN: "bad-pkg,node@22"
        } {
            probe-packages {
                pacman: ["ripgrep", "bad-pkg"],
                mise: ["node@22", "python@3.12"],
                winget: ["Git.Git"],
                cargo: ["fd-find"]
            }
        })
        assert (($res | where mgr == "pacman" and pkg == "ripgrep" | first).status == "ok")
        assert (($res | where mgr == "pacman" and pkg == "bad-pkg" | first).status == "not_found")
        # mise проверяет имя до '@'
        assert (($res | where mgr == "mise" and pkg == "node@22" | first).status == "not_found")
        assert (($res | where mgr == "mise" and pkg == "python@3.12" | first).status == "ok")
        # winget недоступен на cachyos -> info
        assert (($res | where mgr == "winget" and pkg == "Git.Git" | first).status == "info")
        # cargo доступен везде по HTTP -> ok
        assert (($res | where mgr == "cargo" and pkg == "fd-find" | first).status == "ok")
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `rtk nu tests/run.nu --filter test_list_module_scopes` и `rtk nu tests/run.nu --filter test_probe_packages`
Expected: FAIL (`list-module-scopes` / `probe-packages` not found).

- [ ] **Step 3: Implement constants & `list-module-scopes` in `src/manifest.nu`**

Добавить `YGG_MANIFEST_KEYS`, `KNOWN_OS_VALUES`, `DISTRO_AUTO_SCOPES` и `export def list-module-scopes [manifest: record]: nothing -> list<string>` (возвращает `$manifest.scope? | default {} | columns | uniq`).

- [ ] **Step 4: Implement `KNOWN_PKG_MANAGERS`, `PROBE_ARGVS` and `probe-packages` in `src/pkg.nu`**

- Добавить `export const KNOWN_PKG_MANAGERS` и приватный `const HTTP_PROBE_MGRS = ["paru", "cargo", "pnpm", "uv"]`.
- Добавить `const PROBE_ARGVS` для CLI-менеджеров:
  - `winget`: `[winget show --exact --id]` (not_found: exit_code != 0 и вывод содержит `No package found` / код `-1978335212`; иначе сетевой/CLI сбой → `warn`)
  - `scoop`: `[scoop info]` (not_found: вывод содержит `Could not find` или пустой/exit != 0)
  - `pacman`: `[pacman -Si]` (not_found: stderr содержит `was not found` / `не найден`)
  - `apt`: `[apt-cache show]` (not_found: exit_code == 100 или `No packages found`)
  - `dnf`: `[dnf info --quiet]` (not_found: `No matching Packages`)
  - `zypper`: `[zypper --non-interactive info]` (not_found: `not found`)
  - `brew`: `[brew info]` (not_found: `No available formula`)
  - `mise`: `[mise ls-remote]` (имя пакета до `@`: `$pkg | split row "@" | first`; not_found: пустой stdout или exit != 0 без признаков rate-limit/сети; при `rate limit`/`timeout`/`connection` → `warn`).
- Для `HTTP_PROBE_MGRS` (реальный режим):
  - `paru`: батч-запрос `http get --allow-errors` к `https://aur.archlinux.org/rpc/v5/info?arg[]=...` (разбивать по 50 пакетов), отсутствующие в `.results | get Name` → `not_found`; сетевой сбой → `warn`.
  - `cargo`: `http get --allow-errors --headers [User-Agent "ygg-lint"] $"https://crates.io/api/v1/crates/($pkg)"` (404 → `not_found`, 200 → `ok`, иначе → `warn`).
  - `pnpm`: `http get --allow-errors $"https://registry.npmjs.org/($pkg | url encode)"` (404 → `not_found`, 200 → `ok`, иначе → `warn`).
  - `uv`: `http get --allow-errors $"https://pypi.org/pypi/($pkg)/json"` (404 → `not_found`, 200 → `ok`, иначе → `warn`).
- Для всех CLI-проб: если бинарник не найден на `PATH` → `warn` (не `not_found`); если менеджер не входит в `allowed-package-managers $eff_host_os` и не входит в `HTTP_PROBE_MGRS` → `info` (`"manager not available on this OS; verified in CI matrix"`).
- В мок-режиме (`is-mock-mode`): логировать `"probe ($mgr) ($pkg)"` в `$env.YGG_MOCK_PKG_LOG`; проверять `$pkg` (и для `mise` также имя до `@`) против `csv-env "YGG_MOCK_PKG_UNKNOWN"`.
- Таймаут CLI-пробы — 30 сек через `run-with-timeout $argv 30` (без `--label`, чтобы не писать в `stderr` и не создавать `ygg-proc-*.log`).

- [ ] **Step 5: Run tests to verify pass**

Run: `rtk nu tests/run.nu --filter test_list_module_scopes` и `rtk nu tests/run.nu --filter test_probe_packages`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
rtk git add src/manifest.nu src/pkg.nu tests/test_manifest.nu tests/test_pkg_git.nu
rtk oco -y
```

---

### Task 2: Статический анализ в `src/lint.nu` (стадии L1, L2, L3, L4, compose)

**Files:**
- Create: `src/lint.nu`
- Create: `tests/test_lint.nu` (начальные тесты L1–L4 и compose)

**Interfaces:**
- Consumes: `load-module-manifest`, `eval-scope-expression`, `list-module-scopes`, `YGG_MANIFEST_KEYS`, `KNOWN_OS_VALUES` (`src/manifest.nu`); `KNOWN_PKG_MANAGERS` (`src/pkg.nu`); `detect-container-runtime` (`src/container.nu`); `run-with-timeout` (`src/pkg.nu`).
- Produces (в `src/lint.nu`):
  - `export def lint-finding [check: string, severity: string, target: string, detail: string, fix: string]: nothing -> record<check: string, severity: string, target: string, detail: string, fix: string>`
  - `export def lint-schemas [mod_dir: string]: nothing -> record<findings: list<record>, manifest: any>`
  - `export def lint-sources [mod_dir: string]: nothing -> list<record>`
  - `export def lint-scopes [manifest: record]: nothing -> list<record>`
  - `export def lint-setup [mod_dir: string, src_dir: string]: nothing -> list<record>`
  - `export def lint-compose [mod_dir: string, manifest: record]: nothing -> list<record>`

- [ ] **Step 1: Write failing tests for L1, L2, L3, L4 and compose in `tests/test_lint.nu`**

Покрыть в `tests/test_lint.nu` (внутри `with-temp-ygg`, с `# regression: #23`):
- `test_lint_l1_schemas_and_unknown_keys`: битый TOML в `links.toml` → `error`; `[scopes.x]` в `ygg.toml` → `warn`; неизвестный менеджер `aptget` в `[scope.linux.packages]` → `error`; неизвестное значение `os = ["freebsd"]` → `error`; несуществующий `mod_dir` или битый `ygg.toml` → `error` (без неперехваченного исключения — Review Focus #1).
- `test_lint_l2_sources_inactive_scope_and_save`: отсутствующий источник в неактивном `[scope.work.links]` → `error` с `target` вида `"links.toml [scope.work] opencode"`; `mode = "dir"` на файле → `error`; отсутствующий источник в `[save]` → `error`; отсутствующий файл в `[scope.work.containers].files` → `error`.
- `test_lint_l3_invalid_scope_expression`: `[scope."work and ("]` → `error`.
- `test_lint_l4_setup_syntax_and_spaces`: синтаксическая ошибка в `setup.nu` (в каталоге с пробелом в имени — Review Focus #2) → `error`; валидный `setup.nu` с `use sdk.nu *` → `[]`.
- `test_lint_compose_no_runtime_info`: модуль с `compose.yml` при `YGG_MOCK_PKG_LOG` + `YGG_MOCK_CONTAINER_STATUS: "no_runtime"` → `info`.

- [ ] **Step 2: Run tests to verify failure**

Run: `rtk nu tests/run.nu --filter test_lint_l`
Expected: FAIL (`src/lint.nu` does not exist).

- [ ] **Step 3: Implement L1–L4 and `lint-compose` in `src/lint.nu`**

Ключевые детали реализации:
- `lint-schemas`:
  - Проверяет существование `$mod_dir` и `$mod_dir/ygg.toml`; при ошибке парсинга возвращает `{ findings: [(lint-finding "schema" "error" "ygg.toml" ...)], manifest: null }`.
  - Проверяет ключи верхнего уровня `$raw_ygg | columns` против `YGG_MANIFEST_KEYS` → для каждого неизвестного `lint-finding "schema" "warn" $"ygg.toml ($k)" ...`.
  - Проверяет парсинг каждого существующего из `["packages.toml", "links.toml", "env.toml", "aliases.toml", "services.toml", "secrets.example.toml"]` через `try { open $p }` → при ошибке `error`.
  - Вызывает `load-module-manifest $mod_dir` в `try/catch`; проверяет значения `$manifest.os` против `KNOWN_OS_VALUES` → `error`; проверяет ключи `$manifest.packages` и всех `$manifest.scope.<s_name>.packages` против `KNOWN_PKG_MANAGERS` → `error`.
- `lint-sources`:
  - Обходит сырые `ygg.toml` и `links.toml` напрямую (не объединённый манифест), сохраняя `$file_name` (`"ygg.toml"` или `"links.toml"`) и `$section` (`"[links]"`, `"[scope.work]"`, `"[save]"`, `"[containers]"`, `"[scope.work.containers]"`).
  - Формирует `target` точно по §5.1 спеки: `$"($file_name) ($section) ($key)"`.
  - Проверяет существование источника (`$mod_dir | path join $src`) для каждой записи ссылок (строка или record с `src`/`mode`), каждого `[save]` и каждого `[containers].files` (плюс автообнаруженный `compose.yml`, если он битый symlink). Для `mode == "dir"` проверяет `($full | path type) == "dir"`.
  - Для записей с glob-шаблонами (`*`, `?`, `[`) проверяет существование базового каталога до первого wildcard-сегмента.
- `lint-scopes`: для каждого `$expr` из `list-module-scopes $manifest` вызывает `try { eval-scope-expression $expr [] | ignore } catch { |e| ... }`.
- `lint-setup`: если `$mod_dir/setup.nu` существует, запускает с очищенным `YGG_HOST_OS_OVERRIDE: null` и `YGG_LINT_SETUP: $setup_path`:
  - `^nu -I $src_dir -c 'nu-check $env.YGG_LINT_SETUP' | complete`
  - при `exit_code != 0` запрашивает диагностику: `^nu -I $src_dir --ide-check 10 $setup_path | complete` (fallback на `stderr` от `nu-check`) → `lint-finding "setup" "error" "setup.nu" $diag "Fix syntax error in setup.nu"`.
- `lint-compose`: собирает уникальные существующие compose-файлы из `$manifest.containers.files?`, `$manifest.scope.*.containers.files?` и корневого `compose.yml`/`compose.yaml`. Если список не пуст: вызывает `detect-container-runtime` (при `status != "ok"` → `info`); иначе для каждого файла запускает `run-with-timeout [$rt.bin "compose" "-f" $file "config" "-q"] 30` → при `exit_code != 0` добавляет `error`.

- [ ] **Step 4: Run tests to verify pass**

Run: `rtk nu tests/run.nu --filter test_lint_l` и `rtk nu tests/run.nu --filter test_lint_compose`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
rtk git add src/lint.nu tests/test_lint.nu
rtk oco -y
```

---

### Task 3: Стадия L5 (план в песочнице), фикстуры `ci/hosts/*.toml` и оркестратор `run-lint`

**Files:**
- Modify: `src/lint.nu`
- Modify: `tests/test_lint.nu`

**Interfaces:**
- Consumes: `resolve-effective-plan`, `DISTRO_AUTO_SCOPES`, `KNOWN_OS_VALUES` (`src/manifest.nu`); `resolve-link-targets`, `compute-link-ops`, `preflight-check`, `format-preflight-errors` (`src/link.nu`); `detect-host-os` (`src/state.nu`); `probe-packages` (`src/pkg.nu`); L1–L4 и `lint-compose` из Task 2.
- Produces (в `src/lint.nu`):
  - `export def compute-lint-targets [manifest: record, os_filter: list<string> = []]: nothing -> list<string>`
  - `export def compute-scope-sets [manifest: record]: nothing -> list<list<string>>`
  - `export def run-lint [mod_dir: string, --packages, --os: list<string> = [], --src-dir: string = ""]: nothing -> list<record>`

- [ ] **Step 1: Write failing tests for L5, fixtures, dependencies, isolation & cleanup in `tests/test_lint.nu`**

Добавить в `tests/test_lint.nu`:
- `test_lint_l5_cross_os_conflict`: модуль с `os = ["linux", "windows"]`, конфликт целей (побайтно одинаковая цель из базового `[links]` и `[scope.work]`, проявляющийся при `os = windows` и scope `work`) → `error`, на не-Windows хосте у находки `cross_os == true`, `os == "windows"`, в `detail` есть пометка о чужой ОС (§6 п.5).
- `test_lint_l5_depends_on_without_and_with_fixture`:
  - без фикстуры: модуль с `depends_on = ["dep-mod"]` → L5 выполняется, `missing_dependency` понижен до `warn`, `errors == 0`;
  - с фикстурой `ci/hosts/default.toml` и локальной зависимостью (`source = "../dep-mod"`) → `missing_dependency` отсутствует, коллизия целей между модулем и зависимостью → `error` (§6 п.6).
- `test_lint_l5_distro_targets_and_expr_scopes`: модуль с `os = ["linux"]`, `[scope.cachyos]` и `[scope."work and not headless"]` → `compute-lint-targets` включает `"cachyos"`, `compute-scope-sets` содержит `[]`, `["work"]`, `["headless"]` (Review Focus #4).
- `test_lint_l6_packages_and_no_override_leak`: запуск `run-lint --packages` на модуле с `os = ["linux", "windows"]` при `YGG_MOCK_PKG_LOG` и `YGG_MOCK_PKG_UNKNOWN` — L5 гоняет `windows` с override, затем L6 всё равно видит реальную ОС хоста (Review Focus #3) и выдаёт `error` для неизвестного пакета и `info` для менеджера чужой ОС (§6 п.7).
- `test_lint_readonly_and_tmp_cleanup`: запуск `run-lint` (включая сценарий с битой фикстурой `ci/hosts/broken.toml` — Review Focus #5) в дочернем `^nu` с собственными `TMPDIR`/`TEMP`/`TMP` внутри `with-temp-ygg` → в `YGG_HOME` и `HOME` нет новых файлов, в `TMPDIR` не осталось временных каталогов `lint` (§6 п.8).

- [ ] **Step 2: Run tests to verify failure**

Run: `rtk nu tests/run.nu --filter test_lint_`
Expected: FAIL (`run-lint` / `compute-lint-targets` not defined).

- [ ] **Step 3: Implement `compute-lint-targets`, `compute-scope-sets`, fixture loader, `lint-plan` and `run-lint` in `src/lint.nu`**

Ключевые детали реализации:
- Токенизатор выражений scopes `extract-scope-tokens [expr: string]: nothing -> list<string>`: удаляет `(`, `)`, делит по пробелам, приводит к lowercase, исключает `["and", "or", "not", ""]`.
- `compute-lint-targets`: объединяет `$manifest.os` и токены из `list-module-scopes $manifest`, входящие в `DISTRO_AUTO_SCOPES`; при непустом `$os_filter` фильтрует пересечением.
- `compute-scope-sets`: из токенов всех ключей `list-module-scopes $manifest` отбрасывает входящие в `KNOWN_OS_VALUES`; возвращает `[[]]` + `($user_scopes | each { |s| [$s] })`.
- Загрузчик фикстур `load-lint-fixtures [mod_dir: string, mod_name: string, deps_dir: string]`:
  - Ищет `ci/hosts/*.toml` внутри `$mod_dir`. Если файлов нет — возвращает `{ has_fixtures: false, fixtures: [], findings: [] }`.
  - Каждый TOML парсится в `try/catch` (при ошибке → `lint-finding "fixture" "error" $"ci/hosts/($fname)" ...`).
  - Для каждой записи `[[modules]]`: если `name == $mod_name`, подставляется `path: $mod_dir`; иначе если `source?` непустой: относительный путь резолвится относительно `$mod_dir`, а URL (`http://`, `https://`, `git@`, `ssh://`) клонируется один раз в `$deps_dir/<name>` (`^git clone --depth 1` + опционально `--branch $ref`).
- `lint-plan`:
  - Определяет нативную ОС до любых override (`let native = (detect-host-os)`).
  - Для каждой комбинации `(target_os, scopes, extra_modules, has_fixture)`:
    - `is_cross_os = ($target_os != $native.os) and ($target_os != $native.distro) and ($target_os not-in $native.auto_scopes)`
    - Выставляет `with-env` с `YGG_HOME: $tmp_ygg`, `YGG_SANDBOX: $tmp_sb`, `YGG_MOCK_PKG_LOG: $tmp_mock_log` и (если `$is_cross_os`) `YGG_HOST_OS_OVERRIDE: $target_os`.
    - Вызывает `resolve-effective-plan $tmp_ygg --extra-modules $extra_mods` → `resolve-link-targets $plan $tmp_sb` → `compute-link-ops $resolved.links {}` → `preflight-check $tmp_ygg $plan $resolved $ops --sandbox $tmp_sb --quiet`.
    - Каждую проблему `$p` маппит в находку:
      - `severity = if (not $has_fixture) and ($p.reason == "missing_dependency") { "warn" } else { "error" }`
      - `target = $"($p.module): ($p.key)"`
      - `detail` = если `$p.reason == "missing_dependency"` и без фикстуры → `$p.detail + " (dependency not verified without ci/hosts/ fixture)"`; если `$is_cross_os` → добавить `$" [план для ($target_os) построен на ($native.os); окончательная проверка — нативный прогон в CI]"`.
      - Дополнительные поля записи: `os: $target_os`, `scopes: $scopes`, `cross_os: $is_cross_os`.
- `run-lint`:
  - Создаёт `$tmp_root = (mktemp -d -t ygg-lint-XXXXXX)` (внутри создаёт `ygg`, `sandbox`, `deps`, `mock.log`).
  - Весь прогон обёрнут в `try { ... } catch { |e| try { rm -rf $tmp_root } catch {}; error make { msg: $e.msg } }`, затем `try { rm -rf $tmp_root } catch {}`.
  - Последовательность: L1 → если `manifest == null`, вернуть L1 → L2 → L3 → L4 (без override) → L5 (с изолированным `with-env`) → `lint-compose` (вне override и вне временного `mock.log`) → если `$packages`, собрать все пакеты модуля из базовых `[packages]` и всех `[scope.*.packages]` и вызвать `probe-packages $all_pkgs` (вне override и с внешним `YGG_MOCK_PKG_LOG`, если он был задан тестом).

- [ ] **Step 4: Run tests to verify pass**

Run: `rtk nu tests/run.nu --filter test_lint`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
rtk git add src/lint.nu tests/test_lint.nu
rtk oco -y
```

---

### Task 4: CLI `ygg lint` в `bin/ygg.nu`, completions и удаление `test_phase2_modules.nu` (#35)

**Files:**
- Modify: `bin/ygg.nu:1-50, 910-920`
- Delete: `tests/test_phase2_modules.nu`
- Modify: `mise.toml:9-14`
- Modify: `tests/run.nu:24-30`
- Modify: `tests/test_lint.nu` (CLI E2E тесты: `--json`, exit codes, `--os`, `--packages`)

**Interfaces:**
- Consumes: `run-lint` (`src/lint.nu`).
- Produces: публичная CLI-команда `ygg lint [path] [--packages] [--os <list>] [--json]` в `bin/ygg.nu` (автоматически подхватывается `main completions` из `scope commands`).

- [ ] **Step 1: Write failing CLI tests in `tests/test_lint.nu`**

Добавить в `tests/test_lint.nu`:
- `test_lint_cli_json_and_exit_codes`:
  - чистый модуль → `^nu bin/ygg.nu lint $mod_dir --json` возвращает `exit_code == 0`, валидный JSON `[]`, пустой `stderr`;
  - модуль только с `warn` (`[scopes.x]`) → `exit_code == 0`, JSON содержит `severity == "warn"`;
  - модуль с `error` (отсутствующий источник) → `exit_code == 1`, JSON содержит `{check, severity, target, detail, fix}`, пустой `stderr` (§6 п.9);
  - битый `ygg.toml` с `--json` → `exit_code == 1`, валидный JSON-массив (Review Focus #1).
- `test_lint_cli_human_output_stdout_only`: без `--json` вывод идёт в `stdout` (таблица + строка `Lint: N error(s), M warning(s).`), `stderr` пуст.

- [ ] **Step 2: Run tests to verify failure**

Run: `rtk nu tests/run.nu --filter test_lint_cli`
Expected: FAIL (`lint` subcommand not found).

- [ ] **Step 3: Add `main lint` to `bin/ygg.nu`**

- Импортировать `use ../src/lint.nu [run-lint]`.
- Добавить строку справки `ygg lint [path] [--packages] [--os <os>] [--json]` в `def main []`.
- Реализовать `def "main lint" [path: string = ".", --packages, --os: string = "", --json]`:
  - `let os_list = ($os | split row "," | each { |s| $s | str trim | str lowercase } | where { |s| $s != "" })`
  - `let src_dir = ($env.FILE_PWD | path dirname | path join "src")`
  - `let report = (run-lint $path --packages=$packages --os=$os_list --src-dir=$src_dir)`
  - Форматирование вывода аналогично `main doctor` (`bin/ygg.nu:888-915`):
    - при `--json`: `print ($report | to json --raw)`
    - без `--json`: если не пуст — `print ($report | table --expand)`; затем `print $"Lint: ($errors) error\(s\), ($warns) warning\(s\)."`
  - `if $errors > 0 { exit 1 }`.

- [ ] **Step 4: Delete `tests/test_phase2_modules.nu` and clean up `mise.toml` & `tests/run.nu` (#35)**

- Удалить файл `tests/test_phase2_modules.nu`.
- Удалить секцию `[tasks.test-phase2]` из `mise.toml`.
- Удалить блок `if $file_name == "test_phase2_modules.nu" ...` из `tests/run.nu`.

- [ ] **Step 5: Run tests (lint + completions + full suite)**

Run:
```bash
rtk nu tests/run.nu --filter test_lint
rtk nu tests/run.nu --filter test_e2e_completions
rtk mise run test
```
Expected: ALL PASS (в т.ч. тест RFC-052 подтверждает наличие `lint` и его флагов во всех 6 генераторах completions — §6 п.10).

- [ ] **Step 6: Commit**

```bash
rtk git add bin/ygg.nu mise.toml tests/run.nu tests/test_lint.nu
rtk git rm tests/test_phase2_modules.nu
rtk oco -y
```
*(Если PR 1 сдаётся отдельно от #38 — добавить футеры `Fixes #23` и `Fixes #35` в коммит/PR).*

---

### Task 5: Reusable workflow `.github/workflows/module-check.yml`, фикстура `tests/fixtures/module-sample/`, `scripts/release.nu` и интеграция в `ci.yml` (#38)

**Files:**
- Create: `.github/workflows/module-check.yml`
- Create: `tests/fixtures/module-sample/ygg.toml`
- Create: `tests/fixtures/module-sample/links.toml`
- Create: `tests/fixtures/module-sample/packages.toml`
- Create: `tests/fixtures/module-sample/configs/sample.conf`
- Modify: `.github/workflows/ci.yml`
- Modify: `scripts/release.nu:39-46, 135-152`
- Modify: `tests/test_release.nu`

**Interfaces:**
- Consumes: `bin/ygg.nu lint`, `read-ygg-version` (`src/engine.nu`).
- Produces:
  - `.github/workflows/module-check.yml` (`on: workflow_call`, inputs: `ygg-version`, `module-path`, `packages`, `os`).
  - `scripts/release.nu`: `export def set-workflow-ygg-version [content: string, version: string]: nothing -> string`.

- [ ] **Step 1: Write failing test for `set-workflow-ygg-version` in `tests/test_release.nu`**

```nushell
# regression: #38
export def test_set_workflow_ygg_version [] {
    let sample = "      ygg-version:\n        default: 'v0.3.0'\n"
    let updated = (set-workflow-ygg-version $sample "0.4.0")
    assert ($updated | str contains "default: 'v0.4.0'")
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `rtk nu tests/run.nu --filter test_set_workflow_ygg_version`
Expected: FAIL (`set-workflow-ygg-version` not defined).

- [ ] **Step 3: Create `.github/workflows/module-check.yml`**

Реализовать `on: workflow_call` строго по §5.6:
- Inputs:
  - `ygg-version`: `type: string`, `default: 'v0.3.0'` (текущая `YGG_VERSION` из `bin/ygg.nu`)
  - `module-path`: `type: string`, `default: '.'`
  - `packages`: `type: boolean`, `default: true`
  - `os`: `type: string`, `default: ''`
- Job `matrix` (`runs-on: ubuntu-latest`, `hustcer/setup-nu@v3` `0.116.1`):
  - Checkout вызывающего модуля (`actions/checkout@v5`).
  - Nushell-скрипт читает `os` (из input `os` или из `<module-path>/ygg.toml` + distro scopes) и формирует JSON-матрицу `{ os, runner, container }` по таблице §5.6:
    - `windows` → `windows-latest`, `""`
    - `macos` → `macos-latest`, `""`
    - `linux`/`ubuntu`/`debian` → `ubuntu-latest`, `""`
    - `arch`/`cachyos` → `ubuntu-latest`, `archlinux:latest`
    - `fedora` → `ubuntu-latest`, `fedora:latest`
    - прочее → `ubuntu-latest`, `""` (с `::warning::` в логе).
  - Также вычисляет output `has-mise` (`true`/`false` — есть ли `mise` в `packages` модуля).
- Job `lint` (`needs: matrix`, `fail-fast: false`, `runs-on: ${{ matrix.runner }}`, `container: ${{ matrix.container }}`):
  - Checkout модуля в `module/` и `gidragir/ygg@${{ inputs.ygg-version }}` в `ygg-engine/`.
  - Установка Nushell `0.116.1` (`hustcer/setup-nu@v3`; в контейнерах `archlinux`/`fedora` fallback на `pacman -Sy --noconfirm nushell` / `dnf install -y nushell`, если `setup-nu` недоступен).
  - При `needs.matrix.outputs.has-mise == 'true'`: установка `jdx/mise-action@v2` с `GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}`.
  - Для `archlinux`: `pacman -Sy` (обновление sync-БД перед `pacman -Si`).
  - Запуск `nu ygg-engine/bin/ygg.nu lint module/${{ inputs.module-path }} --os ${{ matrix.os }}` (с `--packages`, если `inputs.packages == true`), передавая `GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}`.

- [ ] **Step 4: Update `scripts/release.nu` to sync `ygg-version` default**

- Добавить `export def set-workflow-ygg-version [content: string, version: string]: nothing -> string` (заменяет `default: 'v...'` под `ygg-version:` в `.github/workflows/module-check.yml`).
- В `main prepare`: обновлять `.github/workflows/module-check.yml` рядом с `bin/ygg.nu` (включая вывод в `--dry-run`, откат при ошибке `git-cliff` и `git add`).

- [ ] **Step 5: Create `tests/fixtures/module-sample/` and wire into `.github/workflows/ci.yml`**

- Создать `tests/fixtures/module-sample/` с `ygg.toml` (`name = "module-sample"`, `os = ["linux", "windows"]`), `links.toml` (`"configs/sample.conf" = "~/.config/ygg-sample/sample.conf"`), `packages.toml` (минимальные валидные пакеты или пустой `[packages]`), `configs/sample.conf`.
- Добавить в `.github/workflows/ci.yml` job `module-check`:
  ```yaml
  module-check:
    name: Module check workflow
    uses: ./.github/workflows/module-check.yml
    with:
      ygg-version: ${{ github.sha }}
      module-path: tests/fixtures/module-sample
      packages: false
  ```
  *(Включить `packages: true` при наличии стабильных пакетов в фикстуре, проверив на реальном CI PR).*

- [ ] **Step 6: Run tests to verify pass**

Run:
```bash
rtk nu tests/run.nu --filter test_release
rtk nu bin/ygg.nu lint tests/fixtures/module-sample
```
Expected: `test_release` PASS; `ygg lint tests/fixtures/module-sample` возвращает `Lint: 0 error(s), 0 warning(s).` и код `0`.

- [ ] **Step 7: Commit**

```bash
rtk git add .github/workflows/module-check.yml .github/workflows/ci.yml scripts/release.nu tests/test_release.nu tests/fixtures/module-sample
rtk oco -y
```

---

### Task 6: Документация, обновление скилла `ygg-module-verification` и финальная верификация

**Files:**
- Modify: `README.md`
- Modify: `.agents/skills/ygg-module-verification/SKILL.md`

**Interfaces:**
- Consumes: финальные сигнатуры `ygg lint` и `.github/workflows/module-check.yml`.
- Produces: актуальная документация и скилл проверки модулей.

- [ ] **Step 1: Update `README.md`**

Добавить раздел «Проверка модуля» (§5.7 спеки):
- Использование `ygg lint [path] [--packages] [--os <list>] [--json]`.
- Настройка `pre-push` hook: Unix (`ygg lint || exit 1`) и Windows (через `.cmd`-шим).
- Подключение CI в модуле (5-строчный `.github/workflows/ygg.yml` с `uses: gidragir/ygg/.github/workflows/module-check.yml@vX.Y.Z`).
- Краткое описание опциональных фикстур `ci/hosts/*.toml`.

- [ ] **Step 2: Update `.agents/skills/ygg-module-verification/SKILL.md`**

Сделать `ygg lint <path>` (и `ygg lint <path> --packages`) первым шагом проверки модуля; ручной sandbox-сценарий оставить как шаг углублённой отладки.

- [ ] **Step 3: Full verification & drift audit**

Run:
```bash
rtk mise run test
rtk context-init update . --compact --prune
rtk context-init check --compact
```
Expected: все тесты зелёные, `context-init check` без дрейфа.

- [ ] **Step 4: Commit**

```bash
rtk git add README.md .agents/skills/ygg-module-verification/SKILL.md
rtk oco -y
```
