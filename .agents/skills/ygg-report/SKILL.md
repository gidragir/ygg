---
name: ygg-report
description: Use when the user shares observations, errors or improvement ideas from using ygg (raw notes, a session recap, a pasted stack trace, docs/bugs/inbox.md) and wants them recorded as GitHub issues, or says "заведи issue", "зафиксируй проблему", "разбери inbox".
---

# Заметки об ygg → GitHub Issues

## Обзор

Бэклог — Issues **публичного** `gidragir/ygg` и доска `ygg project` (#5). Выбор задачи, история перед фиксом и DoD — в AGENTS.md §1a.

## Порядок

1. **Разрезать** на пункты: один пункт = одна проблема = один PR. Тип каждого:
   - `bug` — падает, портит данные, делает не то, что заявлено;
   - `ux` — работает, но вывод или порядок вводит в заблуждение;
   - `feature` — новая команда, флаг, секция манифеста, SDK-хелпер;
   - **не issue** — вопрос «как сделать» (ответить в чате) или проблема личного модуля (сказать, где чинить; если ygg мог бы это предотвратить — `feature`).
2. **Обезличить** (репозиторий публичный):
   - `C:\Users\<имя>\...`, `/home/<имя>/...`, `/Users/<имя>/...` → `~/...`; `~/.ygg/.state/tmp/clone-XXXX/` → `<staged clone>/`;
   - имена личных модулей → роль (`<dotfiles module>`); `host.toml`, `secrets.toml`, токены, e-mail, имена хостов — убрать;
   - `file:///...` → путь в репозитории (`bin/ygg.nu:548`).
3. **Метки:** ровно один `type:*`, один или несколько `area:*`, `os:*` — только если проблема на конкретной ОС, `needs-repro` — если нет шагов или версии. Таблица `area:*` → код: [references/labels-and-board.md](references/labels-and-board.md).
4. **Дубли:** сначала внутри пачки, затем `gh issue list --repo gidragir/ygg --state all --search "<2–3 слова>"`. Открытый дубль → предложить комментарий; закрытый решённый, но воспроизводится → новый issue с `Regression of #N`; `wontfix` → показать причину.
5. **Таблица и подтверждение.** Создание и комментарий — публикация. Покажи таблицу и жди явного «да»; «я ушёл», «быстро» — не подтверждение.

   | # | Тип | Заголовок | Метки | Priority | Size | Действие |
   |---|---|---|---|---|---|---|
   | 1 | bug | `doctor: broken junction reported as OK` | `type:bug area:doctor os:windows` | `P0` | `S` | создать |

   - **Priority:** `P0` — любой bug в `apply`/`doctor` и блокеры; `P1` — важный UX, диагностика, целостность; `P2` — улучшения и фичи.
   - **Size:** `XS` — точечная правка; `S` — один модуль; `M` — несколько модулей или подкоманда; `L`/`XL` — крупная фича, новая секция манифеста.
6. **Создать.** Заголовок и тело на английском, заголовок `<command или area>: <суть>`. Тело — ровно секции формы из `.github/ISSUE_TEMPLATE/`:
   - bug: `### Version`, `### OS`, `### Command`, `### Actual behavior`, `### Expected behavior`, `### Steps to reproduce`, `### Logs`;
   - ux: `### Version`, `### OS`, `### Command`, `### Current behavior`, `### Proposal`;
   - feature: `### Problem`, `### Proposal`, `### Cross-platform notes`.

   Неизвестное поле — `_unknown_`. Тело — UTF-8 файл в scratchpad и `--body-file`. Затем карточка на доску с Priority и Size ([references/labels-and-board.md](references/labels-and-board.md)). В конце — список `#N — заголовок`; обработанное удалить из `docs/bugs/inbox.md`.

Без сети или `gh auth` — дописать в `docs/bugs/inbox.md` блоки `## <type>: <заголовок>` со строкой `Labels:`.

## Частые ошибки

| Ошибка | Как правильно |
|---|---|
| Свои секции тела (`## Observed`, `## Notes`) | Секции формы: по ним потом ищут воспроизведение |
| `%USERPROFILE%` или имя пользователя в пути | `~/...` |
| Тело через heredoc или `--body "..."` | `--body-file`: на Windows ломаются кавычки и кодировка |
| Bug в `apply`/`doctor` с `P1`/`P2` | `P0` |
| Придуманная версия или шаги | `_unknown_` + `needs-repro` |
