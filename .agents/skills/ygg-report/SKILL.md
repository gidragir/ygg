---
name: ygg-report
description: Use when the user shares observations, errors or improvement ideas from using ygg (raw notes, a session recap, a pasted stack trace, docs/bugs/inbox.md) and wants them recorded, or says "заведи issue", "зафиксируй проблему", "разбери inbox"; also when prioritizing or picking tasks from the project board, or when starting a fix or spec that references a GitHub issue (#N) and prior history of that area is needed.
---

# Фиксация проблем ygg в GitHub Issues

Бэклог ygg живёт в GitHub Issues (`gidragir/ygg`, **публичный** репозиторий). Знание о решённых проблемах — в репозитории: коммит с `Fixes #N`, регрессионный тест, `CHANGELOG.md`. Навык превращает сырые заметки в атомарные issues и помогает найти историю перед работой.

## Режим 1. Захват (заметки → issues)

### Шаг 1. Разрезать на атомарные пункты

Один пункт = одна проблема, которую можно закрыть одним PR. Заметка «4 улучшения doctor» — это 4 пункта. Для каждого определи тип:

| Тип | Признак | Метка |
|---|---|---|
| bug | ygg падает, портит данные, делает не то, что заявлено | `type:bug` |
| ux | работает, но вывод/сообщение/порядок вводят в заблуждение | `type:ux` |
| feature | нужна новая команда, флаг, секция манифеста, SDK-хелпер | `type:feature` |
| не issue | вопрос «как сделать», справка, проблема в пользовательском модуле, а не в ядре | не заводить; сказать пользователю, куда это относится |

Проблема в личном модуле (конфиг остался не в том модуле, PowerShell-профиль импортирует отсутствующий модуль) — не issue ядра. Issue ядра из неё получается только если ygg мог бы это предотвратить или поддержать (тогда формулируй как feature ядра).

### Шаг 2. Нормализовать приватные данные

Репозиторий публичный. В тексте issue:
- `C:\Users\<имя>\...`, `/home/<имя>/...`, `/Users/<имя>/...` → `~/...`; временные пути `~/.ygg/.state/tmp/clone-XXXX/` → `<staged clone>/`;
- имена личных модулей → роль (`<dotfiles module>`, `<windows module>`), если имя не нужно для воспроизведения;
- содержимое `host.toml`, `secrets.toml`, токены, e-mail, имена хостов — убрать полностью;
- ссылки `file:///...` на локальные файлы → путь в репозитории ygg (`bin/ygg.nu:548`).

### Шаг 3. Проставить метки

Ровно один `type:*`, один или несколько `area:*`, `os:*` только если проблема проявляется на конкретной ОС. `needs-repro` — если нет шагов воспроизведения или версии.

| Метка | Где код |
|---|---|
| `area:cli` | `bin/ygg.nu`: команды, флаги, конвейер apply, итоговый вывод |
| `area:link` | `src/link.nu`: линковка, `preflight-check`, бэкапы, хуки `on_change`, prune |
| `area:doctor` | `src/doctor.nu` |
| `area:git` | `src/git.nu`: clone/add/update модулей, `ygg.lock` |
| `area:state` | `src/state.nu`: состояние, пути, журнал, `host.lock` |
| `area:manifest` | `src/manifest.nu`: разбор `ygg.toml`, `links.toml`, scopes |
| `area:pkg` | `src/pkg.nu` |
| `area:env` | `src/env.nu`: env, секреты |
| `area:sdk` | `src/sdk.nu`: хелперы для `setup.nu` |
| `area:container`, `area:progress` | `src/container.nu`, `src/progress.nu` |
| `area:ci`, `area:docs` | `.github/`, `scripts/release.nu`; README, `docs/` |

Сомневаешься в области — проверь через `context_pack(<subsystem>, mode="toc")` или `rg -n "<текст сообщения>" src bin`.

### Шаг 4. Найти дубли

Сначала внутри пачки (одна проблема из двух сессий → один пункт, оба контекста в теле). Затем в GitHub по 2–3 ключевым словам на пункт:

```bash
gh issue list --repo gidragir/ygg --state all --search "on_change hook warning" --json number,title,state,labels
```

- открытый дубль → не создавать, предложить комментарий с новым контекстом;
- закрытый как решённый, но проблема снова есть → новый issue с `Regression of #N` в теле;
- закрытый как `wontfix` → не создавать, показать пользователю причину закрытия.

### Шаг 5. Показать план и ждать подтверждения

Создание issue — публикация. Перед любым `gh issue create`/`gh issue comment` покажи таблицу с предлагаемыми `Priority` (`P0` блокеры/баги `apply`/`doctor`, `P1` важные UX/диагностика/целостность, `P2` улучшения/фичи) и `Size` (`XS` точечная правка, `S` один модуль, `M` несколько модулей/новая подкоманда, `L`/`XL` крупная фича/новая секция манифеста) и дождись явного «да»:

| # | Тип | Заголовок | Метки | Priority | Size | Действие |
|---|---|---|---|---|---|---|
| 1 | ux | `apply: summary printed before finalize, hook warnings get lost` | `type:ux area:cli` | `P0` | `S` | создать |
| 2 | bug | `doctor: acl_unreadable false positives for .state/env on Windows` | `type:bug area:doctor os:windows` | `P0` | `S` | создать |
| 3 | — | `ygg init` — что делает (справка) | — | — | — | не issue: ответ на вопрос |

### Шаг 6. Создать и добавить на доску

Заголовок и тело — на английском (как README и коммиты). Заголовок: `<command или area>: <суть>`. Тело — секции соответствующей формы из `.github/ISSUE_TEMPLATE/` (без них агент, ищущий историю, не найдёт воспроизведение):

- bug: `### Version`, `### OS`, `### Command`, `### Actual behavior`, `### Expected behavior`, `### Steps to reproduce`, `### Logs`;
- ux: `### Version`, `### OS`, `### Command`, `### Current behavior`, `### Proposal`;
- feature: `### Problem`, `### Proposal`, `### Cross-platform notes`.

Неизвестное поле — `_unknown_`, не выдумывать. Тело пиши во временный файл в scratchpad (UTF-8) и передавай через `--body-file`: так не ломаются кавычки и кодировка на Windows.

```bash
url=$(gh issue create --repo gidragir/ygg --title "doctor: acl_unreadable false positives for .state/env on Windows" \
  --label type:bug --label area:doctor --label os:windows --body-file "$SCRATCH/issue-2.md")
gh project item-add 5 --owner gidragir --url "$url"
```

Для выставления `Priority` и `Size` на доске `ygg project` (`#5`, владелец `gidragir`) получи ID полей и опций через `gh project field-list 5 --owner gidragir --format json` и обнови карточку через `gh project item-edit --project-id <proj-id> --id <item-id> --field-id <field-id> --single-select-option-id <opt-id>`. Если `gh project` сообщает о нехватке скоупа `project`, нужен `gh auth refresh -s project` (переменная `GITHUB_TOKEN` в окружении перекрывает keyring и мешает `refresh` — её нужно предварительно убрать).

После создания выведи список `#N — заголовок`. Обработанные пункты удали из `docs/bugs/inbox.md`, если источник — он.

### Без сети или без `gh auth`

Допиши пункты в `docs/bugs/inbox.md` (каталог в `.gitignore`) в формате шага 6 — по блоку `## <type>: <заголовок>` с метками в строке `Labels:`. Следующий запуск навыка выгрузит inbox в Issues.

## Режим 2. История перед фиксом или спекой

Для выбора следующей задачи с доски `ygg project` (`Priority board`) и проверки истории перед работой над issue `#N` или областью `area:X`:

```bash
gh project item-list 5 --owner gidragir --format json --limit 100   # задачи по Priority и Size
gh issue view N --repo gidragir/ygg --comments
gh issue list --repo gidragir/ygg --state all --label area:X --json number,title,state
git log --oneline --grep "#N"            # коммиты, закрывшие или упомянувшие issue
git log --oneline -- src/<file>.nu | head -20
rg -n "regression: #" tests               # регрессионные тесты с привязкой к issue
```

Спека или план, начатые по issue, ссылаются на него в шапке (`Issues: #12, #15`).

## Закрытие проблемы (DoD фикса)

1. Регрессионный тест в `tests/`, над ним комментарий `# regression: #N`.
2. Коммит фикса с футером `Fixes #N` (несколько: `Fixes #12` и `Fixes #15` отдельными строками). Упоминание без закрытия — `Refs #N`.
3. `CHANGELOG.md` не правится руками: перед релизом `mise run changelog` (git-cliff) собирает его из коммитов и подставляет ссылки на issues из футеров.

## Частые ошибки

| Ошибка | Как правильно |
|---|---|
| Один issue «улучшения doctor» на 4 разные проблемы | 4 issue, каждый закрывается своим PR |
| Абсолютный путь с именем пользователя в логе | `~/...`, staged clone → `<staged clone>/` |
| Заведён issue на вопрос «как сделать» | Ответить; если ответ неочевиден из `ygg --help` — `type:feature area:docs` |
| Issue создан без показа таблицы | Публикация только после явного подтверждения |
| Придуманная версия или шаги воспроизведения | `_unknown_` + метка `needs-repro` |
| `Fixes #N` в заголовке коммита | Только в футере (после пустой строки), иначе git-cliff не подставит ссылку |
