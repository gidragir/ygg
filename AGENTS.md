# 🤖 AGENTS.md — Архитектурное руководство репозитория `ygg`

> **Назначение:** Независимый кроссплатформенный CLI-менеджер модулей конфигураций (`ygg` — от *Yggdrasil*).  
> **Рантайм:** Nushell (`nu >= 0.116`), `TOML`, `git`, `just` (`set shell := ["nu", "-c"]`).  
> **Целевые ОС:** Linux (CachyOS / Arch и др.), Windows 11 / Server (Non-Admin, без Developer Mode), macOS.

---

## 📌 1. Документация и спецификация

* **Базовая архитектурная спецификация:** [docs/specs/2026-11-07-modular-omni-architecture-design.md](docs/specs/2026-11-07-modular-omni-architecture-design.md)
* **Спецификация улучшений и стабилизации ядра (RFC-001..025):** [docs/specs/2026-11-08-ygg-engine-improvements-and-hardening.md](docs/specs/2026-11-08-ygg-engine-improvements-and-hardening.md)
* **План реализации ядра Фазы 1:** [docs/plans/2026-11-07-ygg-phase1-engine.md](docs/plans/2026-11-07-ygg-phase1-engine.md)
* **План реализации улучшений Фазы 2:** [docs/plans/2026-11-08-ygg-engine-improvements-and-hardening.md](docs/plans/2026-11-08-ygg-engine-improvements-and-hardening.md)
* **Спецификация Фазы 3 (RFC-026..040):** [docs/specs/2026-11-08-ygg-phase3-resilience-and-ecosystem.md](docs/specs/2026-11-08-ygg-phase3-resilience-and-ecosystem.md)
* **План реализации Фазы 3:** [docs/plans/2026-11-08-ygg-phase3-implementation-plan.md](docs/plans/2026-11-08-ygg-phase3-implementation-plan.md)
* **Спецификация Фазы 4 — корректность и безопасность (RFC-041..058):** [docs/specs/2026-11-10-ygg-phase4-correctness-and-security-hardening.md](docs/specs/2026-11-10-ygg-phase4-correctness-and-security-hardening.md)
* **План реализации Фазы 4:** [docs/plans/2026-11-10-ygg-phase4-implementation-plan.md](docs/plans/2026-11-10-ygg-phase4-implementation-plan.md)
* **Навыки разработки:**
  - Разработка на Nushell: [.agents/skills/nushell-ygg-dev/SKILL.md](.agents/skills/nushell-ygg-dev/SKILL.md)
  - Тестирование и верификация модулей dotfiles: [.agents/skills/ygg-module-verification/SKILL.md](.agents/skills/ygg-module-verification/SKILL.md)

---

## 🔒 2. Жёсткие инварианты безопасности и архитектуры

1. **Абсолютная изоляция хоста при разработке и тестах (ZERO HOST MUTATION):**
   * Ни один тест и ни один отладочный запуск `ygg` в рамках разработки не имеют права читать или модифицировать реальные `~/.ygg`, `~/.config` или `$HOME` рабочей станции.
   * Все тесты обязаны выполняться строго внутри временных каталогов (`with-temp-ygg`), все пути в тестах производны от его аргумента `home`; литеральных `/tmp/...` в `tests/` нет. `with-temp-ygg` задаёт `YGG_HOME`, `YGG_SANDBOX` и `YGG_MOCK_PKG_LOG = ""`; тест, которому нужен мок, задаёт путь лога явно внутри своего временного каталога.
   * `tests/run.nu` запускает каждый тест с очищенным окружением: все унаследованные `YGG_*` скрыты, кроме `YGG_RUN_HOST_E2E`.
   * Команды `ygg doctor`, `ygg diff` и `ygg status` строго read-only: им запрещено вызывать `ensure-ygg-dirs`, `mkdir` или `save`.

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

4. **Кроссплатформенность и Windows Non-Admin:**
   * Для каталогов на Windows каскадный fallback: `mklink /J` (Junction) -> `mklink /D` (Symlink) -> `cp -r` (`dir_copy`).
   * Для одиночных файлов и секции `[save]` — 3-way hash sync копирование.
   * Для скриптов в `bin/` — автогенерация парных `.cmd`-шиммов с изолирующим `setlocal`.
   * Пути Win32 нормализуются через `to-win32-path` (`path expand -n`), предотвращая разыменование симлинков.

5. **Пакетная изоляция и безопасность процессов:**
   * Предварительная проверка пакетов Arch/CachyOS через `pacman -T` и проверка доступности sudo без пароля в неинтерактивном режиме.
   * Завершение дерева процессов по таймауту (`kill-job-tree` считывает PID до `job kill`).
   * Кэширование хэшей наборов пакетов в `state.hashes` (пропуск при повторном запуске без изменений).

6. **Навигация по коду и дрейф через `context-init`:**
   * Вся навигация по подсистемам репозитория выполняется через MCP `context-init` (`context_get_subsystems`, `context_pack`). Прямое рекурсивное вычитывание файлов ядра запрещено.
   * Перед сдачей задач обязателен аудит дрейфа через `context_check`.

---

## 🗂 3. Глоссарий проекта

* **`Ygg Home` (`~/.ygg/` или `$env.YGG_HOME`)** — единая папка пользователя на хосте (`host.toml`, `secrets.toml`, `modules/`, `.state/`).
* **`Module` (`ygg.toml`)** — независимая папка или Git-репозиторий с пакетами, ссылками и опциональным `setup.nu`.
* **`Scope` (`[scope.<name>]`)** — фильтр железа/роли (`pc`, `asus`, `work`) или автоматически активируемый фильтр ОС (`linux`, `windows`, `unix`, `cachyos`).
* **`Host` (`host.toml`)** — список подключённых модулей компьютера, их активных `scopes`, исключений `exclude` и параметров `config`.

## 🗺 Архитектурная карта и навигация (OpenViking L0-L2)

Проект `ygg` описан трехуровневой базой знаний context-init (L0-L2), которая лежит в `.context-init/knowledge/` и коммитится вместе с кодом. Людям можно читать её напрямую; агентам — предпочитать MCP/`pack` ниже: это компактнее и учитывает бюджет токенов. После структурных изменений запустите `context-init update` и закоммитьте изменения базы в том же PR.

### ⚡ MCP-First Protocol (context-init)

1. `context_get_subsystems` — карта подсистем проекта (L0).
2. `context_get_subsystem(subsystem_id)` — компактная L1-карточка подсистемы.
3. `context_pack(subsystem_id, compress=true)` — AST-сжатый код подсистемы.
4. `context_check` — проверка архитектурного дрейфа перед сдачей задачи.

Без доступа к MCP (субагенты, скрипты): `rtk context-init pack <subsystem_id> --compress` и `rtk context-init check --compact`.

### 📦 Доступные подсистемы:
- `bin` (Bin) — Модуль и компоненты директории `bin` (1 файлов)
- `docs` (Docs) — Модуль и компоненты директории `docs` (11 файлов)
- `scripts` (Scripts) — Модуль и компоненты директории `scripts` (2 файлов)
- `src_doctor` (Doctor) — Модуль и компоненты директории `src/doctor` (1 файлов)
- `src_env` (Env) — Модуль и компоненты директории `src/env` (1 файлов)
- `src_git` (Git) — Модуль и компоненты директории `src/git` (1 файлов)
- `src_link` (Link) — Модуль и компоненты директории `src/link` (1 файлов)
- `src_manifest` (Manifest) — Модуль и компоненты директории `src/manifest` (1 файлов)
- `src_mod` (Mod) — Модуль и компоненты директории `src/mod` (1 файлов)
- `src_pkg` (Pkg) — Модуль и компоненты директории `src/pkg` (1 файлов)
- `src_sdk` (Sdk) — Модуль и компоненты директории `src/sdk` (1 файлов)
- `src_state` (State) — Модуль и компоненты директории `src/state` (1 файлов)
- `tests` (Tests) — Тесты проекта
