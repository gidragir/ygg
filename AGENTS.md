# 🤖 AGENTS.md — Архитектурное руководство репозитория `ygg`

> **Назначение:** Независимый кроссплатформенный CLI-менеджер модулей конфигураций (`ygg` — от *Yggdrasil*).  
> **Рантайм:** Nushell (`nu >= 0.116`), `TOML`, `git`. Задачи разработки — `mise run <task>` ([mise.toml](mise.toml)).  
> **Целевые ОС:** Linux (CachyOS / Arch и др.), Windows 11 / Server (Non-Admin, без Developer Mode), macOS.

---

## 📌 1. Документация, навыки, команды

* **Спецификации и планы:** индекс — [docs/README.md](docs/README.md). Базовая архитектура — [docs/specs/2026-11-07-modular-omni-architecture-design.md](docs/specs/2026-11-07-modular-omni-architecture-design.md).
* **Навыки разработки** (`.agents/skills/`):
  - `nushell-ygg-dev` — любая правка `.nu` в `src/`, `bin/`, `tests/`;
  - `ygg-module-verification` — проверка модуля в одноразовой песочнице;
  - `ygg-report` — заметки и ошибки → GitHub Issues.
* **Тесты:** `mise run test` (весь набор), `nu tests/run.nu --filter <имя>` (точечно).
* **Журнал изменений:** [CHANGELOG.md](CHANGELOG.md) — генерируется `mise run changelog` (git-cliff, [cliff.toml](cliff.toml)), руками не правится.

---

## 🐞 1a. Баги, бэклог и история решений

* **Бэклог — GitHub Issues** (`gidragir/ygg`, публичный). Новые наблюдения, ошибки и идеи заводятся через навык `ygg-report` (атомарные issues, метки `type:*` / `area:*` / `os:*`, нормализация приватных путей, создание только после подтверждения пользователя). Офлайн — `docs/bugs/inbox.md` (в `.gitignore`).
* **Выбор задачи:** доска `ygg project` (#5) — `gh project item-list 5 --owner gidragir --format json --limit 100`, сначала меньший `Priority`, затем меньший `Size`.
* **Перед фиксом или спекой** по issue `#N` или области `area:X` агент читает историю: `gh issue view N --comments`, `gh issue list --state all --label area:X`, `git log --grep "#N"`, `git log --oneline -- src/<file>.nu`, `rg -n "regression: #" tests`. Спека по issue указывает его в шапке (`Issues: #N`).
* **Обязательный чеклист контрактов (выполнить ДО написания кода, спеки или плана):**
  1. **Сигнатура и рантайм-тип:** прочитай объявление целевой и смежных функций в `src/*.nu` (`: nothing -> record<...>`). При добавлении/изменении поля в возвращаемом `record` обнови аннотацию типа функции (проверяется в рантайме!).
  2. **Все потребители через `rg`:** выполни `rg -n "<func_or_field>" src/ bin/ tests/` и перечисли все места распаковки возвращаемого `record` (включая `format-apply-summary`, `run-link-hooks`, `run-service-actions`).
  3. **Кэш `state.hashes`:** если добавляется условный пропуск шага (`skip`), проверь, не запишется ли хэш в `state.hashes` до фактического выполнения действия.
  4. **Мокируемый детект и `--dry-run`:** для каждой новой проверки/предупреждения зафиксируй один конкретный механизм мока (`YGG_MOCK_*` или `write-mock-cli`) и убедись, что в `--dry-run` / read-only командах не создаются файлы и не пишется прогресс в `stderr` (§2.1).
* **Актуальность индекса и сверка со спеками:** при создании новой спеки (`docs/specs/…`) или плана (`docs/superpowers/plans/…`) строка в [docs/README.md](docs/README.md) обновляется в том же цикле. Перед любым архитектурным ревью, аудитом или предложением рефакторинга агент обязан сверить существующие решения с [docs/README.md](docs/README.md) и профильными спеками, чтобы не принимать осознанные ограничения (например, `mv` в `probe-locked-targets` или `with-env` IPC) за баги.
* **Тестирование контрактов «продюсер → потребитель»:** при тестировании функций-потребителей (`run-service-actions`, `run-link-hooks`, `format-apply-summary`) запрещено подавать только вручную сконструированные синтетические `record` с угаданными именами полей/операций — хотя бы один тест обязан прогонять реальный выход функции-продюсера (`compute-link-ops`, `plan-copy-sync`) в потребитель.
* **DoD фикса:** регрессионный тест с комментарием `# regression: #N` и коммит с футером `Fixes #N` — только в футере, иначе git-cliff не подставит ссылку; несколько issue — по строке на каждый, упоминание без закрытия — `Refs #N`. `CHANGELOG.md` руками не правится: перед релизом его собирает `mise run changelog`.

### 🔀 Регламент работы с PR и тестами

* **Проверка CI после создания PR:** сразу после `gh pr create` запускать `gh pr checks --watch` (или проверять статус CI), чтобы ловить платформенные отличия (`windows-latest` ACL, `ENOTDIR` на Linux/macOS) в том же цикле.
* **Точечный прогон при правках `apply-plan`:** при изменениях в `apply-plan` / `apply` прогонять не только `--filter test_cli`, но и `--filter test_apply` (а перед финализацией — полный `mise run test`). E2E-тесты разнесены по доменам в `tests/test_e2e_*.nu`.

### 🌿 Git-процесс: ветки, PR и завершение задачи

* **Имя ветки — [Conventional Branch 1.0](https://conventional-branch.github.io/):** `<type>/<description>`, только `a-z`, `0-9`, `-` (без `_`, заглавных, пробелов, двойных и концевых дефисов; точки — только в версии `release/`).
  * `type`: `feat` (или `feature`), `fix` (или `bugfix`), `hotfix`, `release`, `chore`. Документация, CI, тесты и рефакторинг идут в `chore/`.
  * Номер issue — с префиксом `issue-`: `fix/issue-8-apply-summary`, `feat/issue-15-init-scaffold`. Без issue — только описание: `chore/split-e2e-tests`. Релиз — `release/v0.4.0`.
  * Каталог worktree повторяет ветку с `-` вместо `/`: `.worktrees/fix-issue-8-apply-summary`.
* **Одна ветка = один issue = один PR.** Коммит закрывает issue футером `Fixes #N`, тело PR — `Closes #N`. Issue закрывается только merge'ем PR: открытый PR — открытый issue, это норма.
* **Спеки и планы живут в `main`, без ветки, worktree и PR.** Документ пишется в основной рабочей копии на `main` (`docs/specs/…`, `docs/superpowers/plans/…`), пока обсуждается, лежит неотслеженным, а по просьбе пользователя коммитится и пушится прямо в `main`. Ветка и worktree создаются только для реализации — от `origin/main`, где спека и план уже лежат. Это правило важнее навыков, которые предлагают отдельную ветку или PR для дизайна.
* **Старт задачи:** `git fetch origin`, затем `git worktree add .worktrees/<dir> -b <branch> origin/main`. Основная рабочая копия (корень репозитория) остаётся на `main`.
* **Завершение задачи — обязательный последний шаг перед итоговым сообщением**, после `git push`, `gh pr create` и `gh pr checks --watch`: в основной рабочей копии выполнить `git switch main` и `git pull --ff-only origin main`. Задача не сдана, пока основная копия не стоит на обновлённом `main`. В итоговом сообщении указать ветку, PR и то, что `main` обновлён.
* **После merge PR** (на GitHub включено автоудаление веток, `deleteBranchOnMerge`): `git worktree remove .worktrees/<dir>`, `git branch -d <branch>`, `git fetch --prune`, `git pull --ff-only`. В начале каждой задачи проверить `git worktree list` и `git branch --merged main` и убрать хвосты уже влитых веток.

---

## 🔒 2. Жёсткие инварианты безопасности и архитектуры

1. **Абсолютная изоляция хоста при разработке и тестах (ZERO HOST MUTATION):**
   * Ни один тест и ни один отладочный запуск `ygg` в рамках разработки не имеют права читать или модифицировать реальные `~/.ygg`, `~/.config` или `$HOME` рабочей станции.
   * Все тесты обязаны выполняться строго внутри временных каталогов (`with-temp-ygg`), все пути в тестах производны от его аргумента `home`; литеральных `/tmp/...` в `tests/` нет. `with-temp-ygg` задаёт `YGG_HOME`, `YGG_SANDBOX` и `YGG_MOCK_PKG_LOG = ""`; тест, которому нужен мок, задаёт путь лога явно внутри своего временного каталога.
   * `tests/run.nu` запускает каждый тест с очищенным окружением: все унаследованные `YGG_*` скрыты, кроме `YGG_RUN_HOST_E2E`.
   * **Параллельный прогон (`par-each --threads 4`):** тест на отсутствие временных файлов запускает код в дочернем `^nu` со своими `TMPDIR`/`TEMP`/`TMP` (навык `nushell-ygg-dev`, `references/testing.md`). Падение теста нельзя списывать на гонку, не воспроизведя его через `--filter <name>`.
   * Команды `ygg doctor`, `ygg diff` и `ygg status` строго read-only: им запрещено вызывать `ensure-ygg-dirs`, `mkdir` или `save`.
   * Статусный/прогресс-вывод CLI направляется строго в `stderr`, отключает управляющие последовательности при отсутствии TTY (`not (is-terminal --stderr)`), `TERM == "dumb"` или `NO_COLOR`, и полностью подавляется во **всех** `--dry-run`/`--read-only` сценариях (включая `add --dry-run`, `upgrade --dry-run`, `apply --dry-run`), `ygg diff`, `ygg status`, `ygg doctor` (запрещены `progress-step`, `--label`, `--progress` и создание `ygg-proc-*.log`).

2. **Чистота ядра `ygg` от личных репозиториев:**
   * Движок `ygg` не должен содержать захардкоженных имён пользовательских модулей (`omni-dotfiles`, `ai-dotfiles`, `hermes` и т.п.) или сторонних утилит (`chezmoi`, `sops`). Вся логика строится строго вокруг контракта `host.toml` и модульного `ygg.toml`.

3. **Безопасность данных и транзакционность (Zero-Data-Loss & Preflight):**
   * **Барьер `preflight-check`:** запускается до модификации файловой системы и пакетов. Проверяет наличие всех файлов-источников, соответствие `mode = "dir"`, отсутствие конфликтов вложенности и затенения непустых каталогов хоста.
   * **Удаление ссылок:** `remove-link-only` проверяет, что цель является ссылкой/репарспоинтом (`($p | path type) == "symlink"` или `is-link-or-junction`), удаляя только сам линк без рекурсивного удаления каталогов назначения.
   * **Бэкапы:** физические файлы и каталоги при замене (`dir_copy`, `copy`) перемещаются в `$YGG_HOME/.state/backups/<timestamp>/` через `backup-with-notice`.
   * **Порядок операций:** устаревшие ссылки и копии удаляются строго первыми (`PRUNE`-first), исключая коллизии при переходе с каталога на глоб.
   * **Атомарная замена:** смена симлинка на Unix выполняется атомарно (`swap-symlink-atomic` через `mv -Tf`/`-hf`), предотвращая появление битых окон доступности.
   * **Блокировка и журнал:** мутирующие команды берут атомарную advisory-блокировку `$YGG_HOME/.state/host.lock` (`--no-lock` отключает её для песочниц); `apply` ведёт журнал v2 (статус сбоя, восстановление roll-forward повторным выполнением), `doctor --fix` работает под той же блокировкой.
   * **Секреты:** значения внешних секретов не материализуются на диск по умолчанию (ленивое разрешение); схемы секретов читаются только из `secrets.toml` и проверяются до мутаций.

4. **Кроссплатформенность и Windows Non-Admin (Обязательный архитектурный гейт):**
   * **Запрет Unix-only решений в общем контуре:** любые новые фичи ядра `ygg`, модульные паттерны и рекомендуемые внешние CLI-утилиты обязаны работать на всех целевых ОС (**Linux, Windows 11/Server Non-Admin, macOS**). Предлагать или зашивать Unix-only инструменты (`systemd`, `dockcheck`, `podman-auto-update`, `bash`-скрипты) как универсальное решение запрещено — платформозависимые механизмы допустимы строго внутри `[scope.linux]` / `[scope.unix]` при наличии явного эквивалента для `[scope.windows]` либо через единый кроссплатформенный слой (Nushell, кроссплатформенный CLI).
   * Для каталогов на Windows каскадный fallback: `mklink /J` (Junction) -> `mklink /D` (Symlink) -> `cp -r` (`dir_copy`).
   * Для одиночных файлов и секции `[save]` — 3-way hash sync копирование.
   * Для скриптов в `bin/` — автогенерация парных `.cmd`-шиммов с изолирующим `setlocal`.
   * Пути Win32 нормализуются через `to-win32-path` (`path expand -n`), предотвращая разыменование симлинков.

5. **Пакетная изоляция и безопасность процессов:**
   * Предварительная проверка пакетов Arch/CachyOS через `pacman -T` и проверка доступности sudo без пароля в неинтерактивном режиме.
   * Завершение дерева процессов по таймауту (`kill-job-tree` считывает PID до `job kill`).
   * Кэширование хэшей наборов пакетов в `state.hashes` (пропуск при повторном запуске без изменений).
   * **`run-with-timeout`** сохраняет раздельные `stdout`/`stderr`, возвращает 127 при отсутствии бинарника и 124 при таймауте, гарантированно вызывает `kill-job-tree` и чистит temp; ненулевой код проверяет вызывающий код (`WINGET_OK_CODES`). Полный контракт — навык `nushell-ygg-dev`, `references/processes.md` §7.
   * **Защита интерактивного `sudo`:** `sudo-available` при TTY `stdin` возвращает `true` даже без кэшированного пароля; перерисовка `\r`-прогресса не должна запускаться поверх команд с возможным запросом пароля (`sudo`, `paru`) без предварительной валидации `sudo -v` или отключения тикера.

6. **Контейнеры модулей (RFC-059):**
   * **Декларативность и Compose v2+:** модули объявляют стеки стандартным `compose.yml` (автообнаружение в корне) или `[containers].files` / `[scope.<name>.containers].files`; поддерживается только провайдер Compose v2+ (`docker compose` / `podman compose` с `docker-compose` v2+).
   * **Защита данных:** ни одна команда ядра не передаёт `-v`, `--volumes` или `--rmi`. Все команды рантайма строятся строго как `list<string>` (argv), пути нормализуются через `path expand -n`.
   * **Моки в тестах и песочнице:** без `YGG_MOCK_PKG_LOG` в песочнице (`YGG_SANDBOX`) команды контейнеров возвращают `skipped_sandbox`. Для тестов: `YGG_MOCK_CONTAINER_FAIL`, `YGG_MOCK_CONTAINER_STATUS` (`no_runtime` | `daemon_down`), `YGG_MOCK_CONTAINER_RUNNING`, и `YGG_NONINTERACTIVE=1` при `ygg add` без `--containers`/`--no-containers`.

7. **Навигация по коду и дрейф через `context-init`:** если доступен MCP `context-init` или CLI `context-init`, навигация и проверка дрейфа перед сдачей идут через него (раздел «Архитектурная карта» ниже), а не через рекурсивное чтение файлов ядра. Без них — точечный поиск (`rg`, Grep/Glob) и чтение только нужных файлов; в итоговом сообщении указать, что `context_check` не выполнялся.

### 🏛 Зафиксированные архитектурные решения (ADR)

Эти решения приняты осознанно (в т.ч. через инциденты и RFC); предлагать или внедрять их отмену без отдельного RFC запрещено:

* **ADR-01 — Roll-forward транзакционность `state.json`, `state.json.bak` и `journal.json` (RFC-043/053):**
  `ygg apply` — идемпотентный roll-forward конвейер. Пошаговый `save-state` после каждой фазы (`packages`, `links`, `hooks`, `services`, `containers`) обязателен, чтобы при сбое на позднем шаге уже созданные ссылки и файлы сохранили учёт владения (откладывать сохранение `state.json` до конца `apply` запрещено). При этом `state.json.bak` снимается **один раз** перед началом мутаций в `begin-journal-transaction`; `save-state` при неизменённом сериализованном состоянии является no-op; список шагов `APPLY_STEPS` задаётся единой константой для `journal.json` и оркестратора `apply-plan`; цели из `$link_res.failed` отфильтровываются до запуска `run-link-hooks` и `run-service-actions`.
* **ADR-02 — Проверка блокировок `BACKUP_REPLACE` на Windows и `with-env` IPC для `setup.nu` (RFC-061/063):**
  Детект занятых целей `BACKUP_REPLACE` в `probe-locked-targets` выполняется до `host.toml`-регистрации и до `begin-journal-transaction` через атомарный `MoveFile` (`mv`) с детерминированным именем `<dest>.ygg-probe` и авто-восстановлением осиротевшей пробы при старте. Заменять `mv` на `[IO.File]::Open` запрещено: .NET/Win32 `Open` бросает `UnauthorizedAccessException` на каталогах и `ReadOnly`-файлах и не обнаруживает открытые дескрипторы/CWD в глубине дерева каталога. Передача `YGG_BACKUP_ID`, `YGG_DRY_RUN`, `YGG_FORCE`, `YGG_SANDBOX` через `with-env` — штатный межпроцессный IPC-контракт с дочерним `^nu setup.nu`.
* **ADR-03 — Безопасная запись секретов (`atomic-save --private`) и 3-way инвариант `ygg save`:**
  Любые приватные/секретные файлы (`env.*`, `export-secrets`, `merge-json --mode 0600`) создаются строго через: пустой `.tmp` рядом с целью → ограничение прав (`0600` и Windows `restrict-file-access` с fallback на `whoami`) → запись содержимого → атомарный `mv -f`. Вызов `icacls /inheritance:r` при пустом пользователе (без `/grant:r`) запрещён, так как создаёт пустой DACL и блокирует владельца. Команда `ygg save` без `--force` переносит файл с хоста в модуль только при `host_hash != last_hash` и `src_hash == last_hash` (3-way конфликт требует `--force`, а обновление только модуля никогда не затирается старым файлом с хоста).
* **ADR-04 — Бюджет внешних процессов на Windows (`One-Subprocess-Per-Phase`):**
  В горячем контуре (`apply`, `status`, `doctor`) запрещено порождать `powershell`/`pwsh`/`icacls` внутри поштучных циклов по файлам и ссылкам: кэшировать `$DOCUMENTS` один раз на процесс, проверять встроенный `path expand` до вызова `link-literal-target`, батчить `Get-Acl` одним вызовом PowerShell на фазу, не вызывать `restrict-file-access` при обновлениях `record-journal-step`, а планирование (`resolve-link-targets` → `compute-link-ops` → `preflight-check`) и SHA-256 хэширование в `apply` выполнять за один проход.
* **ADR-05 — Тестовый паритет Windows и `Post-Apply Invariant Gate`:**
  Запрещено отключать тесты на Windows (`if $nu.os-info.family == "windows" { return }`) из-за POSIX-заглушек: использовать кроссплатформенный генератор моков (`.cmd` + POSIX script) и проверять ACL на Windows через `read-windows-acl`, а скрипты PowerShell (`env.ps1`, `aliases.ps1`, `completions ps1`) — в реальном `^pwsh`. После успешного `ygg apply` в E2E-тестах обязан выполняться инвариант чистого состояния: `ygg diff` возвращает `0` изменений, `ygg doctor` возвращает `0` ошибок, `.state/host.lock` и `.state/journal.json` отсутствуют.

---

## 🗂 3. Глоссарий проекта

* **`Ygg Home` (`~/.ygg/` или `$env.YGG_HOME`)** — единая папка пользователя на хосте (`host.toml`, `secrets.toml`, `modules/`, `.state/`).
* **`Module` (`ygg.toml`)** — независимая папка или Git-репозиторий с пакетами, ссылками и опциональным `setup.nu`.
* **`Scope` (`[scope.<name>]`)** — фильтр железа/роли (`pc`, `asus`, `work`) или автоматически активируемый фильтр ОС (`linux`, `windows`, `unix`, `cachyos`).
* **`Host` (`host.toml`)** — список подключённых модулей компьютера, их активных `scopes`, исключений `exclude` и параметров `config`.

## 🗺 Архитектурная карта и навигация (OpenViking L0-L2)

Проект `ygg` описан трехуровневой базой знаний context-init (L0-L2), которая лежит в `.context-init/knowledge/` и коммитится вместе с кодом. Людям можно читать её напрямую; агентам — предпочитать MCP/`pack` ниже: это компактнее и учитывает бюджет токенов. После структурных изменений запустите `context-init update` и закоммитьте изменения базы в том же PR.

### ⚡ MCP-First Protocol (context-init)

Во все вызовы передавайте `"path": "<repo_root>"`.

1. `context_get_subsystems` — карта подсистем проекта (L0).
2. `context_get_subsystem(subsystem_id)` — компактная L1-карточка подсистемы.
3. `context_pack(subsystem_id, mode="toc")` — символы со строками; `context_pack(subsystem_id, compress=true)` — AST-сжатый код (`style="compact"` по умолчанию).
4. `context_pack(subsystem_id, files=["<file>"], compress=false)` — точный код нужных файлов.
5. `context_check` — проверка архитектурного дрейфа перед сдачей задачи.

Ответ с `truncated: true` — повторите вызов с `cursor` из футера или сузьте `files`.

Без доступа к MCP (субагенты, скрипты): `rtk context-init pack <subsystem_id> --compress --max-lines 200` (`--toc`, `--files <f> --no-compress`, `--cursor "cur_..."`) и `rtk context-init check --compact`.

### 📦 Доступные подсистемы:
- `bin` (Bin) — Модуль и компоненты директории `bin` (1 файлов)
- `docs` (Docs) — Модуль и компоненты директории `docs` (15 файлов)
- `scripts` (Scripts) — Модуль и компоненты директории `scripts` (3 файлов)
- `src_container` (Container) — Модуль и компоненты директории `src/container` (1 файлов)
- `src_doctor` (Doctor) — Модуль и компоненты директории `src/doctor` (1 файлов)
- `src_engine` (Engine) — Модуль и компоненты директории `src/engine` (1 файлов)
- `src_env` (Env) — Модуль и компоненты директории `src/env` (1 файлов)
- `src_git` (Git) — Модуль и компоненты директории `src/git` (1 файлов)
- `src_link` (Link) — Модуль и компоненты директории `src/link` (1 файлов)
- `src_manifest` (Manifest) — Модуль и компоненты директории `src/manifest` (1 файлов)
- `src_mod` (Mod) — Модуль и компоненты директории `src/mod` (1 файлов)
- `src_pkg` (Pkg) — Модуль и компоненты директории `src/pkg` (1 файлов)
- `src_progress` (Progress) — Модуль и компоненты директории `src/progress` (1 файлов)
- `src_sdk` (Sdk) — Модуль и компоненты директории `src/sdk` (1 файлов)
- `src_state` (State) — Модуль и компоненты директории `src/state` (1 файлов)
- `tests` (Tests) — Тесты проекта
