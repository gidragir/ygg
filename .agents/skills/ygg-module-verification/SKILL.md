---
name: ygg-module-verification
description: Use when verifying ygg module integrity, testing dotfiles migration, or diagnosing link/package conflicts across Linux and Windows in an isolated sandbox.
---

# Верификация и тестирование модулей ygg

Используй этот навык для тестирования модулей конфигураций (`omni-dotfiles`, `dotfiles`, `ai-dotfiles`, `win-dotfiles` и др.) без риска для реальной хост-системы.

## 1. Диагностика без мутаций (Read-Only)

Всегда начинай диагностику с пассивных проверок:

```bash
# Проверка целостности ссылок, прав на secrets.toml, отсутствия орфанов и коллизий
rtk nu bin/ygg.nu doctor

# Машиночитаемый JSON-статус модулей, веток, git dirty и точности ссылок
rtk nu bin/ygg.nu status --json
```

## 2. Предварительный аудит плана (Dry-Run)

Расчёт графа операций без выполнения изменений и без создания служебных директорий:

```bash
# Просмотр запланированных операций (LINK, PRUNE, HOOK, PKG, SETUP)
rtk nu bin/ygg.nu diff

# Фильтрация по конкретному пакетному менеджеру (например, mise)
rtk nu bin/ygg.nu diff --pkg mise
```

## 3. Изолированное применение в песочнице (Sandbox Execution)

Для физической проверки создания ссылок и скриптов `setup.nu` без модификации `$HOME`:

```nushell
let sb = "/tmp/ygg-test-sandbox"
mkdir $sb
with-env {
    YGG_SANDBOX: $sb,
    YGG_MOCK_PKG_LOG: ($sb | path join "pkg.log")
} {
    rtk nu bin/ygg.nu apply --sandbox $sb
}

# Проверка отсутствия битых ссылок
rtk fd -H -I --type l . $sb | rtk nu -c "$in | lines | where { |p| not ($p | path exists) }"
```

## 4. Сквозной E2E-тест мигрированных модулей

Для запуска интеграционного набора проверок всех модулей хоста в изолированной песочнице:

```bash
rtk nu tests/test_phase2_modules.nu
```

## 5. Проверка модулей с контейнерами (RFC-059)

Модули объявляют контейнеры обычным `compose.yml` в корне или `[containers].files` / `[scope.<name>.containers].files` в `ygg.toml` (поддерживается только Compose v2+).

* **Неинтерактивный `add` в песочнице/тестах:** передавай `YGG_NONINTERACTIVE=1` (иначе `ygg add` повиснет на вопросе) либо явный флаг `--containers` / `--no-containers`.
* **Мок рантайма в песочнице:** задай `YGG_MOCK_PKG_LOG` (пишет `container: <argv>` и `container-probe: <argv>`), а при проверке `status`/`doctor` — `YGG_MOCK_CONTAINER_RUNNING="proj1,proj2"` и `YGG_MOCK_CONTAINER_STATUS=daemon_down|no_runtime`.
* **Проверка колонки `containers`:** `rtk nu bin/ygg.nu status --json` должен возвращать `-`, `off`, `on N/M running`, `on (no runtime)` или `on (daemon down)` (без `?`).
* **Контроль безопасности:** убедись, что в мок-логе нет флагов `-v`, `--volumes`, `--rmi`.

## 6. Кроссплатформенный аудит модулей и внешних инструментов

Перед приёмкой модуля, архитектуры или рекомендации внешней утилиты проверяй совместимость со всеми целевыми ОС (`linux`, `windows` Non-Admin, `macos`):

* **Запрет Unix-only решений по умолчанию:** утилиты и механизмы, работающие только на Unix (`systemd`, `dockcheck`, `podman-auto-update`, `bash`-скрипты, `cron`), запрещено использовать без явного `[scope.linux]` / `[scope.unix]` и равнозначной альтернативы для Windows.
* **Единый рантайм автоматизации:** любая логика в `setup.nu` и `bin/` пишется на Nushell с использованием `path join`, `which` и `$nu.os-info.name` вместо вызовов `sh`/`bash`/PowerShell-специфичных однострочников.
* **Внешние CLI-инструменты:** перед включением в `[pkg]` или рекомендацией для модулей проверь наличие сборок и работоспособность под Windows 11 (Non-Admin) и Linux.

## 7. Полный тестовый набор движка

Перед фиксацией любых изменений в ядре `ygg`:

```bash
rtk just test
```
