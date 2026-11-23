# 🗺 Карта архитектуры: ygg (L0)

> **Стек:** Generic / Multi-language | **Обновлено:** 2026-11-21
> **Описание:** > **Minimalist, cross-platform modular dotfile and configuration manager powered by [Nushell](https://www.nushell.sh/).**

## 🚪 Точки входа (Root Entrypoints)
- `mise.toml`

## ⚡️ Быстрые команды
```bash
# Тесты
rtk mise run test

```

## 🧩 Каталог подсистем (L1)

| Подсистема | Роль / Назначение | Точки входа | L1 Карточка |
| :--- | :--- | :--- | :--- |
| **Bin** | Модуль и компоненты директории `bin` (1 файлов) | `-` | [subsystems/bin.md](subsystems/bin.md) |
| **Docs** | Модуль и компоненты директории `docs` (15 файлов) | `-` | [subsystems/docs.md](subsystems/docs.md) |
| **Scripts** | Модуль и компоненты директории `scripts` (3 файлов) | `-` | [subsystems/scripts.md](subsystems/scripts.md) |
| **Container** | Модуль и компоненты директории `src/container` (1 файлов) | `-` | [subsystems/src_container.md](subsystems/src_container.md) |
| **Doctor** | Модуль и компоненты директории `src/doctor` (1 файлов) | `-` | [subsystems/src_doctor.md](subsystems/src_doctor.md) |
| **Engine** | Модуль и компоненты директории `src/engine` (1 файлов) | `-` | [subsystems/src_engine.md](subsystems/src_engine.md) |
| **Env** | Модуль и компоненты директории `src/env` (1 файлов) | `-` | [subsystems/src_env.md](subsystems/src_env.md) |
| **Git** | Модуль и компоненты директории `src/git` (1 файлов) | `-` | [subsystems/src_git.md](subsystems/src_git.md) |
| **Link** | Модуль и компоненты директории `src/link` (1 файлов) | `-` | [subsystems/src_link.md](subsystems/src_link.md) |
| **Lint** | Модуль и компоненты директории `src/lint` (1 файлов) | `-` | [subsystems/src_lint.md](subsystems/src_lint.md) |
| **Manifest** | Модуль и компоненты директории `src/manifest` (1 файлов) | `-` | [subsystems/src_manifest.md](subsystems/src_manifest.md) |
| **Mod** | Модуль и компоненты директории `src/mod` (1 файлов) | `-` | [subsystems/src_mod.md](subsystems/src_mod.md) |
| **Pkg** | Модуль и компоненты директории `src/pkg` (1 файлов) | `-` | [subsystems/src_pkg.md](subsystems/src_pkg.md) |
| **Progress** | Модуль и компоненты директории `src/progress` (1 файлов) | `-` | [subsystems/src_progress.md](subsystems/src_progress.md) |
| **Sdk** | Модуль и компоненты директории `src/sdk` (1 файлов) | `-` | [subsystems/src_sdk.md](subsystems/src_sdk.md) |
| **State** | Модуль и компоненты директории `src/state` (1 файлов) | `-` | [subsystems/src_state.md](subsystems/src_state.md) |
| **Tests** | Тесты проекта | `-` | [subsystems/tests.md](subsystems/tests.md) |
| **Tests Fixtures** | Тесты для `tests` | `-` | [subsystems/tests_fixtures.md](subsystems/tests_fixtures.md) |

## 📋 Инварианты и правила проекта
- Поддерживать актуальность карт модулей и документации архитектуры.
- Все изменения фиксируются через атомарные и типизированные коммиты.
