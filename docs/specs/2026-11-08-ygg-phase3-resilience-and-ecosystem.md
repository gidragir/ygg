# Спецификация Фазы 3: Отказоустойчивость, Экосистема и Безопасность движка `ygg` (RFC-026 — RFC-040)

> **Дата создания:** 2026-11-08  
> **Статус:** `Предложено (RFC-026 — RFC-040)`  
> **Цель документа:** Официальный архитектурный стандарт и спецификация Фазы 3 развития движка `ygg`. Документ устраняет критические точки отказа (гонки хоста, неатомарность многоэтапного конвейера, накопление мусора), расширяет экосистему поддерживаемых ОС (Homebrew macOS, дистрибутивы Debian/Fedora), внедряет управление зависимостями модулей, внешние секреты, воспроизводимый lockfile и CI-матрицу.  
> **База контракта:** `docs/specs/2026-11-08-ygg-engine-improvements-and-hardening.md` (RFC-001 — RFC-025), Nushell `>= 0.116.1`.

---

## 1. Архитектурная матрица улучшений (RFC-026 — RFC-040)

| RFC ID | Подсистема | Зона ответственности | Приоритет | Ключевая цель |
| :--- | :--- | :--- | :--- | :--- |
| **RFC-026** | `src/state.nu`, `bin/ygg.nu` | Concurrency & Locks | **P0 (Критический)** | Кроссплатформенная блокировка хоста (`ygg.lock`), предотвращение гонок процессов |
| **RFC-027** | `src/state.nu`, `bin/ygg.nu`, `src/doctor.nu` | Reliability & Crash Recovery | **P1 (Высокий)** | Транзакционный журнал (WAL) конвейера `apply`, восстановление после сбоев |
| **RFC-028** | `src/state.nu`, `bin/ygg.nu` | Garbage Collection & Backups | **P1 (Высокий)** | Ротация бэкапов (retention policy) и сборка мусора устаревших хэшей `state.hashes` |
| **RFC-029** | `src/pkg.nu` | Package Providers | **P0 (Критический)** | Поддержка Homebrew (`brew`) на macOS и дистрибутивов Linux (`apt`, `dnf`) |
| **RFC-030** | `src/pkg.nu`, `bin/ygg.nu` | Package Providers | **P2 (Средний)** | Декларативная очистка неиспользуемых пакетов (`apply --prune-packages`) для изолированных менеджеров |
| **RFC-031** | `src/manifest.nu`, `bin/ygg.nu` | Manifest & Plan Engine | **P1 (Высокий)** | Граф зависимостей модулей (`depends_on`) и топологическая сортировка алгоритмом Кана |
| **RFC-032** | `src/git.nu`, `src/manifest.nu`, `bin/ygg.nu` | Git & State Engine | **P1 (Высокий)** | Фиксация версий модулей (`ref`, `pin`) и воспроизводимый `ygg.lock` |
| **RFC-033** | `src/manifest.nu` | Manifest & Plan Engine | **P2 (Средний)** | Логические составные скоупы (`[scope."linux and !work"]`) |
| **RFC-034** | `src/env.nu`, `src/sdk.nu` | Secrets & Env Compiler | **P2 (Средний)** | Провайдеры внешних секретов (`op://`, `bw://`, `pass:`, `eval:age ...`) |
| **RFC-035** | `src/doctor.nu` | Diagnostics & Security | **P1 (Высокий)** | Аудит прав доступа и списков контроля доступа (ACL) на Windows через `icacls` |
| **RFC-036** | `src/env.nu` | Env Compiler | **P2 (Средний)** | Генерация переменных окружения и алиасов для Fish Shell (`env.fish`, `aliases.fish`) |
| **RFC-037** | `src/manifest.nu`, `bin/ygg.nu` | Runtime Services | **P2 (Средний)** | Декларативное управление демонами (`[services]` для systemd user units) |
| **RFC-038** | `src/doctor.nu`, `bin/ygg.nu` | Diagnostics & Self-Healing | **P2 (Средний)** | Режим автоматического устранения дефектов `ygg doctor --fix` |
| **RFC-039** | `bin/ygg.nu` | CLI Usability & DX | **P3 (Низкий)** | Автоматическая генерация дополнений командной строки (`ygg completions`) |
| **RFC-040** | `.github/workflows/`, `tests/` | CI & Test Isolation | **P0 (Критический)** | Кроссплатформенная CI-матрица (Linux, Win, Mac) и изоляция тестов от хостовых путей |

---

## 2. Спецификация требований и контрактов (RFC Items)

### RFC-026: Кроссплатформенная межпроцессная блокировка хоста (`Advisory Host Lock: ygg.lock`)

* **Компонент:** `src/state.nu`, `bin/ygg.nu`
* **Приоритет:** Критический (P0)
* **Статус:** `Предложено`

#### Проблема
При одновременном запуске команд `ygg apply`, `ygg add` или `ygg update` из разных агентских сессий, фоновых планировщиков (cron/systemd-timer) или пользовательского терминала происходит конкурентная модификация `$YGG_HOME/.state/state.json`, `$YGG_HOME/host.toml` и каталога резервных копий. Отсутствие механизма взаимного исключения приводит к потере данных и повреждению состояния.

#### Архитектурное требование
1. Перед выполнением мутирующих операций (`apply`, `add`, `remove`, `update`, `save`) движок обязан захватить эксклюзивную advisory-блокировку: `$YGG_HOME/.state/ygg.lock`.
2. Файл блокировки содержит JSON-структуру:
   ```json
   {
     "pid": 12345,
     "timestamp": "2026-11-08T22:00:00Z",
     "command": "apply",
     "user": "username"
   }
   ```
3. **Автоматическое снятие зависших блокировок (Stale Lock Recovery):**
   - Если файл блокировки существует, движок проверяет существование процесса с указанным `pid`.
   - Unix (Linux/macOS): вызов `^kill -0 $pid`. Если процесс не существует — блокировка считается устаревшей и перехватывается с предупреждением в stderr.
   - Windows: проверка через `^tasklist /FI $"PID eq ($pid)" /FO CSV`. Если PID не найден в списке активных задач — блокировка снимается.
4. Освобождение блокировки должно гарантированно происходить при завершении команды (включая аварийный выход через блок `try ... catch`).
5. Флаг `--no-lock` отключает блокировку (строго для изолированных песочниц тестов с `YGG_SANDBOX`).

#### Контракт реализации (`src/state.nu`)
```nushell
export def acquire-host-lock [ygg_home: string, command: string, --no-lock: bool = false]: nothing -> string {
    if $no_lock or (($env.YGG_NO_LOCK? | default "") == "1") {
        return ""
    }
    let lock_file = ($ygg_home | path join ".state" "ygg.lock")
    ensure-ygg-dirs $ygg_home

    if ($lock_file | path exists) {
        let lock_data = (try { open $lock_file } catch { {} })
        let lock_pid = ($lock_data.pid? | default 0)
        let is_alive = (check-process-alive $lock_pid)
        if $is_alive {
            error make { msg: $"Host is locked by another ygg instance \(PID: ($lock_pid), Command: '($lock_data.command? | default "unknown")', Started: ($lock_data.timestamp? | default "")\). Aborting." }
        } else {
            print -e $"[ygg] Warning: Removing stale lock from terminated process \(PID ($lock_pid)\)."
            try { rm -f $lock_file } catch { }
        }
    }

    let payload = {
        pid: $nu.pid,
        timestamp: (date now | format date "%Y-%m-%dT%H:%M:%SZ"),
        command: $command
    }
    $payload | to json | save -f $lock_file
    $lock_file
}

export def release-host-lock [lock_file: string]: nothing -> nothing {
    if ($lock_file != "") and ($lock_file | path exists) {
        try { rm -f $lock_file } catch { }
    }
}
```

#### Тестирование
* Тест в `tests/test_state.nu`: параллельный вызов `acquire-host-lock` с живым PID второго процесса возвращает структурированную ошибку; при мертвом PID старый lock-файл безопасно перезаписывается.

---

### RFC-027: Транзакционный журнал и восстановление после сбоев (`Intent WAL & Crash-Recovery`)

* **Компонент:** `src/state.nu`, `bin/ygg.nu`, `src/doctor.nu`
* **Приоритет:** Высокий (P1)
* **Статус:** `Предложено`

#### Проблема
Конвейер `apply-plan` последовательно выполняет 5 этапов:
1. `install-packages`
2. `apply-links`
3. `compile-environment`
4. `run-module-setup`
5. `run-link-hooks`

Если на этапе 3 или 4 возникает непредвиденная ошибка (сбой синтаксиса в скрипте `setup.nu`, исчерпание диска, аппаратный сбой), ссылки этапа 2 уже созданы на хосте, бэкапы перемещены, а `state.json` либо записан частично, либо содержит устаревшую информацию. Хост переходит в рассогласованное состояние.

#### Архитектурное требование
1. До начала мутаций в `$YGG_HOME/.state/journal.json` фиксируется план транзакции (Write-Ahead Log / Intent Log):
   - Хэш целевого плана;
   - Список запланированных операций со ссылками;
   - Список команд установки пакетов.
2. В процессе выполнения каждый этап атомарно меняет свой статус в журнале (`PENDING` → `IN_PROGRESS` → `COMMITTED`).
3. При успешном выполнении всех этапов журнал удаляется.
4. При запуске любой команды `ygg` наличие активного журнала сигнализирует о прерванной транзакции:
   - `ygg doctor` генерирует диагностику `check: journal_incomplete`, `severity: error`.
   - `ygg apply` перед началом работы сообщает о незавершенной операции и выполняет автовосстановление (`replay committed / rollback incomplete`).

#### Тестирование
* Юнит-тест в `tests/test_state.nu`: имитация падения `setup.nu` создает `journal.json`; повторный вызов `apply` или `doctor` обнаруживает прерванную транзакцию и завершает откат ссылок.

---

### RFC-028: Политика ротации бэкапов и сборка мусора стейта (`Backup Retention & State GC`)

* **Компонент:** `src/state.nu`, `bin/ygg.nu`
* **Приоритет:** Высокий (P1)
* **Статус:** `Предложено`

#### Проблема
1. Каждый запуск `backup-existing` создает подкаталог `$YGG_HOME/.state/backups/<timestamp>/`. При регулярном тестировании или частых обновлениях объем бэкапов растет неограниченно.
2. В `state.hashes` навсегда сохраняются SHA-256 хэши для ключей `onchange`, принадлежащих модулям, которые были удалены через `ygg remove` или исключены из `host.toml`.

#### Архитектурное требование
1. Конфигурация хранения бэкапов задается в `host.toml` (с безопасными значениями по умолчанию):
   ```toml
   [ygg.backups]
   max_count = 20        # хранить не более 20 последних бэкапов
   max_age_days = 30     # удалять бэкапы старше 30 дней
   ```
2. Функция `rotate-backups` в `src/state.nu` сканирует `.state/backups/`, сортирует папки по метке времени и удаляет избыточные каталоги.
3. Добавить команду `ygg clean [--backups] [--hashes] [--dry-run]` для принудительной ручной очистки.
4. **Сборщик мусора хэшей (State Hashes GC):** на этапе `apply` движок сравнивает ключи из `state.hashes` со списком ключей активных модулей (хуки `on_change` и вызовы `onchange` в манифестах) и удаляет осиротевшие записи.

#### Тестирование
* Тест в `tests/test_state.nu`: создание 25 фиктивных каталогов бэкапов; после вызова `rotate-backups` остается строго 20 самых свежих.
* Тест в `tests/test_state.nu`: запись устаревшего ключа в `state.hashes`; после `ygg apply` ключ удаляется из стейта.

---

### RFC-029: Расширение пакетных провайдеров: Homebrew (macOS) и дистрибутивы Linux (`brew`, `apt`, `dnf`)

* **Компонент:** `src/pkg.nu`
* **Приоритет:** Критический (P0)
* **Статус:** `Предложено`

#### Проблема
В `src/pkg.nu` реализована жесткая привязка к Arch Linux (`pacman`, `paru`) и Windows (`winget`, `scoop`). Для macOS пакетный менеджер Homebrew (`brew`) полностью отсутствует в коде (список менеджеров для macOS содержит только `mise`, `cargo`, `pnpm`, `uv`). На дистрибутивах семейств Debian/Ubuntu и Fedora/RHEL системные пакеты не устанавливаются, так как вызовы `apt` и `dnf` не поддерживаются.

#### Архитектурное требование
1. **Поддержка macOS Homebrew:**
   - Включить `brew` в список разрешенных менеджеров для `os == "macos"`.
   - Контракт запуска: `brew install ...$pkgs`.
   - Проверка наличия пакета: батчевая проверка через `brew list --formula $pkg` / `brew list --cask $pkg`.
2. **Поддержка дистрибутивов Linux:**
   - В `detect-host-os` парсить `/etc/os-release` с выявлением `distro` и семейств `ID_LIKE`:
     - `debian`, `ubuntu`, `pop`, `mint` → менеджер `apt` (команда: `sudo apt-get install -y --no-install-recommends ...$pkgs`).
     - `fedora`, `rhel`, `centos` → менеджер `dnf` (команда: `sudo dnf install -y ...$pkgs`).
     - `opensuse`, `sles` → менеджер `zypper` (команда: `sudo zypper install -y ...$pkgs`).
3. Поддержка `brew` на Linux (Linuxbrew), если бинарник `brew` присутствует на `PATH`.

#### Контракт реализации (`src/pkg.nu`)
```nushell
def pkg-argv-list [mgr: string, pkgs: list<string>]: nothing -> list<list<string>> {
    match $mgr {
        "winget" => ($pkgs | each { |p| [winget install --exact --disable-interactivity --accept-source-agreements --accept-package-agreements $p] }),
        "scoop" => ($pkgs | each { |p| [scoop install $p] }),
        "uv" => ($pkgs | each { |p| [uv tool install $p] }),
        "brew" => [[brew install ...$pkgs]],
        "apt" => [[sudo apt-get install -y --no-install-recommends ...$pkgs]],
        "dnf" => [[sudo dnf install -y ...$pkgs]],
        "pacman" => [[sudo pacman -S --needed --noconfirm ...$pkgs]],
        "paru" => [[paru -S --needed --noconfirm ...$pkgs]],
        "mise" => [[mise use --path "~/.config/mise/config.local.toml" ...$pkgs]],
        "cargo" => [[cargo install ...$pkgs]],
        "pnpm" => [[pnpm add -g ...$pkgs]],
        _ => [[$mgr install ...$pkgs]]
    }
}
```

#### Тестирование
* Тесты в `tests/test_pkg_git.nu` с мок-окружением:
  - `YGG_HOST_OS_OVERRIDE=macos` проверяет генерацию команд `brew install`.
  - `YGG_HOST_OS_OVERRIDE=ubuntu` проверяет генерацию команд `sudo apt-get install`.

---

### RFC-030: Декларативная очистка неиспользуемых пакетов (`Package Pruning for Isolated Providers`)

* **Компонент:** `src/pkg.nu`, `bin/ygg.nu`
* **Приоритет:** Средний (P2)
* **Статус:** `Предложено`

#### Проблема
При удалении пакета из манифеста модуля (`packages.toml`) или при исключении модуля из `host.toml` пакет остается установленным на хосте. Для системных менеджеров (`pacman`, `apt`) автоматическое удаление опасно из-за системных зависимостей, однако для пользовательских изолированных менеджеров (`mise`, `uv tool`, `pnpm -g`, `cargo install`) пакеты захламляют дисковое пространство.

#### Архитектурное требование
1. В `state.json` сохранять секцию `packages`:
   ```json
   {
     "packages": {
       "mise": ["node@20", "rust@latest"],
       "uv": ["ruff", "black"]
     }
   }
   ```
2. При вызове `ygg apply --prune-packages`:
   - Вычислять разность: `$stale = $state_pkgs - $current_plan_pkgs`.
   - Выполнять удаление для разрешенных безопасных менеджеров:
     - `mise` → `mise prune` / `mise uninstall $pkg`
     - `uv` → `uv tool uninstall $pkg`
     - `pnpm` → `pnpm remove -g $pkg`
     - `cargo` → `cargo uninstall $pkg`
3. Для системных менеджеров (`pacman`, `apt`, `dnf`, `winget`, `brew`) удаление пакетов по умолчанию запрещено и требует явного флага `--force-system-prune`.

#### Тестирование
* Тест в `tests/test_pkg_git.nu`: при удалении утилиты из секции `[packages.uv]` флаг `--prune-packages` генерирует команду `uv tool uninstall`.

---

### RFC-031: Граф зависимостей модулей и топологическая сортировка (`Module Dependencies: depends_on`)

* **Компонент:** `src/manifest.nu`, `bin/ygg.nu`
* **Приоритет:** Высокий (P1)
* **Статус:** `Предложено`

#### Проблема
Модули могут иметь неявные зависимости (например, модуль `desktop-hyprland` требует предварительного развертывания `core-shell` для наличия переменных окружения и базовых утилит). Сейчас порядок применения модулей определяется исключительно порядком их объявления в `host.toml`. Ошибка пользователя в порядке строк приводит к сбоям `setup.nu`.

#### Архитектурное требование
1. В `ygg.toml` модуля разрешить декларативное поле зависимостей:
   ```toml
   name = "desktop-hyprland"
   os = ["linux"]
   depends_on = ["core-shell", "fonts"]
   ```
2. Функция `resolve-effective-plan` строит ориентированный граф (DAG) модулей и выполняет топологическую сортировку алгоритмом Кана (Kahn's algorithm).
3. **Preflight-проверка:**
   - Если объявленный в `depends_on` модуль отсутствует в `host.toml` — ошибка `preflight-check` с прерыванием операции.
   - При обнаружении циклической зависимости (`A -> B -> A`) — фатальная ошибка с распечаткой цикла.
4. Отсортированный порядок модулей определяет порядок запуска шагов `setup.nu` и приоритет переопределения конфигураций.

#### Тестирование
* Юнит-тест в `tests/test_manifest.nu`: набор модулей с зависимостями `C -> B -> A` сортируется в порядок `[A, B, C]`.
* Тест на циклическую зависимость `A -> B -> A` выбрасывает исключение с указанием имен модулей.

---

### RFC-032: Фиксация версий модулей и воспроизводимый Lockfile (`Git Pinning & ygg.lock`)

* **Компонент:** `src/git.nu`, `src/manifest.nu`, `bin/ygg.nu`
* **Приоритет:** Высокий (P1)
* **Статус:** `Предложено`

#### Проблема
При использовании удаленных Git-модулей команда `ygg update` выполняет `git pull --rebase` на текущей ветке. Если автор модуля внес ломающие изменения в upstream, хост пользователя ломается. Отсутствует возможность зафиксировать конфигурацию на конкретный тег, коммит или запретить автоматическое обновление.

#### Архитектурное требование
1. Поддержка параметров фиксации версии в `host.toml`:
   ```toml
   [[modules]]
   name = "omni-dotfiles"
   ref = "v1.4.2"        # Git-тег или ветка
   rev = "8a3f91c"       # Фиксированный SHA коммита
   pin = true            # Игнорировать при ygg update
   ```
2. **Воспроизводимый Lockfile (`$YGG_HOME/ygg.lock`):**
   При каждом успешном `ygg apply` движок фиксирует точные хэши всех Git-модулей:
   ```toml
   # ygg.lock — generated automatically, do not edit
   version = 1

   [[module]]
   name = "omni-dotfiles"
   source = "https://github.com/user/omni-dotfiles.git"
   commit = "8a3f91cb14502d99a0f447781b0a824cb2a5e998"
   timestamp = "2026-11-08T18:30:00Z"
   ```
3. Флаг `ygg apply --locked` сверяет текущие ревизии локальных клонов с `ygg.lock` и завершается с ошибкой при несовпадении коммитов (критично для CI и продакшн-хостов).
4. Команда `ygg update` пропускает модули с `pin = true`.

#### Тестирование
* Тест в `tests/test_pkg_git.nu`: `ygg update` оставляет нетронутым модуль с флагом `pin = true`.
* Тест `ygg apply --locked` падает с ошибкой, если коммит клона не совпадает с `ygg.lock`.

---

### RFC-033: Логические составные скоупы (`Scope Boolean Expressions`)

* **Компонент:** `src/manifest.nu`
* **Приоритет:** Средний (P2)
* **Статус:** `Предложено`

#### Проблема
В текущей модели скоупы фильтруются строго по точному совпадению строкового идентификатора (`[scope.work]`). Невозможно задать конфигурацию для сложного условия, например: «применять на рабочей машине под Linux, но не на ноутбуке» (`work and linux and !laptop`).

#### Архитектурное требование
1. Поддержка составных булевых выражений в секциях манифеста:
   ```toml
   [scope."work and !laptop".links]
   "work-monitor.kdl" = "~/.config/niri/config.d/monitor.kdl"

   [scope."linux and (arch or cachyos)".packages]
   pacman = ["libva-nvidia-driver"]
   ```
2. Поддерживаемые операторы: `and`, `or`, `not` / `!`, круглые скобки `(...)`.
3. Парсер вычисляет предикат относительно активного множества скоупов хоста (`host_os.auto_scopes` + список скоупов из `host.toml`).

#### Тестирование
* Юнит-тест в `tests/test_manifest.nu`: выражение `"linux and !work"` вычисляется в `true` при активных скоупах `["linux", "pc"]` и в `false` при `["linux", "work"]`.

---

### RFC-034: Провайдеры внешних секретов (`External Secret Resolvers`)

* **Компонент:** `src/env.nu`, `src/sdk.nu`
* **Приоритет:** Средний (P2)
* **Статус:** `Предложено`

#### Проблема
Хранение всех конфиденциальных токенов в открытом файле `$YGG_HOME/secrets.toml` нарушает корпоративные и персональные стандарты безопасности. Требуется поддержка извлечения секретов из внешних хранилищ (менеджеры паролей, утилиты шифрования) без их долговременного сохранения на диске в открытом виде.

#### Архитектурное требование
1. В значениях переменных в `secrets.toml` разрешить URI-схемы внешних резолверов:
   - `op://<vault>/<item>/<field>` — вызов 1Password CLI (`op read ...`);
   - `bw://<item>/<field>` — вызов Bitwarden CLI (`bw get ...`);
   - `pass:<path>` — вызов Pass / Gopass (`pass show ...`);
   - `eval:<command>` — выполнение команды расшифровки в память (например, `eval:age -d -i ~/.age/key.txt secrets.age`).
2. Разрешение внешних секретов выполняется strictly in-memory на этапе компиляции переменных окружения (`compile-environment`).
3. Запрещено сохранять расшифрованные значения во временные промежуточные файлы на диске.
4. При сбое резолвера (например, хранилище заблокировано) `ygg apply` выдает понятную ошибку с указанием ключа и прерывает работу до записи поврежденного окружения.

#### Тестирование
* Юнит-тест в `tests/test_env.nu` с мок-резолвером `eval:echo secret123` подтверждает корректную подстановку значения в `clean_env`.

---

### RFC-035: Аудит безопасности прав доступа и ACL на Windows (`Windows ACL Perms in ygg doctor`)

* **Компонент:** `src/doctor.nu`
* **Приоритет:** Высокий (P1)
* **Статус:** `Предложено`

#### Проблема
В `src/doctor.nu:116` проверка прав доступа `check-perms` для Windows содержит безусловный возврат: `if ($nu.os-info.family == "windows") { return [] }`. В результате на платформе Windows файл `secrets.toml` и каталог `.state/env/` могут иметь открытые права чтения для группы `BUILTIN\Users` или `Everyone`, что создает критическую уязвимость утечки токенов.

#### Архитектурное требование
1. Реализовать проверку списков контроля доступа (ACL) на Windows через запуск `icacls.exe`:
   ```powershell
   icacls.exe "$target_file"
   ```
2. Файл признается небезопасным, если вывод содержит разрешения на чтение (`(R)`, `(F)`, `(M)`) для:
   - `BUILTIN\Users`
   - `Everyone`
   - `NT AUTHORITY\Authenticated Users` (если на машине несколько локальных учетных записей).
3. При обнаружении уязвимости `ygg doctor` возвращает:
   - `check: "perm"`
   - `severity: "error"`
   - `fix: "icacls <path> /inheritance:r /grant:r %USERNAME%:F"`
4. На Windows проверка распространяется на:
   - `$YGG_HOME/secrets.toml`
   - `$YGG_HOME/.state/env/env.ps1`
   - файлы, указанные модулями в `[doctor] private_files`.

#### Тестирование
* Юнит-тест в `tests/test_doctor.nu`: на Windows проверка корректно парсит вывод `icacls` и генерирует предупреждение при наличии прав у `Everyone`.

---

### RFC-036: Поддержка Fish Shell в компиляторе окружения (`env.fish` & `aliases.fish`)

* **Компонент:** `src/env.nu`
* **Приоритет:** Средний (P2)
* **Статус:** `Предложено`

#### Проблема
Движок `ygg` генерирует артефакты окружения для Nushell (`env.nu`, `aliases.nu`), Zsh (`env.zsh`, `aliases.zsh`) и PowerShell (`env.ps1`, `aliases.ps1`), но полностью игнорирует популярный шелл `fish`. Пользователи Fish вынуждены вручную писать скрипты конвертации.

#### Архитектурное требование
1. В функцию `compile-environment` добавить генерацию:
   - `$YGG_HOME/.state/env/env.fish`
   - `$YGG_HOME/.state/env/aliases.fish`
2. **Формат `env.fish`:**
   ```fish
   set -gx KEY 'VALUE'
   ```
   С экранированием обратных слэшей `\` и одинарных кавычек `'` по синтаксису Fish: `\'`.
3. **Формат `aliases.fish`:**
   ```fish
   alias KEY 'CMD'
   ```
4. Если переменная содержит список путей `PATH`, экспортировать ее через `fish_add_path` или разделение пробелами по синтаксису списков Fish.

#### Тестирование
* Юнит-тест в `tests/test_env.nu`: генерация `env.fish` и `aliases.fish` с проверкой корректности экранирования кавычек и спецсимволов.

---

### RFC-037: Декларативное управление демонами и сервисами (`[services]` Section)

* **Компонент:** `src/manifest.nu`, `bin/ygg.nu`, `src/sdk.nu`
* **Приоритет:** Средний (P2)
* **Статус:** `Предложено`

#### Проблема
После развертывания ссылок или обновления конфигурационных файлов часто требуется перезапустить пользовательские демоны (systemd user units на Linux, launchd agents на macOS, сервисы на Windows). Сейчас это пишется императивно в `setup.nu` через вызовы `systemctl --user restart` внутри блоков `onchange`, что засоряет код модулей.

#### Архитектурное требование
1. Ввести декларативную секцию `[services]` в `ygg.toml` / `links.toml`:
   ```toml
   [services.systemd.user]
   enable = ["syncthing.service"]
   reload_on_change = { "waybar.service" = ["config.jsonc", "style.css"] }
   restart_on_change = { "ollama.service" = ["config.json"] }

   [services.windows]
   restart_on_change = { "glazewm" = ["config.yaml"] }
   ```
2. Исполнение секции привязывается к этапу 5 `apply-plan`:
   - Если файлы, указанные в маске `*_on_change`, были модифицированы на этапе ссылок (операции `LINK`, `RELINK`, `BACKUP_REPLACE`), сервис автоматически перезапускается/перечитывает конфигурацию.
3. В режиме `--dry-run` выводить планируемые действия:
   `SERVICE waybar.service (reload systemd-user)`.
4. Ошибки перезапуска сервисов логируются как предупреждения и не ломают общий статус успешности применения конфигураций.

#### Тестирование
* Тест в `tests/test_sdk.nu`: при модификации отслеживаемого файла формируется команда перезапуска сервиса; при неизменных файлах перезапуск пропускается.

---

### RFC-038: Режим автоматического устранения дефектов (`ygg doctor --fix`)

* **Компонент:** `src/doctor.nu`, `bin/ygg.nu`
* **Приоритет:** Средний (P2)
* **Статус:** `Предложено`

#### Проблема
Команда `ygg doctor` строго доступна только для чтения (`read-only`). В поле `fix` выводятся рецепты исправления, которые пользователю приходится вручную копировать и запускать в терминале (исправление прав доступа, удаление висячих ссылок в каталогах конфигураций).

#### Архитектурное требование
1. Добавить флаг `--fix` в команду `ygg doctor`:
   ```bash
   ygg doctor --fix
   ```
2. Автоматическому исправлению подлежат только детерминированные безопасные дефекты:
   - `check: perm` → установка прав `0600` на Unix (`chmod 600 $path`) или вызов `icacls` на Windows.
   - `check: orphan_link` → удаление битых симлинков в каталогах пользователя через `remove-link-only`.
   - `check: state_orphan` → очистка записей в `state.links` / `state.copies` для модулей, отсутствующих в `host.toml`.
3. Опасные дефекты (`sync` конфликты, затенение каталогов) не исправляются автоматически и по-прежнему требуют явного флага `--force`.
4. Перед внесением изменений выводить интерактивный запрос подтверждения (или применять сразу при наличии `-y` / `--yes`).

#### Тестирование
* Юнит-тест в `tests/test_doctor.nu`: файл с правами `0644` после `ygg doctor --fix` получает права `0600`, а битый симлинк в `~/.config` удаляется.

---

### RFC-039: Автоматическая генерация дополнений командной строки (`ygg completions`)

* **Компонент:** `bin/ygg.nu`
* **Приоритет:** Низкий (P3)
* **Статус:** `Предложено`

#### Проблема
Сложные флаги (`--pkg-timeout`, `--refresh-packages`, `--skip-packages`) и аргументы (имена модулей, доступные скоупы) требуют ручного ввода, что снижает скорость работы с CLI.

#### Архитектурное требование
1. Добавить подкоманду: `ygg completions <shell>`, где `shell` ∈ `[nu, zsh, bash, fish, ps1]`.
2. **Nushell:** Генерация нативного блока `export extern ygg [...]` с автодополнением подкоманд, флагов и динамическим чтением имен модулей из `host.toml`.
3. **Zsh / Bash / Fish / PowerShell:** Генерация стандартных скриптов автодополнения для размещения в каталогах completion соответствующего шелла.

#### Тестирование
* Тест в `tests/test_cli_e2e.nu`: вызов `ygg completions nu` возвращает валидный синтаксис определений Nushell без ошибок парсера.

---

### RFC-040: Изоляция тестов ядра и непрерывная интеграция (`CI Matrix & Host E2E Guard`)

* **Компонент:** `.github/workflows/ci.yml`, `tests/test_phase2_modules.nu`, `tests/run.nu`
* **Приоритет:** Критический (P0)
* **Статус:** `Предложено`

#### Проблема
1. В репозитории полностью отсутствует конвейер CI для автоматического тестирования PR и коммитов на целевых ОС (Linux, Windows, macOS).
2. В файле `tests/test_phase2_modules.nu` захардкожены абсолютные локальные пути хоста разработчика (`/data/projects/...`, `/data/projects/worktree/ygg-phase2`), что нарушает инвариант чистоты ядра (`AGENTS.md`, п. 2.2) и приводит к сбоям тестов на любой сторонней машине.

#### Архитектурное требование
1. **Изоляция хостовых тестов:**
   - В `tests/test_phase2_modules.nu` добавить защитный барьер: тест выполняется только при наличии переменной окружения `YGG_RUN_HOST_E2E=1` и доступности указанных директорий. При их отсутствии — выводить информативное сообщение о пропуске (`SKIP`).
   - Исключить хостовые пути из стандартного прогона `tests/run.nu`.
2. **Создание GitHub Actions Workflow (`.github/workflows/ci.yml`):**
   - Матрица тестирования: `ubuntu-latest`, `windows-latest`, `macos-latest`.
   - Шаги:
     1. Checkout репозитория.
     2. Установка `just` и `nushell`.
     3. Запуск полного юнит-набора: `nu tests/run.nu`.
     4. Проверка чистоты ядра: валидация отсутствия личных путей и имен в `src/` и `bin/`.

#### Тестирование
* Прогон `nu tests/run.nu` на чистой машине без каталога `/data/projects` завершается с кодом 0 и 100% успехом всех тестов.

---

## 3. Этапы и дорожная карта реализации (Implementation Roadmap)

| Этап | Состав RFC | Фокус этапа |
| :--- | :--- | :--- |
| **Этап 3.1: Инфраструктура и P0 Безопасность** | RFC-040 (CI Matrix), RFC-026 (Host Lock), RFC-029 (Brew macOS & Linux distros) | Закрытие фундаментальных рисков гонок, запуск кроссплатформенного CI, поддержка macOS и стандартного Linux |
| **Этап 3.2: Надежность данных и транзакции** | RFC-027 (Crash WAL), RFC-028 (Backup Retention & State GC), RFC-035 (Windows ACL) | Защита от аварийных прерываний, автоматическая очистка диска, устранение уязвимостей прав доступа на Windows |
| **Этап 3.3: Модель оркестрации и воспроизводимость** | RFC-031 (Module `depends_on`), RFC-032 (Git Pinning & `ygg.lock`), RFC-033 (Scope Expressions) | Топологический порядок модулей, повторяемость сборок и гибкие условия конфигураций |
| **Этап 3.4: Экосистема, сервисы и DX** | RFC-034 (External Secrets), RFC-036 (Fish Shell), RFC-037 (`[services]`), RFC-038 (`doctor --fix`), RFC-030 (Prune pkgs), RFC-039 (Completions) | Интеграция с менеджерами паролей, декларативные сервисы, автоисправление и удобство CLI |
