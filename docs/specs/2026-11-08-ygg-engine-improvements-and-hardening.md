# Спецификация улучшений и стабилизации движка `ygg` (Living Spec)

> **Дата создания:** 2026-11-08  
> **Статус:** `Реализовано (Linux; пункты Windows/macOS ожидают проверки на целевых ОС)`: RFC-001 — RFC-025 (RFC-021 сокращён до защиты от затенения и `mode = "dir"`, часть `mode = "merge"` `Отложено`)  
> **Цель документа:** Единый живой реестр архитектурных улучшений, платформенных исправлений и адаптаций рантайма `ygg`, выявленных в процессе реальной миграции модулей (`win-dotfiles`, `omni-dotfiles`, `dotfiles`, `ai-dotfiles`). Документ дополняется по мере поступления новых отчётов об использовании для исключения двойной работы.  
> **База проверки:** коммит `d3a90bb`, Nushell 0.116.1, Linux. Утверждения отчётов сверены с кодом и пробами в `/tmp/ygg-test-*`. Поведение на реальной Windows и macOS не проверялось: такие места помечены `Проверить на Windows` / `Проверить на macOS` и входят в приёмку соответствующего RFC.

---

## 1. Реестр отчётов об использовании (Source Reports)

| ID отчёта | Дата | Источник / Модуль | Ключевые проблемы | Статус разбора |
| :--- | :--- | :--- | :--- | :--- |
| **REP-001** | 2026-11-08 | Миграция `win-dotfiles` (Windows 11) | Падение Win32 API на масках файлов в `onchange`, фатальный сбой `apply` при отсутствии `scoop`, потребность в 1-to-N ссылках (`glazewm`), невидимость 3-way конфликтов в `status`, отсутствие `--version`, сбои батчинга `winget`. | Разобран, включён в RFC-001 — RFC-006 |
| **REP-002** | 2026-11-08 | `omni-dotfiles`, `apply` на Windows | Прямые слэши в `cmd /c`, падение `mklink /J` на существующей связи, `mise trust`, нет выбора менеджеров и таймаутов, батч `winget`, поиск `nu.exe`. | Разобран, см. раздел 1.1 |
| **REP-003** | 2026-11-08 | `omni-dotfiles`, подготовка миграции `dotfiles`, `ai-dotfiles`, `win-dotfiles` | Нет флагов предпросмотра в `ygg add`, нет `ygg diff`, молчаливые коллизии, скрытые бэкапы, нет `ygg doctor`. | Разобран, см. раздел 1.1 |
| **REP-004** | 2026-11-08 | `omni-dotfiles`, песочницы `--sandbox` и `bwrap` | Пустой отчёт dry-run, утечка stderr от `chmod`, `~` в `env.toml`, `ygg status` не показывает цель модуля, остатки Chezmoi. | Разобран, см. раздел 1.1 |
| **REP-005** | 2026-11-08 | `dotfiles` (живая сессия Niri / Noctalia) | Сбои файловых вотчеров при `apply`, нет реакции приложений на изменения, приоритет скоупа над глобом, медленный опрос пакетов, нет диагностики дрифта. | Разобран, см. раздел 1.1 |
| **REP-006** | 2026-11-08 | Боевая миграция CachyOS / Niri (`omni-dotfiles`, `dotfiles`, `ai-dotfiles`) | Битый симлинк вместо рабочего каталога `ollama`, затенение runtime-файлов `OpenRGB`, неатомарная замена ссылок, запрос `on_change` и `ygg doctor`. | Разобран, см. раздел 1.1 |
| **REP-007** | 2026-11-08 | Миграция `ai-dotfiles` | Зависание на `sudo pacman` без TTY, нет `safe-link`, относительные связи в `setup.nu`, запрос `ygg status --json`, незамеченные отсутствующие секреты. | Разобран, см. раздел 1.1 |
| **REP-008** | 2026-11-08 | `win-dotfiles`, VM с VirtIO-FS | `nu` падает при запуске: `mise` отключает конфигурацию из-за сбоя канонизации пути через Junction на `Z:\`. | Разобран, см. раздел 1.1. Windows-часть взята из отчёта и не воспроизводилась |

### 1.1. Трассировка пунктов отчётов

| Пункт | Суть | Результат проверки | Решение |
| :--- | :--- | :--- | :--- |
| REP-002.1 | `to-win32-path` | Дефект подтверждён. Предложенный хелпер с `path expand` разрешает симлинки, поэтому `del` и `rmdir` сработали бы по реальной цели. | RFC-008, хелпер исправлен |
| REP-002.2 | Идемпотентность Junction | Подтверждено, та же причина у REP-005.1. | RFC-009 |
| REP-002.3 | `mise trust` | Подтверждено: `src/pkg.nu:12`. | RFC-013 |
| REP-002.4 | `--pkg` и таймаут 120 с | Подтверждено. 120 с ломают `cargo install` и сборку AUR. Таймаут через `^nu -c` оставляет живой дочерний процесс. | RFC-013, таймаут пересмотрен |
| REP-002.5 | Поштучный `winget` | Дубль RFC-005. Новое: `scoop`. | RFC-005, расширен |
| REP-002.6 | Поиск `nu.exe` | 3 из 5 путей уже есть в `bin/ygg.cmd`. Нужны только 2 новых. | RFC-019 |
| REP-003.1 | `ygg add --dry-run/--force` | Флагов нет. Простого проброса в `apply` мало: `add-module` меняет `host.toml` и `modules/` до `apply`. | RFC-012 |
| REP-003.2 | `ygg diff` | Команды нет. Алиас небезопасен: dry-run выполняет блоки `onchange` и пишет `merge-json`. | RFC-011 |
| REP-003.3 | Предупреждение о коллизиях | Подтверждено. Реальный случай: `~/.config/sheldon` в `omni-dotfiles` и `dotfiles`. Коллизии с глобами в `src/manifest.nu` не видны. | RFC-010 |
| REP-003.4 | Логирование бэкапов | Подтверждено: `src/link.nu:230`, `:257`. | RFC-011 |
| REP-003.5 | `ygg doctor` | Команды нет. Поиск по шаблонам Chezmoi и путь `sops` в ядре нарушают инвариант чистоты ядра. | RFC-017, проверки обобщены |
| REP-004.1 | Отчёт dry-run | Подтверждено: выводится только `Applied N module(s).`. Файла `src/cli.nu` нет, CLI находится в `bin/ygg.nu`. | RFC-011 |
| REP-004.2 | Утечка stderr от `chmod` | Подтверждено пробой. | RFC-018 |
| REP-004.3 | `~` в `env.toml` | Подтверждено. Отчёт не учёл два приёмника: `systemctl import-environment` и реестр Windows. `man 5 environment.d` не описывает `%h`. | RFC-016, механизм заменён |
| REP-004.4 | Цель модуля в `ygg status` | Подтверждено. Команда находится в `src/git.nu:224`, а не в `src/cli.nu`. | RFC-004, расширен |
| REP-004.5 | Рецепт `cutover-chezmoi` | Задача репозитория `omni-dotfiles`. Движок не знает об этих файлах и не должен знать. | Вне движка, передано в `omni-dotfiles` |
| REP-005.1 | Неатомарная замена ссылок | Подтверждено и шире отчёта: при каждом `apply` пересоздаются **все** ссылки, даже неизменённые. | RFC-009 |
| REP-005.2 | Хуки `on_change` | Новая функция, переиспользует `onchange`. | RFC-015 |
| REP-005.3 | Приоритет скоупа над глобом | Подтверждено: сейчас приоритет зависит от порядка ключей и модулей. | RFC-010 |
| REP-005.4 | Производительность пакетов | Контрольная сумма `packages.toml` не покрывает `ygg.toml` и скоупы. Отдельный `ygg sync` меняет контракт CLI. | RFC-014 |
| REP-005.5 | Диагностика дрифта | Дубль REP-003.5. Дополнительно: `links_ok` возвращает `true` для битой ссылки и для файла на месте ссылки. | RFC-017, RFC-004 |
| REP-006.1 | Проверка источников до любых операций | Подтверждено пробой: каталог уходит в бэкап, на его месте битый симлинк, код выхода 0. Глоб с отсутствующим источником молча создаёт пустой каталог. | RFC-020 |
| REP-006.2 | Затенение каталога, `mode = "merge"` | Подтверждено. Уточнение: файлы перемещаются в `.state/backups/`, а не удаляются. Глоб `/*` уже даёт слияние на один уровень, но переход `"X"` → `"X/*"` сейчас падает с ошибкой владения. Вложенных гибридных каталогов в модулях нет (`OpenRGB/*`, `antigravity/*` и `profiles/*` закрывают все случаи). | RFC-021 (`mode = "dir"` и защита от затенения), RFC-011; `mode = "merge"` отложено (раздел 4.3) |
| REP-006.3 | Атомарная замена | Дубль REP-005.1. `RENAME_NOREPLACE` из отчёта не подходит: он завершается ошибкой, если цель существует. Открытые дескрипторы на новую цель не переходят. | RFC-009, уточнён |
| REP-006.4 | `on_change` | Дубль REP-005.2, инлайн-таблица совместима с RFC-015. | RFC-015 |
| REP-006.5 | `ygg doctor` | Дубль REP-003.5. Новое: затенённые файлы. Сверка запущенных процессов с файлами отклонена: движок не знает, какой процесс читает какой файл. | RFC-017, расширен |
| REP-007.1 | Проверка пакетов до `sudo pacman` | Подтверждено: `src/pkg.nu:10`. Вместо `pacman -Q` на каждый пакет выбран один вызов `pacman -T`. | RFC-022 |
| REP-007.2 | SDK `safe-link` | Вложенная ссылка подтверждена пробой. `rm -rf` из отчёта нарушает Zero-Data-Loss и заменён бэкапом. | RFC-023 |
| REP-007.3 | Секция `[rel-links]` | `.env` создаётся в `setup.nu` уже после шага ссылок, а глоб по `~/.hermes/profiles/*` на чистом хосте ничего не найдёт. `safe-link` закрывает задачу циклом. | Отложено, раздел 4.3 |
| REP-007.4 | `ygg status --json` | `Broken pipe` не воспроизвёлся: файл, `cat`, `head` и конфигурация с указанным хуком отработали с кодом 0. Запрос обоснован иначе: в пайпе таблица скрывает `branch`, `dirty` и `links_ok`. | RFC-004, RFC-017, расширены |
| REP-007.5 | Аудит секретов | Подтверждено: `src/sdk.nu:198`, `:217`. Шаблон `mise.example.toml` специфичен для `ai-dotfiles`, в ядре остаётся только `secrets.example.toml`. | RFC-024 |
| REP-008.1 | Junction на VirtIO-FS ломает канонизацию в `mise` | Ограничение драйвера и инструмента, а не движка. Движок должен предупреждать, а RFC-009 не должен зависеть от канонизации. `src/git.nu:41` скрывает сбой `mklink`. | RFC-025, RFC-009 |
| REP-008.2 | `try` в `env.nu:68` не перехватил ошибку | На Linux не воспроизводится: `try` перехватывает такой конвейер. Файл принадлежит `omni-dotfiles`. | Вне движка, раздел 4.3 |

---

## 2. Матрица дедупликации компонентов (De-duplication Matrix)

Чтобы предотвратить дублирование логики и фрагментацию кода, все доработки строго привязаны к ответственным подсистемам:

| Подсистема | Файл | Зона ответственности | Связанные RFC |
| :--- | :--- | :--- | :--- |
| **SDK & Reactive Runner** | `src/sdk.nu` | Изоляция Win32 File API от wildcard-масок, хэширование файлов `onchange`, соблюдение `YGG_DRY_RUN`, запуск хуков `on_change`, `safe-link`, предупреждения о секретах | RFC-001, RFC-011, RFC-015, RFC-023, RFC-024 |
| **Package Providers** | `src/pkg.nu` | Диспетчеризация пакетных менеджеров, проверка доступности (`which`), поштучная установка, фильтр `--pkg`, таймауты, подготовка `mise`, кэш набора пакетов, проверка перед `sudo` | RFC-002, RFC-005, RFC-013, RFC-014, RFC-022 |
| **Manifest & Plan Engine** | `src/manifest.nu` | Парсинг `links.toml`, `save`, 1-to-N списки путей, табличная форма ссылок и `mode`, сбор кандидатов без разрешения коллизий | RFC-003, RFC-010, RFC-012, RFC-015, RFC-021 |
| **Git & Telemetry** | `src/git.nu` | Диагностика `ygg status`, подсчёт `sync_conflicts` и `pending_save` из `state.copies`, цель модуля, `--json`, `add-module --dry-run`, проверка `mklink` и нелокальных томов | RFC-004, RFC-012, RFC-025 |
| **Link & Sync Engine** | `src/link.nu` | Безопасность ссылок, fallback с `mklink /J` на `/D` и `cp -r` на UNC/сетевых путях, идемпотентность и атомарность, разрешение приоритетов, план операций, логирование бэкапов, предварительная проверка, защита от затенения каталогов | RFC-006, RFC-009, RFC-010, RFC-011, RFC-018, RFC-020, RFC-021 |
| **State & Paths** | `src/state.nu` | Канонический `to-win32-path` | RFC-008 |
| **Env Compiler** | `src/env.nu` | Разворачивание `~` и `$HOME` в значениях окружения | RFC-016 |
| **Diagnostics** | `src/doctor.nu` (новый) | Проверки `ygg doctor`, только чтение | RFC-017, RFC-021, RFC-024, RFC-025 |
| **CLI Entrypoint** | `bin/ygg.nu` | Маршрутизация аргументов, флаги `--version` / `-v`, подкоманды `version`, `diff`, `doctor`, флаги `add`, `--pkg`, `--pkg-timeout`, `--refresh-packages`, `--json`, вызов предварительной проверки до всех шагов | RFC-004, RFC-007, RFC-011, RFC-012, RFC-013, RFC-014, RFC-017, RFC-020 |
| **Windows Shim** | `bin/ygg.cmd` | Поиск `nu.exe` | RFC-019 |

---

## 3. Спецификация улучшений (RFC Items)

### RFC-001: Безопасность Win32 File API при обработке glob-масок в `onchange`

* **Компонент:** `src/sdk.nu`
* **Приоритет:** Критический (Must Fix / Crash)
* **Статус:** `Согласовано`

#### Проблема
В функции `onchange` в Nushell выражение:
```nushell
if (($resolved_pattern | path exists) or (($resolved_pattern | path type) != null)) and not ($resolved_pattern | str contains "*") ...
```
вычисляет скобки слева направо. На платформе Windows системный вызов Win32 API к файлу, содержащему символы `*` или `?` (например, `glazewm/cfg/*.yaml`), вызывает ошибку ядра `ERROR_INVALID_NAME`, приводя к аварийному падению Nushell:
`nu::shell::io::invalid_filename: Invalid filename`.

#### Архитектурное требование
1. Проверка наличия символов подстановки (`*`, `?`) обязана выполняться **до** любых обращений к файловой системе (`path exists`, `path type`).
2. Обращение к `path exists` должно быть защищено блоком `try { ... } catch { false }`.

#### Контракт реализации
```nushell
let has_wildcard = ($resolved_pattern | str contains "*") or ($resolved_pattern | str contains "?")
let is_exact = if not $has_wildcard {
    try { ($resolved_pattern | path exists) or (($resolved_pattern | path type) != null) } catch { false }
} else {
    false
}

if $is_exact {
    # Точечный путь (файл или каталог)
    let ptype = ($resolved_pattern | path type)
    ...
} else {
    # Glob-маска
    let matched = (try { glob $resolved_pattern } catch { [] })
    ...
}
```

#### Тестирование
* Юнит-тест в `tests/test_sdk.nu`: передача паттерна с wildcard `watch_globs: ["cfg/*.yaml"]` на несуществующей или существующей директории не вызывает панику рантайма.

---

### RFC-002: Устойчивость установки пакетов к отсутствующим менеджерам (`Resilient Package Providers`)

* **Компонент:** `src/pkg.nu`, `bin/ygg.nu`
* **Приоритет:** Критический (Must Fix / Workflow Blocking)
* **Статус:** `Согласовано`

#### Проблема
Кроссплатформенные или комплексные модули могут объявлять зависимости для нескольких пакетных менеджеров (например, `winget` и `scoop` на Windows, `pacman` и `paru` на Arch). Если один из них не установлен на целевой машине (`scoop` отсутствует на чистой ОС):
1. `ygg apply` выполняет `scoop install ...`.
2. Команда завершается с ошибкой `Command scoop not found`.
3. Запись попадает в `pkg_res.failed`.
4. `ygg apply` аварийно прерывает работу с кодом выхода 1, не применив симлинки, переменные окружения и `setup.nu`.

#### Архитектурное требование
1. Перед вызовом внешнего менеджера пакетов проверять его наличие в `PATH` через `which $mgr | is-not-empty`.
2. При отсутствии менеджера:
   - Логировать предупреждение в `stderr`: `[ygg] Warning: Package manager '($mgr)' not found on PATH. Skipping ($pkgs | length) package(s).`
   - Пропускать пакеты данного менеджера, **не добавляя** его в список фатальных ошибок `failed`.
   - Продолжать установку пакетов остальных доступных менеджеров и последующие шаги `apply`.
3. Для тестовой изоляции поддержать мок отсутствия через `$env.YGG_MOCK_PKG_MISSING`.

#### Контракт реализации
```nushell
let mock_missing = ($env.YGG_MOCK_PKG_MISSING? | default "" | split row "," | each { |s| $s | str trim } | where { |it| $it != "" })
let is_missing = if ($mock_log != "") {
    ($mgr in $mock_missing)
} else {
    (which $mgr | is-empty)
}

if $is_missing {
    print -e $"[ygg] Warning: Package manager '($mgr)' not found on PATH. Skipping ($pkgs | length) package\(s\)."
    continue
}
```

#### Тестирование
* Тест в `tests/test_pkg_git.nu`: модуль с недоступным менеджером логирует предупреждение, завершает `apply` успешно и создает все целевые симлинки.

---

### RFC-003: Декларативная поддержка 1-to-N ссылок в `links.toml` и `save`

* **Компонент:** `src/manifest.nu`, `src/link.nu`
* **Приоритет:** Высокий (Feature / Migration Blocker)
* **Статус:** `Согласовано`

#### Проблема
Ряд Windows-приложений (GlazeWM, Zebar) исторически читают конфигурацию из `%USERPROFILE%\.glzr\<app>\`, в то время как репозитории `dotfiles` стандартизированы под `~/.config/<app>/`. В текущей реализации значение целевого пути в `links.toml` принимается только как одиночная строка (`dest_raw: string`). Для создания второй ссылки приходится писать императивный код в `setup.nu`.

#### Архитектурное требование
1. Разрешить в `links.toml` и секции `[save]` в качестве значения как одиночную строку, так и список строк (`list<string>`):
   ```toml
   [links]
   "glazewm" = ["~/.config/glazewm", "~/.glzr/glazewm"]
   "zebar"   = ["~/.config/zebar", "~/.glzr/zebar"]

   [save]
   "settings.json" = ["~/.config/app/settings.json", "~/.local/share/app/settings.json"]
   ```
2. В `src/manifest.nu` нормализовать значение цели к `list<string>`.
3. Генерировать независимые записи в `$plan.links` и `$plan.save` для каждого целевого пути.
4. В стейте (`state.links` / `state.copies`) ключом выступает физический целевой путь (`dest`), что исключает коллизии ключей при сохранении и разлинковке.
5. **Поправка RFC-010:** `src/manifest.nu` больше не отбрасывает записи с совпадающим `dest_raw`. План содержит всех кандидатов, коллизии разрешает `resolve-link-targets`.
6. **Поправка RFC-015:** значение ссылки также может быть таблицей `{ target, on_change }`, где `target` — строка или список.

#### Контракт реализации
```nushell
# src/manifest.nu
# $mod_links — таблица кандидатов модуля с полями key, value, origin_rank (см. RFC-010)
for entry in $mod_links {
    let link_key = $entry.key
    let spec = (normalize-link-value $link_key $entry.value)   # { targets: list<string>, on_change: string, mode: string }

    for dest_raw in $spec.targets {
        if ($link_key in $excludes) or ($dest_raw in $excludes) {
            continue
        }
        let clean_key = ($link_key | str replace --regex '^\./' '')
        let base_rel = ($clean_key | str replace --regex '/\*$' '')
        let src_path = ($mod_dir | path join $base_rel)
        let is_glob = (($link_key | str ends-with "/*") or ($dest_raw | str ends-with "/*"))

        $plan_links = ($plan_links | append {
            module: $mod_name,
            module_rank: $mod_rank,
            origin_rank: $entry.origin_rank,
            key: $link_key,
            src_rel: $clean_key,
            src_path: $src_path,
            dest_raw: $dest_raw,
            is_glob: $is_glob,
            on_change: $spec.on_change,
            mode: $spec.mode
        })
    }
}
```

#### Тестирование
* Юнит-тест в `tests/test_manifest.nu`: резолв 1-to-N манифеста создаёт обе записи в плане.
* Тест в `tests/test_link.nu`: `apply-links` создает обе ссылки/папки на хосте и корректно отслеживает их в `state.links`.

---

### RFC-004: Отображение 3-way конфликтов и ожидающих синхронизаций в `ygg status`

* **Компонент:** `src/git.nu` (`modules-status`), `bin/ygg.nu`
* **Приоритет:** Высокий (Visibility & Data Safety)
* **Статус:** `Согласовано`

#### Проблема
При первом `ygg apply` файлы из секции `[save]` с разным содержимым на хосте и в модуле переходят в статус `conflict` (файл хоста сохраняется, перезапись отменяется до `--force`). Однако `ygg status` выводит только `dirty: false, links_ok: true`, скрывая наличие неразрешённых расхождений и изменений, готовых к отправке в репозиторий через `ygg save`.

#### Архитектурное требование
1. Расширить таблицу `ygg status` двумя новыми колонками:
   * `sync_conflicts`: счётчик файлов модуля в `state.copies`, где оба файла (`src` и `dest`) существуют, их хэши различаются, и либо baseline отсутствует (`last_synced_hash == ""`), либо оба файла были изменены независимо.
   * `pending_save`: счётчик файлов модуля, где файл на хосте был изменён локально (`dest_hash != baseline`), а исходник в репозитории не менялся (`src_hash == baseline`).

#### Контракт реализации
```nushell
# src/git.nu (modules-status)
mut conflicts_count = 0
mut pending_save_count = 0

let mod_copies = ($state.copies | columns | where { |k| (($state.copies | get $k | get -o module) == $name) })
for dest in $mod_copies {
    let entry = ($state.copies | get $dest)
    let src = $entry.src
    let baseline = ($entry.last_synced_hash? | default "")
    let src_exists = ($src | path exists)
    let dest_exists = ($dest | path exists)

    if $src_exists and $dest_exists {
        let host_hash = (open --raw $dest | hash sha256)
        let mod_hash = (open --raw $src | hash sha256)
        if $host_hash != $mod_hash {
            if ($baseline == "") or (($host_hash != $baseline) and ($mod_hash != $baseline)) {
                $conflicts_count += 1
            } else if ($host_hash != $baseline) and ($mod_hash == $baseline) {
                $pending_save_count += 1
            }
        }
    }
}
```

#### Расширение: цель модуля и достоверный `links_ok` (REP-004.4, REP-005.5)
1. **Колонка `target`:** `path` показывает `~/.ygg/modules/<name>`, из-за чего нельзя отличить основную ветку от worktree. Новая колонка содержит `$mod_path | path expand`, то есть разрешённый путь.
2. **Исправление `links_ok`:** выражение `(is-link-or-junction $dest) or ($dest | path exists)` в `src/git.nu:262` возвращает `true` для битого симлинка и для обычного файла на месте ссылки (подтверждено пробой). Новое правило зависит от типа записи в `state.links`:
   * `symlink`, `junction`: `(link-target-matches $dest $entry.src) and ($dest | path exists)`. Проверка существования обязательна: литеральное сравнение из RFC-009 истинно и для битой ссылки;
   * `copy`, `dir_copy`: `$dest | path exists`.
3. **Флаг `--json` (REP-007.4).** `ygg status --json` печатает `to json --raw` и не зависит от ширины терминала. В пайпе таблица Nushell скрывает колонки: в пробе остались `name`, `scopes`, `path` и `...`, то есть `branch`, `dirty` и `links_ok` терялись. Вывод в JSON содержит все колонки, включая новые.

#### Тестирование
* Тест в `tests/test_state.nu` / `tests/test_pkg_git.nu`: `modules-status` корректно рапортует число коллизий и число ожидающих `save` файлов.
* Тест в `tests/test_pkg_git.nu`: модуль, подключённый симлинком, показывает разрешённый `target`.
* Тест в `tests/test_pkg_git.nu`: `links_ok == false` для битого симлинка и для обычного файла на месте ссылки.
* Тест в `tests/test_cli_e2e.nu`: вывод `ygg status --json` через пайп разбирается `from json` и содержит все колонки при любой ширине.

---

### RFC-005: Поштучная изолированная установка для однопозиционных пакетных менеджеров (`WinGet` / `Scoop` / `uv`)

* **Компонент:** `src/pkg.nu`
* **Приоритет:** Высокий (Windows Stability)
* **Статус:** `Согласовано`

#### Проблема
Синтаксис WinGet CLI не поддерживает передачу пачки пакетов в аргументах команды: `winget install --exact pkg1 pkg2` завершается с ошибкой синтаксиса аргументов. Кроме того, пачечный запуск приводит к тому, что сбой одного пакета (например, уже установленного вручную или временно недоступного в репозитории) блокирует установку всех остальных пакетов модуля.

#### Архитектурное требование
1. Для провайдеров, требующих атомарного вызова (`winget`, `scoop`, `uv tool`), генерировать и выполнять команды строго поштучно для каждого пакета из списка. `scoop` принимает пачку пакетов синтаксически, но поштучный режим нужен для изоляции сбоев (REP-002.5).
2. Сбой установки отдельного пакета логируется в stderr, но цикл продолжается для оставшихся пакетов.
3. В отчёте `pkg_res.failed` фиксируются конкретные пакеты: `{ mgr, pkg, reason, stderr }`, где `reason` — `error` или `timeout` (RFC-013). `bin/ygg.nu` включает имена пакетов в итоговое сообщение об ошибке.
4. Для `winget` добавить `--disable-interactivity`, чтобы команда не ждала ввода.
5. Коды `winget` «пакет уже установлен» и «обновление не требуется» считаются успехом: `-1978335135` (`0x8A150061`) и `-1978335189` (`0x8A15002B`). Иначе повторный `apply` падает на установленных пакетах. `Проверить на Windows`.

#### Контракт реализации
```nushell
# src/pkg.nu — команды формируются как argv, а не как строка для `nu -c` (см. RFC-013)
def pkg-argv-list [mgr: string, pkgs: list<string>]: nothing -> list<list<string>> {
    match $mgr {
        "winget" => ($pkgs | each { |p| [winget install --exact --disable-interactivity --accept-source-agreements --accept-package-agreements $p] }),
        "scoop" => ($pkgs | each { |p| [scoop install $p] }),
        "uv" => ($pkgs | each { |p| [uv tool install $p] }),
        "pacman" => [[sudo pacman -S --needed --noconfirm ...$pkgs]],
        "paru" => [[paru -S --needed --noconfirm ...$pkgs]],
        "mise" => [[mise use --path "~/.config/mise/config.local.toml" ...$pkgs]],
        "cargo" => [[cargo install ...$pkgs]],
        "pnpm" => [[pnpm add -g ...$pkgs]],
        _ => [[$mgr install ...$pkgs]]
    }
}

const WINGET_OK_CODES = [0, -1978335135, -1978335189]
```

#### Тестирование
* Тест в `tests/test_pkg_git.nu`: для `winget`, `scoop` и `uv` генерируются индивидуальные вызовы команд в mock-лог.
* Тест в `tests/test_pkg_git.nu`: сбой одного пакета через `YGG_MOCK_PKG_FAIL` не останавливает остальные, а `failed` содержит только этот пакет. Формат `YGG_MOCK_PKG_FAIL` расширяется значением `<mgr>:<pkg>` без отказа от `<mgr>`.

---

### RFC-006: Отказоустойчивый Fallback для Windows Junctions (`UNC & ReFS/FAT Fallback`)

* **Компонент:** `src/link.nu`
* **Приоритет:** Средний (Edge-case Resilience)
* **Статус:** `Согласовано`

#### Проблема
`^cmd /c mklink /J` завершается фатальной системной ошибкой Win32, если целевой или исходный путь находится на сетевом UNC-ресурсе (`\\server\share\...`) или файловой системе, не поддерживающей Reparse Points. В Nushell вызов внешней команды с ненулевым кодом выхода без `| complete` аварийно прерывает выполнение скрипта.

#### Архитектурное требование
1. Вызов `^cmd /c mklink /J` обязан перехватывать результат через `| complete`.
2. При сбое создания Junction:
   - Шаг 1: Попытка создания каталожного симлинка `^cmd /c mklink /D $win_dest $win_src | complete`.
   - Шаг 2: При отсутствии прав / запрете Developer Mode — выполнение рекурсивного копирования каталога `cp -r $src_path $dest`.
   - Регистрация типа связи в `state.links` как `copy` или `junction`.

#### Контракт реализации
```nushell
# src/link.nu
let res = (^cmd /c mklink /J $win_dest $win_src | complete)
if $res.exit_code != 0 {
    let res_d = (^cmd /c mklink /D $win_dest $win_src | complete)
    if $res_d.exit_code != 0 {
        # Fallback на рекурсивное копирование
        cp -r $src_path $dest
        let link_record = { module: $mod_name, src: $src_path, type: "dir_copy", cmd_shim: "" }
        $state.links = ($state.links | upsert $dest $link_record)
    }
}
```

#### Уточнения
* Создание связи входит в единый шаг `create-link` (RFC-009), а пути передаются через `to-win32-path` (RFC-008).
* Запись `dir_copy` не синхронизируется автоматически. Повторный `apply` возвращает для неё операцию `OK` с предупреждением, а не пересоздаёт каталог, чтобы не потерять правки на хосте.
* Удаление `dir_copy` при `prune` и `unlink` выполняется только через `backup-existing`. Текущие `prune-copy` и `remove-link-only` каталог-копию не удаляют, поэтому без этого правила каталог остался бы на диске без учёта в `state`.

---

### RFC-007: Стандартизация CLI — флаг `--version` / `-v` и подкоманда `version`

* **Компонент:** `bin/ygg.nu`
* **Приоритет:** Средний (CLI Standards & Tooling)
* **Статус:** `Согласовано`

#### Проблема
Вызов `ygg --version` или `ygg -v` приводит к синтаксической ошибке парсера Nushell: `unknown flag --version`, что нарушает POSIX/GNU ожидания внешних утилит и пользователей.

#### Архитектурное требование
1. Сигнатура `def main` в `bin/ygg.nu` должна принимать флаги `--version (-v)`.
2. Добавить явную подкоманду `def "main version" []`.
3. Формат вывода: `ygg <version> (commit <short_sha>)` при запуске из git-репозитория или `ygg <version>` вне репозитория.

#### Контракт реализации
```nushell
const YGG_VERSION = "0.1.0"

def "main version" [] {
    let root = ($env.FILE_PWD? | default "." | path dirname)
    let commit = (try {
        (^git -C $root rev-parse --short HEAD | complete).stdout | str trim
    } catch { "" })

    if ($commit != "") {
        print $"ygg ($YGG_VERSION) \(commit ($commit)\)"
    } else {
        print $"ygg ($YGG_VERSION)"
    }
}

def main [
    --version (-v)
] {
    if $version {
        main version
        return
    }
    ...
}
```

---

### RFC-008: Канонический `to-win32-path`

* **Компонент:** `src/state.nu`, `src/link.nu`, `src/git.nu`
* **Приоритет:** Высокий (Windows Stability, Zero-Data-Loss)
* **Статус:** `Согласовано`
* **Источник:** REP-002.1

#### Проблема
`cmd.exe` принимает `/` за начало ключа (`Invalid switch - "..."`). Замена слэшей повторена в `src/link.nu:20`, `:61`, `:322-323`, `:389-390` и `src/git.nu:39-40`, поэтому новый вызов легко оставить без неё.

Вариант из отчёта с `path expand` опасен: без флага он разрешает симлинки. Проба: `lnk -> real_dir` превращается в `real_dir`, а `flnk -> real_dir/f.txt` в `real_dir/f.txt`. Тогда `remove-link-only` выполнит `del /f /q` или `rmdir` по реальной цели, что нарушает инвариант Zero-Data-Loss.

#### Архитектурное требование
1. Единственный способ передать путь в `cmd /c` — `to-win32-path`. Хелпер использует только `path expand -n`.
2. Заменить все перечисленные места вызова и использовать хелпер в RFC-006 и RFC-009.
3. `src/env.nu:32` не меняется: это запись в пользовательский `Path`, а не вызов `cmd`.

#### Контракт реализации
```nushell
# src/state.nu
export def to-win32-path [p: string]: nothing -> string {
    $p | path expand -n | str replace -a "/" "\\"
}
```

#### Тестирование
* Тест в `tests/test_state.nu`: путь к симлинку не разрешается в цель, в результате нет `/`.
* `Проверить на Windows`: `tests/sandbox.wsb`, удаление Junction и файлового симлинка сохраняет содержимое цели.

---

### RFC-009: Идемпотентные и атомарные ссылки

* **Компонент:** `src/link.nu`
* **Приоритет:** Критический (живые демоны и блокеры на Windows)
* **Статус:** `Согласовано`
* **Источник:** REP-002.2, REP-005.1

#### Проблема
`prepare-dest` (`src/link.nu:235`) удаляет существующую ссылку, а затем `apply-links` создаёт её снова. Это происходит при каждом `apply` и для каждой ссылки: в пробе inode неизменённой ссылки меняется при повторном запуске. Отсюда два симптома:
* **Unix:** демоны получают `ENOENT` между удалением и созданием, файловые вотчеры ломаются;
* **Windows:** если `rmdir` заблокирован процессом, сбой игнорируется (`src/link.nu:64-68`), а следующий `mklink /J` без `complete` прерывает `apply`.

#### Архитектурное требование
1. **Основное исправление — no-op.** Если ссылка уже разрешается в нужный источник, движок не трогает её: нет удаления, нет создания, нет событий файловой системы.
2. **Сравнение целей в два шага.** Сначала литеральная цель ссылки из `link-literal-target`, приведённая к абсолютному пути без разрешения симлинков, сравнивается с источником. На Unix `ls -lD $dest | get 0.target` возвращает цель симлинка, но на Windows для NTFS Junction колонка `target` в `ls -lD` может быть пустой: в этом случае `link-literal-target` запрашивает `(Get-Item -LiteralPath ... -Force).Target` через PowerShell (строковая конкатенация без `$"..."` с `[`). Затем сравниваются разрешённые пути обеих сторон (`path expand`): так перенацеливание симлинка `~/.ygg/modules/<name>` на другой worktree не требует пересоздания ссылок. Первый шаг обязателен для томов, где канонизация не работает (REP-008): там `path expand` вернёт сам путь, и без литерального сравнения каждый `apply` пересоздавал бы ссылку. На Windows сравнение регистронезависимое, префикс `\\?\` и `UNC\` отбрасываются, разделители приводятся к `\`. `Проверить на Windows`.
3. **Атомарная замена на Unix.** Если цель отличается, замена выполняется переименованием временной ссылки из того же каталога. Встроенный `mv` Nushell запрещён: в пробе `mv -f tmp link` при `link -> каталог` переместил `tmp` внутрь каталога.
4. **Windows.** Атомарной замены Junction нет: выполняется `rmdir`, затем `mklink /J` с `complete` и fallback из RFC-006. Сбой одной связи не прерывает `apply`: он попадает в `failed` результата `apply-links` (`record<applied: list<string>, pruned: list<string>, copies: list<string>, failed: list<record<dest: string, src: string, module: string, stderr: string>>>`), а `bin/ygg.nu` завершает работу с кодом 1 после всех шагов.
5. **Обычный файл или каталог на месте ссылки.** Сначала бэкап (RFC-011), затем создание. Этот случай не атомарен.

#### Ограничение
Атомарная замена убирает окно `ENOENT`, но вотчер, подписанный на inode старой цели, сам не переподпишется, а уже открытые дескрипторы останутся на старом каталоге (REP-006.3 предполагал обратное). Поэтому главное средство — отсутствие операций над неизменёнными ссылками, а перечитывание конфигурации обеспечивает `on_change` (RFC-015). Нужен обычный `rename` с заменой, то есть `mv -T`: флаг `RENAME_NOREPLACE` из отчёта запрещает замену существующей цели.

#### Контракт реализации
```nushell
# src/link.nu
def normalize-case [p: string]: nothing -> string {
    if ($nu.os-info.family == "windows") {
        $p | str replace --regex '^\\\\\?\\(UNC\\)?' '' | str replace -a "/" "\\" | str trim -r -c "\\" | str lowercase
    } else {
        $p | str trim -r -c "/"
    }
}

def link-literal-target [dest: string]: nothing -> string {
    let t = (try { ls -lD $dest | get -o 0.target | default "" } catch { "" })
    let raw = if ($t != "") or ($nu.os-info.family != "windows") {
        $t
    } else {
        let esc = ($dest | str replace --all "'" "''")
        let cmd = ("(Get-Item -LiteralPath '" + $esc + "' -Force).Target | Select-Object -First 1")
        try { (^powershell -NoProfile -Command $cmd | complete).stdout | str trim } catch { "" }
    }
    if ($raw == "") or ($raw =~ '^(/|[A-Za-z]:|\\\\)') {
        $raw
    } else {
        $dest | path dirname | path join $raw
    }
}

export def link-target-matches [dest: string, src: string]: nothing -> bool {
    if not (is-link-or-junction $dest) {
        return false
    }
    let literal = (link-literal-target $dest)
    let lexical_src = ($src | path expand -n | normalize-case $in)
    if ($literal != "") and (($literal | path expand -n | normalize-case $in) == $lexical_src) {
        return true
    }
    if not (($dest | path exists) and ($src | path exists)) {
        return false
    }
    (normalize-case ($dest | path expand)) == (normalize-case ($src | path expand))
}

def swap-symlink-atomic [src: string, dest: string]: nothing -> nothing {
    let tmp = $"($dest).ygg-tmp-(random chars --length 8)"
    ^ln -s $src $tmp
    # GNU: -T; BSD/macOS: -h (Проверить на macOS)
    let no_follow = if ($nu.os-info.name == "macos") { "-hf" } else { "-Tf" }
    let res = (^mv $no_follow $tmp $dest | complete)
    if $res.exit_code != 0 {
        ^rm -f $tmp | complete | ignore
        ^ln -sfn $src $dest
    }
}
```

| Состояние `dest` | Операция RFC-011 | Действие |
| :--- | :--- | :--- |
| Отсутствует | `LINK` | Создать ссылку |
| Ссылка на нужный источник | `OK` | Ничего, запись в `state` обновляется |
| Ссылка на другой источник или битая | `RELINK` | Unix: `swap-symlink-atomic`. Windows: `rmdir` и `mklink /J` |
| Обычный файл или каталог | `BACKUP_REPLACE` | `backup-existing`, затем создать ссылку |
| Отслеживаемая копия | `COPY` / `CONFLICT` / `OK` | 3-way sync без изменений |

#### Тестирование
* Тест в `tests/test_link.nu`: inode не меняется при повторном `apply`, поле `applied` пустое.
* Тест в `tests/test_link.nu`: при смене источника ссылка указывает на новый источник, временных файлов нет ни рядом с `dest`, ни внутри старого каталога (регрессия встроенного `mv`).
* Тест в `tests/test_link.nu`: перенацеливание симлинка модуля не меняет inode ссылок.
* Тест в `tests/test_link.nu`: `link-target-matches` для абсолютной и относительной цели, цепочки ссылок, другой цели, не ссылки и отсутствующего пути.
* `Проверить на Windows`: повторный `apply` не вызывает `mklink` (в том числе если `ls -lD` не заполнил `target` для Junction), удерживаемый каталог даёт запись в `failed` без аварийного прерывания; на VirtIO-FS литеральное сравнение даёт `OK`.

---

### RFC-010: Разрешение приоритетов и диагностика коллизий ссылок

* **Компонент:** `src/manifest.nu`, `src/link.nu`
* **Приоритет:** Критический (блокер миграции `dotfiles`)
* **Статус:** `Согласовано`
* **Источник:** REP-003.3, REP-005.3

#### Проблема
Победитель определяется порядком обработки, а не правилом:
* `src/manifest.nu:393` молча отбрасывает только совпадающие неглобальные `dest_raw`, сравнивая сырые строки;
* глоб разворачивается позже в `apply-links`, поэтому побеждает тот, кто обработан последним. В пробе глоб более позднего модуля перекрыл явную ссылку из `[scope.pc.links]`;
* внутри одного модуля результат зависит от порядка ключей: `merge` сохраняет позицию существующего ключа, поэтому скоуп, перенацеливший `a.kdl`, проиграл следующему за ним глобу `zz/*`;
* при пересечении глоба и явной ссылки цель пересоздаётся дважды за каждый `apply`, что несовместимо с RFC-009.

Случаи в действующих манифестах: `~/.config/sheldon` (`omni-dotfiles` и `dotfiles`), `~/.config/niri/cfg/display.kdl`, `~/.zsh/alias/cooler.zsh` и `~/.zsh/scripts/cooler-toggle.sh` (явная ссылка скоупа внутри глоба `dotfiles`).

#### Архитектурное требование
1. `src/manifest.nu` собирает всех кандидатов. Единственное место разрешения — `resolve-link-targets` в `src/link.nu`, потому что для глобов нужен список файлов источника.
2. Правила применяются сверху вниз, сравниваются абсолютные пути после `expand-target-path`:

| # | Правило | Следствие |
| :--- | :--- | :--- |
| 1 | Явный путь сильнее глоба | Безусловно, независимо от модуля и порядка ключей |
| 2 | Более поздний модуль в `host.toml` сильнее раннего | Сохраняет Last-Module-Wins |
| 3 | Внутри модуля скоуп сильнее базы | Ключ из скоупа замещает одноимённый ключ базы и получает ранг скоупа |
| 4 | Между скоупами сильнее более поздний | Порядок: `auto_scopes`, затем `scopes` из `host.toml` |
| 5 | Внутри одного источника определений — порядок ключей | Только для детерминизма |

3. **Диагностика.** Если проигравший и победитель из разных модулей, в stderr выводится одна строка на целевой путь: `[ygg] Collision: destination '<path>' claimed by '<mod1>' is overridden by '<mod2>'`. Переопределение внутри модуля — намеренный приём, предупреждения нет.
4. **Вложенность.** Если явная ссылка на каталог является родителем другого целевого пути, запись прошла бы через симлинк в чужой репозиторий. Результат — ошибка `Shared directory ownership conflict`, тот же тип, что в `src/link.nu:293`, выводится на предварительной проверке (RFC-020). В `omni-dotfiles` и `dotfiles` таких случаев нет. Родителем считается любая победившая ссылка на каталог (`is_dir`), включая дочерние элементы глоба `/*`, которые сами являются каталогами (так реализовано в `resolve-link-targets`).
5. `[save]` использует правила 2–5 и ту же диагностику.
6. Функция не меняет файловую систему и используется в `apply`, `diff` и `doctor`.

#### Контракт реализации
```nushell
# src/manifest.nu: mod_links становится таблицей, а не record
# origin_rank: 0 = база, 1..N = порядок активных скоупов
def merge-link-entries [base: table, scoped: table]: nothing -> table {
    $base | where { |b| $b.key not-in ($scoped | get key) } | append $scoped
}

# src/link.nu
export def resolve-link-targets [
    plan: record,
    --sandbox: string = ""
]: nothing -> record<
    targets: table<dest: string, src: string, module: string, key: string, is_dir: bool, is_glob_child: bool, glob_dest_dir: string, on_change: string, mode: string>,
    save_targets: table<dest: string, src: string, module: string, key: string>,
    collisions: table<dest: string, winner_module: string, winner_key: string, loser_module: string, loser_key: string>,
    nesting_conflicts: list<record<module: string, key: string, parent_dest: string, child_dest: string>>
> {
    # 1. Развернуть каждого кандидата plan.links в строки с вычислением:
    #    - для глоба: clean_dest_raw без суффикса /* или \*, glob_dest_dir = expand-target-path,
    #      элементы ls -a $src_path (без . и .. и .git), specificity = 0, is_glob_child = true
    #    - для неглобальной ссылки: dest = expand-target-path, is_dir = (($src_path | path type) == "dir"),
    #      specificity = 1, is_glob_child = false, glob_dest_dir = ""
    # 2. Отсортировать по specificity, module_rank, origin_rank, key_order;
    #    сгруппировать по normalize-case(dest); победитель — последняя строка группы
    # 3. Проигравшие из другого модуля (loser.module != winner.module) -> collisions
    # 4. Разрешить plan.save по module_rank, origin_rank, key_order -> save_targets (с записью межмодульных коллизий в collisions)
    # 5. Проверить вложенность: ни один победитель с is_dir == true не является строгим префиксом пути другого победителя -> nesting_conflicts
}
```
На Windows ключ группировки `dest` нормализуется через `normalize-case`.

#### Тестирование
* Тесты в `tests/test_link.nu`: явная ссылка скоупа раннего модуля сильнее глоба позднего; скоуп с перенацеленным ключом сильнее следующего глоба; файл из глоба, не занятый скоупом, создаётся; пересечение глоба и явной ссылки не меняет inode при повторном `apply`.
* Тест в `tests/test_link.nu`: предупреждение выводится для двух модулей и не выводится внутри одного; `~/x` и абсолютный путь считаются одной целью.
* Тест в `tests/test_link.nu`: вложенность даёт ошибку, в том числе при dry-run.
* `tests/test_manifest.nu:42-43` переписывается: план содержит обоих кандидатов, проверка победителя переходит в `resolve-link-targets`.

---

### RFC-011: Единый план операций, `ygg diff` и прозрачность бэкапов

* **Компонент:** `src/link.nu`, `src/sdk.nu`, `bin/ygg.nu`
* **Приоритет:** Критический (Data Safety)
* **Статус:** `Согласовано`
* **Источник:** REP-003.2, REP-003.4, REP-004.1

#### Проблема
1. `ygg apply -n` печатает только `Applied N module(s).`: `bin/ygg.nu:140` отбрасывает результат, а `applied` при dry-run пуст.
2. **Dry-run изменяет систему.** `setup.nu` законно запускается с `YGG_DRY_RUN=true` (`tests/test_sdk.nu:233`), но SDK эту переменную не читает. В пробе `ygg apply --dry-run` выполнил блок `onchange`, записал результат `merge-json` и зафиксировал хеш в `state.json`. Следующий настоящий `apply` пропустит этот блок. Поэтому `ygg diff` нельзя вводить как простой алиас до исправления SDK.
3. Бэкапы молчаливы: `backup-existing ... | ignore` в `src/link.nu:230` и `:257`.
4. Ветви глоба и одиночной ссылки в `apply-links` дублируют логику (`src/link.nu:316-370` и `:381-439`).

#### Архитектурное требование
1. **Сначала план, потом исполнение.** `compute-link-ops` только читает систему и возвращает операции. `apply-links` исполняет их, dry-run печатает. Дублирование ветвей убирается.
2. **Чистая классификация копий.** `sync-single-file` делится на `plan-copy-sync` (только чтение) и `run-copy-sync` (запись).
3. **Операции:**

| Операция | Значение |
| :--- | :--- |
| `OK` | Ссылка или копия актуальна, изменений нет |
| `LINK` | Новая ссылка |
| `RELINK` | Ссылка на другой источник или битая |
| `BACKUP_REPLACE` | На месте ссылки файл или каталог, будет перемещён в `.state/backups/` |
| `COPY` | 3-way sync изменит файл (в `detail` указано направление: `seeded_host`, `seeded_module`, `pulled_to_module`, `pushed_to_host`, `force_to_host`, `force_to_module`) |
| `CONFLICT` | 3-way конфликт, файл не меняется |
| `PRUNE` | Устаревшая запись `state.links` или `state.copies` будет удалена (`detail`: `unlink`, `rm_unchanged_copy`, `backup_edited_copy`, `backup_dir_copy`) |
| `PKG` | Команда пакетного менеджера или `SKIP (cached)` (RFC-014) |
| `SETUP` | `setup.nu` будет запущен с `YGG_DRY_RUN=true` |
| `HOOK` | Хук `on_change` будет выполнен (RFC-015) |

4. **Вывод dry-run.** По умолчанию скрывает `OK`, флаг `--all (-a)` показывает их. Итоговая строка заменяет `Applied ...`: `Plan: <N> change(s), <M> unchanged across <K> module(s). No changes made.`
5. **SDK соблюдает `YGG_DRY_RUN`.** При значении `true`:
   * `onchange` считает хеш, сообщает `[ygg] dry-run: onchange '<key>' would run`, не выполняет блок, не фиксирует хеш и возвращает `false`;
   * `merge-json` и `export-secrets` сообщают целевой файл и ничего не записывают.
6. **Граница гарантии.** Произвольные команды внутри `setup.nu` остаются ответственностью модуля, как и сейчас (проверка `is_dry` в `dotfiles` и `ai-dotfiles`).
7. **`ygg diff`** — подкоманда поверх dry-run с флагами `--all`, `--skip-packages`, `--pkg`, `--sandbox`.
8. **Бэкапы.** Каждое перемещение пишет в stdout: `[ygg] Backed up existing '<path>' -> '<backup_path>'`. Правило действует и для `prune-copy`.
9. **Порядок исполнения.** Операции `PRUNE` выполняются первыми. Сейчас устаревшие ссылки снимаются последними, поэтому переход от `"X" = "~/.config/X"` к `"X/*"` падает с `Shared directory ownership conflict` на собственной старой ссылке (подтверждено пробой). Проверка владения считает ссылку конфликтом, только если она не помечена как `PRUNE` этого же запуска.

#### Контракт реализации
```nushell
# src/link.nu
export def compute-link-ops [
    ygg_home: string,
    resolved: record,   # результат resolve-link-targets: { targets, save_targets, collisions, nesting_conflicts }
    --force,
    --sandbox: string = ""
]: nothing -> table<op: string, dest: string, src: string, module: string, key: string, detail: string> {
    # 1. Загрузить state = load-state $ygg_home и определить OS (is_windows)
    # 2. Собрать устаревшие записи state.links и state.copies, которых нет в resolved.targets / resolved.save_targets -> строки PRUNE (идут первыми)
    # 3. Для каждой строки resolved.targets:
    #    - если запись в state.links имеет type == "dir_copy" и ($dest | path exists) -> OK (detail: "dir_copy preserved")
    #    - если is_windows и not is_dir (одиночный файл на Windows) -> классифицировать через plan-copy-sync (OK / COPY / CONFLICT; если на месте dest симлинк или каталог -> BACKUP_REPLACE + COPY)
    #    - иначе (симлинк или Junction): по таблице состояний RFC-009 (Отсутствует -> LINK; link-target-matches и ($dest | path exists) -> OK; иная/битая ссылка -> RELINK; обычный файл/каталог -> BACKUP_REPLACE)
    # 4. Для каждой строки resolved.save_targets (с раскрытием wildcard-масок dest): классифицировать через plan-copy-sync (OK / COPY / CONFLICT)
}

def backup-with-notice [ygg_home: string, target: string]: nothing -> string {
    let bkp = (backup-existing $ygg_home $target)
    if ($bkp != "") {
        print $"[ygg] Backed up existing '($target)' -> '($bkp)'"
    }
    $bkp
}
```
```nushell
# bin/ygg.nu
# Show planned changes across all modules without modifying the filesystem
def "main diff" [
    --all (-a),
    --skip-packages (-S),
    --pkg: string = "",
    --sandbox: string = ""
] {
    main apply --dry-run --all=$all --skip-packages=$skip_packages --pkg=$pkg --sandbox=$sandbox
}
```

#### Тестирование
* Тест в `tests/test_link.nu`: каждая операция таблицы получается на подготовленном состоянии; снимок файловой системы до и после dry-run совпадает.
* Тест в `tests/test_sdk.nu`: при `YGG_DRY_RUN=true` блок `onchange` не выполняется, хеш не фиксируется, `merge-json` и `export-secrets` не пишут файлы; следующий настоящий запуск выполняет блок.
* Тест в `tests/test_cli_e2e.nu`: `ygg diff` показывает `LINK` и `BACKUP_REPLACE`, не меняет sandbox; настоящий `apply` печатает строку бэкапа, и файл лежит по указанному пути.
* Тест в `tests/test_link.nu`: смена `"X"` на `"X/*"` завершается успешно, а ссылка неуправляемого каталога по-прежнему даёт ошибку владения.

---

### RFC-012: `ygg add --dry-run` и `--force`

* **Компонент:** `bin/ygg.nu`, `src/git.nu`, `src/manifest.nu`
* **Приоритет:** Высокий (блокер миграции)
* **Статус:** `Согласовано`
* **Источник:** REP-003.1

#### Проблема
`main add` не принимает `--dry-run` и `--force`. Простого проброса в `main apply` недостаточно: `add-module` до вызова `apply` заменяет `modules/<name>` и записывает `host.toml` (`src/git.nu:30-54`, `:94-111`). Такой «предпросмотр» подключил бы модуль на самом деле.

Уточнение к отчёту: занятый целевой путь не вызывает ошибку без `--force`. Файл перемещается в бэкап, а `--force` влияет на 3-way sync и защиту от удаления всех ссылок.

Отдельный дефект: `rm -rf $mod_dest` в `src/git.nu:34` и `:98` удаляет реальный каталог модуля без проверки незакоммиченных изменений, хотя `remove-module` такую проверку выполняет.

#### Архитектурное требование
1. При `--dry-run` `host.toml` и `modules/` не меняются. Модуль участвует в плане как виртуальная запись `{ name, path, scopes }`: `resolve-effective-plan` уже поддерживает поле `path` (`src/manifest.nu:281`).
2. Удалённый источник клонируется в `.state/tmp/clone-*` на время предпросмотра и удаляется после него.
3. Запись с тем же именем в `host.toml` заменяется виртуальной, как при настоящем `add`.
4. `--force` передаётся в `apply` и разрешает заменить каталог модуля с незакоммиченными изменениями. Без него это ошибка.
5. **Предварительная проверка до регистрации.** Настоящий `add` сначала строит план с виртуальной записью и выполняет `preflight-check` (RFC-020). Иначе модуль с отсутствующим источником остался бы в `host.toml`, а `add` завершился бы ошибкой.

#### Контракт реализации
```nushell
# bin/ygg.nu
def "main add" [
    source: string,
    --scope (-s): string = "",
    --dry-run (-n),
    --force (-f),
    --skip-packages (-S),
    --pkg: string = "",
    --sandbox: string = ""
] { ... }

# src/git.nu
export def add-module [
    ygg_home: string,
    source: string,
    --scopes: list<string> = [],
    --dry-run,
    --force
]: nothing -> record   # { name, path, scopes, tmp_clone }

# src/manifest.nu
export def resolve-effective-plan [
    ygg_home: string,
    --modules-filter: list<string> = [],
    --extra-modules: list<record> = []
]: nothing -> record
```

#### Тестирование
* Тест в `tests/test_cli_e2e.nu`: после `ygg add <path> --dry-run` файлы `host.toml`, `modules/` и sandbox не изменены, вывод содержит план будущего модуля.
* Тест в `tests/test_pkg_git.nu`: предпросмотр локального bare-репозитория не оставляет `.state/tmp/clone-*`.
* Тест в `tests/test_pkg_git.nu`: повторный `add` поверх модуля с незакоммиченными изменениями завершается ошибкой, с `--force` выполняется.
* Тест в `tests/test_cli_e2e.nu`: `add` модуля с отсутствующим источником завершается ошибкой, `host.toml` и `modules/` не меняются.

---

### RFC-013: Выбор менеджеров, таймауты и подготовка `mise`

* **Компонент:** `src/pkg.nu`, `bin/ygg.nu`
* **Приоритет:** Высокий (зависания на Windows)
* **Статус:** `Согласовано`
* **Источник:** REP-002.3, REP-002.4

#### Проблема
1. `--skip-packages` отключает все менеджеры разом, выбрать один нельзя.
2. Зависшая загрузка блокирует `apply` без ограничения времени.
3. `mise trust` встроен в строку команды (`src/pkg.nu:12`), а его сбой не виден.
4. Запуск через `^nu -c $cmd_str` мешает таймауту: в пробе `job kill` завершил `nu`, но его дочерний процесс продолжил работать. Прямой внешний процесс завершается корректно.

#### Архитектурное требование
1. **`--pkg <m1,m2>`** в `apply`, `add`, `diff`. Вместе с `--skip-packages` это ошибка. Менеджер без пакетов в плане даёт предупреждение.
2. **Запуск по argv** вместо `^nu -c`. В реальном запуске `~` в аргументах разворачивается заранее, а mock-лог сохраняет форму `~/...`, на которую опирается `tests/test_pkg_git.nu:139`.
3. **Таймаут на один вызов.** Срабатывание записывается в `failed` с `reason: "timeout"`, установка продолжается.

| Менеджер | Единица | По умолчанию | Причина |
| :--- | :--- | :--- | :--- |
| `winget`, `scoop`, `uv` | Один пакет | 300 с | Сетевая загрузка |
| `mise`, `pnpm` | Весь набор | 300 с | Сетевая загрузка |
| `cargo`, `paru` | Весь набор | Нет | Законная сборка длится дольше |
| `pacman` | Весь набор | Нет | Запрос пароля `sudo` не должен обрываться таймаутом |

   Значение 120 с из отчёта не принято: оно вызвало бы ложные сбои на обычной загрузке. Флаг `--pkg-timeout <sec>` задаёт значение для всех менеджеров, `0` отключает таймаут. Без таймаута команда выполняется в основном потоке, без `job spawn`.
4. **Подготовка провайдера.** Перед первым вызовом `mise` выполняется `mise trust --yes` для существующих `~/.config/mise/config.toml` и `config.local.toml`. Сбой даёт предупреждение. Шаг запускается только если `mise` выбран и в плане есть его пакеты. В mock-режиме шаг пишется в лог, при dry-run показывается как `PKG`.

#### Контракт реализации
```nushell
# src/pkg.nu
def kill-job-tree [jid: int]: nothing -> nothing {
    let pids = (try { job list | where id == $jid | get -o 0.pids | default [] } catch { [] })
    if ($nu.os-info.family == "windows") {
        for pid in $pids {
            try { ^taskkill /T /F /PID ($pid | into string) | complete | ignore } catch { }
        }
    } else {
        for pid in $pids {
            try { ^pkill -KILL -P ($pid | into string) | complete | ignore } catch { }
            try { ^kill -KILL ($pid | into string) | complete | ignore } catch { }
        }
    }
    try { job kill $jid | ignore } catch { }
}

export def run-with-timeout [argv: list<string>, timeout_sec: int]: nothing -> record {
    let bin = ($argv | first)
    let args = ($argv | skip 1)
    if $timeout_sec <= 0 {
        return (^$bin ...$args | complete | insert timed_out false)
    }
    # Уникальный тег обязателен: убитое задание отправляет свой результат позже,
    # и без тега следующий `job recv` получит устаревшее сообщение (подтверждено пробой).
    let tag = (random int 1..1000000000)
    let jid = (job spawn { ^$bin ...$args | complete | job send 0 --tag $tag })
    try {
        job recv --tag $tag --timeout ($timeout_sec * 1sec) | insert timed_out false
    } catch {
        kill-job-tree $jid
        { exit_code: 124, stdout: "", stderr: $"timed out after ($timeout_sec)s", timed_out: true }
    }
}

def prepare-provider-environment [mgr: string]: nothing -> nothing { ... }
```
`kill-job-tree` обязательно извлекает `pids` из `job list | where id == $jid` **до** вызова `job kill $jid`: после `job kill` запись исчезает из `job list`, и дочерние процессы (на Windows — `.cmd`-шиммы `scoop`, на Unix — `nu -c` в хуках `on_change`) остались бы сиротами. `Проверить на Windows`.

#### Тестирование
* Тест в `tests/test_pkg_git.nu`: `--pkg mise` оставляет в mock-логе только `mise`; `--pkg` вместе с `--skip-packages` даёт ошибку.
* Тест в `tests/test_pkg_git.nu`: `run-with-timeout [sleep 30] 1` и `run-with-timeout [nu -c "^sleep 30"] 1` завершаются за секунды с `timed_out: true`, дочерний процесс `sleep` не выживает, следующий вызов не получает устаревший результат.
* Тест в `tests/test_pkg_git.nu`: mock-лог содержит `mise trust` перед `mise use`, а без пакетов `mise` строки нет.
* `Проверить на Windows`: зависший `winget` и `.cmd`-шим прерываются, дерево процессов завершено.

---

### RFC-014: Кэш набора пакетов

* **Компонент:** `src/pkg.nu`, `bin/ygg.nu`
* **Приоритет:** Средний (производительность)
* **Статус:** `Согласовано`
* **Источник:** REP-005.4

#### Проблема
Опрос `pacman`, `paru` и `cargo` занимает 5–15 секунд при каждом `apply`, поэтому `--skip-packages` стал обычным флагом и реальные изменения можно пропустить.

#### Архитектурное требование
1. После успешной установки в `state.hashes` записывается `pkg:<mgr>` — SHA-256 отсортированного списка пакетов менеджера из **эффективного плана**. При совпадении менеджер пропускается. `pacman` и `paru` в кэше не участвуют: для них быстрая проверка `pacman -T` выполняется при каждом запуске (RFC-022).
2. Хеш не записывается при сбое, таймауте, отсутствии менеджера, dry-run и в sandbox без mock-лога.
3. Кэш обходят `--refresh-packages` и явный `--pkg <mgr>`.
4. Dry-run показывает пропуск как `PKG <mgr> SKIP (cached)`.

#### Отклонённые варианты
* **Контрольная сумма `packages.toml`:** пакеты также задаются в `ygg.toml` и скоупах, а итоговый набор зависит от всех модулей и `host.toml`.
* **Разделение на `ygg apply` и `ygg sync`:** ломает контракт базовой спецификации, где `apply` устанавливает пакеты, и переносит выбор на пользователя при каждом запуске.

#### Ограничение
Для менеджеров с кэшем пакет, удалённый вручную, не будет обнаружен до изменения плана или запуска с `--refresh-packages`.

#### Контракт реализации
```nushell
# src/pkg.nu
def pkg-set-hash [pkgs: list<string>]: nothing -> string {
    $pkgs | uniq | sort | str join "\n" | hash sha256
}

export def install-packages [
    ygg_home: string,
    plan: record,
    --dry-run,
    --skip-packages (-S),
    --pkg: string = "",
    --pkg-timeout: int = -1,
    --refresh-packages,
    --sandbox: string = ""
]: nothing -> record<
    executed: list<string>,
    skipped: list<string>,
    failed: list<record<mgr: string, pkg: string, reason: string, stderr: string>>
>
```

#### Тестирование
* Тесты в `tests/test_pkg_git.nu`: второй запуск не пишет в mock-лог; добавление пакета запускает менеджер снова; сбой не фиксирует хеш; `--refresh-packages` и `--pkg` обходят кэш.
* Существующие тесты с повторным запуском на одном логе проверяются и при необходимости получают `--refresh-packages`.

---

### RFC-015: Декларативные хуки `on_change` в ссылках

* **Компонент:** `src/manifest.nu`, `src/sdk.nu`, `bin/ygg.nu`
* **Приоритет:** Средний (Feature)
* **Статус:** `Согласовано`
* **Источник:** REP-005.2

#### Проблема
После `ygg apply` запущенные приложения не перечитывают конфигурацию, приходится вручную вызывать `noctalia msg config-reload` и `niri msg action reload-config`. `setup.nu` для этого слишком тяжёл: он выполняется целиком.

#### Архитектурное требование
1. Значение ссылки может быть таблицей. Строка и список продолжают работать:
   ```toml
   [links."noctalia/config.toml"]
   target = "~/.config/noctalia/config.toml"
   on_change = "noctalia msg config-reload"

   [links."niri/cfg/*"]
   target = "~/.config/niri/cfg/*"
   on_change = "niri msg action reload-config"
   ```
2. Форма работает и в `[scope.<name>.links]`. Ссылка, исключённая через `exclude` в `host.toml`, не запускает свой хук.
3. **Условие срабатывания.** Изменился хеш файлов источника (рекурсивно для каталога и глоба) либо на этом ключе выполнена операция `LINK`, `RELINK` или `BACKUP_REPLACE`. Первый `apply` срабатывает, как и `onchange`. `--force` запускает хук безусловно.
4. **Переиспользование.** Логика хеширования `onchange` выносится в `hash-watch-set`. Ключ в `state.hashes`: `on_change:<module>:<link_key>`.
5. **Порядок.** Хуки выполняются последним шагом `apply`, после `setup.nu`. Одинаковая команда выполняется один раз за запуск, а хеш фиксируется для всех её ключей.
6. **Сбой не прерывает `apply`.** Например, compositor не запущен в SSH-сессии. Выводится `[ygg] Warning: on_change for '<key>' failed: <stderr>`, хеш не фиксируется, следующий `apply` повторит хук. Таймаут 30 с через `run-with-timeout` (RFC-013, функция экспортируется из `src/pkg.nu`). Команда хука передаётся как `["nu", "-c", $cmd]`, а `kill-job-tree` завершает как сам `nu`, так и его дочерние процессы.
7. **Изоляция.** При dry-run выводится операция `HOOK`, без выполнения и фиксации хеша. В sandbox реальные команды не выполняются: при заданном `YGG_MOCK_PKG_LOG` в него пишется строка `hook: <cmd>`, и хеш фиксируется.

#### Отклонённый вариант
Отдельная секция `[[on_change]]` с `watch` и `run` не привязана к ссылке: `exclude` на неё не действует, а источники пришлось бы описывать дважды.

#### Контракт реализации
```nushell
# src/manifest.nu
def to-string-list [value: any]: nothing -> list<string> {
    if (($value | describe) starts-with "list") { $value } else { [$value] }
}

# Поле mode описано в RFC-021
def normalize-link-value [key: string, value: any]: nothing -> record<targets: list<string>, on_change: string, mode: string> {
    if not (($value | describe) starts-with "record") {
        return { targets: (to-string-list $value), on_change: "", mode: "" }
    }
    if ($value.target? == null) {
        error make { msg: $"Link '($key)': table form requires 'target'" }
    }
    let mode = ($value.mode? | default "")
    if $mode not-in ["", "dir"] {
        error make { msg: $"Link '($key)': unknown mode '($mode)' \(expected 'dir'\)" }
    }
    if ($mode != "") and ($key | str ends-with "/*") {
        error make { msg: $"Link '($key)': mode cannot be combined with /*" }
    }
    { targets: (to-string-list $value.target), on_change: ($value.on_change? | default ""), mode: $mode }
}

# src/sdk.nu
export def hash-watch-set [watch_globs: list<string>, base_dir: string]: nothing -> string
export def run-link-hooks [
    ygg_home: string,
    targets: table,
    ops: table,
    --dry-run,
    --force,
    --sandbox: string = ""
]: nothing -> list<record<module: string, keys: list<string>, cmd: string, status: string, stderr: string>> {
    # 1. Выбрать строки targets с on_change != "" и сгруппировать по (module, key, on_change)
    # 2. Для каждой группы вычислить current_hash = hash-watch-set [$src_pattern] $mod_dir и проверить state.hashes."on_change:<module>:<key>"
    # 3. Группа срабатывает, если force, либо current_hash != prev_hash, либо в ops для этой пары (module, key) есть LINK / RELINK / BACKUP_REPLACE
    # 4. Дедуплицировать сработавшие группы по строке команды cmd (сохраняя список всех ключей keys и их хешей)
    # 5. При dry-run вернуть записи со status: "dry_run"; в sandbox с YGG_MOCK_PKG_LOG записать "hook: <cmd>\n" и обновить state.hashes;
    #    в sandbox без mock-лога вернуть status: "skipped_sandbox"; иначе выполнить run-with-timeout ["nu", "-c", $cmd] 30:
    #    при exit_code == 0 обновить state.hashes для всех keys группы (status: "ok"), иначе вывести предупреждение в stderr (status: "failed")
}
```
Инлайн-форма `"x" = { target = "...", on_change = "..." }` из REP-006.4 равнозначна подтаблице: TOML разбирает их одинаково.

#### Тестирование
* Тесты в `tests/test_manifest.nu`: все три формы нормализуются; таблица без `target` даёт ошибку.
* Тесты в `tests/test_sdk.nu`, все через mock-лог: хук срабатывает при первом запуске и при изменении файла, не срабатывает без изменений, одинаковая команда выполняется один раз.
* Тест в `tests/test_sdk.nu`: при сбое `apply` завершается успешно, хеш не фиксируется, следующий запуск повторяет хук.
* Тест в `tests/test_link.nu`: исключённая ссылка не запускает хук; dry-run не выполняет команду.

---

### RFC-016: Разворачивание `~` и `$HOME` в значениях окружения

* **Компонент:** `src/env.nu`
* **Приоритет:** Высокий (блокирует `KUBECONFIG`, `XDG_*_HOME`)
* **Статус:** `Согласовано`
* **Источник:** REP-004.3

#### Проблема
Значения попадают в приёмники буквально. Проба: `export KUBECONFIG='~/.kube/config'` в `env.zsh` и `KUBECONFIG="~/.kube/config"` в `99-ygg.conf`. Из-за этого переменные в модулях пришлось закомментировать.

Отчёт предлагал отдельный синтаксис для каждого шелла и `%h` для systemd. Механизм заменён по трём причинам:
* `man 5 environment.d` не описывает спецификатор `%h`;
* отчёт не учитывает ещё два приёмника: `systemctl --user import-environment` (`src/env.nu:223`) и `SetEnvironmentVariable` (`src/env.nu:16`);
* всё в `.state/env/` создаётся для конкретного хоста и не попадает в Git, поэтому абсолютный путь здесь безопасен.

#### Архитектурное требование
1. Значение разворачивается **один раз** в `compile-environment`, сразу после слияния `env` и секретов, до записи в любой приёмник.
2. Обрабатывается только начало значения: `~`, `~/`, `~\`, `$HOME`, `$HOME/`, `$HOME\`. Остальное остаётся литералом, сохраняя семантику из `4cab8e7`.
3. Списки через разделитель не поддерживаются: в `~/a:~/b` разворачивается только первый элемент.
4. В sandbox значение перенаправляется в каталог sandbox через `expand-target-path`.

#### Контракт реализации
```nushell
# src/env.nu
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

#### Тестирование
* Тесты в `tests/test_env.nu`: `~/x`, `~` и `$HOME/x` дают абсолютный путь в `env.nu`, `env.zsh`, `env.ps1` и `99-ygg.conf`; `a/~/b` и `$OTHER/x` остаются литералами, а `$` в `99-ygg.conf` по-прежнему экранируется.
* Тест в `tests/test_env.nu`: `format-windows-env-script` получает абсолютное значение.

---

### RFC-017: `ygg doctor`

* **Компонент:** `src/doctor.nu` (новый), `src/mod.nu`, `src/manifest.nu`, `bin/ygg.nu`
* **Приоритет:** Средний (Diagnostics)
* **Статус:** `Согласовано`
* **Источник:** REP-003.5, REP-005.5

#### Проблема
`ygg status` не показывает битые ссылки и файлы, перезаписанные приложениями. Аудит хоста после миграции выполняется вручную.

Отчёт предлагал искать остатки Chezmoi и проверять `~/.config/sops/age/keys.txt` прямо в движке. Это нарушает инвариант чистоты ядра (`AGENTS.md`, раздел 2, пункт 2). Проверки обобщены и дают тот же результат: битые симлинки Chezmoi находятся как обычные битые симлинки, а путь к ключу объявляется модулем.

#### Архитектурное требование
Команда только читает систему, поддерживает `--sandbox` (первой строкой вызывает `assert-sandbox-home $effective_sandbox` из `src/state.nu`), ничего не исправляет автоматически.

| Проверка | Условие | Серьёзность |
| :--- | :--- | :--- |
| `link` | Управляемая ссылка битая, указывает не туда или заменена файлом (`RELINK` / `BACKUP_REPLACE` из `compute-link-ops`) | `error` |
| `link_pending` | Есть в плане, но не применено (`LINK` из `compute-link-ops`) | `warn` |
| `orphan_link` | Битый симлинк без записи в `state` в `~`, `~/.config`, `~/.local/bin` и родительских каталогах управляемых путей, глубина 1 | `warn` |
| `state_orphan` | Запись в `state` от модуля, которого нет в `host.toml` | `warn` |
| `sync` | `sync_conflicts` и `pending_save` из RFC-004 | `warn` |
| `perm` | Не `0600` (`rw-------`) на Unix: `secrets.toml`, `.state/env/*`, `99-ygg.conf`, файлы из `[doctor] private_files` | `error` |
| `tool` | `nu` ниже 0.116, нет `git`, нет менеджера с пакетами в плане | `error` |
| `collision` | Коллизии из RFC-010 (`resolved.collisions`) | `warn` |
| `shadow` | Каталог заменён ссылкой, а в его последнем бэкапе `.state/backups/<timestamp>/...` есть файлы, которых нет в источнике (REP-006.5); в `fix` указан путь к бэкапу, восстановление выполняет пользователь | `warn` |
| `secrets` | Ключи из `secrets.example.toml` отсутствуют в `secrets.toml` (RFC-024) | `warn` |
| `canonical` | Цель ссылки или модуля доступна, но путь не канонизируется (RFC-025) | `warn` |

Сверка запущенных процессов с файлами на диске из REP-006.5 не вводится: движок не знает, какой процесс читает какой файл, а хранение таких связей потребовало бы новой модели данных.

Дополнительные проверки модуля объявляются в манифесте (`load-module-manifest` в `src/manifest.nu` сохраняет `doctor: ($raw.doctor? | default {})`):
```toml
[doctor]
private_files = ["~/.config/sops/age/keys.txt"]
```
Вывод — таблица `check`, `severity`, `target`, `detail`, `fix`, а также итоговая строка со счётчиками. Флаг `--json` печатает те же записи как JSON (`to json --raw`), без итоговой строки (REP-007.4). Код выхода `1` при наличии `error`, предупреждения на него не влияют. Псевдоним `ygg audit` не вводится.

Файлы Chezmoi, оставшиеся обычными файлами, движок определить не может: они закрываются рецептом в `omni-dotfiles` (REP-004.5).

#### Контракт реализации
```nushell
# src/doctor.nu
export def run-doctor [
    ygg_home: string,
    --sandbox: string = ""
]: nothing -> table<check: string, severity: string, target: string, detail: string, fix: string> {
    # 1. Вызвать resolve-effective-plan $ygg_home, resolve-link-targets $plan --sandbox $sb и compute-link-ops $ygg_home $resolved --sandbox $sb
    # 2. Собрать строки для каждой из 11 проверок таблицы выше строго в режиме чтения (без создания папок или записи state)
    # 3. Вернуть итоговую таблицу записей { check, severity, target, detail, fix }
}

# bin/ygg.nu
def "main doctor" [--json, --sandbox: string = ""] {
    let effective_sandbox = if ($sandbox != "") { $sandbox } else { ($env.YGG_SANDBOX? | default "") }
    assert-sandbox-home $effective_sandbox
    let ygg_home = (get-ygg-home)
    let report = (run-doctor $ygg_home --sandbox=$effective_sandbox)
    if $json {
        print ($report | to json --raw)
    } else {
        print $report
        ...
    }
    if ($report | any { |r| $r.severity == "error" }) {
        exit 1
    }
}
```

#### Тестирование
* Тесты в `tests/test_doctor.nu`, все в `/tmp/ygg-test-*` с sandbox: по одному сценарию на каждую проверку; снимок файловой системы до и после совпадает; код выхода `1` при `error` и `0` при только `warn`.
* Статическая проверка в том же файле: `src/doctor.nu` не содержит `chezmoi` и `sops`.

---

### RFC-018: Подавление stderr от `chmod`

* **Компонент:** `src/link.nu`
* **Приоритет:** Низкий (шум в выводе)
* **Статус:** `Согласовано`
* **Источник:** REP-004.2

#### Проблема
`try { ^chmod +x $src }` в `src/link.nu:359` и `:428` не скрывает stderr внешней команды. Проба: `chmod: changing permissions ...` попадает в терминал при успешном `try`.

#### Архитектурное требование
Использовать один хелпер с паттерном из `src/env.nu:187`. Если файл уже исполняемый, `chmod` не вызывается: это исключает лишнюю запись на read-only файловой системе, а хелпер выполняется и при `OK` из RFC-009.

#### Контракт реализации
```nushell
# src/link.nu
def ensure-executable [p: string]: nothing -> nothing {
    let mode = (try { ls -lD $p | get -o 0.mode | default "" } catch { "" })
    if ($mode != "") and not (($mode | str substring (($mode | str length) - 9)..) =~ '^..x') {
        try { ^chmod +x $p | complete | ignore } catch { }
    }
}
```
В Nushell 0.116 `ls -lD` возвращает `mode` из 9 символов без символа типа файла (`rw-r--r--`, проверено пробой). Бит исполняемости владельца (`u+x`) стоит на **третьей** позиции: проверяется `^..x` по последним 9 символам строки, что работает и при появлении символа типа в других версиях.

#### Тестирование
* Тест в `tests/test_link.nu`: файл в `bin/` с исходными правами `0644` становится исполняемым (`rwx...`), при повторном вызове `chmod` не запускается; сбой `chmod` не даёт вывода в stderr (Linux, `/proc/version`, для пользователя без root).

---

### RFC-019: Дополнительные пути поиска `nu.exe`

* **Компонент:** `bin/ygg.cmd`
* **Приоритет:** Низкий (Windows UX)
* **Статус:** `Согласовано`
* **Источник:** REP-002.6

#### Проблема
`bin/ygg.cmd:5-11` уже проверяет `%USERPROFILE%\.local\bin`, `%LOCALAPPDATA%\Programs\nu\bin` и `%LOCALAPPDATA%\Microsoft\WinGet\Links`. Не проверяются установка в `Program Files` и Scoop. Кроме того, `setlocal` стоит после изменения `PATH` (`bin/ygg.cmd:13`), поэтому изменение остаётся в сессии вызывающего `cmd`.

#### Архитектурное требование
1. Порядок проверки: `.local\bin`, `Programs\nu\bin`, `WinGet\Links`, `%ProgramFiles%\nu\bin`, `%USERPROFILE%\scoop\shims`.
2. Перенести `setlocal` выше первого изменения `PATH`.

#### Контракт реализации
```bat
@echo off
setlocal
where nu >nul 2>nul
if %ERRORLEVEL% neq 0 (
    if exist "%USERPROFILE%\.local\bin\nu.exe" (
        set "PATH=%USERPROFILE%\.local\bin;%PATH%"
    ) else if exist "%LOCALAPPDATA%\Programs\nu\bin\nu.exe" (
        set "PATH=%LOCALAPPDATA%\Programs\nu\bin;%PATH%"
    ) else if exist "%LOCALAPPDATA%\Microsoft\WinGet\Links\nu.exe" (
        set "PATH=%LOCALAPPDATA%\Microsoft\WinGet\Links;%PATH%"
    ) else if exist "%ProgramFiles%\nu\bin\nu.exe" (
        set "PATH=%ProgramFiles%\nu\bin;%PATH%"
    ) else if exist "%USERPROFILE%\scoop\shims\nu.exe" (
        set "PATH=%USERPROFILE%\scoop\shims;%PATH%"
    )
)
```

#### Тестирование
* Статический тест в `tests/test_cli_e2e.nu`: `bin/ygg.cmd` содержит пять путей в указанном порядке, `setlocal` стоит раньше первого `set "PATH=`.
* `Проверить на Windows`: `tests/sandbox.wsb`, запуск с `nu.exe` только в `%ProgramFiles%\nu\bin`.

---

### RFC-020: Предварительная проверка до любых изменений (Pre-flight)

* **Компонент:** `src/link.nu`, `bin/ygg.nu`
* **Приоритет:** Критический (Data Safety)
* **Статус:** `Согласовано`
* **Источник:** REP-006.1

#### Проблема
`apply-links` не проверяет источник. В пробе `"configs/ollama" = "~/.config/ollama"` без каталога в модуле переместил рабочий `~/.config/ollama` в бэкап, создал битый симлинк и завершился с кодом 0. Глоб с отсутствующим источником молча создаёт пустой целевой каталог. Шаг пакетов при этом выполняется раньше шага ссылок.

#### Архитектурное требование
1. `preflight-check` выполняется **до всех шагов `apply`, включая пакеты**, и при dry-run тоже. Функция только читает систему.
2. Проверяются все ссылки эффективного плана, включая глобы и `mode = "dir"`: `$src_path | path exists`. Битый симлинк в модуле считается отсутствующим источником. Для ссылки с `mode = "dir"` проверяется, что существующий источник является каталогом (`($src_path | path type) == "dir"`).
3. **Ошибки собираются и выводятся одним сообщением** с указанием модуля и ключа, затем `apply` завершается с кодом 1. Хост не меняется.
4. На этом же шаге проверяются: вложенность целей (`resolved.nesting_conflicts`, RFC-010), затенение каталога хоста (RFC-021) и `Shared directory ownership conflict` (для глоб-директорий `glob_dest_dir`, если `is-link-or-junction $glob_dest_dir` истинно и путь не помечен как `PRUNE` этого же запуска). Сейчас эта ошибка возникает на середине `apply-links`, когда часть ссылок уже изменена.
5. `--force` **не обходит** проверку источников, вложенности и конфликта владения (но разрешает затенение каталога с предупреждением и бэкапом согласно RFC-021). Для отдельного хоста остаётся `exclude` в `host.toml`.
6. `[save]` не проверяется: отсутствующий источник при существующем файле хоста — штатный сценарий `seeded_module` (`src/link.nu:142`).

#### Граница гарантии
Это проверка до начала, а не транзакция с откатом. Сбой на этапе исполнения (`mklink`, права доступа) попадает в `failed` (RFC-009), заменённые файлы остаются в `.state/backups/`, автоматического отката нет.

Правило безопасно для текущих модулей: в манифестах `omni-dotfiles`, `dotfiles`, `ai-dotfiles` и в ветке `feat/ygg-migration` модуля `win-dotfiles` отсутствующих источников сейчас нет.

#### Контракт реализации
```nushell
# src/link.nu
export def preflight-check [
    ygg_home: string,
    plan: record,
    resolved: record,   # результат resolve-link-targets
    ops: table,         # результат compute-link-ops
    --force,
    --sandbox: string = ""
]: nothing -> list<record<module: string, key: string, reason: string, detail: string>> {
    # 1. Проверить каждый элемент plan.links: ($link.src_path | path exists) -> при false добавить reason: "missing_source";
    #    при link.mode == "dir" и (($link.src_path | path type) != "dir") -> добавить reason: "invalid_mode_source"
    # 2. Проверить resolved.nesting_conflicts -> добавить reason: "nesting_conflict"
    # 3. Проверить уникальные glob_dest_dir из resolved.targets: если (is-link-or-junction $glob_dest_dir)
    #    и $glob_dest_dir не входит в список PRUNE-операций из ops -> добавить reason: "ownership_conflict"
    # 4. Для целей с is_dir == true и операцией BACKUP_REPLACE на существующем реальном каталоге (($dest | path type) == "dir" и not (is-link-or-junction $dest)):
    #    вычислить extra = shadowed-files $dest $src; если extra не пуст и link.mode != "dir" и not $force -> добавить reason: "shadowed_files"
}

# bin/ygg.nu: первое действие после resolve-effective-plan, resolve-link-targets и compute-link-ops
let resolved = (resolve-link-targets $plan --sandbox=$effective_sandbox)
let ops = (compute-link-ops $ygg_home $resolved --force=$force --sandbox=$effective_sandbox)
let problems = (preflight-check $ygg_home $plan $resolved $ops --force=$force --sandbox=$effective_sandbox)
if ($problems | is-not-empty) {
    error make { msg: (format-preflight-errors $problems) }
}
```

#### Тестирование
* Тесты в `tests/test_cli_e2e.nu`: отсутствующий источник и отсутствующий источник глоба дают код 1; снимок sandbox совпадает; mock-лог пакетов пуст; сообщение перечисляет все отсутствующие источники сразу.
* Тест в `tests/test_cli_e2e.nu`: `--force` не обходит проверку; `exclude` снимает её для указанной ссылки.
* Тест в `tests/test_link.nu`: `[save]` с отсутствующим источником и существующим файлом хоста проходит проверку.

---

### RFC-021: Защита от затенения каталогов (режим `mode = "merge"` отложен)

* **Компонент:** `src/manifest.nu`, `src/link.nu`
* **Приоритет:** Критический (потеря runtime-состояния)
* **Статус:** `Согласовано` (защита от затенения и `mode = "dir"`); часть `mode = "merge"` — `Отложено` (см. разделы 4.2 и 4.3)
* **Источник:** REP-006.2

#### Проблема
`"OpenRGB" = "~/.config/OpenRGB"` заменяет весь каталог хоста ссылкой на папку модуля. В инциденте 12 файлов состояния приложения перестали быть видимыми, а демон потерял настройки. Файлы не удалены, они лежат в `.state/backups/`, но приложение уже работает без них.

Глоб `"OpenRGB/*" = "~/.config/OpenRGB/*"` (или точечные ссылки файлов согласно инварианту гибридных директорий) полностью закрывает этот случай и все остальные гибридные каталоги в реальных модулях (`antigravity/*`, `services/hermes/profiles/<p>/*`, `glazewm/cfg/*`). Переход с `"X"` на `"X/*"` раньше падал с ошибкой владения, что исправлено в RFC-011 (требование 9).

Рекурсивный режим `mode = "merge"` не имеет ни одного реального потребителя в мигрированных модулях, но потребовал бы сложного отслеживания сотен листовых симлинков и оставлял бы пустые физические подкаталоги после `PRUNE`. Поэтому `mode = "merge"` отложен, а в движке реализуется барьер против случайного затенения каталогов и явное подтверждение `mode = "dir"`.

#### Архитектурное требование

| Форма | Поведение | Файлы хоста вне источника |
| :--- | :--- | :--- |
| `"X" = "~/x"` | Ссылка на каталог | **Ошибка** на предварительной проверке (`preflight-check`) |
| `"X" = { target = "~/x", mode = "dir" }` | Ссылка на каталог, замена подтверждена | Предупреждение со списком, каталог уходит в бэкап |
| `"X/*" = "~/x/*"` | Поштучные ссылки первого уровня | Не затрагиваются, кроме совпадающих имён |

1. **Обнаружение затенения.** Для операции `BACKUP_REPLACE` с настоящим каталогом (`($dest | path type) == "dir"` и `not (is-link-or-junction $dest)`) сравниваются относительные пути всех файлов (включая скрытые dot-файлы) в `dest` и `src`. Сравниваются только относительные пути: различие содержимого одноимённых файлов — намеренное обновление.
2. **Ошибка без подтверждения.** Отчёт предлагал только предупреждение, но оно появилось бы уже после потери настроек у работающего демона. Ошибка на предварительной проверке выводит до 20 затеняемых файлов и указывает три выхода: перейти на `"X/*" = "~/x/*"` (или точечные ссылки), указать `mode = "dir"` или запустить с `--force`. `--force` разрешает замену с предупреждением и бэкапом, как `mode = "dir"`.
3. **Валидация `mode = "dir"`.** Существующий источник с `mode = "dir"` обязан быть каталогом (`preflight-check` возвращает ошибку `invalid_mode_source` для файла); комбинация `mode` с `/*` запрещена в `normalize-link-value` (RFC-015).
4. **Смена режима.** Ссылка, созданная движком на месте каталога, при переходе на `"X/*"` снимается операцией `PRUNE` (RFC-011, требование 9). Неуправляемая ссылка на корне `target` — ошибка владения.
5. **Восстановление.** Бэкапы не возвращаются автоматически, на них указывает проверка `shadow` в `ygg doctor` (RFC-017).

#### Контракт реализации
```nushell
# src/link.nu
def relative-files [dir: string]: nothing -> list<string> {
    if not ($dir | path exists) {
        return []
    }
    glob --no-dir --no-symlink ($dir | path join "**" "*")
    | each { |f| $f | path relative-to $dir }
    | sort
}

export def shadowed-files [dest: string, src: string]: nothing -> list<string> {
    let tracked = (relative-files $src)
    relative-files $dest | where { |f| $f not-in $tracked }
}
```
Разбор `mode` приведён в `normalize-link-value` (RFC-015). В `glob` Nushell 0.116 шаблон `**/*` включает скрытые файлы и каталоги по умолчанию (подтверждено пробой).

#### Тестирование
* Тесты в `tests/test_link.nu`: каталог хоста с лишним файлом (включая скрытый `.state`) и обычная ссылка на каталог дают ошибку `shadowed_files` на предварительной проверке, хост не меняется; если все файлы хоста есть в источнике — проверка проходит; `mode = "dir"` и `--force` проходят с предупреждением, лишний файл лежит в бэкапе.
* Тест в `tests/test_manifest.nu` / `tests/test_link.nu`: неизвестный `mode` (включая `"merge"`), `mode` вместе с `/*` и `mode = "dir"` для файла дают ошибку.

---

### RFC-022: Проверка пакетов перед `sudo` и работа без TTY

* **Компонент:** `src/pkg.nu`
* **Приоритет:** Высокий (автоматизация и агенты)
* **Статус:** `Согласовано`
* **Источник:** REP-007.1

#### Проблема
`src/pkg.nu:10` всегда запускает `sudo pacman -S --needed`, даже если всё установлено. В сессии агента или cron команда запрашивает пароль, который никто не введёт. Кэш RFC-014 эту проблему не решает: первый запуск и каждое изменение набора всё равно идут через `sudo`.

#### Архитектурное требование
1. Перед `pacman` и `paru` определяется список отсутствующих пакетов одним вызовом `pacman -T`. Проба на этом хосте: выполнение меньше 500 мс, код `0` — всё установлено, `127` — в stdout только отсутствующие. Вариант `pacman -Q` на каждый пакет из отчёта не выбран: это отдельный процесс на пакет.
2. Менеджер получает **только отсутствующие** пакеты. Пустой список — вызова нет, `sudo` не запускается.
3. Другой код возврата `pacman -T` считается отсутствием всех пакетов: поведение тогда такое же, как сейчас. Имя группы `-T` также считает отсутствующим, поэтому группа по-прежнему уходит в `pacman -S --needed`.
4. **Неинтерактивный режим.** Если остались пакеты для установки, `is-terminal --stdin` возвращает `false` или задан `YGG_NONINTERACTIVE=1`, выполняется `sudo -n true`. При неудаче менеджер не вызывается, в `failed` добавляется запись с `reason: "sudo_required"` и списком пакетов.
5. Переменная `YGG_NONINTERACTIVE` нужна сессиям с псевдотерминалом, где `is-terminal` истинно, но ввести пароль некому.
6. В mock-режиме реальные `pacman` и `sudo` не вызываются: установленные пакеты задаёт `YGG_MOCK_PKG_INSTALLED`, отсутствие прав — `YGG_MOCK_SUDO_DENIED`.

#### Контракт реализации
```nushell
# src/pkg.nu
def missing-native-pkgs [pkgs: list<string>]: nothing -> list<string> {
    let res = (^pacman -T ...$pkgs | complete)
    match $res.exit_code {
        0 => [],
        127 => ($res.stdout | lines | where { |l| $l != "" }),
        _ => $pkgs
    }
}

def sudo-available []: nothing -> bool {
    let non_interactive = (not (is-terminal --stdin)) or (($env.YGG_NONINTERACTIVE? | default "") == "1")
    if not $non_interactive {
        return true
    }
    (^sudo -n true | complete).exit_code == 0
}
```

#### Тестирование
* Тесты в `tests/test_pkg_git.nu`: все пакеты установлены — строки `pacman` в mock-логе нет; часть установлена — команда содержит только отсутствующие; `paru` ведёт себя так же.
* Тест в `tests/test_pkg_git.nu`: при `YGG_MOCK_SUDO_DENIED` запись содержит `reason: "sudo_required"`, а ссылки и остальные шаги выполняются.
* Существующие тесты без `YGG_MOCK_PKG_INSTALLED` получают все пакеты как отсутствующие, поэтому строка команды не меняется.

---

### RFC-023: SDK-хелпер `safe-link`

* **Компонент:** `src/sdk.nu`, `src/link.nu`, `bin/ygg.nu`
* **Приоритет:** Средний (SDK)
* **Статус:** `Согласовано`
* **Источник:** REP-007.2

#### Проблема
Если `dest` — настоящий каталог, `^ln -sfn src dest` создаёт ссылку **внутри** него (подтверждено пробой). Поэтому `ai-dotfiles/setup.nu:19-37` (в репозитории `ai-dotfiles`, в ветке `feat/ygg-migration` — строки `19-28`) повторяет защитный код с прямым вызовом `^ln -sfn`.

Вариант из отчёта очищает цель через `rm -rf`, что нарушает инвариант Zero-Data-Loss (`AGENTS.md`, раздел 2, пункт 3). Заменено бэкапом.

#### Архитектурное требование
1. Логика совпадает с таблицей состояний из RFC-009: нужная ссылка — no-op; другая или битая — атомарная замена; файл или каталог — `backup-with-notice`, затем создание.
2. Относительный `src` записывается в ссылку как есть. Его существование проверяется относительно родительского каталога `dest` (`($dest | path dirname) | path join $src`), а для пути, начинающегося с `~` или токена (`$APPDATA` и др.) — через `expand-target-path`. Отсутствующий источник — ошибка, как в RFC-020.
3. `dest` проходит через `expand-target-path`, поэтому sandbox соблюдается. При `YGG_DRY_RUN=true` функция только сообщает о действии.
4. На Windows: для каталога создаётся Junction с абсолютным путём (`to-win32-path`), потому что Junction не поддерживает относительные цели. Для файла — ошибка с указанием использовать `[save]`. `Проверить на Windows`.
5. Ссылки `safe-link` не попадают в `state.links` и не участвуют в `PRUNE`: ими управляет сам `setup.nu`.
6. Для единообразия с `onchange`, `merge-json` и `export-secrets` в `bin/ygg.nu` добавляется SDK-подкоманда `ygg safe-link <src> <dest>`.

#### Контракт реализации
```nushell
# src/sdk.nu
export def safe-link [src: string, dest: string]: nothing -> nothing {
    let ygg_home = (get-ygg-home)
    let is_dry = (($env.YGG_DRY_RUN? | default "false") == "true")
    let target_dest = (expand-target-path $dest)
    let dest_parent = ($target_dest | path dirname)
    let check_src = if (is-path-absolute $src) {
        expand-target-path $src
    } else {
        $dest_parent | path join $src
    }
    if not ($check_src | path exists) {
        error make { msg: $"safe-link: source '($src)' \(resolved to '($check_src)'\) does not exist" }
    }
    if (link-target-matches $target_dest $check_src) and ($target_dest | path exists) {
        return
    }
    if $is_dry {
        print $"[ygg] dry-run: safe-link '($target_dest)' -> '($src)'"
        return
    }
    mkdir $dest_parent
    if (is-link-or-junction $target_dest) {
        if ($nu.os-info.family == "windows") {
            remove-link-only $target_dest
            create-windows-dir-link $check_src $target_dest
        } else {
            swap-symlink-atomic $src $target_dest
        }
    } else {
        if (($target_dest | path type) != null) {
            backup-with-notice $ygg_home $target_dest | ignore
        }
        if ($nu.os-info.family == "windows") {
            create-windows-dir-link $check_src $target_dest
        } else {
            ^ln -s $src $target_dest
        }
    }
}
```
Замена в `ai-dotfiles/setup.nu` выполняется отдельно в этом модуле:
```nushell
for p in $profiles {
    safe-link "../../plugins" $"~/.hermes/profiles/($p)/plugins"
}
for p in ["coder", "gemini", "thinker"] {
    safe-link "../../.env" $"~/.hermes/profiles/($p)/.env"
}
```

#### Тестирование
* Тесты в `tests/test_sdk.nu`: `dest` — настоящий каталог: вложенной ссылки нет, содержимое в бэкапе; повторный вызов не меняет inode; другая цель заменяется; относительная цель сохраняется буквально; отсутствующий источник даёт ошибку; `YGG_DRY_RUN=true` ничего не меняет.
* Статическая проверка: `src/sdk.nu` не содержит `rm -rf`.

---

### RFC-024: Проверка секретов по шаблону

* **Компонент:** `src/sdk.nu`, `src/env.nu`, `src/doctor.nu`
* **Приоритет:** Средний (отложенные сбои демонов)
* **Статус:** `Согласовано`
* **Источник:** REP-007.5

#### Проблема
`export-secrets` молча выходит без `secrets.toml` (`src/sdk.nu:198`) и молча отбрасывает отсутствующие ключи (`src/sdk.nu:217`). Демоны падают позже, и причина с `apply` не связывается.

#### Архитектурное требование
1. **Соглашение:** необязательный `secrets.example.toml` в корне модуля. Формат совпадает с `secrets.toml`: секция `[env]` или ключи верхнего уровня. Закомментированные ключи необязательны. Такой файл уже есть в `dotfiles`.
2. Ключ считается отсутствующим, если его нет в `secrets.toml` или значение пустое.
3. `apply` выводит `[ygg] Warning: module '<m>' is missing secrets: <KEY1>, <KEY2>`. Команда не падает: секреты могут быть не нужны на этом хосте.
4. `export-secrets --keys` предупреждает о каждом запрошенном, но отсутствующем ключе (включая случай, когда сам `secrets.toml` отсутствует и `--keys` не пуст).
5. `ygg doctor` показывает ту же проверку как `secrets`. Отдельная команда `ygg check-secrets` не вводится.
6. **Значения секретов никогда не выводятся**, только имена ключей.
7. `mise.example.toml` не поддерживается в ядре: `ai-dotfiles` добавляет у себя `secrets.example.toml` (раздел 4.3).

#### Контракт реализации
```nushell
# src/env.nu
def secret-keys [p: string]: nothing -> record {
    if not ($p | path exists) {
        return {}
    }
    let d = (try { open $p } catch { {} })
    let extracted = if "env" in $d { $d.env } else { $d }
    if (($extracted | describe) starts-with "record") { $extracted } else { {} }
}

export def missing-secret-keys [template: string, secrets: string]: nothing -> list<string> {
    let have = (secret-keys $secrets)
    secret-keys $template
    | columns
    | where { |k| (($have | get -o $k | default "") | into string) == "" }
}
```

#### Тестирование
* Тесты в `tests/test_env.nu`: пустое значение и отсутствующий файл считаются отсутствием, закомментированный ключ — нет, модуль без шаблона не проверяется, вывод не содержит значений.
* Тест в `tests/test_sdk.nu`: `export-secrets --keys` предупреждает об отсутствующем ключе и записывает остальные.

---

### RFC-025: Модули на томах без канонизации путей

* **Компонент:** `src/git.nu`, `src/doctor.nu`, базовая спецификация
* **Приоритет:** Средний (VM и сетевые диски)
* **Статус:** `Согласовано`
* **Источник:** REP-008.1

#### Проблема
По отчёту, `ygg add Z:\omni-dotfiles` создал цепочку `~/.config/mise` → `~/.ygg/modules/omni-dotfiles\mise` → `Z:\omni-dotfiles\mise`. Драйвер VirtIO-FS не поддерживает `GetFinalPathNameByHandleW`, `std::fs::canonicalize()` в `mise` падает, и его конфигурация попадает в `ignored_config_files`. Шиммы возвращают код 1, а запуск `nu` падает. Перенос модуля на `C:` устранил сбой. Движок видел `links_ok: true` и не сообщал о проблеме.

Это ограничение драйвера и инструмента: `mklink /J` здесь успешен, поэтому fallback из RFC-006 не поможет. Базовая спецификация (строка 41) разрешает модули «на любом диске», и это утверждение нужно уточнить.

Дополнительный дефект: `^cmd /c mklink /J ... | complete | ignore` в `src/git.nu:41` скрывает сбой создания связи, после чего модуль всё равно регистрируется.

#### Архитектурное требование
1. **Проверка `mklink` в `add`.** Ненулевой код — ошибка, `host.toml` не меняется.
2. **Предупреждение в `add` на Windows.** Если `$source | path expand --strict` завершается ошибкой, хотя каталог доступен, выводится: `[ygg] Warning: '<source>' is on a volume without path canonicalization support. Tools such as mise may ignore configs reached through it. Copy the module to a local NTFS disk and add it from there.` `Проверить на Windows`: совпадает ли поведение `path expand --strict` со сбоем `mise`.
3. **Проверка `canonical` в `ygg doctor`** для модулей и ссылок. Цель читается, а `path expand --strict` падает — это `warn`. Битая ссылка обрабатывается проверкой `link`.
4. **RFC-009 не зависит от канонизации:** первый шаг сравнения литеральный.
5. **Базовая спецификация:** заменить «на любом диске» на «на любом локальном NTFS-томе»; VirtIO-FS и сетевые диски поддерживаются ограниченно.
6. **Сценарии проверки в VM** копируют модуль на `C:` перед `ygg add`. Проверка по `Z:\` не отражает работу на реальном хосте.

#### Отклонённые варианты
* **Автоматическое копирование и `ygg add --copy`:** копия разрывает связь с Git и скрывает различия от автора. Ручное копирование и `ygg add C:\...` занимают одну команду.
* **Ошибка вместо предупреждения:** Git и многие инструменты на таком томе работают, а сбой зависит от инструмента.

#### Контракт реализации
```nushell
# src/git.nu
def warn-if-not-canonicalizable [path: string]: nothing -> nothing {
    let mocked = (($env.YGG_MOCK_NO_CANONICALIZE? | default "") == "1")
    let failed = $mocked or (try { $path | path expand --strict | ignore; false } catch { true })
    if $failed and ($path | path exists) {
        print -e $"[ygg] Warning: '($path)' is on a volume without path canonicalization support. Tools such as mise may ignore configs reached through it. Copy the module to a local NTFS disk and add it from there."
    }
}
```

#### Тестирование
* Тест в `tests/test_pkg_git.nu`: при `YGG_MOCK_NO_CANONICALIZE=1` `add` выводит предупреждение и регистрирует модуль.
* Тест в `tests/test_doctor.nu`: тот же режим даёт запись `canonical` с `warn`; код выхода 0.
* `Проверить на Windows`: VM с VirtIO-FS, предупреждение появляется на `Z:\`, отсутствует на `C:`; сбой `mklink` не регистрирует модуль.

---

## 4. Порядок реализации и решения на ревью

### 4.1. Порядок реализации

Порядок следует зависимостям контрактов. Этап 2 рекомендуется завершить до миграции `dotfiles`, `ai-dotfiles` и `win-dotfiles`, как и просит REP-003.

| Этап | RFC | Причина |
| :--- | :--- | :--- |
| **0. Защита данных** | RFC-020 (базовая проверка источников в `plan.links`), RFC-011 (требование 5: SDK соблюдает `YGG_DRY_RUN`) | Устраняют потерю данных и изменение системы при dry-run, не зависят от остальных RFC |
| **1. Независимые исправления** | RFC-001, RFC-002, RFC-007, RFC-008, RFC-016, RFC-018, RFC-019, RFC-024 | Не зависят от других контрактов, снимают аварийные сбои |
| **2. Ядро ссылок** | RFC-003 → RFC-010 → RFC-009 и RFC-006 → RFC-011 → RFC-021 → RFC-012 → RFC-023 | Кандидаты дают приоритеты (`resolve-link-targets`), `link-target-matches` из RFC-009 позволяет классифицировать `OK`/`RELINK` в `compute-link-ops` (RFC-011), затем исполнение. На нём строятся защита от затенения, `add --dry-run` и `safe-link` |
| **3. Пакеты** | RFC-022, затем RFC-005 и RFC-013 → RFC-014 | Сначала снять зависание на `sudo`, затем единый запуск по argv и кэш |
| **4. Наблюдаемость и реакция** | RFC-004 и RFC-025 → RFC-017, затем RFC-015 | `doctor` (RFC-017) потребляет `sync_conflicts` из RFC-004, `canonical` из RFC-025 и `secrets` из RFC-024; хуки `on_change` (RFC-015) используют `run-with-timeout` из Этапа 3 и `hash-watch-set` |

На этапе 0 `preflight-check` (RFC-020) проверяет только существование `$link.src_path` по `plan.links`. Проверки вложенности (`nesting_conflicts`), конфликта владения (`ownership_conflict`) и затенения (`shadowed_files`) подключаются к `preflight-check` на Этапе 2 вместе с RFC-010, RFC-011 и RFC-021.

### 4.2. Решения, отличающиеся от отчётов

Итоговые решения по результатам архитектурного ревью:

1. **`on_change` (RFC-015):** табличная форма в `links.toml`, как в отчёте, а не отдельная секция хуков — **Итог: Оставить как есть.** Привязка к ключу ссылки сохраняет действие `exclude` в `host.toml` и исключает дублирование путей источников.
2. **Пакеты (RFC-014):** кэш хеша эффективного набора вместо контрольной суммы `packages.toml` и вместо `ygg sync` — **Итог: Оставить как есть.** Пакеты собираются из нескольких модулей, `ygg.toml` и активных скоупов, а отдельный `ygg sync` ломает контракт `ygg apply`.
3. **Таймауты (RFC-013):** 300 с для сетевых менеджеров, без таймаута для `cargo`, `paru` и `pacman`, вместо единых 120 с — **Итог: Оставить как есть.** Таймаут 120 с обрывает штатную компиляцию крейтов/AUR и интерактивный ввод пароля `sudo`.
4. **`~` в окружении (RFC-016):** абсолютный путь на этапе генерации вместо синтаксиса для каждого шелла и `%h` — **Итог: Оставить как есть.** Приёмники `systemctl import-environment` и `HKCU\Environment` не раскрывают `~` и `%h`, а файлы `.state/env/*` локальны для хоста.
5. **`ygg doctor` (RFC-017):** обобщённые проверки и `[doctor] private_files` вместо упоминания Chezmoi и `sops` в ядре — **Итог: Оставить как есть.** Соблюдает инвариант чистоты ядра `AGENTS.md` (п. 2.2) без потери проверяемых сценариев.
6. **Вложенные целевые пути (RFC-010):** ошибка, а не предупреждение — **Итог: Оставить как есть.** Запись внутрь симлинка родительского каталога мутирует чужой Git-репозиторий, что нарушает изоляцию модулей.
7. **Затенение каталога (RFC-021):** ошибка до изменений, если замена не подтверждена через `mode = "dir"` или `--force` — **Итог: Оставить как есть.** Предупреждение после бэкапа не предотвращает потерю runtime-состояния работающим демоном (`OpenRGB`).
8. **`mode = "merge"` (RFC-021):** рекурсивное слияние вводится вместе с существующим `/*`, а не заменяет его — **Итог: Отказаться от `mode = "merge"` (Отложено), упростить RFC-021 до защиты от затенения и `mode = "dir"`.** В реальных модулях нет вложенных гибридных каталогов (все случаи закрыты `/*`), а рекурсивная линковка файлов усложняет `state.links` и оставляет пустые каталоги при `PRUNE`.
9. **`safe-link` (RFC-023):** бэкап вместо `rm -rf` из отчёта — **Итог: Оставить как есть.** `rm -rf` реального каталога нарушает инвариант Zero-Data-Loss (`AGENTS.md`, п. 2.3).
10. **`[rel-links]` (REP-007.3):** отложено в пользу `safe-link` — **Итог: Отказаться / оставить отложенным.** Единственный случай в `ai-dotfiles` зависит от `.env`, создаваемого в `setup.nu` после этапа ссылок, и решается 6 строками с `safe-link`.
11. **VirtIO-FS (RFC-025):** предупреждение и диагностика, без `ygg add --copy` — **Итог: Оставить как есть.** Флаг `--copy` разрывает связь модуля с Git и скрывает дрейф на редком сценарии VM.

### 4.3. Вне рамок движка и отложенное

* **`cutover-chezmoi` (REP-004.5):** рецепт для `omni-dotfiles`. Удаление осиротевших `~/.config/{nushell,zsh}/aliases.*`, перенацеливание модуля и вызов `ygg apply` относятся к этому репозиторию.
* **`nushell/env.nu` (REP-008.2):** передать в `omni-dotfiles`. Инициализация `zoxide` и `starship` должна переживать сбой шимма и не записывать пустой файл автозагрузки: в пробе `try { ... | save -f }` перехватил ошибку, но файл создал пустым. Причина, по которой на Windows ошибка прошла мимо `try`, не установлена.
* **`ai-dotfiles` (RFC-023, RFC-024):** заменить цикл создания ссылок профилей в `setup.nu` на `safe-link` и добавить `secrets.example.toml`.
* **`[rel-links]` (REP-007.3):** `Отложено`. Шаг ссылок выполняется до `setup.nu`, поэтому цель `../../.env`, которую создаёт `export-secrets`, ещё не существует и не пройдёт проверку RFC-020. Глоб по `~/.hermes/profiles/*` на чистом хосте не найдёт ничего, тогда как `setup.nu` перечисляет профили явно. Единственный потребитель покрывается циклом с `safe-link`. Вернуться к вопросу, если такая потребность появится у второго модуля.
* **`mode = "merge"` (RFC-021 / REP-006.2):** `Отложено`. Во всех четырёх мигрированных модулях (`omni-dotfiles`, `dotfiles`, `ai-dotfiles`, `win-dotfiles`) гибридные каталоги имеют глубину 1 и полностью закрываются существующим глобом `/*` или точечными ссылками (`OpenRGB/*`, `antigravity/*`, `services/hermes/profiles/<p>/*`, `glazewm/cfg/*`). Защита от случайного затенения каталога и явный режим `mode = "dir"` сохранены в RFC-021; рекурсивный `mode = "merge"` отложен до появления реального потребителя с вложенными гибридными подкаталогами.

---

## 5. Порядок расширения спецификации (Living Spec Lifecycle)

При возникновении новых проблем или получении отчётов об использовании других модулей (`omni-dotfiles`, `ai-dotfiles`):
1. **Регистрация отчёта:** Внести запись в Таблицу 1 («Реестр отчётов об использовании») с ID `REP-XXX` и разложить пункты в трассировке 1.1.
2. **Проверка утверждений:** Сверить каждый пункт с кодом и при необходимости пробой в `/tmp/ygg-test-*`. Отчёт описывает симптом, предложенное в нём решение остаётся гипотезой.
3. **Проверка на дублирование:** Сопоставить выявленные симптомы с Таблицей 2 («Матрица дедупликации компонентов»). Если проблема уже покрыта существующим RFC, дополнить тестовые сценарии этого RFC.
4. **Создание нового RFC:** Если требуется изменение контрактов или новая механика, завести секцию `RFC-XXX` со статусом `Предложено`, описанием проблемы, требований, сигнатур и тестов.
5. **Согласование:** После ревью статус меняется на `Согласовано`.
6. **Реализация и приёмка:** Реализация закрывает RFC переводом статуса в `Реализовано` с подтверждением прохождения тестового набора (`rtk just test`) и всех проверок `Проверить на Windows` / `Проверить на macOS` этого RFC.
