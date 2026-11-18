# RFC-064: Диагностика сбоев пакетных менеджеров и защита запущенных рантаймов (`nu`/`pwsh`)

* **Дата:** 2026-11-18
* **Статус:** черновик, на утверждении
* **Issues:** #14
* **Затрагивает:** `src/pkg.nu` (`run-with-timeout`, `run-install-argv`, `install-packages`, новые хелперы хвоста вывода и проверки активного рантайма), `bin/ygg.nu` (`apply-plan`), `tests/test_pkg_git.nu`, `tests/test_e2e_apply.nu`

---

## 1. Зачем

При сбое установки пакетов в `ygg apply` пользователь видит только общую сводку без кода возврата и вывода пакетного менеджера (#14):

```text
Package installation failed for: winget: Microsoft.PowerShell (error), winget: nushell (timeout)
   at bin/ygg.nu:573  error make { msg: ($errors | str join "; ") }
```

Проблема состоит из двух частей:

1. **Потеря диагностики (`src/pkg.nu` + `bin/ygg.nu`):**
   * `run-install-argv` ([src/pkg.nu:515](../../src/pkg.nu#L515)) отбрасывает `exit_code` и `stdout`, возвращая только `stderr`.
   * На Windows `winget` (и ряд других менеджеров, например `scoop`) пишет прогресс, статус и сообщения об ошибках преимущественно в `stdout`, оставляя `stderr` пустым. В результате `install-packages` ([src/pkg.nu:679](../../src/pkg.nu#L679)) печатает пустой хвост после двоеточия (`... failed for '...' (error): `), а `run-with-timeout` ([src/pkg.nu:194-195](../../src/pkg.nu#L194-L195)) к этому моменту уже удалил временные файлы `out_log` / `err_log`.
   * `apply-plan` ([bin/ygg.nu:568-571](../../bin/ygg.nu#L568-L571)) формирует итоговое сообщение только из `mgr`, `pkg` и `reason`, не передавая ни код возврата, ни хвост вывода.
   * Дополнительно: `run-with-timeout` ([src/pkg.nu:217](../../src/pkg.nu#L217)) проверяет только `$exit_code == 0`, из-за чего коды успеха `winget` (`WINGET_OK_CODES`: `-1978335135` «уже установлен», `-1978335189` «нет доступного обновления») рисуются в прогрессе как `[fail]`, хотя `run-install-argv` считает их успехом.

2. **Зависание/сбой `winget` на запущенных рантаймах (`Microsoft.PowerShell`, `Nushell.Nushell`):**
   * `winget install --exact ... <id>` при уже установленном пакете и наличии новой версии в источнике пытается выполнить обновление на месте (например, на хосте `Microsoft.PowerShell` `7.6.10.0` -> `7.7.0.0`).
   * Поскольку `ygg` сам работает внутри `nu` (и часто запускается из `pwsh`), обновление `nu.exe` или `pwsh.exe` на лету упирается в заблокированные исполняемые файлы, что приводит к ошибке установщика или таймауту `300s`.

**Критерий успеха:** при сбое или таймауте любого пакетного менеджера пользователь сразу видит код возврата и последние осмысленные строки вывода (`stderr` или `stdout`, очищенные от ANSI и `\r`-прогресса). Попытка обновить через `winget` рантайм, в котором прямо сейчас запущен `ygg` (`nu` / активный `pwsh`), не приводит к таймауту и падению `apply` — вместо этого выводится предупреждение с подсказкой обновить пакет вне запущенного шелла.

---

## 2. Цели, не-цели, анти-цели

**Цели**
1. Сохранять `exit_code` и очищенный хвост вывода (`stderr`, при пустом — `stdout`) для каждого упавшего или зависшего по таймауту пакета, показывать их в `stderr`-логе `install-packages` и в итоговой ошибке `apply-plan`.
2. Корректно отображать `[ok]` в прогрессе `run-with-timeout` для допустимых ненулевых кодов (`--ok-codes`, включая `WINGET_OK_CODES`).
3. Обнаруживать попытку `winget install` для рантайма, который прямо сейчас используется процессом `ygg` (`Nushell.Nushell`, `Microsoft.PowerShell`), пропускать его с явным `[warn]` вместо зависания на 300 секунд.

**Не-цели**
* Полный парсинг локализованных сообщений `winget` или маппинг всех HRESULT-кодов Windows.
* Полноценный precheck всех пакетов `winget` через `winget list` (один вызов `winget list --exact --id ...` на реальном хосте занимает ~5–15 секунд и заметно замедлит каждый `ygg apply`).
* Сохранение постоянных лог-файлов каждого запуска `pkg` на диск (достаточно включать очищенный хвост последних строк прямо в диагностику).
* Поддержка менеджера `psgallery` (#51).

**Анти-цели**
* Пропуск `Microsoft.PowerShell`, когда `pwsh` ещё **не** установлен на машине (первичная установка из `cmd.exe` / Windows PowerShell 5.1 / `nu` должна выполняться штатно).
* Вывод сырого `\r`-спама прогресс-баров `winget` или ANSI-последовательностей в `error make` или лог.
* Нарушение ZERO HOST MUTATION в тестах: все проверки идут через `with-temp-ygg` и моки `YGG_MOCK_*`, без реального запуска `winget`.

---

## 3. Ограничения

* Кроссплатформенность (AGENTS.md §2.4): улучшение диагностики (хвост вывода, `exit_code`, `--ok-codes`) работает для **всех** пакетных менеджеров на Linux, Windows и macOS. Проверка активного рантайма `nu`/`pwsh` специфична для `winget` на Windows (на других ОС и менеджерах — no-op).
* Обратная совместимость контракта `install-packages`: поля `mgr`, `pkg`, `reason`, `stderr` в элементах `failed` сохраняются, новые поля (`exit_code`, `tail`) добавляются без поломки существующих тестов.
* Заметка по `needs-repro` (#14): в исходном багрепорте точный код возврата и текст ошибки `winget` не сохранились именно из-за отсутствия диагностики. Часть 1 (диагностика) устраняет слепую зону напрямую; часть 2 (защита активных `nu`/`pwsh`) основана на воспроизведённом механизме `winget install` при наличии обновления установленного пакета.
* DoD: регрессионные тесты с `# regression: #14` и коммит с футером `Fixes #14`.

---

## 4. Рассмотренные подходы

| Вопрос | Варианты | Выбрано | Почему |
|---|---|---|---|
| Где брать текст ошибки при пустом `stderr` | (а) только `stderr`; (б) `stderr`, а если пуст — хвост `stdout`; (в) писать лог-файл в `.state/logs/` и печатать путь | **(б)** | `winget` и `scoop` пишут ошибки в `stdout`. Хвост в сообщении даёт ответ сразу без лишних файлов в `.state/` и не требует ротации логов. |
| Как очищать вывод от прогресс-баров `winget` | (а) `str trim` последних строк; (б) сплит по `[\r\n]+` + `sanitize-log-line` из `src/progress.nu` | **(б)** | `winget` рисует спиннер и прогресс через `\r` и ANSI; `sanitize-log-line` уже решает это в ядре. |
| Как защитить запущенные `nu`/`pwsh` | (а) общий `winget list` precheck для всех пакетов; (б) точечная проверка активного рантайма для известных ID (`Nushell.Nushell`, `Microsoft.PowerShell`) | **(б)** | `winget list` занимает ~5–15с на пакет. Проверка процесса `ygg` и его предка мгновенна и не трогает установку других пакетов. |

---

## 5. Решение

### 5.1. Диагностика сбоев пакетных менеджеров (`src/pkg.nu`, `bin/ygg.nu`)

1. **`run-with-timeout` ([src/pkg.nu:87](../../src/pkg.nu#L87)):**
   * Добавить необязательный флаг `--ok-codes: list<int> = [0]`.
   * Строка статуса завершения: `$status` считается `"ok"`, если `$exit_code in $ok_codes` (а не только `$exit_code == 0`).
   * `run-install-argv` передаёт `--ok-codes=$ok_codes`, чтобы `WINGET_OK_CODES` отображались как `[ok]`.

2. **Хелпер `format-pkg-failure-tail` (`src/pkg.nu`):**
   * Сигнатура: `export def format-pkg-failure-tail [stderr: string, stdout: string, --max-lines: int = 5]: nothing -> string`.
   * Разбивает текст по `[\r\n]+`, прогоняет каждую строку через `sanitize-log-line` ([src/progress.nu:12](../../src/progress.nu#L12)), отбрасывает пустые строки.
   * Источник: сначала пробует `stderr`; если после очистки строк не осталось, берёт `stdout`.
   * Возвращает последние `$max_lines` непустых строк, объединённые через `\n` (при отсутствии вывода — `""`).

3. **`run-install-argv` ([src/pkg.nu:515](../../src/pkg.nu#L515)):**
   * Возвращает `{ ok: bool, reason: string, exit_code: int, stderr: string, stdout: string }`.
   * При `timed_out: true` возвращает `exit_code: 124`, `stdout: ($r.stdout | default "")`, `stderr: ($r.stderr | default "")`.
   * В mock-режиме при `YGG_MOCK_PKG_FAIL` возвращает `exit_code: 1`, `stdout: ""`, `stderr: $"Package manager '($mgr)' error: simulated failure"`.

4. **`install-packages` ([src/pkg.nu:543](../../src/pkg.nu#L543), [679-680](../../src/pkg.nu#L679-L680)):**
   * В запись `failed` добавляются поля `exit_code: int` и `tail: string` (дополнительно к `mgr`, `pkg`, `reason`, `stderr`).
   * В возвращаемый record добавляется `warnings: list<record<source: string, module: string, item: string, message: string>>` (по умолчанию `[]`, формат совместим с `format-apply-summary`), не смешиваясь с `skipped` (`skipped` остаётся строго списком имён менеджеров, пропущенных по кэшу хэшей — `bin/ygg.nu:458`).
   * В `stderr` при ошибке печатается:
     ```text
     [ygg] Error: package manager 'winget' failed for 'Microsoft.PowerShell' (error, exit -1978335189):
       <до 5 очищенных строк хвоста>
     ```
     Если `tail` пустой, двоеточие и блок строк не добавляются.

5. **`apply-plan` ([bin/ygg.nu:568-571](../../bin/ygg.nu#L568-L571), [606](../../bin/ygg.nu#L606)):**
   * Форматирование каждого элемента `$pkg_res.failed` в итоговой ошибке:
     * базовый суффикс: `($f.reason), exit ($f.exit_code)` (для `timeout` — `timeout, exit 124`);
     * если `$f.tail != ""`, добавляется последняя (или склеенная) строка хвоста: `($f.mgr): ($f.pkg) (($meta): ($last_line))`.
   * Предупреждения `$pkg_res.warnings` прибавляются к счётчику предупреждений в `format-apply-summary` (вместе с `hook-warnings $hooks`), чтобы итоговая строка `Applied N module(s) with M warning(s)` честно отражала пропущенные пакеты.

### 5.2. Защита запущенных рантаймов `nu` / `pwsh` на Windows (`src/pkg.nu`)

1. **Чистая функция `active-runtime-winget-warning` (`src/pkg.nu`):**
   * Принимает `pkg: string` и контекст процесса (для тестируемости без реального Windows/процессов): `{ os: string, in_pwsh: bool }`.
   * На любой ОС, кроме `"windows"`, всегда возвращает `""`.
   * Нормализует имя пакета в нижний регистр:
     * `nushell.nushell` (и `nushell`): `ygg` всегда исполняется под `nu`, поэтому `nu.exe` гарантированно запущен. Возвращает сообщение:
       `"Nushell is currently running ygg and cannot be upgraded in-place via winget; run 'winget upgrade Nushell.Nushell' outside nu if needed"`
     * `microsoft.powershell` (и `microsoft.powershell.preview`): если `$in_pwsh` истинно, возвращает сообщение:
       `"PowerShell (pwsh) is currently in use and cannot be upgraded in-place via winget; run 'winget upgrade Microsoft.PowerShell' outside pwsh if needed"`
     * Если `pwsh` **не** активен (например, первичная установка из `cmd.exe` или `nu` без запущенного `pwsh`), установка `Microsoft.PowerShell` выполняется как обычно.
   * Определение `in_pwsh` на хосте: встроенный в Nushell `ps | any { |p| $p.name =~ '(?i)^pwsh(\.exe)?$' }` (учитывает как родительский процесс `pwsh`, так и открытую соседнюю вкладку с `pwsh.exe`, блокирующую бинарник). В тестах управляется контекстом / `YGG_MOCK_ACTIVE_RUNTIME`.

2. **Поведение в `install-packages` (`src/pkg.nu`):**
   * В `--dry-run` (`ygg diff` / `apply --dry-run`) проверка активного рантайма не выполняется и предупреждения не печатаются (сохраняется строгий read-only/предсказуемый вывод).
   * В обычном режиме для `mgr == "winget"` перед запуском `run-install-argv` для пакета проверяется `active-runtime-winget-warning`:
     * печатается `[ygg] Warning: <сообщение>` в `stderr` и добавляется в `warnings`;
     * пакет пропускается (не добавляется ни в `failed`, ни в `skipped`), остальные пакеты `winget` продолжают устанавливаться штатно;
     * выставляется флаг `$mgr_skipped_runtime = true`, по которому для `$mgr` **не** сохраняется `set_hash` в `state.hashes` (иначе при следующем `ygg apply` уже вне `pwsh` `winget` был бы пропущен по кэшу, и `Microsoft.PowerShell` никогда не установился бы).
   * **Ограничение моков:** в mock-режиме (`is-mock-mode`) проверка активного рантайма срабатывает только при заданном `YGG_MOCK_ACTIVE_RUNTIME` (например, `"nu,pwsh"` или `"nu"`), чтобы не ломать существующие тесты с `YGG_MOCK_PKG_LOG`.

---

## 6. План проверки и тесты

* **Unit-тесты (`tests/test_pkg_git.nu`, с `# regression: #14`):**
  * `format-pkg-failure-tail`: очистка `\r`-прогресса и ANSI, выбор `stdout` при пустом `stderr`, обрезка до `--max-lines`.
  * `run-install-argv` / `install-packages`: сохранение `exit_code` и `tail` в `$res.failed`, передача `--ok-codes` для `WINGET_OK_CODES`.
  * `active-runtime-winget-warning`: проверка комбинаций (`windows`/`linux`, `Nushell.Nushell`, `Microsoft.PowerShell` с `in_pwsh: true` и `in_pwsh: false`, обычный пакет `Git.Git`).
* **E2E-тест (`tests/test_e2e_apply.nu`, с `# regression: #14`):**
  * Падение пакетного менеджера в `ygg apply` с `YGG_MOCK_PKG_FAIL` выводит в ошибке `exit <code>` и диагностику, а не голый `(error)`.
* **Полный прогон:** `mise run test` на Windows и Linux.
