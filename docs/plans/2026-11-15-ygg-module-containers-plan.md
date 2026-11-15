# RFC-059 Контейнеры модулей — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** модуль объявляет контейнеры обычным compose-файлом, а `ygg` управляет их жизненным циклом: вопрос в `add`, `apply --containers/--no-containers [...modules]`, `upgrade --containers [...modules]`, `down` при `remove`, отображение в `status`/`doctor`.

**Architecture:** новый `src/container.nu` (обнаружение стеков, имя проекта, рантайм, argv, исполнение с моком, шаг apply, upgrade). `manifest.nu` кладёт стеки в `plan.containers`; `link.nu` проверяет их в `preflight-check`; `bin/ygg.nu` добавляет флаги, команду `upgrade` и шаг журнала `containers`.

**Tech Stack:** Nushell `>= 0.116`, TOML, `docker compose` / `podman compose` (только провайдер Compose v2).

**Spec:** [docs/specs/2026-11-15-ygg-module-containers-design.md](../specs/2026-11-15-ygg-module-containers-design.md). Исполнитель читает спеку и план вместе.

## Global Constraints

* Ветка: `feat/module-containers` от `main`. Незакоммиченные правки пользователя в `AGENTS.md` и `.agents/skills/*` не трогать и не включать в коммиты.
* Коммиты: Conventional Commits на английском, одна строка `<type>(<scope>): <subject>`, через `rtk oco -y` (или `rtk git commit -m` с той же строкой). Все шелл-вызовы — с префиксом `rtk`.
* Все команды рантайма — argv-списки (`list<string>`), без интерполяции в строку шелла. Пути — через `path expand -n`.
* Белый список: `export const CONTAINER_RUNTIMES = ["docker", "podman"]`.
* Ни один argv не содержит `-v`, `--volumes`, `--rmi`.
* Таймаут команды compose по умолчанию `600` с (`[ygg.containers].timeout`), через `run-with-timeout` из `src/pkg.nu`.
* Мок: при непустом `YGG_MOCK_PKG_LOG` каждая команда пишется строкой `container: <argv через пробел>`; `YGG_MOCK_CONTAINER_FAIL` — список подстрок argv через запятую, команды с ними «падают». Песочница (`YGG_SANDBOX`) без мок-лога → статус `skipped_sandbox`, ничего не выполняется.
* Дополнительно для тестов (решение плана): `YGG_MOCK_CONTAINER_STATUS` = `no_runtime` | `daemon_down` подменяет результат определения рантайма в мок-режиме; `YGG_MOCK_CONTAINER_RUNNING` — запущенные проекты через запятую для read-only опроса `status`/`doctor` (без записи в лог).
* Мок-проба рантайма: в мок-режиме `detect-container-runtime` и `list-running-projects` пишут в лог строку `container-probe: <argv>`. По ней тесты проверяют, что рантайм не опрашивался.
* **Порядок проверок в каждой точке входа** (`run-container-step`, `upgrade-containers`, `down-module-stacks`, `detect-container-runtime`, `list-running-projects`):
  1. `--dry-run` → рантайм не опрашивается;
  2. песочница без мок-лога → `skipped_sandbox`, внешних вызовов нет;
  3. мок-режим;
  4. реальный вызов.
* Песочница определяется так же, как в `run-service-actions`: `if ($sandbox != "") { $sandbox } else { ($env.YGG_SANDBOX? | default "") }`.
* Запись в `state.containers` и `state.hashes` делается только при `status == "ok"`. `skipped_*`, `dry_run` и `failed` состояние не меняют.
* Планы, собранные без поля контейнеров (тесты, `empty_plan` в `run-doctor`), читаются только через `($plan.containers? | default [])` и `($plan.container_settings? | default { runtime: "", timeout: 600 })`.
* Чтение YAML (`name:`, наличие `build:`): `from yaml` внутри `try`. При ошибке (например, теги `!reset`/`!override`, которые Nushell 0.116 не понимает) — запасной поиск регуляркой: верхнеуровневый `^name:\s*(\S+)` и любая строка `^\s+build:`.
* **Тесты и TTY:** `tests/run.nu` наследует stdin от терминала. Поэтому каждый e2e-тест, где `ygg add` вызывается для модуля со стеками без флага `--containers`/`--no-containers`, обязан задать `YGG_NONINTERACTIVE: "1"` в `with-env`. Иначе тест повиснет на `input` при запуске из терминала.
* Тесты — только внутри `with-temp-ygg`; пути производны от `home`; никаких литеральных `/tmp`. Отсутствие записи в файл проверяется по хэшу содержимого (`open --raw | hash sha256`), а не по mtime.
* `status`, `doctor` (без `--fix`), `diff`, `--dry-run` не пишут в `state.json`/`host.toml` и не вызывают мутирующих команд рантайма.
* Пользовательские строки (точный текст):
  * вопрос: `Module '<name>' declares containers (<rel1>, <rel2>). Start them now? [y/N]: `
  * подсказка без терминала: `[ygg] Containers of '<name>' are not started. Run: ygg apply --containers <name>`
  * dry-run: `"  " + ("CONTAINER" | fill -w 15) + " up <project>  (<module>: <rel>)"` и `... down <project>  (<module>: <reason>)`, где `<reason>` ∈ `removed from manifest` | `module removed` | `disabled`
* Тесты одной задачи: `nu tests/run.nu --filter <префикс>`; полный прогон один раз в конце — `rtk just test`.

## Review Focus

1. Путь к модулю или compose-файлу с пробелами → argv передаёт путь одним элементом, команда не ломается (тест в Task 3).
2. Имя модуля с заглавными буквами и точками (`My.Data`) → имя проекта нормализовано (`my-data`), compose его принимает (тест в Task 1).
3. `state.json` старой версии без ключа `containers` → `load-state` возвращает `containers: []`, `apply` не падает (тест в Task 1).
4. `containers = "yes"` (не bool) в `host.toml` → ошибка preflight `invalid_containers_flag`, а не молчаливое «выключено» (тест в Task 2).
5. Два включённых стека, `up` одного падает → второй всё равно поднят, код выхода 1, хэш упавшего не записан (тест в Task 4).

---

### Task 1: Обнаружение стеков и `plan.containers`

**Files:**
- Create: `src/container.nu`, `tests/test_container.nu`
- Modify: `src/mod.nu` (добавить `export use container.nu *`), `src/manifest.nu` (поле `containers` в `load-module-manifest` ~стр. 122-138; скоупы и сборка в `resolve-effective-plan` ~стр. 640-808), `src/state.nu:38-63` (`load-state`: ключ `containers`)

**Interfaces:**
- Produces:
  * тип `Stack = record<module: string, rel: string, file: string, override: string, project: string, enabled: bool>` (`file`/`override` — абсолютные, `override = ""` если нет)
  * `discover-stacks [module: string, mod_dir: string, cfg: record, scope_files: list<string>]: nothing -> list<Stack>` (`enabled: false`; проставляет вызывающий)
  * `compose-project-name [module: string, mod_dir: string, file: string]: nothing -> string`
  * `normalize-project-name [raw: string]: nothing -> string`
  * `find-override-file [file: string]: nothing -> string`
  * `plan.containers: list<Stack>` (все стеки модулей плана; `enabled = (containers_raw == true)`)
  * `plan.modules.*.containers_raw: any` — сырое значение ключа `containers` записи модуля в `host.toml` (`null`, если ключа нет); нужно preflight (Task 2)
  * `plan.container_settings: record<runtime: string, timeout: int>` (из `host.toml` `[ygg.containers]`, по умолчанию `{runtime: "", timeout: 600}`)
  * `load-state` возвращает ещё `containers: list` (по умолчанию `[]`); `save-state` сохраняет его как есть.

- [ ] **Step 0: Ветка и спека**

```bash
rtk git switch -c feat/module-containers
rtk git add docs/specs/2026-11-15-ygg-module-containers-design.md docs/plans/2026-11-15-ygg-module-containers-plan.md
rtk git commit -m "docs(containers): add RFC-059 spec and implementation plan"
```

- [ ] **Step 1: Написать падающие тесты** в `tests/test_container.nu` (импорт `use ../src *`, `use helpers.nu [with-temp-ygg, test-link-dir]`):

```nu
export def test_container_discover_default_order [] {
    # в корне модуля docker-compose.yml и compose.yml -> выбран compose.yml (порядок: compose.yaml, compose.yml, docker-compose.yaml, docker-compose.yml)
    # assert equal ($stacks | get rel) ["compose.yml"]; assert equal ($stacks.0.project) "ds"
}
export def test_container_discover_explicit_files_and_empty_list [] {
    # cfg {files: ["infra/pg/compose.yml"]} -> rel ["infra/pg/compose.yml"], project "ds-pg"
    # cfg {files: []} при наличии compose.yml в корне -> []
}
export def test_container_discover_scope_files_appended [] {
    # cfg {files: ["a/compose.yml"]}, scope_files ["b/compose.yml"] -> rel ["a/compose.yml", "b/compose.yml"]
}
export def test_container_project_name_rules [] {
    # name: "my-pg" в YAML -> "my-pg"; файл в корне -> имя модуля; невалидный YAML -> имя по умолчанию, без ошибки
    # compose с тегом `ports: !reset []` и `name: tagged` -> "tagged" (запасной поиск регуляркой)
    # assert equal (normalize-project-name "My.Data") "my-data"
}
export def test_container_override_detected [] {
    # compose.yml + compose.override.yml -> override == абсолютный путь; docker-compose.yml + docker-compose.override.yml -> тоже
}
export def test_container_plan_enabled_flag_and_settings [] {
    # host.toml: [[modules]] name="ds" containers=true ; [ygg.containers] runtime="podman"
    # plan.containers.0.enabled == true; plan.container_settings == {runtime: "podman", timeout: 600}
}
export def test_container_load_state_without_containers_key [] {
    # state.json = {"links":{}} -> (load-state $home).containers == []
}
```

- [ ] **Step 2: Запустить, убедиться что падают**

Run: `nu tests/run.nu --filter test_container_`
Expected: FAIL (compile error: `discover-stacks` not found).

- [ ] **Step 3: Реализовать** функции из Interfaces в `src/container.nu`. Подход:
  * автообнаружение зависит **только** от базового `cfg` (`[containers]`): ключа `files` нет → автообнаружение; `files = []` → базовый список пуст;
  * `resolve-effective-plan` в том же цикле активных скоупов, где `packages`, собирает `[scope.<name>.containers].files` в **отдельный** список `scope_files` (`append | uniq`) и передаёт его в `discover-stacks` вторым списком. В `cfg.files` скоупные файлы не сливаются: иначе модуль с `files` только в скоупе потерял бы автообнаружение. Итог: базовые (или автообнаруженные) стеки + стеки из `scope_files`, без дублей по `rel`;
  * `name:` читается `open --raw | from yaml` внутри `try`; проект по умолчанию: файл в корне → `<module>`, иначе `<module>-<basename родительского каталога>`; затем `normalize-project-name` (нижний регистр, всё вне `[a-z0-9_-]` → `-`, схлопнуть повторы, обрезать `-`/`_` по краям);
  * `find-override-file`: `<stem>.override.<ext>` рядом с файлом;
  * `manifest.containers` = `($raw.containers? | default {})`; `container.nu` не импортирует `manifest.nu` (иначе цикл).

- [ ] **Step 4: Тесты проходят**

Run: `nu tests/run.nu --filter test_container_` → все PASS; `nu tests/run.nu --filter test_manifest` → PASS (регрессия).

- [ ] **Step 5: Commit** — `feat(containers): discover compose stacks into plan`

---

### Task 2: Preflight для контейнеров

**Files:**
- Modify: `src/link.nu` (`preflight-check` ~стр. 938+, новый блок после `[services]`), `src/container.nu`
- Test: `tests/test_container.nu`

**Interfaces:**
- Consumes: `plan.containers`, `plan.container_settings`, `plan.modules.*.containers_raw` (Task 1).
- Produces: `export const CONTAINER_RUNTIMES = ["docker", "podman"]` в `container.nu`; `check-container-stacks [plan: record]: nothing -> list<record<module: string, key: string, reason: string, detail: string>>` в `container.nu`; `preflight-check` добавляет её результат. Причины (`reason`): `container_file_missing`, `container_path_outside_module`, `container_project_collision`, `invalid_container_runtime`, `invalid_containers_flag`.

- [ ] **Step 1: Падающие тесты**

```nu
export def test_container_preflight_missing_file_and_outside_path [] {
    # включённый модуль, files = ["nope.yml"] -> reason "container_file_missing"
    # files = ["../x/compose.yml"] и абсолютный путь -> "container_path_outside_module"
    # тот же модуль с containers=false -> проблем нет (проверяются только включённые)
}
export def test_container_preflight_project_collision [] {
    # два включённых модуля, у обоих в compose.yml `name: pg` -> одна проблема "container_project_collision"
}
export def test_container_preflight_runtime_and_flag_validation [] {
    # [ygg.containers] runtime = "nerdctl" -> "invalid_container_runtime"
    # [[modules]] containers = "yes" -> "invalid_containers_flag"
}
```

- [ ] **Step 2:** `nu tests/run.nu --filter test_container_preflight` → FAIL.
- [ ] **Step 3:** реализовать `check-container-stacks`; вызвать из `preflight-check`. `invalid_containers_flag`: `containers_raw` не `null` и не `bool`. Остальные проверки — только для `enabled` стеков.
- [ ] **Step 4:** `nu tests/run.nu --filter test_container_` и `--filter test_link` → PASS.
- [ ] **Step 5: Commit** — `feat(containers): validate stacks in preflight`

---

### Task 3: Рантайм, argv и исполнение команд

**Files:**
- Modify: `src/container.nu`
- Test: `tests/test_container.nu`

**Interfaces:**
- Consumes: `run-with-timeout [argv: list<string>, timeout_sec: int]: nothing -> record` (`src/pkg.nu`), `Stack`.
- Produces:
  * `compose-version-ok [output: string]: nothing -> bool` — true, если в выводе есть `Docker Compose version v?<major>.` с `major >= 2`
  * `detect-container-runtime [settings: record, --runtime: string = "", --sandbox: string = ""]: nothing -> record<runtime: string, status: string, detail: string>`; `status` ∈ `ok` | `no_runtime` | `unsupported_provider` | `daemon_down` | `skipped_sandbox`. Выбор рантайма: `--runtime` (конкретный, нужен для `down` по `entry.runtime`), иначе `settings.runtime`, иначе `docker`→`podman`. Проверки: `<rt> compose version` (+ `compose-version-ok`), затем проба демона `<rt> compose ls --format json`. В мок-режиме внешних вызовов нет: пишется `container-probe: <rt> compose version`, `runtime` выбирается так же (по умолчанию `docker`), `status` = `YGG_MOCK_CONTAINER_STATUS` или `ok`.
  * `build-compose-argv [runtime: string, action: string, stack: record]: nothing -> list<string>`; `action` ∈ `up` | `down` | `pull` | `build`:
    * `up`: `[rt compose -f <file> (-f <override>) -p <project> up -d --remove-orphans]`
    * `down`: `[rt compose -p <project> down]`
    * `pull`: `[rt compose -f <file> (-f <override>) -p <project> pull --ignore-buildable]`
    * `build`: `[rt compose -f <file> (-f <override>) -p <project> build --pull]`
  * `run-compose [argv: list<string>, timeout: int, --dry-run, --sandbox: string = ""]: nothing -> record<status: string, stderr: string>`; `status` ∈ `ok` | `failed` | `dry_run` | `skipped_sandbox`
  * `stack-has-build [file: string]: nothing -> bool` (какой-либо сервис с ключом `build`; YAML не читается → false)
  * `stack-inputs-hash [stack: record]: nothing -> string` (основной файл + override + `.env` в каталоге основного файла; отсутствующие пропускаются)

- [ ] **Step 1: Падающие тесты**

```nu
export def test_container_compose_version_parsing [] {
    assert (compose-version-ok "Docker Compose version v2.29.7")
    assert (compose-version-ok ">>>> Executing external compose provider \"/usr/bin/docker-compose\".\nDocker Compose version 2.31.0")
    assert (not (compose-version-ok "podman-compose version 1.2.0\npodman version 5.3.1"))
    assert (not (compose-version-ok "docker-compose version 1.29.2, build 5becea4c"))
}
export def test_container_argv_shapes_and_no_volume_flags [] {
    # stack с override и путём с пробелом ("my mod/compose.yml"):
    # up == ["docker" "compose" "-f" <file> "-f" <ovr> "-p" "ds" "up" "-d" "--remove-orphans"]; путь — один элемент
    # down == ["podman" "compose" "-p" "ds" "down"]
    # для всех action: argv не содержит "-v", "--volumes", "--rmi"
}
export def test_container_run_compose_mock_sandbox_dry_run [] {
    # YGG_MOCK_PKG_LOG=$log -> строка "container: docker compose -p ds down" в логе, status ok
    # YGG_MOCK_CONTAINER_FAIL="down" -> status failed
    # мок-лог пуст, YGG_SANDBOX задан -> skipped_sandbox, лог не создан
    # --dry-run -> dry_run, лог не создан
}
export def test_container_detect_runtime_mock [] {
    # мок, settings {runtime: ""} -> {runtime: "docker", status: "ok"}; settings runtime "podman" -> podman
    # YGG_MOCK_CONTAINER_STATUS=daemon_down -> status daemon_down
    # --runtime podman при settings.runtime "docker" -> runtime "podman"
    # песочница без мок-лога -> status skipped_sandbox, лог не создан
}
export def test_container_has_build_yaml_and_tag_fallback [] {
    # services.app.build: "." -> true; только image -> false; файл с `!override` и `build:` -> true
}
export def test_container_inputs_hash_tracks_override_and_env [] {
    # хэш меняется при правке compose.yml, compose.override.yml, .env; не меняется при правке Dockerfile
}
```

- [ ] **Step 2:** `nu tests/run.nu --filter test_container_` → новые FAIL.
- [ ] **Step 3:** реализовать функции из Interfaces. Для `unsupported_provider` в `detail` — подсказка `install the docker-compose v2 plugin`. Хэш — по образцу `hash-watch-set` (`src/sdk.nu:18`).
- [ ] **Step 4:** `nu tests/run.nu --filter test_container_` → PASS.
- [ ] **Step 5: Commit** — `feat(containers): add runtime detection and compose command layer`

---

### Task 4: Шаг `containers` в `apply`

**Files:**
- Modify: `src/container.nu`, `bin/ygg.nu` (`apply-plan` ~стр. 244-467), `src/state.nu` (`gc-state-hashes` ~стр. 736, `collect-active-hash-keys` ~стр. 774)
- Test: `tests/test_container.nu`

**Interfaces:**
- Consumes: всё из Task 1-3.
- Produces:
  * `run-container-step [ygg_home: string, plan: record, --dry-run, --force-up: list<string> = [], --strict, --sandbox: string = ""]: nothing -> record<status: string, results: list<record<module: string, project: string, action: string, status: string, stderr: string, reason: string>>>`
    * `status` шага ∈ `noop` | `ok` | `failed` | `skipped_no_runtime` | `skipped_daemon_down` | `skipped_sandbox` (`unsupported_provider` даёт `skipped_no_runtime`)
    * `--force-up`: модули, чьи включённые стеки поднимаются без проверки хэша
    * `--strict`: недоступный рантайм → `error make` вместо `skipped_*`
  * `state.containers: list<record<module: string, project: string, file: string, override: string, runtime: string>>`; хэш `state.hashes."containers:<module>:<project>"`
  * `apply-plan` получает флаги `--containers-enable: list<string> = []`, `--containers-disable: list<string> = []`. Запись в `host.toml` делается в Task 5.
  * `apply-container-overrides [plan: record, enable: list<string>, disable: list<string>]: nothing -> record` — ставит `enabled` у стеков этих модулей. `apply-plan` вызывает её **сразу после `resolve-effective-plan`, до `preflight-check`**, и в dry-run, и в реальном прогоне. Так `--dry-run` показывает те же ошибки preflight, что и реальный запуск.

Алгоритм `run-container-step` (§5.6 спеки):
1. `down`-кандидаты: записи `state.containers`, для которых в `plan.containers` нет включённого стека с тем же `(module, project)`; `reason`: модуля нет в плане → `module removed`, стек не объявлен → `removed from manifest`, модуль выключен → `disabled`.
2. `up`-кандидаты: включённые стеки, где модуль в `--force-up`, или стека нет в `state.containers`, или `stack-inputs-hash` ≠ сохранённого.
3. Нет кандидатов → `noop`, рантайм не определяется.
4. `--dry-run` → каждому кандидату `status: "dry_run"`, рантайм не опрашивается. `--force-up` учитывается и в dry-run.
5. Песочница без мок-лога → `skipped_sandbox` (см. Global Constraints).
6. Рантайм для `up` — `detect-container-runtime $settings`. Рантайм для каждого `down` — `detect-container-runtime $settings --runtime $entry.runtime`: стек опускается тем рантаймом, которым он был поднят, даже если `[ygg.containers].runtime` с тех пор сменили. Недоступный рантайм → кандидаты этого рантайма получают `skipped_*` (при `--strict` — ошибка), в stderr предупреждение, их состояние не меняется.
7. Выполнить все `down`, затем все `up`; ошибка одной команды не прерывает остальные. Успешный `down` снимает запись и хэш; успешный `up` пишет запись (с фактическим `runtime`) и хэш. Состояние сохраняется одним `save-state` в конце.

- [ ] **Step 1: Падающие тесты** (вызов `run-container-step` напрямую, мок-лог, `YGG_HOST_OS_OVERRIDE` как в `tests/test_sdk.nu:409`):

```nu
export def test_container_step_up_once_then_noop_then_hash_change [] {
    # 1-й вызов: лог == ["container: docker compose -f <f> -p ds up -d --remove-orphans"], state.containers.0.project == "ds"
    # 2-й вызов без изменений: status "noop", лог не растёт (в том числе нет строк "container-probe:")
    # правка compose.yml -> 3-й вызов: ещё одна строка up
}
export def test_container_step_down_for_removed_and_disabled [] {
    # после up: containers=false в host.toml -> down, reason "disabled", state.containers == [], хэш удалён
    # после up: модуль удалён из host.toml -> down "module removed"
    # после up: файл убран из files -> down "removed from manifest" (argv без -f)
    # после up docker'ом: [ygg.containers] runtime = "podman", containers=false -> down выполняется "docker compose -p ds down"
}
export def test_container_step_sandbox_without_mock_touches_nothing [] {
    # YGG_MOCK_PKG_LOG = "", YGG_SANDBOX задан, стек включён -> status "skipped_sandbox", state.containers == [], хэша нет
}
export def test_container_step_partial_failure [] {
    # два включённых модуля, YGG_MOCK_CONTAINER_FAIL="-p a " -> status "failed", стек b в state.containers, хэша a нет
}
export def test_container_step_runtime_unavailable_soft_and_strict [] {
    # YGG_MOCK_CONTAINER_STATUS=daemon_down -> status "skipped_daemon_down", state не изменён
    # то же с --strict -> ошибка (assert error)
}
export def test_container_step_force_up_and_dry_run [] {
    # --force-up ["ds"] без изменений -> up выполняется
    # --dry-run -> results с status "dry_run", лог и state.json не тронуты
}
export def test_container_hash_keys_survive_gc [] {
    # collect-active-hash-keys содержит "containers:ds:ds" для включённого стека; gc-state-hashes удаляет ключ стека, которого нет в плане
}
```

- [ ] **Step 2:** `nu tests/run.nu --filter test_container_` → FAIL.
- [ ] **Step 3:** реализовать `run-container-step` и `apply-container-overrides`. В `gc-state-hashes` добавить префикс `containers:` к ветке «удалять, если не в active_keys»; в `collect-active-hash-keys` — ключи включённых стеков. Журнал: добавить `containers` между `services` и `finalize` в `steps` у `begin-journal-transaction` (`src/state.nu:442`) и в списки известных шагов (`src/state.nu:496, 588, 622`).
- [ ] **Step 4: Встроить в `apply-plan`:**
  * сразу после `resolve-effective-plan` (до `preflight-check`): `apply-container-overrides`;
  * dry-run: вызвать `run-container-step --dry-run --force-up $containers_enable`, напечатать строки `CONTAINER` (формат из Global Constraints), прибавить их к счётчику изменений;
  * реальный прогон: после блока `services` — `record-journal-step "containers"`; `IN_PROGRESS` → `run-container-step --force-up $containers_enable --strict=(($containers_enable | is-not-empty) or ($containers_disable | is-not-empty))`; `failed` → `FAILED` и сообщение `Container actions failed: <module>: <action> <project> (<stderr>), ...` в `$errors`; любой другой статус → `COMMITTED`.
- [ ] **Step 5:** добавить e2e в `tests/test_cli_e2e.nu`:

```nu
export def test_cli_apply_runs_container_step_from_host_toml [] {
    # host.toml containers=true, ^nu ygg.nu apply -> в мок-логе строка up; повторный apply -> строк не добавилось
    # ^nu ygg.nu apply --dry-run после правки compose.yml -> stdout содержит "CONTAINER" и " up ds  (ds: compose.yml)"
}
```

- [ ] **Step 6:** `nu tests/run.nu --filter test_container_` и `--filter test_cli` → PASS.
- [ ] **Step 7: Commit** — `feat(containers): add containers step to apply pipeline`

---

### Task 5: `apply --containers/--no-containers` и вопрос в `add`

**Files:**
- Modify: `bin/ygg.nu` (`main apply` ~стр. 212, `main add` ~стр. 97), `src/container.nu`
- Test: `tests/test_cli_e2e.nu`, `tests/test_container.nu`

**Interfaces:**
- Consumes: `apply-plan --containers-enable/--containers-disable` (Task 4), `load-host-config`/`save-host-config` (`src/manifest.nu:7,25`), `resolve-effective-plan`, `discover-stacks`.
- Produces:
  * `resolve-container-targets [plan: record, modules: list<string>, mode: string]: nothing -> list<string>` (`mode` ∈ `enable` | `disable`); пустой `modules` → `enable`: все модули со стеками, `disable`: все модули с `enabled`. Неизвестный модуль или модуль без стеков → `error make` с текстом `Module '<m>' not found` / `Module '<m>' declares no containers`.
  * `set-modules-containers [ygg_home: string, names: list<string>, value: bool]: nothing -> nothing` — пишет `containers = <value>` в записи модулей `host.toml`.
  * `parse-yes-answer [answer: string]: nothing -> bool` (чистая) — `y`/`yes` без учёта регистра и пробелов по краям → true, всё остальное (включая пустую строку) → false.
  * `ask-containers [name: string, rels: list<string>]: nothing -> bool` — сначала `YGG_NONINTERACTIVE == "1"`, затем `not (is-terminal --stdin)` → false без вопроса, с подсказкой (текст в Global Constraints). Иначе `input` с точным текстом вопроса → `parse-yes-answer` (ошибка `input` → false).
  * `main apply [...modules: string, --containers, --no-containers, ...существующие флаги]`
  * `main add [source, --containers, --no-containers, ...]`

Правила `main apply`:
* `modules` без `--containers`/`--no-containers` → ошибка `module names require --containers or --no-containers`; оба флага сразу → ошибка `--containers and --no-containers are mutually exclusive`.
* Цели вычисляются до мутаций. Не dry-run: под уже взятым host lock сначала `resolve-effective-plan` → `apply-container-overrides` → `check-container-stacks`. При проблемах — ошибка, `host.toml` не меняется. Только после этого `set-modules-containers`, затем `apply-plan --containers-enable/--containers-disable`. Dry-run: `host.toml` не трогается, переопределение только через флаги `apply-plan`.

Правила `main add`:
* После `add-module ... --dry-run` (стейджинг) и до `preflight-check`: `resolve-effective-plan $ygg_home --extra-modules $extra` и фильтр `plan.containers` по имени модуля. Так учитываются активные скоупы: `eval-scope-expression` живёт в `manifest.nu` и из `container.nu` недоступна. Нет стеков → флаг не пишется. Есть: значение = флаг, иначе `ask-containers`. При `--dry-run` вопрос не задаётся, значение = флаг или false.
* Значение кладётся в `$extra` (`containers: <bool>`), план пересобирается, и preflight проверяет стеки уже с учётом ответа. В `host.toml` значение попадает через `register-staged-module` (`src/git.nu:115`): вызывать его с `($prep | insert containers $value)` и в нём делать `upsert containers`, если ключ есть.

- [ ] **Step 1: Падающие тесты**

```nu
export def test_container_parse_yes_answer [] {
    assert (parse-yes-answer "y"); assert (parse-yes-answer " YES ")
    assert (not (parse-yes-answer "")); assert (not (parse-yes-answer "n")); assert (not (parse-yes-answer "yep"))
}
export def test_cli_add_noninteractive_defaults_containers_off [] {
    # YGG_NONINTERACTIVE=1: ^nu ygg.nu add <mod с compose.yml> -> host.toml: containers == false; stderr содержит "ygg apply --containers ds"; в мок-логе нет "container:"
}
export def test_cli_add_scope_only_stack_triggers_question_path [] {
    # YGG_NONINTERACTIVE=1, compose только в [scope.linux.containers].files, YGG_HOST_OS_OVERRIDE=cachyos -> containers == false записан (стек найден через скоуп)
}
export def test_cli_apply_containers_preflight_failure_keeps_host_toml [] {
    # два модуля с `name: pg`, у первого containers=true: apply --containers second -> exit != 0, "container_project_collision"; хэш host.toml не изменился
}
export def test_cli_add_containers_flag_starts_stack [] {
    # add --containers -> containers == true, в логе строка up
    # add <mod без compose> -> ключа containers в записи нет
}
export def test_cli_add_dry_run_does_not_touch_host_toml [] {
    # add --dry-run --containers -> host.toml не создан/не изменён
}
export def test_cli_apply_containers_enable_disable_targets [] {
    # два модуля со стеками (ds, ml), оба добавлены с --no-containers: apply --containers ds -> ds = true, ml = false, up только для ds
    # apply --no-containers (без имён) -> ds = false, ml остаётся false, в логе down для ds
    # apply --containers (без имён) -> ds = true и ml = true, в логе up для обоих
}
export def test_cli_apply_container_argument_errors [] {
    # apply ds (без флага) -> exit != 0, сообщение "module names require --containers or --no-containers"
    # apply --containers --no-containers -> exit != 0
    # apply --containers nope -> "Module 'nope' not found"; host.toml не изменён
    # apply --containers <модуль без стеков> -> "declares no containers"
}
export def test_cli_apply_containers_strict_when_runtime_down [] {
    # YGG_MOCK_CONTAINER_STATUS=no_runtime: apply --containers ds -> exit != 0; обычный apply -> exit 0 и предупреждение
}
```

- [ ] **Step 2:** `nu tests/run.nu --filter test_cli_a` → FAIL.
- [ ] **Step 3:** реализовать по правилам выше.
- [ ] **Step 4:** `nu tests/run.nu --filter test_cli` и `--filter test_container_` → PASS.
- [ ] **Step 5: Commit** — `feat(containers): add --containers flags to add and apply`

---

### Task 6: `ygg upgrade --containers` и `down` при `remove`

**Files:**
- Modify: `bin/ygg.nu` (новая `main upgrade` рядом с `main update` ~стр. 480; `main remove` ~стр. 186), `src/container.nu`, `src/git.nu:196` (`remove-module`)
- Test: `tests/test_cli_e2e.nu`, `tests/test_container.nu`

**Interfaces:**
- Consumes: `resolve-container-targets`, `detect-container-runtime`, `build-compose-argv`, `run-compose`, `stack-has-build`, `stack-inputs-hash`.
- Produces:
  * `upgrade-containers [ygg_home: string, plan: record, modules: list<string>, --dry-run, --sandbox: string = ""]: nothing -> list<record<module: string, project: string, status: string, stderr: string>>` — цели: указанные модули (каждый должен быть `enabled`, иначе ошибка `Containers of '<m>' are disabled. Run: ygg apply --containers <m>`) или все включённые. Рантайм недоступен → ошибка. Для стека: `pull` → (`build`, если `stack-has-build`) → `down` → `up`; первый неуспешный шаг останавливает этот стек, остальные стеки продолжаются; успешный `up` обновляет хэш и запись в `state.containers`.
  * `down-module-stacks [ygg_home: string, module: string, settings: record, --sandbox: string = ""]: nothing -> list<record>` — `down` для всех записей модуля в `state.containers`, каждая — своим `entry.runtime` (`detect-container-runtime $settings --runtime $entry.runtime`). Записи снимаются всегда. При сбое, недоступном рантайме или песочнице без мока — предупреждение с командой для ручного запуска (`<rt> compose -p <project> down`). `settings` передаёт вызывающий (`container.nu` не импортирует `manifest.nu`).
  * `main upgrade [...modules: string, --containers, --dry-run (-n), --no-lock, --sandbox: string = ""]`:
    * без `--containers` → ошибка `upgrade requires a target: --containers`;
    * в начале `assert-sandbox-home`, как в `main apply`;
    * `--dry-run` печатает каждую команду строкой `"  " + ("CONTAINER" | fill -w 15) + " " + (argv | str join " ")`, ничего не выполняет и lock не берёт;
    * иначе берёт `acquire-host-lock $ygg_home "upgrade"`;
    * exit 1, если хоть один стек не `ok`.
  * `remove-module [ygg_home: string, name: string, --sandbox: string = ""]` — читает `[ygg.containers]` из `load-host-config` и вызывает `down-module-stacks` перед `unlink-module`. `main remove` пробрасывает `--sandbox`.

- [ ] **Step 1: Падающие тесты**

```nu
export def test_cli_upgrade_order_pull_down_up [] {
    # включённый ds после apply: upgrade --containers -> последние 3 строки лога: pull --ignore-buildable, down, up -d --remove-orphans
}
export def test_cli_upgrade_with_build_service [] {
    # compose.yml с build: . -> между pull и down строка "build --pull"
}
export def test_cli_upgrade_pull_failure_keeps_containers [] {
    # YGG_MOCK_CONTAINER_FAIL="pull" -> exit != 0, в логе нет down после pull
}
export def test_cli_upgrade_errors [] {
    # upgrade (без --containers) -> exit != 0 "upgrade requires a target"
    # upgrade --containers ds при containers=false -> exit != 0 "are disabled"
    # upgrade --containers --dry-run -> строки в stdout, лог не растёт
}
export def test_cli_remove_downs_stacks_without_volumes [] {
    # после apply с ds: remove ds -> в логе "container: docker compose -p ds down", ни одной строки с "-v"/"--volumes"; state.containers == []
}
```

- [ ] **Step 2:** `nu tests/run.nu --filter test_cli_upgrade` и `--filter test_cli_remove` → FAIL.
- [ ] **Step 3:** реализовать функции и команды.
- [ ] **Step 4:** `nu tests/run.nu --filter test_cli` и `--filter test_container_` → PASS.
- [ ] **Step 5: Commit** — `feat(containers): add upgrade --containers and down on remove`

---

### Task 7: `status`, `doctor`, документация

**Files:**
- Modify: `src/git.nu:423` (`modules-status`), `src/doctor.nu:392` (`run-doctor`, новая `check-containers`), `src/container.nu`, `README.md`, `AGENTS.md` (§1 — ссылки на спеку и план; только эти строки, правки пользователя не трогать)
- Test: `tests/test_doctor.nu`, `tests/test_cli_e2e.nu`, `tests/test_pkg_git.nu:716` (точный список колонок `modules-status` — добавить `containers` в конец)

`modules-status` **не** вызывает `resolve-effective-plan`: сломанный модуль не должен ронять `status`. Для каждой записи `host.toml`: `try { load-module-manifest; discover-stacks }`, при ошибке значение колонки `?`. Рантайм опрашивается один раз и только если есть хотя бы один включённый стек. `[scope.*.containers]` здесь не учитываются (только базовые/автообнаруженные стеки) — это решение плана, чтобы не тянуть оценку скоупов в `status`.

**Interfaces:**
- Consumes: `plan.containers`, `state.containers`, `detect-container-runtime`.
- Produces:
  * `container-status-label [stacks: list, state_containers: list, runtime: record, running: list<string>]: nothing -> string` (чистая) → `-` | `off` | `on N/M running` | `on (no runtime)` | `on (daemon down)`
  * `list-running-projects [runtime: string]: nothing -> list<string>` — один вызов `<rt> compose ls --format json`, только чтение; в мок-режиме — `YGG_MOCK_CONTAINER_RUNNING` (проекты через запятую, решение плана), без записи в лог
  * колонка `containers` в строках `modules-status`
  * `check-containers [plan: record, state: record]: nothing -> list<record>` → находки `finding "containers" "warn" <project> <detail> "run: ygg apply"`: включённый стек не запущен; включённые модули при недоступном рантайме; запись `state.containers`, которой нет среди стеков плана. `doctor-fix` эти находки пропускает.

- [ ] **Step 1: Падающие тесты**

```nu
export def test_container_status_label_values [] {
    # нет стеков -> "-"; стеки есть, не включены -> "off"; 1 из 2 запущен -> "on 1/2 running"; runtime daemon_down -> "on (daemon down)"
}
export def test_doctor_container_findings_read_only [] {
    # включённый ds, YGG_MOCK_CONTAINER_RUNNING="" -> warn с check "containers"; хэш содержимого state.json не изменился; в мок-логе только строки "container-probe:"
}
export def test_cli_status_shows_containers_column [] {
    # ^nu ygg.nu status --json -> у ds поле containers == "on 1/1 running" при YGG_MOCK_CONTAINER_RUNNING="ds"
    # второй модуль с битым ygg.toml -> status не падает, у него containers == "?"
}
```

- [ ] **Step 2:** `nu tests/run.nu --filter test_container_status`, `--filter test_doctor_container`, `--filter test_cli_status` → FAIL.
- [ ] **Step 3:** реализовать. Документация: раздел «Контейнеры» в `README.md` (пример `data-science` из §6 спеки, команды, «только Compose v2», «тома не удаляются»); в `AGENTS.md` §1 — две строки со ссылками на спеку и план RFC-059.
- [ ] **Step 4: Полный прогон и дрейф**

Run: `rtk just test` → все PASS (кроме пропущенного `test_phase2_modules.nu`).
Run: `rtk context-init update . --compact`, затем `rtk context-init check --compact` → без дрейфа.

- [ ] **Step 5: Commit** — `feat(containers): show containers in status and doctor` (код и `.context-init/` вместе; `AGENTS.md` — `rtk git add -p`, только строки RFC-059).
