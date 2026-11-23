---
name: ygg-module-verification
description: Use when checking a ygg module via ygg lint or sandbox apply (ygg.toml, links, setup.nu, packages, compose) before pushing or after migrating dotfiles, or when diagnosing link, package or preflight conflicts of a module without touching the real host.
---

# Проверка модуля ygg

## Обзор

Проверка модуля состоит из двух уровней:

1. **Первый шаг — `ygg lint <path>`** (и `ygg lint <path> --packages`): read-only проверка движка без изменения `~/.ygg`, `$HOME` и `host.toml`. Команда сама поднимает одноразовую песочницу и удаляет её по завершении. Проверяет схемы (L1), источники во **всех** `[scope.*]` и `mode = "dir"` (L2), выражения scopes (L3), синтаксис `setup.nu` (L4), план `apply` и `preflight-check` по ОС и наборам scopes или фикстурам `ci/hosts/*.toml` (L5), `compose config -q` и (с `--packages`) существование пакетов (L6). Код выхода `1` — только при наличии `error`.
2. **Второй шаг (углублённая отладка) — ручная одноразовая песочница:** `ygg lint` не исполняет `setup.nu` и не создаёт реальных ссылок на диске. Для отладки `apply`, поведения `setup.nu`, `doctor`, `status` или кэша пакетов используется отдельная сессия `nu` со своим `YGG_HOME`, `HOME` и **копией** модуля. Реальный `~/.ygg` не читается и не меняется (AGENTS.md §2.1); `mise run test` проверяет код движка, а не конкретный модуль.

## Шаг 1. Базовая проверка (`ygg lint`)

Из корня репозитория движка (или через установленный `ygg`):

```nushell
let ygg = ("bin/ygg.nu" | path expand)
nu $ygg lint ~/dev/my-module
nu $ygg lint ~/dev/my-module --packages
nu $ygg lint ~/dev/my-module --os linux,windows --json
```

* Если у модуля есть `depends_on`, нужные сочетания scopes или `config`, заведите фикстуры `ci/hosts/*.toml` — без них L5 проверит одиночный модуль и понизит `missing_dependency` до `warn`.
* Находки L5 для чужой ОС помечаются `cross_os: true` (окончательная проверка для целевой ОС выполняется нативным прогоном в CI через `.github/workflows/module-check.yml`).
* Если `ygg lint` зелёный, но нужно проверить фактическое исполнение `setup.nu`, создание симлинков/junction, мок контейнеров или повторный `diff` — переходите к Шагу 2.

## Шаг 2. Углублённая отладка в одноразовой песочнице

### До запуска

- Прочитай `setup.nu`: `apply` выполняет его по-настоящему. Пути он должен брать из `YGG_SANDBOX`/SDK — `~` и `$nu.home-path` на Windows смотрят в реальный профиль при любом `USERPROFILE`, это дефект модуля.
- Выпиши из `ygg.toml` пользовательские scopes (`[scope.<name>]`, кроме ОС) — их нужно включить в `host.toml`, иначе план почти пуст и «зелёный».

### Порядок

Отдельная сессия `nu` в корне репозитория движка (переменные ниже живут до выхода из неё):

```nushell
let ygg = ("bin/ygg.nu" | path expand)
let root = (mktemp -d -t ygg-verify.XXXXXX)
let yh = ($root | path join "ygg")
let home = ($root | path join "home")
mkdir ($yh | path join "modules") $home
# Копия, а не `ygg add <путь>`: add ставит junction/симлинк на рабочее дерево,
# и тогда `rm -r` песочницы или [save] дотянутся до ваших файлов.
cp -r ~/dev/my-module ($yh | path join "modules" "my-module")
# scopes — из ygg.toml модуля; containers = true, только если в модуле есть compose
"[[modules]]\nname = \"my-module\"\nscopes = [\"work\"]\ncontainers = true\n" | save ($yh | path join "host.toml")
load-env {
    YGG_HOME: $yh, YGG_SANDBOX: $home,
    YGG_MOCK_PKG_LOG: ($root | path join "pkg.log"),   # пакеты и compose пишутся в лог, не выполняются
    YGG_NONINTERACTIVE: "1",                           # иначе вопрос о контейнерах повесит команду
    HOME: $home, USERPROFILE: $home, XDG_CONFIG_HOME: ($home | path join ".config"),
    APPDATA: ($home | path join "AppData" "Roaming"), LOCALAPPDATA: ($home | path join "AppData" "Local")
}
```

1. **План:** `nu $ygg diff --sandbox $home` — `LINK`/`PRUNE`/`HOOK`/`PKG`/`SETUP` и ошибки preflight. `SETUP (skipped)` — норма без `[setup] dry_run_safe = true`.
2. **Применение:** `nu $ygg apply --sandbox $home --no-lock`.
3. **Проверки:**
   - `nu $ygg doctor --json --sandbox $home` → `[]` (битые, осиротевшие, затенённые ссылки, включая junction);
   - `open ($root | path join "pkg.log")` — менеджеры и ID пакетов для активных scopes;
   - повторный `diff` → `Plan: 0 change(s)` (пакеты — `SKIP (cached)`).
4. **Другие ОС:** `with-env { YGG_HOST_OS_OVERRIDE: "linux" } { nu $ygg diff --sandbox $home }` (также `windows`, `macos`, `cachyos`). Unix-only шаг без альтернативы в `[scope.windows]` — дефект модуля (AGENTS.md §2.4).
5. **Уборка:** `rm -rf $root` и выход из сессии `nu`.

## Модули с контейнерами

Моки — AGENTS.md §2.6. Проверь:
- `diff` показывает `CONTAINER up <module>`; в `pkg.log` строки `container: docker compose -f ... up -d --remove-orphans` без `-v`, `--volumes`, `--rmi`;
- `nu $ygg status --json` (флага `--sandbox` нет, читает `YGG_HOME`): `containers` — `on 0/1 running`, не `off` и не `?`;
- `doctor` предупреждает `container stack ... is not running` — норма для мока; с `YGG_MOCK_CONTAINER_RUNNING: "my-module"` в `load-env` предупреждение пропадает и `status` даёт `on 1/1 running`.

## Частые ошибки

| Ошибка | Как правильно |
|---|---|
| Ручная песочница до `ygg lint` | Сначала `ygg lint <path>` (и `--packages`) — ловит схемы, все `[scope.*]` и `setup.nu` |
| `doctor`/`status`/`diff` без `YGG_HOME` | Это чтение реального `~/.ygg` — только в песочнице |
| Литеральный `/tmp/...` | `mktemp -d -t ygg-verify.XXXXXX` |
| `ygg add ~/dev/my-module` в песочнице | Копия в `$YGG_HOME/modules/` + `host.toml` |
| `host.toml` без scopes или `containers` модуля | Пустой план проходит «зелёным» |
| `fd --type l` для битых ссылок | `doctor --json`: `fd` не видит junction |
