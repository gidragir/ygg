# ygg Engine (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Создать в корне репозитория `ygg` автономный кроссплатформенный CLI-менеджер модулей `ygg` на Nushell с полным покрытием изолированными ФС-автотестами (Этап 1 спецификации).

**Architecture:** Независимый от `omni-dotfiles` пакет модулей Nushell (`src/*.nu`) с точками входа `bin/ygg` (Unix) и `bin/ygg.cmd` (Windows Non-Admin), управляющий единой директорией `$YGG_HOME` (`~/.ygg/`). Вся работа с ФС, пакетными менеджерами и сессией ОС параметризуется переменными `YGG_HOME`, `--sandbox` и `YGG_MOCK_PKG`, что позволяет выполнять полный цикл интеграционных тестов в `/tmp` без затрагивания хоста.

**Tech Stack:** Nushell (`nu`), `TOML` (нативный парсер Nushell), `git`, `just` (`set shell := ["nu", "-c"]`), `mise`.

**Spec:** `docs/specs/2026-11-07-modular-omni-architecture-design.md`

## Global Constraints

- Репозиторий движка создаётся изолированно в корне репозитория `ygg` (живой `$HOME` хоста во время разработки и тестов не модифицируется).
- Нулевой внешний шаблонизатор (`Zero-Templates`): все манифесты строго в формате `TOML` (`host.toml`, `secrets.toml`, `ygg.toml`, опциональные `packages.toml`, `links.toml`, `env.toml`, `aliases.toml`), внутренний стейт — `.state/state.json`.
- Windows Non-Admin: запрещены файловые симлинки на Windows и требования Developer Mode; для папок используется `cmd /c mklink /J` (NTFS Junction), для одиночных файлов и `[save]` — контролируемое копирование с `3-way hash sync`, для скриптов в `bin` — автогенерация `.cmd`-врапперов.
- Чистота ОС (`Zero-Trash`): бэкапы сохраняются только в `$YGG_HOME/.state/backups/<timestamp>/`, никаких `.bak` внутри `~/.config/`; удаление ссылок (`unlink`/`prune`) удаляет только сам симлинк/Junction, никогда не удаляя рекурсивно содержимое целевых папок.
- Инвариант терминала хоста: все shell-вызовы при разработке и проверках выполняются с префиксом `rtk`; использование GNU `find` и `grep` запрещено (использовать нативные команды Nushell, `fd` и `rg`).

## Review Focus

- Битый (dangling) симлинк в точке назначения `dest` (где `path exists` возвращает `false`, но сам файл ссылки существует): линкер обязан распознать битую ссылку и атомарно заменить её новой ссылкой без падения `File exists` и без копирования мусора в `.state/backups/` (проверяется в Task 3: `test_replaces_dangling_symlink_without_backup`).
- Смена скоупа модуля в `host.toml` (например, `scopes = ["pc"]` -> `scopes = ["asus"]`): ссылки отключённого скоупа должны удаляться при следующем `ygg apply`, а физическое содержимое папок модуля (аналог `noctalia`) обязано оставаться нетронутым (проверяется в Task 3: `test_scope_switch_prunes_old_links_safely`).
- Спецсимволы, пробелы, кавычки и знаки `$` / `=` в значениях `~/.ygg/secrets.toml` (например, `TOKEN = 'pa$$w0rd="x"&y=1'`): генератор `env.{nu,zsh,ps1}`, `99-ygg.conf` и `export-secrets` обязан экранировать строки без выполнения подстановок шелла и синтаксических сбоев (проверяется в Task 5: `test_env_special_chars_escaping`).
- Отсутствующий, пустой (0 байт) или являющийся старым симлинком целевой файл при вызове `ygg merge-json` (`~/.gemini/config/config.json`): функция обязана создать родительскую папку, снять симлинк (превратив таргет в обычный файл), слить JSON с `{}` и выставить права `0600` на Unix (проверяется в Task 4: `test_merge_json_missing_and_symlink_target`).
- Конфликт слияния при `ygg update` в модуле с локальной правкой отслеживаемого файла: движок обязан перехватить сбой `git pull --rebase --autostash`, выполнить откат `git rebase --abort` с восстановлением рабочего дерева (без маркеров `<<<<<<<` в живых конфигах) и вернуть понятную ошибку (проверяется в Task 6: `test_update_aborts_cleanly_on_conflict`).

---

## File Structure (корень репозитория `ygg`)

- `mise.toml` — фиксация `nushell` и `just` для проекта.
- `justfile` — рецепты `test` и `check` (`set shell := ["nu", "-c"]`).
- `.gitignore`, `README.md`, `AGENTS.md` — метаданные и правила репозитория движка.
- `src/state.nu` — разрешение `$YGG_HOME`, чтение/запись `.state/state.json`, перенос оригиналов в `.state/backups/`, автодетект ОС/дистрибутива и раскрытие токенов путей (`~`, `$APPDATA`, `$LOCALAPPDATA`, `$DOCUMENTS`).
- `src/manifest.nu` — загрузка `host.toml` и модульного `ygg.toml` (+ слияние опциональных `packages.toml`, `links.toml`, `env.toml`, `aliases.toml`), проверка совместимости `os`, фильтрация авто-скоупов ОС и пользовательских `scopes`, применение `exclude` и `Last-Module-Wins`.
- `src/link.nu` — создание симлинков/Junctions, поштучное раскрытие `/*` с защитой от чужого симлинка-родителя, `3-way hash sync` для одиночных файлов Windows и `[save]`, генерация `.cmd`-шиммов, безопасный `prune` и `unlink`.
- `src/sdk.nu` — функции `onchange`, `merge-json`, `export-secrets` и изолированный запуск `setup.nu` модуля.
- `src/env.nu` — каскадная сборка `env.toml` + `aliases.toml` + `secrets.toml` в `.state/env/{env,aliases}.{nu,zsh,ps1}`, `local.nu`, `~/.config/environment.d/99-ygg.conf` (Linux) и `HKCU\Environment` (Windows).
- `src/pkg.nu` — пакетные драйверы (`pacman`, `paru`, `mise`, `cargo`, `winget`, `scoop`, `pnpm`, `uv`) с режимами `--dry-run`, `--sandbox` и `YGG_MOCK_PKG`.
- `src/git.nu` — управление модулями в `$YGG_HOME/modules/` (`add-module`, `remove-module`, `update-modules`, `modules-status`).
- `src/mod.nu` — публичный реэкспорт ядра и SDK.
- `bin/ygg.nu`, `bin/ygg`, `bin/ygg.cmd` — CLI-диспетчер 7 команд (`init`, `add`, `remove`, `apply`, `update`, `save`, `status`) и платформенные точки входа.
- `scripts/install.sh`, `scripts/install.ps1`, `tests/sandbox.wsb` — бутстрапперы с нуля и конфигурация Windows Sandbox.
- `tests/run.nu`, `tests/helpers.nu`, `tests/test_*.nu` — набор изолированных автотестов в `/tmp`.

---

### Task 1: Project Scaffold, Test Harness & `src/state.nu`

**Files:**
- Create: `/data/projects/ygg/mise.toml`
- Create: `/data/projects/ygg/justfile`
- Create: `/data/projects/ygg/.gitignore`
- Create: `/data/projects/ygg/AGENTS.md`
- Create: `/data/projects/ygg/src/state.nu`
- Create: `/data/projects/ygg/tests/helpers.nu`
- Create: `/data/projects/ygg/tests/test_state.nu`
- Create: `/data/projects/ygg/tests/run.nu`

**Interfaces:**
- Consumes: `$env.YGG_HOME?`, `$env.YGG_SANDBOX?`, `$env.YGG_HOST_OS_OVERRIDE?` (для кроссплатформенных тестов).
- Produces (`src/state.nu`):
  - `export def get-ygg-home []: nothing -> string` (возвращает `$env.YGG_HOME` или `("~/.ygg" | path expand)`).
  - `export def ensure-ygg-dirs [ygg_home: string]: nothing -> nothing` (создаёт `modules`, `.state`, `.state/backups`, `.state/env`).
  - `export def load-state [ygg_home: string]: nothing -> record` (возвращает `{ links: {}, copies: {}, hashes: {} }`).
  - `export def save-state [ygg_home: string, state: record]: nothing -> nothing` (атомарная запись `.state/state.json`).
  - `export def detect-host-os []: nothing -> record<os: string, distro: string, auto_scopes: list<string>>` (на CachyOS возвращает `{ os: "linux", distro: "cachyos", auto_scopes: ["linux", "unix", "cachyos", "arch"] }`; учитывает `ID` и `ID_LIKE` из `/etc/os-release`; на Windows — `{ os: "windows", distro: "windows", auto_scopes: ["windows"] }`; поддерживает переопределение через `$env.YGG_HOST_OS_OVERRIDE` в тестах).
  - `export def expand-target-path [raw_path: string, --sandbox: string = ""]: nothing -> string` (раскрывает `~`, `$APPDATA`, `$LOCALAPPDATA`, `$DOCUMENTS`; если передан `--sandbox` или задана переменная `$env.YGG_SANDBOX`, перепривязывает все домашние пути внутрь песочницы, гарантируя 100% защиту живого `$HOME` во всех подкомандах).
  - `export def backup-existing [ygg_home: string, target_path: string]: nothing -> string` (перемещает обычный файл/папку в `.state/backups/<timestamp>/<sanitized_rel_path>` и возвращает путь бэкапа).

- [ ] **Step 1: Создать конфиги тулчейна `mise.toml` и `justfile` в корне `/data/projects/ygg`**

Репозиторий, `.gitignore` и `AGENTS.md` уже инициализированы. Записать `mise.toml` (`nushell = "latest"`, `just = "latest"`) и `justfile` с `set shell := ["nu", "-c"]` и рецептом `test: nu tests/run.nu`.

- [ ] **Step 2: Написать падающие тесты в `tests/helpers.nu`, `tests/test_state.nu` и `tests/run.nu`**

```nushell
# tests/test_state.nu
use std/assert
use ../src/state.nu *
use helpers.nu [with-temp-ygg]

export def test_state_roundtrip_and_dirs [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        assert (($home | path join "modules" | path exists))
        let st = (load-state $home | upsert hashes { test_key: "abc" })
        save-state $home $st
        assert equal ((load-state $home).hashes.test_key) "abc"
    }
}

export def test_expand_target_path_with_sandbox_and_tokens [] {
    let sb = "/tmp/ygg-sb-check"
    let p = (expand-target-path "~/.config/niri" --sandbox $sb)
    assert equal $p "/tmp/ygg-sb-check/.config/niri"
}

export def test_backup_moves_regular_file_outside_config [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let victim = ($home | path join "fake-config.toml")
        "hello" | save -f $victim
        let bak = (backup-existing $home $victim)
        assert (not ($victim | path exists))
        assert ($bak | path exists)
        assert ($bak | str starts-with ($home | path join ".state" "backups"))
    }
}
```

- [ ] **Step 3: Запустить тесты и убедиться в ожидаемом падении**

Run: `rtk nu /data/projects/ygg/tests/run.nu`
Expected: FAIL (`module ../src/state.nu not found`)

- [ ] **Step 4: Реализовать `src/state.nu` по заданным сигнатурам**

Для `$DOCUMENTS` на Windows использовать `pwsh -NoProfile -Command "[Environment]::GetFolderPath('MyDocuments')"` (с fallback на `~/Documents`), на Unix — `~/Documents`. При `--sandbox $sb` заменять префикс `$nu.home-path` (а также `$APPDATA`/`$LOCALAPPDATA`/`$DOCUMENTS`) на подкаталоги внутри `$sb`, чтобы ни один путь в песочнице не выходил в реальный `$HOME`.

- [ ] **Step 5: Проверить прохождение тестов и сделать коммит**

Run: `rtk nu /data/projects/ygg/tests/run.nu`
Expected: PASS (3 tests passed)

```bash
rtk git -C /data/projects/ygg add . && rtk git -C /data/projects/ygg commit -m "feat(state): scaffold ygg repo, test runner, and state/path utilities"
```

---

### Task 2: Manifest Parser, OS Guard & Scope Resolution (`src/manifest.nu`)

**Files:**
- Create: `/data/projects/ygg/src/manifest.nu`
- Create: `/data/projects/ygg/tests/test_manifest.nu`
- Modify: `/data/projects/ygg/tests/run.nu`

**Interfaces:**
- Consumes: `detect-host-os` из `src/state.nu`.
- Produces (`src/manifest.nu`):
  - `export def load-host-config [ygg_home: string]: nothing -> record` (читает `host.toml`, по умолчанию `{ modules: [] }`).
  - `export def save-host-config [ygg_home: string, cfg: record]: nothing -> nothing`
  - `export def load-module-manifest [mod_dir: string]: nothing -> record` (читает `ygg.toml`, валидирует наличие `name` и `os`, автоматически сливает опциональные соседние `packages.toml`, `links.toml`, `env.toml`, `aliases.toml`).
  - `export def validate-module-os [manifest: record, host_os: record]: nothing -> bool` (возвращает `true`, если хотя бы один элемент `manifest.os` входит в `[$host_os.os, $host_os.distro, ...$host_os.auto_scopes]`).
  - `export def resolve-effective-plan [ygg_home: string, --modules-filter: list<string> = []]: nothing -> record` (собирает активные модули из `host.toml`, проверяет `validate-module-os`, объединяет базовые секции со скоупами `[...$host_os.auto_scopes, ...$mod_entry.scopes]`, вычитает `exclude`, разрешает коллизии целевых ссылок по правилу `Last-Module-Wins`, мержит `manifest.config` с `mod_entry.config`).

- [ ] **Step 1: Написать падающие тесты в `tests/test_manifest.nu`**

```nushell
use std/assert
use ../src/manifest.nu *
use helpers.nu [with-temp-ygg]

export def test_scope_isolation_and_last_module_wins [] {
    with-temp-ygg { |home|
        let m1 = ($home | path join "modules" "base")
        let m2 = ($home | path join "modules" "override")
        mkdir $m1 $m2
        'name = "base"
os = ["cachyos"]
[packages]
pacman = ["rofi-wayland"]
[links]
niri = "~/.config/niri"
starship = "~/.config/starship.toml"
[scope.pc.links]
openrgb = "~/.config/OpenRGB"
[scope.asus.links]
rog = "~/.config/rog"
' | save -f ($m1 | path join "ygg.toml")

        'name = "override"
os = ["linux"]
[links]
starship = "~/.config/starship.toml"
' | save -f ($m2 | path join "ygg.toml")

        '[[modules]]
name = "base"
scopes = ["asus"]
[[modules]]
name = "override"
' | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let plan = (resolve-effective-plan $home)
            let dests = ($plan.links | get dest_raw)
            assert ("~/.config/rog" in $dests)
            assert (not ("~/.config/OpenRGB" in $dests))
            let star = ($plan.links | where dest_raw == "~/.config/starship.toml" | first)
            assert equal $star.module "override"
        }
    }
}

export def test_rejects_incompatible_os [] {
    let m = { name: "ai-dotfiles", os: ["cachyos"] }
    let win = { os: "windows", distro: "windows", auto_scopes: ["windows"] }
    assert equal (validate-module-os $m $win) false
}
```

- [ ] **Step 2: Запустить тесты и убедиться в падении**

Run: `rtk nu /data/projects/ygg/tests/run.nu`
Expected: FAIL (`manifest.nu` missing)

- [ ] **Step 3: Реализовать `src/manifest.nu`**

Гарантировать слияние внешних `packages.toml`, `links.toml`, `env.toml`, `aliases.toml` (если файлы присутствуют в `mod_dir`) поверх одноимённых секций `ygg.toml`, включая вложенные `[scope.<s_name>.*]`. При несовместимости ОС в `resolve-effective-plan` выбрасывать явную ошибку `error make`.

- [ ] **Step 4: Проверить прохождение тестов и закоммитить**

Run: `rtk nu /data/projects/ygg/tests/run.nu`
Expected: PASS

```bash
rtk git -C /data/projects/ygg add . && rtk git -C /data/projects/ygg commit -m "feat(manifest): implement TOML manifest loader, OS guard, and scope resolution"
```

---

### Task 3: File Linker, `/*` Unfolding, `3-way Sync` & Safe Pruning (`src/link.nu`)

**Files:**
- Create: `/data/projects/ygg/src/link.nu`
- Create: `/data/projects/ygg/tests/test_link.nu`
- Modify: `/data/projects/ygg/tests/run.nu`

**Interfaces:**
- Consumes: `load-state`, `save-state`, `expand-target-path`, `backup-existing`, `detect-host-os` из `src/state.nu`.
- Produces (`src/link.nu`):
  - `export def is-link-or-junction [path: string]: nothing -> bool` (возвращает `true` даже для битого симлинка, где `path exists` равен `false`, используя `ls -D` / `file -h` / `ReparsePoint`).
  - `export def remove-link-only [path: string]: nothing -> nothing` (удаляет только саму ссылку: `rm` на Unix, `cmd /c rmdir` для Junction / `rm` для файла на Windows; выбрасывает ошибку при попытке вызвать на реальной непустой директории).
  - `export def apply-links [ygg_home: string, plan: record, --dry-run, --force, --sandbox: string = ""]: nothing -> record` (применяет ссылки, `/*`, `.cmd`-шиммы, `3-way hash sync` для копий Windows и `[save]`, выполняет `prune` исчезнувших ссылок из `state.json`).
  - `export def save-copied-files [ygg_home: string, plan: record]: nothing -> list<string>` (принудительный обратный захват `host -> module` для всех записей `state.copies` и `[save]`).
  - `export def unlink-module [ygg_home: string, module_name: string]: nothing -> int` (удаляет все ссылки и `.cmd`-шиммы указанного модуля по `state.json`).

- [ ] **Step 1: Написать падающие тесты в `tests/test_link.nu` (включая оба кейса из Review Focus)**

```nushell
use std/assert
use ../src/state.nu *
use ../src/manifest.nu *
use ../src/link.nu *
use helpers.nu [with-temp-ygg]

export def test_glob_shared_dir_and_ownership_conflict [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "m1")
        let m2 = ($home | path join "modules" "m2")
        mkdir ($m1 | path join "scripts") ($m2 | path join "scripts")
        "#!/bin/sh\necho 1" | save -f ($m1 | path join "scripts" "a.sh")
        "#!/bin/sh\necho 2" | save -f ($m2 | path join "scripts" "b.sh")
        'name = "m1"\nos = ["linux"]\n[links]\n"scripts/*" = "~/.zsh/scripts/"' | save -f ($m1 | path join "ygg.toml")
        'name = "m2"\nos = ["linux"]\n[links]\n"scripts/*" = "~/.zsh/scripts/"' | save -f ($m2 | path join "ygg.toml")
        '[[modules]]\nname = "m1"\n[[modules]]\nname = "m2"' | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        apply-links $home $plan --sandbox $sb
        assert (($sb | path join ".zsh/scripts/a.sh" | path exists))
        assert (($sb | path join ".zsh/scripts/b.sh" | path exists))
        assert (not (is-link-or-junction ($sb | path join ".zsh/scripts")))
    }
}

export def test_replaces_dangling_symlink_without_backup [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        mkdir ($sb | path join ".config")
        let dest = ($sb | path join ".config" "starship.toml")
        ^ln -s "/nonexistent/dead/target" $dest

        let m1 = ($home | path join "modules" "core")
        mkdir $m1
        "add_newline = false" | save -f ($m1 | path join "starship.toml")
        'name = "core"\nos = ["linux"]\n[links]\n"starship.toml" = "~/.config/starship.toml"' | save -f ($m1 | path join "ygg.toml")
        '[[modules]]\nname = "core"' | save -f ($home | path join "host.toml")

        apply-links $home (resolve-effective-plan $home) --sandbox $sb
        assert (($dest | path exists))
        let backups = (glob ($home | path join ".state/backups/**/*"))
        assert ($backups | is-empty)
    }
}

export def test_scope_switch_prunes_old_links_safely [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "dotfiles")
        mkdir ($m1 | path join "openrgb") ($m1 | path join "rog")
        "preset" | save -f ($m1 | path join "openrgb" "off.orp")
        "fan" | save -f ($m1 | path join "rog" "rog.cfg")
        'name = "dotfiles"
os = ["linux"]
[scope.pc.links]
openrgb = "~/.config/OpenRGB"
[scope.asus.links]
rog = "~/.config/rog"' | save -f ($m1 | path join "ygg.toml")

        '[[modules]]
name = "dotfiles"
scopes = ["pc"]' | save -f ($home | path join "host.toml")
        apply-links $home (resolve-effective-plan $home) --sandbox $sb
        assert (($sb | path join ".config/OpenRGB/off.orp" | path exists))

        '[[modules]]
name = "dotfiles"
scopes = ["asus"]' | save -f ($home | path join "host.toml")
        apply-links $home (resolve-effective-plan $home) --sandbox $sb
        assert (not ($sb | path join ".config/OpenRGB" | path exists))
        assert (($m1 | path join "openrgb/off.orp" | path exists))
        assert (($sb | path join ".config/rog/rog.cfg" | path exists))
    }
}

export def test_three_way_copy_sync_preserves_host_gui_edits [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "win")
        mkdir ($m1 | path join "terminal") ($sb | path join "AppData/Local/Packages/Microsoft.WindowsTerminal_123/LocalState")
        let repo_file = ($m1 | path join "terminal/settings.json")
        let host_file = ($sb | path join "AppData/Local/Packages/Microsoft.WindowsTerminal_123/LocalState/settings.json")
        '{"theme":"dark"}' | save -f $repo_file
        '{"theme":"default"}' | save -f $host_file

        'name = "win"
os = ["windows"]
[save]
"terminal/settings.json" = "~/AppData/Local/Packages/Microsoft.WindowsTerminal_*/LocalState/settings.json"' | save -f ($m1 | path join "ygg.toml")
        '[[modules]]\nname = "win"' | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "windows" } {
            # 1. Initial apply (--force seeds host from module)
            apply-links $home (resolve-effective-plan $home) --sandbox $sb --force
            assert equal (open --raw $host_file) '{"theme":"dark"}'

            # 2. User edits file on host via GUI; next apply pulls change back into module
            '{"theme":"catppuccin"}' | save -f $host_file
            apply-links $home (resolve-effective-plan $home) --sandbox $sb
            assert equal (open --raw $repo_file) '{"theme":"catppuccin"}'
        }
    }
}
```

- [ ] **Step 2: Запустить тесты и убедиться в падении**

Run: `rtk nu /data/projects/ygg/tests/run.nu`
Expected: FAIL (`link.nu` missing)

- [ ] **Step 3: Реализовать `src/link.nu`**

Ключевые инварианты реализации:
1. При маске `/*`, если целевая папка уже `is-link-or-junction` — выбрасывать `error make { msg: "Shared directory ownership conflict" }`.
2. Если `is-link-or-junction $dest` истинно, удалять старую ссылку через `remove-link-only $dest` без записи в `.state/backups/`. Бэкап в `.state/backups/` делать только для реальных не-линкованных файлов/папок.
3. При линковке скриптов в `~/.local/bin` на Unix ставить `chmod +x` на исходник, на Windows (`host_os.os == "windows"`) для `.nu` и `.ps1` генерировать `<stem>.cmd` и регистрировать его в `state.links`.
4. Для `[save]` и одиночных файлов на Windows хранить в `state.copies` запись `{ module, src, dest, last_synced_hash }` и выполнять 3-way сверку SHA-256 (`hash sha256`).

- [ ] **Step 4: Запустить тесты и закоммитить**

Run: `rtk nu /data/projects/ygg/tests/run.nu`
Expected: PASS

```bash
rtk git -C /data/projects/ygg add . && rtk git -C /data/projects/ygg commit -m "feat(link): implement cross-platform linker, glob unfolding, 3-way sync, and safe pruning"
```

---

### Task 4: Reactive SDK (`onchange`, `merge-json`, `export-secrets`) & `setup.nu` Runner (`src/sdk.nu`)

**Files:**
- Create: `/data/projects/ygg/src/sdk.nu`
- Create: `/data/projects/ygg/tests/test_sdk.nu`
- Modify: `/data/projects/ygg/tests/run.nu`

**Interfaces:**
- Consumes: `get-ygg-home`, `load-state`, `save-state`, `expand-target-path` из `src/state.nu`.
- Produces (`src/sdk.nu`):
  - `export def onchange [key: string, watch_globs: list<string>, block: closure, --target: string = ""]: nothing -> bool` (вычисляет SHA-256 файлов по `watch_globs` относительно `$env.YGG_MODULE_DIR` или абсолютных путей; пропускает `block` и возвращает `false`, если хеш совпал, `--target` существует и `$env.YGG_FORCE != "true"`; при ошибке внутри `block` не сохраняет новый хеш в `state.json` и пробрасывает ошибку).
  - `export def merge-json [src_fragment: string, dest_json: string, --mode: string = "0600"]: nothing -> nothing` (снимает старый симлинк на `dest_json`, создаёт родительские папки, читает JSON или `{}` если файл пуст/отсутствует, выполняет `merge deep`, сохраняет JSON и ставит `chmod $mode` на Unix).
  - `export def export-secrets [dest_dotenv: string, --keys: list<string> = []]: nothing -> nothing` (читает `$YGG_HOME/secrets.toml`, фильтрует `--keys` если список не пуст, записывает `.env` с экранированием кавычек и правами `0600`; мягко пропускает, если `secrets.toml` отсутствует).
  - `export def run-module-setup [ygg_home: string, mod_plan: record, --dry-run, --force, --sandbox: string = ""]: nothing -> nothing` (запускает `<mod_dir>/setup.nu` в подпроцессе `nu -I <ygg_src_dir>` с переменными `$env.YGG_HOME`, `$env.YGG_MODULE_DIR`, `$env.YGG_SCOPES`, `$env.YGG_MOD_CONFIG`, `$env.YGG_DRY_RUN`, `$env.YGG_FORCE`, `$env.YGG_SANDBOX`).

- [ ] **Step 1: Написать падающие тесты в `tests/test_sdk.nu`**

```nushell
use std/assert
use ../src/state.nu *
use ../src/sdk.nu *
use helpers.nu [with-temp-ygg]

export def test_onchange_skips_recovers_missing_target_and_rolls_back_on_error [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let mod_dir = ($home | path join "modules" "m")
        mkdir $mod_dir
        let src = ($mod_dir | path join "cfg.yaml")
        let out = ($home | path join "built.yaml")
        "v1" | save -f $src

        with-env { YGG_HOME: $home, YGG_MODULE_DIR: $mod_dir, YGG_FORCE: "false" } {
            # 1. First run executes
            let r1 = (onchange "build" ["cfg.yaml"] --target $out { cp $src $out })
            assert equal $r1 true
            assert ($out | path exists)

            # 2. Second run skips
            let r2 = (onchange "build" ["cfg.yaml"] --target $out { cp $src $out })
            assert equal $r2 false

            # 3. Deleted target triggers self-healing re-run
            rm $out
            let r3 = (onchange "build" ["cfg.yaml"] --target $out { cp $src $out })
            assert equal $r3 true
            assert ($out | path exists)

            # 4. Failing block does NOT record new hash
            "v2" | save -f $src
            let failed = (try { onchange "build" ["cfg.yaml"] { error make { msg: "boom" } }; false } catch { true })
            assert $failed
            let r4 = (onchange "build" ["cfg.yaml"] { cp $src $out })
            assert equal $r4 true
        }
    }
}

export def test_merge_json_missing_and_symlink_target [] {
    with-temp-ygg { |home|
        let frag = ($home | path join "plugins.json")
        let dummy = ($home | path join "dummy.json")
        let live = ($home | path join "gemini/config.json")
        '{"plugins":{"a":true},"ui":{"font":14}}' | save -f $frag
        '{"session":"secret-token","ui":{"theme":"dark"}}' | save -f $dummy
        mkdir ($live | path dirname)
        ^ln -s $dummy $live

        merge-json $frag $live --mode "0600"
        assert equal (($live | path type)) "file"
        let res = (open $live)
        assert equal $res.plugins.a true
        assert equal $res.ui.font 14
    }
}
```

- [ ] **Step 2: Запустить тесты и убедиться в падении**

Run: `rtk nu /data/projects/ygg/tests/run.nu`
Expected: FAIL (`sdk.nu` missing)

- [ ] **Step 3: Реализовать `src/sdk.nu`**

При удалении старого симлинка в `merge-json` сначала вычитывать содержимое по старому симлинку (если он валиден), чтобы не потерять существующие ключи сессии вроде `session`, затем удалять симлинк и записывать объединённый физический файл с `chmod 0600`.

- [ ] **Step 4: Запустить тесты и закоммитить**

Run: `rtk nu /data/projects/ygg/tests/run.nu`
Expected: PASS

```bash
rtk git -C /data/projects/ygg add . && rtk git -C /data/projects/ygg commit -m "feat(sdk): add transactional onchange, merge-json, and export-secrets helpers"
```

---

### Task 5: Environment, Aliases & Secrets Compiler (`src/env.nu`)

**Files:**
- Create: `/data/projects/ygg/src/env.nu`
- Create: `/data/projects/ygg/tests/test_env.nu`
- Modify: `/data/projects/ygg/tests/run.nu`

**Interfaces:**
- Consumes: `expand-target-path`, `detect-host-os` из `src/state.nu`, `onchange` из `src/sdk.nu`.
- Produces (`src/env.nu`):
  - `export def compile-environment [ygg_home: string, plan: record, --dry-run, --force, --sandbox: string = ""]: nothing -> nothing` (сливает `plan.env` + `~/.ygg/secrets.toml` `[env]` и `plan.aliases`; записывает `.state/env/env.{nu,zsh,ps1}`, `.state/env/aliases.{nu,zsh,ps1}` и пустой `local.nu` если его нет; вне `--sandbox` на Linux обновляет `~/.config/environment.d/99-ygg.conf` (`0600`) и вызывает `systemctl --user import-environment`, а на Windows обновляет `HKCU\Environment` и шлёт `WM_SETTINGCHANGE`).

- [ ] **Step 1: Написать падающие тесты в `tests/test_env.nu` (включая экранирование спецсимволов из Review Focus)**

```nushell
use std/assert
use ../src/state.nu *
use ../src/manifest.nu *
use ../src/env.nu *
use helpers.nu [with-temp-ygg]

export def test_env_special_chars_escaping [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "core")
        mkdir $m1
        'name = "core"\nos = ["linux"]' | save -f ($m1 | path join "ygg.toml")
        'EDITOR = "nvim"\nPROJECTS_ROOT = "~/projects"' | save -f ($m1 | path join "env.toml")
        'll = "eza -la"' | save -f ($m1 | path join "aliases.toml")
        '[env]\nWEIRD_SECRET = "pa$$w0rd=\"foo\" & '\''bar'\''=1"' | save -f ($home | path join "secrets.toml")
        '[[modules]]\nname = "core"' | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        compile-environment $home $plan --sandbox $sb

        let env_nu = ($home | path join ".state/env/env.nu")
        let env_zsh = ($home | path join ".state/env/env.zsh")
        let local_nu = ($home | path join ".state/env/local.nu")
        assert ($env_nu | path exists)
        assert ($local_nu | path exists)

        # Verify Nushell and Zsh actually parse and evaluate exact secret string without expansion
        let nu_val = (^nu -c $"source ($env_nu); print --raw $env.WEIRD_SECRET")
        assert equal $nu_val 'pa$$w0rd="foo" & ''bar''=1'

        let zsh_val = (^zsh -c $"source ($env_zsh); printf '%s' \"\$WEIRD_SECRET\"")
        assert equal $zsh_val 'pa$$w0rd="foo" & ''bar''=1'
    }
}
```

- [ ] **Step 2: Запустить тесты и убедиться в падении**

Run: `rtk nu /data/projects/ygg/tests/run.nu`
Expected: FAIL (`env.nu` missing)

- [ ] **Step 3: Реализовать `src/env.nu`**

Для `env.nu` сериализовать словарь через `to nuon` внутри `load-env <nuon>`; для `env.zsh` оборачивать значения в одинарные кавычки с заменой `'` на `'\''`; для `env.ps1` оборачивать в одинарные кавычки PowerShell с заменой `'` на `''`; для `99-ygg.conf` экранировать `\`, `"` и `$` (`\$`) в двойных кавычках. В PowerShell-генераторе алиасов (`aliases.ps1`) использовать обёртку функции `function <alias> { <target> @args }` с разрешением бинарника через `Get-Command -CommandType Application` при совпадении имени алиаса с именем утилиты (защита от саморекурсии в PowerShell). На файлах секретов ставить `chmod 0600`.

- [ ] **Step 4: Запустить тесты и закоммитить**

Run: `rtk nu /data/projects/ygg/tests/run.nu`
Expected: PASS

```bash
rtk git -C /data/projects/ygg add . && rtk git -C /data/projects/ygg commit -m "feat(env): compile cross-shell env, aliases, and secrets with strict escaping"
```

---

### Task 6: Package Providers (`src/pkg.nu`) & Module Git Manager (`src/git.nu`)

**Files:**
- Create: `/data/projects/ygg/src/pkg.nu`
- Create: `/data/projects/ygg/src/git.nu`
- Create: `/data/projects/ygg/tests/test_pkg_git.nu`
- Modify: `/data/projects/ygg/tests/run.nu`

**Interfaces:**
- Consumes: `load-host-config`, `save-host-config`, `load-module-manifest`, `validate-module-os` из `src/manifest.nu`; `unlink-module`, `is-link-or-junction`, `remove-link-only` из `src/link.nu`; `detect-host-os` из `src/state.nu`.
- Produces:
  - `src/pkg.nu`: `export def install-packages [plan: record, --dry-run, --sandbox: string = ""]: nothing -> list<string>` (пропускает установку при непустом `--sandbox`; поддерживает провайдеры `pacman`, `paru`, `mise`, `cargo`, `winget`, `scoop`, `pnpm`, `uv`; при `$env.YGG_MOCK_PKG_LOG? != null` дописывает вызванные команды в лог-файл вместо реального запуска пакетных менеджеров).
  - `src/git.nu`:
    - `export def add-module [ygg_home: string, source: string, --scopes: list<string> = []]: nothing -> record` (если `source` — существующий путь на диске, создаёт ссылку в `$YGG_HOME/modules/<name>`; иначе трактует `owner/repo` как `https://github.com/<owner>/<repo>.git` или полный Git URL, клонирует в `$YGG_HOME/modules/<name>`, валидирует `os` — при несовместимости откатывает клон/ссылку и выбрасывает ошибку — и обновляет `host.toml`).
    - `export def remove-module [ygg_home: string, name: string]: nothing -> nothing` (вызывает `unlink-module`, удаляет запись из `host.toml`, удаляет симлинк модуля в `modules/<name>` или клонированную папку только если в ней нет незакоммиченных правок).
    - `export def update-modules [ygg_home: string]: nothing -> list<record>` (для каждого Git-модуля в `modules/` выполняет `git pull --rebase --autostash`; при ненулевом коде возврата немедленно вызывает `git rebase --abort` и помечает модуль статусом `conflict` без разрушения рабочего дерева).
    - `export def modules-status [ygg_home: string]: nothing -> table` (возвращает таблицу: `name`, `scopes`, `path`, `branch`, `dirty`, `links_ok`).

- [ ] **Step 1: Написать падающие тесты в `tests/test_pkg_git.nu` (включая конфликт rebase из Review Focus)**

```nushell
use std/assert
use ../src/state.nu *
use ../src/manifest.nu *
use ../src/pkg.nu *
use ../src/git.nu *
use helpers.nu [with-temp-ygg]

export def test_mock_pkg_filters_by_host_os [] {
    with-temp-ygg { |home|
        let log = ($home | path join "pkg.log")
        let m1 = ($home | path join "modules" "m")
        mkdir $m1
        'name = "m"
os = ["linux"]
[packages]
pacman = ["wireplumber"]
winget = ["Git.Git"]
mise = ["ripgrep"]' | save -f ($m1 | path join "ygg.toml")
        '[[modules]]\nname = "m"' | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: $log } {
            install-packages (resolve-effective-plan $home)
            let lines = (open --raw $log)
            assert ($lines | str contains "pacman")
            assert ($lines | str contains "mise")
            assert (not ($lines | str contains "winget"))
        }
    }
}

export def test_update_aborts_cleanly_on_conflict [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let upstream = ($home | path join "upstream.git")
        let work_up = ($home | path join "work_up")
        ^git init --bare -b main $upstream
        ^git clone $upstream $work_up
        ^git -C $work_up config user.email "t@t.local"
        ^git -C $work_up config user.name "Tester"
        'name = "demo"\nos = ["linux", "cachyos"]' | save -f ($work_up | path join "ygg.toml")
        "line = 1\n" | save -f ($work_up | path join "app.conf")
        ^git -C $work_up add .
        ^git -C $work_up commit -m "init"
        ^git -C $work_up push -u origin main

        add-module $home $upstream
        let cloned = ($home | path join "modules" "demo")

        # Upstream changes line, local user also changes same line without committing
        "line = upstream\n" | save -f ($work_up | path join "app.conf")
        ^git -C $work_up commit -am "upstream change"
        ^git -C $work_up push

        "line = local_custom\n" | save -f ($cloned | path join "app.conf")
        let res = (update-modules $home)
        assert equal ($res | first | get status) "conflict"
        # Working file must remain clean without <<<<<<< markers and no active rebase-merge dir
        let content = (open --raw ($cloned | path join "app.conf"))
        assert (not ($content | str contains "<<<<<<<"))
        assert equal $content "line = local_custom\n"
        assert (not ($cloned | path join ".git/rebase-merge" | path exists))
    }
}
```

- [ ] **Step 2: Запустить тесты и убедиться в падении**

Run: `rtk nu /data/projects/ygg/tests/run.nu`
Expected: FAIL (`pkg.nu` / `git.nu` missing)

- [ ] **Step 3: Реализовать `src/pkg.nu` и `src/git.nu`**

В `update-modules` перед `git pull --rebase` сохранять локальные изменения в `git stash push -u` (если `git status --porcelain` не пуст), выполнять `git pull --rebase`, а затем `git stash pop`: если `stash pop` или `rebase` сигнализирует о конфликте, выполнять `git checkout --theirs` / `git reset --hard ORIG_HEAD` + восстановление локального содержимого файла из stash без конфликтных маркеров (либо проверку `git merge-tree` до слияния), гарантируя инвариант отсутствия `<<<<<<<` в живом конфиге.

- [ ] **Step 4: Запустить тесты и закоммитить**

Run: `rtk nu /data/projects/ygg/tests/run.nu`
Expected: PASS

```bash
rtk git -C /data/projects/ygg add . && rtk git -C /data/projects/ygg commit -m "feat(pkg,git): add OS-aware package providers and conflict-safe git module manager"
```

---

### Task 7: CLI Entrypoints (`bin/ygg*`), Bootstrap Installers & E2E CLI Test

**Files:**
- Create: `/data/projects/ygg/src/mod.nu`
- Create: `/data/projects/ygg/bin/ygg.nu`
- Create: `/data/projects/ygg/bin/ygg`
- Create: `/data/projects/ygg/bin/ygg.cmd`
- Create: `/data/projects/ygg/scripts/install.sh`
- Create: `/data/projects/ygg/scripts/install.ps1`
- Create: `/data/projects/ygg/tests/sandbox.wsb`
- Create: `/data/projects/ygg/tests/test_cli_e2e.nu`
- Create: `/data/projects/ygg/README.md`
- Modify: `/data/projects/ygg/tests/run.nu`

**Interfaces:**
- Consumes: `src/{state,manifest,link,sdk,env,pkg,git}.nu`.
- Produces (`bin/ygg.nu`):
  - `main init [name?: string, --os: string = "linux"]` — создаёт `ygg.toml` и `.gitignore` (`*local*`, `*.db*`, `*.sqlite*`, `__pycache__/`, `logs/`).
  - `main add [source: string, --scope (-s): string = ""]` — вызывает `add-module` (парсит суффикс `repo@s1,s2` и флаг `--scope`) и сразу выполняет `apply`.
  - `main remove [name: string]` — вызывает `remove-module`.
  - `main apply [--dry-run (-n), --force (-f), --sandbox: string = ""]` — выполняет полный конвейер: `resolve-effective-plan` -> `install-packages` -> `apply-links` -> `compile-environment` -> `run-module-setup` для каждого модуля.
  - `main update` — вызывает `update-modules`, и если нет конфликтов — запускает `main apply`.
  - `main save` — вызывает `save-copied-files`.
  - `main status` — выводит таблицу `modules-status`.
  - SDK-подкоманды для вызова из `setup.nu`: `main onchange ...`, `main merge-json ...`, `main export-secrets ...`.

- [ ] **Step 1: Написать сквозной E2E-тест CLI в `tests/test_cli_e2e.nu`**

```nushell
use std/assert
use helpers.nu [with-temp-ygg]

export def test_full_cli_lifecycle [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "my-dotfiles")
        mkdir ($mod_src | path join "niri")
        "layout {}" | save -f ($mod_src | path join "niri" "config.kdl")

        let ygg_bin = ("/data/projects/ygg/bin/ygg.nu")
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_MOCK_PKG_LOG: ($home | path join "pkg.log") } {
            # 1. Init module
            cd $mod_src
            ^nu $ygg_bin init "my-dotfiles" --os "linux,cachyos"
            '[links]\nniri = "~/.config/niri"\n' | save --append ($mod_src | path join "ygg.toml")

            # 2. Add local module (auto-applies strictly inside YGG_SANDBOX)
            ^nu $ygg_bin add $mod_src
            assert (($sb | path join ".config/niri/config.kdl" | path exists))

            # 3. Check status output
            let st = (^nu $ygg_bin status)
            assert ($st | str contains "my-dotfiles")

            # 4. Remove module unlinks from sandbox while keeping source dir intact
            ^nu $ygg_bin remove "my-dotfiles"
            assert (not ($sb | path join ".config/niri" | path exists))
            assert (($mod_src | path join "niri/config.kdl" | path exists))
        }
    }
}
```

- [ ] **Step 2: Запустить тесты и убедиться в падении**

Run: `rtk nu /data/projects/ygg/tests/run.nu`
Expected: FAIL (`bin/ygg.nu` not found)

- [ ] **Step 3: Реализовать `src/mod.nu`, `bin/ygg.nu`, `bin/ygg` (`chmod +x`), `bin/ygg.cmd`, `scripts/install.{sh,ps1}`, `tests/sandbox.wsb` и `README.md`**

В `scripts/install.sh` и `scripts/install.ps1` реализовать чистый бутстрап без Chezmoi: проверка/установка `mise` (user-space) -> `mise use -g nushell` -> клонирование `gidragir/ygg` в `~/.ygg/.engine` -> создание шимма `~/.local/bin/ygg` (`ygg.cmd` на Windows + добавление `~/.local/bin` в `Path`).

- [ ] **Step 4: Запустить весь набор автотестов и сделать финальный коммит Фазы 1**

Run: `rtk just --justfile /data/projects/ygg/justfile test`
Expected: PASS (все модульные и E2E тесты проходят за <3 сек, рабочий `$HOME` не затронут)

```bash
rtk git -C /data/projects/ygg add . && rtk git -C /data/projects/ygg commit -m "feat(cli): complete ygg CLI router, bootstrap installers, and E2E test suite"
```
