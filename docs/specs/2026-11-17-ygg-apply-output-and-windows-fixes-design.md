# RFC-061: Честный итог apply и Windows-исправления (пачка P0/P1)

* **Дата:** 2026-11-17
* **Статус:** черновик, на утверждении
* **Issues:** #19, #8, #9, #21, #22
* **Затрагивает:** `src/doctor.nu` (`read-windows-acl`, `select-powershell`), `src/link.nu` (`preflight-check`, `format-preflight-errors`, `apply-links`, новая проба блокировок), `src/sdk.nu` (`run-link-hooks`), `src/pkg.nu` (`run-with-timeout`), `bin/ygg.nu` (`apply-plan`), `tests/`

---

## 1. Зачем

Пять issues с доски `ygg project`. Все они про одно: на обычной первой установке (Windows, `ygg add`/`ygg apply`) `ygg` выдаёт сигналы, которые не соответствуют реальному состоянию.

* `ygg doctor` каждый раз выдаёт четыре ложных `acl_unreadable` (#19), и за ними теряются настоящие предупреждения.
* `Applied N module(s).` печатается до finalize и даже перед итоговой ошибкой (#8). Некритичный сбой хука выглядит как красный `[fail]` (#9). Пользователь не понимает, установился модуль или нет.
* Ошибка отсутствующего источника показывает путь к удалённому временному клону (#21), а не место в манифесте.
* Каталог, занятый другим процессом, выдаёт сырой `os error 32` после того, как хост уже частично изменён (#22).

**Критерий успеха:** после `ygg add`/`ygg apply` по последним строкам вывода однозначно видно, чем закончилась команда и что делать дальше. `ygg doctor` на чистом Windows-хосте не выдаёт ложных находок.

## 2. Цели, не-цели, анти-цели

**Цели**
1. Устранить причину #19: `doctor` читает ACL независимо от того, из какого шелла запущен `ygg`.
2. Итог `apply` печатается последним, после finalize, и отражает фактический исход: успех, успех с предупреждениями или ошибка.
3. Некритичные сбои (хуки `on_change`) помечаются `[warn]`, `[fail]` остаётся за шагами, которые обрывают команду.
4. Ошибки preflight указывают на манифест модуля, а не на временные пути.
5. Занятые цели на Windows обнаруживаются до первой мутации хоста.

**Не-цели**
* Переделка формата бэкапов и их сводки (#10).
* Вывод winget при сбое пакета (#14, нужно воспроизведение).
* Определение имени процесса, который держит файл (Restart Manager).
* Изменение семантики сбоев: что обрывает apply, а что нет, остаётся как сейчас.

**Анти-цели**
* Проба блокировок оставляет хост в изменённом состоянии (переименованный каталог) при любом исходе.
* Проба запускается в `--dry-run`, `diff`, `status`, `doctor`.
* Новый вывод нарушает правила stderr/TTY/`NO_COLOR` из AGENTS.md §2.1.

## 3. Ограничения

* Nushell `>= 0.116`, Linux / Windows Non-Admin / macOS. Платформозависимая логика (PowerShell, проба rename) работает только на Windows, на Unix это no-op, причём там проблема не возникает: POSIX `rename` не блокируется открытыми файлами.
* ZERO HOST MUTATION в тестах: все новые ветки управляются моками `YGG_MOCK_*` и проверяются кроссплатформенно внутри `with-temp-ygg`.
* Статус и предупреждения пишутся в stderr. Итоговая строка `Applied ...` остаётся в stdout, как сейчас.
* DoD каждого issue: регрессионный тест с `# regression: #N` и коммит с футером `Fixes #N`.

## 4. Рассмотренные подходы

| Issue | Варианты | Выбрано | Почему |
|---|---|---|---|
| #19 | (а) починить только `read-windows-acl`; (б) общий хелпер запуска PowerShell для всех вызовов | **(а)**, решение пользователя после ревью | Проверка показала, что ловушка ломает только `Get-Acl` (модуль Security). Остальные вызовы работают, общий хелпер был бы рефакторингом без исправления. |
| #22 | (а) только подсказка по `os error 32`; (б) подсказка + проба rename до мутаций; (в) Restart Manager для поиска процесса | **(б)**, решение пользователя | (а) не предотвращает частичное применение. (в) медленный, рекурсивный и плохо тестируется. |
| #8/#9 | (а) переставить строку; (б) собрать предупреждения шагов и печатать итог с подсчётом и следующими шагами | **(б)** | Issue #8 явно просит подсчёт и next steps. Без сбора результатов хуков (сейчас `\| ignore`) их не посчитать. |

## 5. Решение

### 5.1. #19 — запуск PowerShell в `doctor` (`area:doctor`, `os:windows`)

**Причина (воспроизведена 2026-11-17):** `read-windows-acl` ([src/doctor.nu:143](../../src/doctor.nu#L143)) выбирает в первую очередь `powershell.exe` (5.1). Если `ygg` запущен из сессии pwsh 7, дочерний 5.1 наследует `PSModulePath` с путями модулей pwsh 7. Автозагрузка `Microsoft.PowerShell.Security` падает (`CouldNotAutoloadMatchingModule`), `Get-Acl` недоступен, exit 1, и получается `acl_unreadable`. Проверено: без `PSModulePath` в окружении (5.1 восстанавливает значение по умолчанию) или под `pwsh` тот же скрипт отрабатывает.

**Другие вызовы PowerShell не затронуты** (проверено тем же способом): `Get-Item` ([src/link.nu:95](../../src/link.nu#L95)), `Set-Service`/`Restart-Service` ([src/sdk.nu:551](../../src/sdk.nu#L551)), `Where-Object` и `[Environment]::...` ([src/env.nu:586](../../src/env.nu#L586)) работают под наследованным `PSModulePath`. Ломается только модуль `Microsoft.PowerShell.Security`. Эти вызовы не меняются.

**Решение** (в `src/doctor.nu`):

* `select-powershell [has_pwsh: bool, has_winps: bool] -> record<bin: string, hide_module_path: bool>`: чистая функция. Сначала `pwsh` (`hide_module_path: false`), затем `powershell.exe` (`hide_module_path: true`), иначе `bin: ""`.
* `read-windows-acl` берёт PowerShell через `select-powershell`. Для `powershell.exe` запуск идёт со скрытым `PSModulePath` (`hide-env -i PSModulePath` внутри замыкания вызова). Флаг `-NonInteractive` и передача пути через `YGG_ACL_PATH` сохраняются.

**Ограничение `doctor` (AGENTS.md §2.1):** `doctor` read-only, ему запрещены `--label`/`--progress` и создание `ygg-proc-*.log`. Поэтому вызов остаётся прямым (`| complete`), без `run-with-timeout`.

Строка подсказки `acl_unreadable` уточняется: к сообщению добавляется первая строка stderr PowerShell, чтобы будущие сбои было видно сразу.

**Тесты:** юнит-тест `select-powershell` на 4 комбинации. `# regression: #19` проверяет, что для `powershell.exe` выставляется `hide_module_path: true`, а при наличии `pwsh` выбирается он. Существующий `test_doctor_windows_acl_unreadable_warns` остаётся.

### 5.2. #8 + #9 — итог apply и статус хуков (`area:cli`, `area:link`)

**#9.** У `run-with-timeout` ([src/pkg.nu:87](../../src/pkg.nu#L87)) появляется флаг `--soft-fail`: при ненулевом коде строка завершения печатается как `[warn] <label> (Ns)` вместо `[fail]`. Таймаут остаётся `[timeout]`. Возвращаемый record не меняется. `run-link-hooks` ([src/sdk.nu:503](../../src/sdk.nu#L503)) вызывает его с `--soft-fail`. Строка `[ygg] Warning: on_change for '<key>' failed: ...` остаётся: она несёт stderr.

**#8.** В `apply-plan` ([bin/ygg.nu](../../bin/ygg.nu#L523-L591)):

0. `apply-plan` вызывается из `add` ([bin/ygg.nu:206](../../bin/ygg.nu#L206)), `apply` ([bin/ygg.nu:303](../../bin/ygg.nu#L303)) и `update` ([bin/ygg.nu:634](../../bin/ygg.nu#L634)). Чтобы итог знал контекст, `apply-plan` получает опциональный параметр `--added-module: string = ""`. Его передаёт только `add`.
1. Результат `run-link-hooks` сохраняется (сейчас `| ignore`), из него берутся записи со `status == "failed"`.
2. Печать `Applied ($mod_count) module(s).` и сводка переносятся **после** `commit-journal-transaction`, то есть строго последними.
3. Если `$errors` не пуст, `Applied ...` не печатается вообще. Остаётся текущий `error make` с перечнем ошибок, вывод `[ygg] Error: failed to link ...` сохраняется.
4. Успех без предупреждений даёт ровно одну строку `Applied N module(s).` в stdout.
5. Успех с предупреждениями: `Applied N module(s) with K warning(s).` в stdout, затем в stderr блок:

```text
[ygg] Warnings:
  - on_change '<key>' (<module>): <первая строка stderr>
[ygg] Next: `ygg apply` re-runs failed hooks · `ygg doctor` to diagnose · `ygg remove <module>` to roll back
```

`ygg apply` действительно перезапускает упавшие хуки: их хэш записывается только при успехе ([src/sdk.nu:443](../../src/sdk.nu#L443)). Подсказка `ygg remove <module>` показывается только при непустом `--added-module` (с этим именем). В `apply`/`update` её нет.

Сбой `setup.nu` по-прежнему обрывает apply через `error make` ([src/sdk.nu:367](../../src/sdk.nu#L367)) и в подсчёт предупреждений не входит. Это вне рамок спеки.

Счётчик предупреждений пока собирается только из хуков. Источники передаются списком record `{source, module, item, message}`, так что позже в него встраиваются другие некритичные события (например, сводка бэкапов из #10), а формат итога не меняется.

**Тесты:** e2e в `tests/test_cli_e2e.nu` с `YGG_MOCK_PKG_LOG` и `YGG_MOCK_HOOK_FAIL`. `# regression: #8`: последняя строка stdout — `Applied 1 module(s) with 1 warning(s).`, а `finalize` в stderr идёт раньше неё. При ошибке линка `Applied` отсутствует. `# regression: #9`: юнит-тест `run-with-timeout --soft-fail` на команде с exit 1 печатает `[warn]`, а не `[fail]`.

### 5.3. #21 — ошибки preflight относительно модуля (`area:link`)

`preflight-check` ([src/link.nu:983](../../src/link.nu#L983)) формирует `detail` из ключа источника без суффикса `/*` и без `./` (то же, что `base_rel` в [src/manifest.nu:732](../../src/manifest.nu#L732); в плане сейчас хранится `src_rel` с `/*`, поэтому `base_rel` либо добавляется в запись плана, либо вычисляется заново) и из `dest_raw`, а не из абсолютного `src_path`:

```text
  - [<module>] 'opencode' (missing_source): source 'opencode' not found in module (links: 'opencode' -> '~/.config/opencode'); if the module is a git repo, check that the path is committed and pushed
```

Подсказка про commit/push появляется только для git-модулей (у staged-клона нет незакоммиченных файлов, и это частая причина ошибки при `ygg add`). Тот же принцип применяется к `invalid_mode_source` и `shadowed_files` (`'($t.src)'` → `<module>/<rel>`). Абсолютные пути хоста (`dest`) остаются как есть.

**Тесты:** `# regression: #21` в `test_cli_e2e.nu`, рядом с `test_preflight_blocks_missing_link_source_before_packages`: сообщение содержит `source 'X' not found in module` и не содержит пути к `modules/`/staged-клону.

### 5.4. #22 — занятые цели на Windows (`area:link`, `os:windows`)

**Факт:** `apply-links` ([src/link.nu:694](../../src/link.nu#L694)) не обрывается на первом сбое. Ошибки линков собираются, шаги env/setup/hooks/services выполняются, `apply` падает в конце. Хост остаётся частично применённым, ошибка показывается сырым `os error 32`. `backup-existing` ([src/state.nu:250](../../src/state.nu#L250)) переносит цель через `mv`: на одном томе это rename, и при блокировке цель остаётся нетронутой.

**Часть 1. Подсказка.** Новая чистая функция `classify-fs-error [msg: string] -> record<kind: string, hint: string>` в `src/link.nu` распознаёт `os error 32`, `os error 33` и текст `being used by another process`, возвращая `kind: "locked"`. Для `os error 5` при операции над реальным каталогом цели на Windows `kind` тоже `"locked"` (переименование каталога с открытым файлом внутри часто даёт именно 5). Сбой линка с `kind == "locked"` дополняется подсказкой: `'<dest>' is in use by another process — close it and re-run ygg apply`.

**Часть 2. Проба до мутаций.** Новая функция `probe-locked-targets [ops: table] -> list<problem>`:

* Где: в `apply-plan` сразу после `preflight-check`, до проверки журнала и шага пакетов. **И** в `add` рядом с его собственным preflight ([bin/ygg.nu:192](../../bin/ygg.nu#L192)), до `register-staged-module`. Иначе при занятой цели модуль уже записан в `host.toml`, а apply обрывается. `add` специально проверяет план до регистрации, и проба должна следовать тому же правилу. Вызывается только при `not $dry_run` и только при `fs-windows`, в том числе в песочнице (`YGG_SANDBOX`): цели там лежат внутри песочницы, и проба безопасна. В `diff`/`status`/`doctor`/`--dry-run` не вызывается. Сам `preflight-check` остаётся read-only.
* Что: каждая операция `BACKUP_REPLACE`, у которой `dest` — реальный файл или каталог (не ссылка/junction).
* Как: `mv <dest> <dest>.ygg-probe-<rand>`, затем сразу обратно. Если первый `mv` упал, получается проблема `{module, key, reason: "target_locked", detail: "'<dest>' is in use by another process (<os error>) — close the program using it and re-run ygg apply"}`.
* Обратное переименование не удалось (гонка): `error make` с явным текстом, где сейчас лежит цель (`<dest>.ygg-probe-<rand>`), и командой ручного возврата. Дальше apply не идёт.
* Проблемы печатаются тем же `format-preflight-errors`, apply обрывается до первой мутации.
* Мок для тестов: если `YGG_MOCK_LOCKED_PATHS` задан (через запятую, сравнение через `normalize-case`), проба **не делает ни одного реального `mv`**. Цели из списка дают `target_locked`, остальные считаются свободными. Под моком проба работает на любой ОС, чтобы её можно было тестировать на Linux CI.
* Между пробой и шагом линков выполняется установка пакетов (минуты). Если программа захватит цель за это время, это не ловится. Остаётся подсказка из части 1.

Проба — это кратковременная обратимая мутация. Она стоит отдельным шагом, а не внутри `preflight-check`, именно чтобы не нарушать read-only контракт preflight (AGENTS.md §2.3).

**Тесты:** `# regression: #22`. Юнит-тест `classify-fs-error` на образцах сообщений. E2e: `YGG_MOCK_LOCKED_PATHS` на цель `BACKUP_REPLACE` даёт `target_locked`, лог пакетного мока пуст (до мутаций), цель на месте. Отдельные тесты: `--dry-run` с тем же моком пробу не запускает; `ygg add` с занятой целью не регистрирует модуль в `host.toml`.

## 6. Порядок поставки

Каждый пункт — отдельный PR с веткой `fix/<N>-<slug>`:

1. **#19**.
2. **#8 + #9**: два коммита (`Fixes #9`, затем `Fixes #8`), один PR.
3. **#21**.
4. **#22**.

## 7. Оставлено исполнителю

* Распознавать ли `os error 5` как `locked` всегда или только в пробе: решение по фактическим сообщениям Windows, с фиксацией в тесте.
* Формулировки английских сообщений в пределах форматов выше.

## 8. Риски

* **`mv` между томами.** Если `$YGG_HOME` на другом томе, чем цель, `backup-existing` копирует и удаляет, а не переименовывает, и занятый файл может оставить частичную копию. Проба этого не покрывает (она делает rename рядом с целью). Это вне рамок спеки: при необходимости завести отдельный issue.
* **Антивирус / индексатор** может кратковременно держать файлы, и проба даст ложный `target_locked`. Повторный запуск решает. Подсказка говорит именно «re-run».
