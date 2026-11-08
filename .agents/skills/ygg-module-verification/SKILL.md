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

## 5. Полный тестовый набор движка

Перед фиксацией любых изменений в ядре `ygg`:

```bash
rtk just test
```
