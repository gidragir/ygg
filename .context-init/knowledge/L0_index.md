# 🗺 Карта архитектуры: ygg (L0)

> **Стек:** Generic / Multi-language | **Обновлено:** 2026-11-11
> **Описание:** > **Minimalist, cross-platform modular dotfile and configuration manager powered by [Nushell](https://www.nushell.sh/).**

## 🚪 Точки входа (Root Entrypoints)
- `mise.toml`
- `justfile`

## ⚡️ Быстрые команды
```bash
```

## 🧩 Каталог подсистем (L1)

| Подсистема | Роль / Назначение | Точки входа | L1 Карточка |
| :--- | :--- | :--- | :--- |
| **Bin** | Модуль и компоненты директории `bin` (1 файлов) | `-` | [subsystems/bin.md](subsystems/bin.md) |
| **Docs** | Модуль и компоненты директории `docs` (10 файлов) | `-` | [subsystems/docs.md](subsystems/docs.md) |
| **Scripts** | Модуль и компоненты директории `scripts` (2 файлов) | `-` | [subsystems/scripts.md](subsystems/scripts.md) |
| **Doctor** | Модуль и компоненты директории `src/doctor` (1 файлов) | `-` | [subsystems/src_doctor.md](subsystems/src_doctor.md) |
| **Env** | Модуль и компоненты директории `src/env` (1 файлов) | `-` | [subsystems/src_env.md](subsystems/src_env.md) |
| **Git** | Модуль и компоненты директории `src/git` (1 файлов) | `-` | [subsystems/src_git.md](subsystems/src_git.md) |
| **Link** | Модуль и компоненты директории `src/link` (1 файлов) | `-` | [subsystems/src_link.md](subsystems/src_link.md) |
| **Manifest** | Модуль и компоненты директории `src/manifest` (1 файлов) | `-` | [subsystems/src_manifest.md](subsystems/src_manifest.md) |
| **Mod** | Модуль и компоненты директории `src/mod` (1 файлов) | `-` | [subsystems/src_mod.md](subsystems/src_mod.md) |
| **Pkg** | Модуль и компоненты директории `src/pkg` (1 файлов) | `-` | [subsystems/src_pkg.md](subsystems/src_pkg.md) |
| **Sdk** | Модуль и компоненты директории `src/sdk` (1 файлов) | `-` | [subsystems/src_sdk.md](subsystems/src_sdk.md) |
| **State** | Модуль и компоненты директории `src/state` (1 файлов) | `-` | [subsystems/src_state.md](subsystems/src_state.md) |
| **Tests** | Тесты проекта | `-` | [subsystems/tests.md](subsystems/tests.md) |

## 📋 Инварианты и правила проекта
- Поддерживать актуальность карт модулей и документации архитектуры.
- Все изменения фиксируются через атомарные и типизированные коммиты.
