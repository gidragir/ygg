# Спецификация улучшений и стабилизации движка `ygg` (Living Spec)

> **Дата создания:** 2026-11-08  
> **Статус:** Согласовано (В процессе реализации)  
> **Цель документа:** Единый живой реестр архитектурных улучшений, платформенных исправлений и адаптаций рантайма `ygg`, выявленных в процессе реальной миграции модулей (`win-dotfiles`, `omni-dotfiles`, `dotfiles`, `ai-dotfiles`). Документ дополняется по мере поступления новых отчётов об использовании для исключения двойной работы.

---

## 1. Реестр отчётов об использовании (Source Reports)

| ID отчёта | Дата | Источник / Модуль | Ключевые проблемы | Статус разбора |
| :--- | :--- | :--- | :--- | :--- |
| **REP-001** | 2026-11-08 | Миграция `win-dotfiles` (Windows 11) | Падение Win32 API на масках файлов в `onchange`, фатальный сбой `apply` при отсутствии `scoop`, потребность в 1-to-N ссылках (`glazewm`), невидимость 3-way конфликтов в `status`, отсутствие `--version`, сбои батчинга `winget`. | Разобран, включён в RFC-001 — RFC-006 |

---

## 2. Матрица дедупликации компонентов (De-duplication Matrix)

Чтобы предотвратить дублирование логики и фрагментацию кода, все доработки строго привязаны к ответственным подсистемам:

| Подсистема | Файл | Зона ответственности | Связанные RFC |
| :--- | :--- | :--- | :--- |
| **SDK & Reactive Runner** | `src/sdk.nu` | Изоляция Win32 File API от wildcard-масок, хэширование файлов `onchange` | RFC-001 |
| **Package Providers** | `src/pkg.nu` | Диспетчеризация пакетных менеджеров, проверка доступности (`which`), поштучная установка | RFC-002, RFC-005 |
| **Manifest & Plan Engine** | `src/manifest.nu` | Парсинг `links.toml`, `save`, 1-to-N списки путей, вычисление эффективного плана | RFC-003 |
| **Git & Telemetry** | `src/git.nu` | Диагностика `ygg status`, подсчёт `sync_conflicts` и `pending_save` из `state.copies` | RFC-004 |
| **Link & Sync Engine** | `src/link.nu` | Безопасность ссылок, fallback с `mklink /J` на `/D` и `cp -r` на UNC/сетевых путях | RFC-006 |
| **CLI Entrypoint** | `bin/ygg.nu` | Маршрутизация аргументов, флаги `--version` / `-v`, подкоманда `version` | RFC-007 |

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

#### Контракт реализации
```nushell
# src/manifest.nu
for link_key in ($mod_links | columns) {
    let dest_val = ($mod_links | get $link_key)
    let dest_list = if (($dest_val | describe) starts-with "list") {
        $dest_val
    } else if ($dest_val != null) and ($dest_val != "") {
        [$dest_val]
    } else {
        []
    }

    for dest_raw in $dest_list {
        if ($link_key in $excludes) or ($dest_raw in $excludes) {
            continue
        }
        let clean_key = ($link_key | str replace --regex '^\./' '')
        let base_rel = ($clean_key | str replace --regex '/\*$' '')
        let src_path = ($mod_dir | path join $base_rel)
        let is_glob = (($link_key | str ends-with "/*") or ($dest_raw | str ends-with "/*"))

        let link_record = {
            module: $mod_name,
            key: $link_key,
            src_rel: $clean_key,
            src_path: $src_path,
            dest_raw: $dest_raw,
            is_glob: $is_glob
        }

        if not $is_glob {
            $plan_links = ($plan_links | where { |it| $it.is_glob or ($it.dest_raw != $dest_raw) } | append $link_record)
        } else {
            $plan_links = ($plan_links | append $link_record)
        }
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

#### Тестирование
* Тест в `tests/test_state.nu` / `tests/test_pkg_git.nu`: `modules-status` корректно рапортует число коллизий и число ожидающих `save` файлов.

---

### RFC-005: Поштучная изолированная установка для однопозиционных пакетных менеджеров (`WinGet` / `uv`)

* **Компонент:** `src/pkg.nu`
* **Приоритет:** Высокий (Windows Stability)
* **Статус:** `Согласовано`

#### Проблема
Синтаксис WinGet CLI не поддерживает передачу пачки пакетов в аргументах команды: `winget install --exact pkg1 pkg2` завершается с ошибкой синтаксиса аргументов. Кроме того, пачечный запуск приводит к тому, что сбой одного пакета (например, уже установленного вручную или временно недоступного в репозитории) блокирует установку всех остальных пакетов модуля.

#### Архитектурное требование
1. Для провайдеров, требующих атомарного вызова (`winget`, `uv tool`), генерировать и выполнять команды строго поштучно для каждого пакета из списка.
2. Сбой установки отдельного пакета WinGet логируется в stderr, но цикл продолжается для оставшихся пакетов.
3. В отчёте `pkg_res.failed` фиксируются конкретные пакеты, завершившиеся ошибкой.

#### Контракт реализации
```nushell
# src/pkg.nu
if $mgr == "winget" {
    for pkg in $pkgs {
        let single_cmd = $"winget install --exact --accept-source-agreements --accept-package-agreements ($pkg)"
        # Выполнение команды с перехватом exit_code
        ...
    }
}
```

#### Тестирование
* Тест в `tests/test_pkg_git.nu`: для `winget` генерируются индивидуальные вызовы команд в mock-лог.

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

## 4. Порядок расширения спецификации (Living Spec Lifecycle)

При возникновении новых проблем или получении отчётов об использовании других модулей (`omni-dotfiles`, `ai-dotfiles`):
1. **Регистрация отчёта:** Внести запись в Таблицу 1 («Реестр отчётов об использовании») с ID `REP-XXX`.
2. **Проверка на дублирование:** Сопоставить выявленные симптомы с Таблицей 2 («Матрица дедупликации компонентов»). Если проблема уже покрыта существующим RFC, дополнить тестовые сценарии этого RFC.
3. **Создание нового RFC:** Если требуется изменение контрактов или новая механика, завести секцию `RFC-XXX` с описанием проблемы, требований, сигнатур и тестов.
4. **Реализация и приёмка:** Реализация закрывает RFC переводом статуса в `Реализовано` с подтверждением прохождения тестового набора (`rtk just test`).
