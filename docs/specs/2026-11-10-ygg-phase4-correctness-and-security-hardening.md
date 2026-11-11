# Спецификация Фазы 4: Корректность, безопасность и приведение Фазы 3 к контракту (RFC-041 — RFC-058)

> **Дата создания:** 2026-11-10  
> **Статус:** `Предложено (RFC-041 — RFC-058)`  
> **Цель документа:** Устранить дефекты, выявленные ревью кода на `ac486e8` после реализации Фазы 3: исполнение команд из манифестов сторонних модулей, запись секретов на диск, журнал без восстановления, удаление пакетов хоста из песочницы, нарушение read-only у `diff`/`status`, неатомарную блокировку. Документ уточняет и местами заменяет требования RFC-026, 027, 030, 032, 034, 035, 037, 038, 039.  
> **База контракта:** `docs/specs/2026-11-08-ygg-phase3-resilience-and-ecosystem.md` (RFC-026 — RFC-040), Nushell `>= 0.116.1`.  
> **Источник:** ревью 2026-11-10; прогон `tests/run.nu` — 155 pass / 1 fail.

---

## 1. Матрица (RFC-041 — RFC-058)

| RFC ID | Подсистема | Приоритет | Ключевая цель | Заменяет / уточняет |
| :--- | :--- | :--- | :--- | :--- |
| **RFC-041** | `src/env.nu` | **P0** | Схемы секретов только из `secrets.toml`; проверка до мутаций | RFC-034 |
| **RFC-042** | `src/env.nu`, `src/doctor.nu` | **P0** | Внешние секреты не материализуются на диск по умолчанию | RFC-034 |
| **RFC-043** | `src/state.nu`, `bin/ygg.nu`, `src/doctor.nu` | **P0** | Журнал v2: статус сбоя, roll-forward-восстановление | RFC-027 |
| **RFC-044** | `src/pkg.nu` | **P0** | Безопасный `--prune-packages`: песочница, история, фильтры | RFC-030 |
| **RFC-045** | `bin/ygg.nu`, `src/sdk.nu`, `src/manifest.nu` | **P0** | `diff`/`status`/`doctor`/`--dry-run` не пишут на диск и не исполняют `setup.nu` | Инвариант §2.1 AGENTS.md |
| **RFC-046** | `src/state.nu` | **P1** | Атомарная блокировка хоста, файл `host.lock` | RFC-026 |
| **RFC-047** | `src/doctor.nu`, `bin/ygg.nu` | **P1** | `doctor --fix` под блокировкой, только над объектами ygg | RFC-038 |
| **RFC-048** | `src/pkg.nu` | **P1** | Системные менеджеры без TTY: sudo-проверка, noninteractive, предпроверка установленного | RFC-029 |
| **RFC-049** | `src/doctor.nu`, `src/env.nu` | **P1** | Аудит Windows ACL по SID; ACL на файлах окружения | RFC-035 |
| **RFC-050** | `src/git.nu`, `bin/ygg.nu` | **P1** | Рабочие `ref`/`rev`, детерминированный `ygg.lock`, код возврата `update` | RFC-032 |
| **RFC-051** | `tests/`, `.github/workflows/ci.yml` | **P1** | Герметичные тесты, CI на Node 24, обезличенный purity-шаг | RFC-040 |
| **RFC-052** | `bin/ygg.nu` | **P2** | Completions из единой таблицы CLI | RFC-039 |
| **RFC-053** | `src/state.nu`, `src/sdk.nu` | **P2** | Отказ на битом `state.json`; GC хэшей без regex-разбора `setup.nu` | RFC-028 |
| **RFC-054** | `src/manifest.nu` | **P2** | Стабильный порядок DAG, сохраняющий приоритет `host.toml` | RFC-031 |
| **RFC-055** | `src/sdk.nu`, `src/link.nu`, `bin/ygg.nu` | **P2** | `[services]`: кэш `enable`, точные триггеры, белый список менеджеров | RFC-037 |
| **RFC-056** | `src/env.nu`, `src/link.nu` | **P2** | `PATH` для nu/zsh/fish; валидация имён переменных и алиасов | RFC-036 |
| **RFC-057** | `bin/ygg.nu`, `src/doctor.nu`, `src/git.nu` | **P3** | Мелкие исправления | — |
| **RFC-058** | `docs/`, `AGENTS.md` | **P3** | Синхронизация документов Фазы 3 с фактом | — |

---

## 2. Требования и контракты

### RFC-041: Схемы секретов только из `secrets.toml` и ранняя проверка

* **Компонент:** `src/env.nu`, `bin/ygg.nu` · **Приоритет:** P0

#### Проблема
`compile-environment` ([src/env.nu:221](../../src/env.nu)) вызывает `resolve-secret-value` для каждого значения объединённого окружения, включая `[env]` из `ygg.toml` модулей. Значение `eval:<cmd>` в манифесте стороннего модуля исполняется при `ygg apply`. Литерал, начинающийся с `pass:`, нельзя задать. Сбой провайдера происходит после установки пакетов и ссылок.

#### Требование
1. Схемы `op://`, `bw://`, `pass:`, `eval:` интерпретируются **только** для значений из `$YGG_HOME/secrets.toml`. Значения `plan.env` всегда литералы.
2. В `secrets.toml` префикс `literal:` отключает интерпретацию: `literal:pass:abc` → `pass:abc`.
3. Новая чистая функция классификации:
   ```nu
   export def classify-secret-value [raw: string]: nothing -> record<kind: string, ref: string>
   # kind ∈ "literal" | "op" | "bw" | "pass" | "eval"; ref — исходная строка без префикса `literal:`/`pass:`/`eval:` (для op/bw — строка целиком)
   ```
4. Новая проверка, вызываемая из `preflight` до любых мутаций (в том числе в `--dry-run`):
   ```nu
   export def validate-secret-providers [ygg_home: string]: nothing -> list<string>
   ```
   Возвращает по строке на каждую схему, чей CLI (`op`, `bw`, `pass`, для `eval` — `nu`) отсутствует в `PATH`. Непустой результат прерывает `apply` до шага пакетов. Сами провайдеры при проверке не вызываются.

#### Критерии приёмки
* Модуль с `[env] X = "eval:touch <маркер>"` после `apply`: маркер не создан, в `env.zsh` — `export X='eval:touch …'`.
* `secrets.toml` с `K = "op://v/i/f"` при отсутствии `op` в `PATH`: `apply` завершается ошибкой, лог пакетов (`YGG_MOCK_PKG_LOG`) пуст.

---

### RFC-042: Внешние секреты не материализуются на диск

* **Компонент:** `src/env.nu`, `src/doctor.nu`, `src/manifest.nu` · **Приоритет:** P0

#### Проблема
Разрешённые значения записываются открытым текстом в `.state/env/env.{nu,zsh,ps1,fish}`, `~/.config/environment.d/99-ygg.conf` и импортируются в `systemctl --user`. Это противоречит цели RFC-034.

#### Требование
1. Режим задаётся в `host.toml`:
   ```toml
   [ygg.secrets]
   materialize = false   # по умолчанию
   ```
2. **`materialize = false` (по умолчанию):** для значений с `kind != "literal"` в файлы окружения пишется вызов провайдера, исполняемый при запуске шелла:

   | Файл | Форма строки |
   | :--- | :--- |
   | `env.zsh` | `export K="$(<argv>)"` |
   | `env.fish` | `set -gx K (<argv>)` |
   | `env.nu` | `$env.K = (^<argv> \| str trim)` |
   | `env.ps1` | `$env:K = (& <argv>)` |

   `<argv>` по схемам: `op read '<ref>'`; `bw get password '<item>'`; `pass show '<path>'` (берётся первая строка вывода); `nu -c '<cmd>'`. Аргументы экранируются по правилам соответствующего шелла.
3. В статические приёмники — `99-ygg.conf`, `systemctl --user import-environment`, пользовательское окружение Windows (реестр) — внешние секреты **не попадают**; на каждый ключ печатается предупреждение в stderr.
4. **`materialize = true`:** текущее поведение (значения разрешаются в памяти до шага пакетов, пишутся открытым текстом), но каждый файл с секретом получает `0600` на Unix и ACL по RFC-049 на Windows. `doctor` выдаёт `warn` с кодом `secrets_materialized`.
5. Литералы из `secrets.toml` пишутся как раньше.

#### Критерии приёмки
* При `materialize = false` и `K = "op://v/i/f"` (мок `op` в `PATH` печатает `S3CRET`): ни один файл под `$YGG_HOME/.state` и `$YGG_SANDBOX` не содержит `S3CRET`; `env.zsh` содержит `export K="$(op read 'op://v/i/f')"`.
* При `materialize = true` значение присутствует в `env.zsh`, права файла `0600`.

---

### RFC-043: Журнал v2 и roll-forward-восстановление

* **Компонент:** `src/state.nu`, `bin/ygg.nu`, `src/doctor.nu` · **Приоритет:** P0

#### Проблема
`apply` при найденном `journal.json` печатает сообщение и перезаписывает журнал ([bin/ygg.nu:291](../../bin/ygg.nu), 338). После любой ошибки `apply` журнал остаётся, и `doctor` сообщает `journal_incomplete` как `error`, хотя падения процесса не было. В журнал целиком сериализуется `plan`.

#### Решение
Конвейер `apply` идемпотентен, заменяемые файлы уходят в бэкапы. Поэтому восстановление — **повторное выполнение (roll-forward)**, а не откат. Требование RFC-027 «replay committed / rollback incomplete» и тест «завершает откат ссылок» отменяются.

#### Требование
1. Формат `.state/journal.json`:
   ```json
   {
     "version": 2,
     "pid": 12345,
     "command": "apply",
     "started": "2026-11-10T12:00:00+03:00",
     "plan_hash": "<sha256>",
     "status": "in_progress",
     "failed_step": "",
     "error": "",
     "steps": { "prune_packages": "PENDING", "packages": "PENDING", "links": "PENDING", "setup": "PENDING", "env": "PENDING", "services": "PENDING", "finalize": "PENDING" }
   }
   ```
   Поле `plan` удаляется. Файл создаётся с правами `0600`.
2. Контракты `src/state.nu`:
   ```nu
   export def begin-journal-transaction [ygg_home: string, plan: record, command: string = "apply"]: nothing -> string
   export def record-journal-step [ygg_home: string, step_name: string, status: string]: nothing -> nothing   # PENDING | IN_PROGRESS | COMMITTED | FAILED
   export def fail-journal-transaction [ygg_home: string, error_msg: string]: nothing -> nothing            # status = "failed", failed_step = первый шаг не в COMMITTED
   export def commit-journal-transaction [ygg_home: string]: nothing -> nothing
   export def check-pending-journal [ygg_home: string]: nothing -> record<state: string, started: string, failed_step: string, error: string, plan_hash: string>
   ```
   `state`: `"none"` — файла нет; `"active"` — `status = in_progress`, PID жив; `"interrupted"` — `in_progress`, PID мёртв; `"failed"` — `status = failed`. Журнал версии 1 или нечитаемый трактуется как `"interrupted"`.
3. Все шаги конвейера, включая `prune_packages`, `services` и `finalize` (ротация бэкапов, GC, `ygg.lock`), отмечаются в журнале.
4. `apply-plan`: любая ошибка после `begin-journal-transaction` → `fail-journal-transaction`, затем исходная ошибка пробрасывается.
5. Следующий `apply` при `state ∈ {interrupted, failed}` печатает в stderr `[ygg] Recovering: previous apply <state> at step '<failed_step>'; re-running full pipeline.`, выполняет полный конвейер с принудительным `--refresh-packages`, если шаг `packages` не был `COMMITTED`, и удаляет журнал при успехе.
6. `doctor`: `interrupted` → `error` `journal_interrupted`; `failed` → `warn` `journal_failed` с текстом ошибки; `active` и `none` — без находки. Подсказка в обоих случаях — `ygg apply`.

#### Критерии приёмки
* `apply` с падающим `setup.nu`: журнал имеет `status = "failed"`, `failed_step = "setup"`, `steps.links = "COMMITTED"`; `doctor --json` содержит `journal_failed` с severity `warn`.
* Повторный `apply` после исправления `setup.nu`: stderr содержит `Recovering:`, журнал удалён.
* Журнал не содержит ключа `plan`.

---

### RFC-044: Безопасный `--prune-packages`

* **Компонент:** `src/pkg.nu`, `bin/ygg.nu` · **Приоритет:** P0

#### Проблема
`prune-unused-packages` ([src/pkg.nu:434](../../src/pkg.nu)): при `YGG_SANDBOX` без `YGG_MOCK_PKG_LOG` выполняет реальные команды удаления; команда строится строкой и режется по пробелам; игнорирует `--pkg` и отсутствие менеджера в `PATH`. В `install-packages` ветки «cached» и «нечего ставить» ([src/pkg.nu:349](../../src/pkg.nu), 356) перезаписывают `state.packages` текущим набором, стирая историю.

#### Требование
1. Сигнатура:
   ```nu
   export def prune-unused-packages [
       ygg_home: string, current_plan: record,
       --dry-run, --force-system-prune,
       --pkg: string = "", --sandbox: string = ""
   ]: nothing -> record<executed: list<string>, failed: list<string>, skipped: list<string>>
   ```
2. При непустой песочнице (`--sandbox` или `YGG_SANDBOX`) и выключенном мок-режиме функция ничего не исполняет и возвращает пустые списки — так же, как `install-packages`.
3. `pkg-uninstall-cmd` заменяется на `pkg-uninstall-argv [mgr: string, pkg: string]: nothing -> list<string>`; `split row " "` удаляется.
4. Обрабатываются только менеджеры из `--pkg` (если задан), входящие в `allowed-package-managers` и присутствующие в `PATH` (в мок-режиме проверка `PATH` пропускается). Пропущенные попадают в `skipped`.
5. Для менеджеров с `sudo` перед удалением выполняется проверка RFC-048.
6. `scoop` переносится из системных в безопасные (user-scope).
7. Для `mise` после `uninstall` выполняется `mise unuse` с тем же `--path`, что использовался при установке.
8. `install-packages` во всех ветках записывает `state.packages[mgr]` как объединение прежнего и текущего списков. Запись сужается до текущего набора только в `prune-unused-packages` после успешного удаления.
9. Удаление пакетов отмечается шагом журнала `prune_packages`; непустой `failed` → ошибка `apply`.

#### Критерии приёмки
* `YGG_SANDBOX` задан, `YGG_MOCK_PKG_LOG` пуст: `executed == []`, `state.packages` не изменён.
* Пакет убран из манифеста → `apply` → `apply --prune-packages`: второй вызов логирует его удаление.
* `--prune-packages --pkg cargo` не трогает `pnpm`.

---

### RFC-045: Контракт read-only и `setup.nu` в dry-run

* **Компонент:** `bin/ygg.nu`, `src/sdk.nu`, `src/manifest.nu` · **Приоритет:** P0

#### Проблема
`main apply` ([bin/ygg.nu:225](../../bin/ygg.nu)), `apply-plan` (261) и `main status` (518) безусловно вызывают `ensure-ygg-dirs`. `ygg diff` реализован как `apply --dry-run` и создаёт каталоги. В dry-run исполняется `setup.nu` (324): команды вне SDK меняют хост.

#### Требование
1. `ensure-ygg-dirs` вызывается только на мутирующем пути. `diff`, `status`, `doctor` (без `--fix`), `apply --dry-run`, `add --dry-run`, `clean --dry-run` не создают и не изменяют ни одного файла в `$YGG_HOME`, `$YGG_SANDBOX`, `$HOME`.
2. `load-state`, `check-pending-journal`, `load-host-config` работают при отсутствии каталогов.
3. В dry-run `setup.nu` **не исполняется**; печатается `[ygg] (dry-run) SETUP <module> (skipped)`.
4. Модуль может разрешить исполнение полем манифеста:
   ```toml
   [setup]
   dry_run_safe = true
   ```
   Тогда `setup.nu` запускается с `YGG_DRY_RUN=true`, как сейчас. `load-module-manifest` отдаёт `setup: { dry_run_safe: bool }` (по умолчанию `false`).

#### Критерии приёмки
* Для свежего `$YGG_HOME` с одним `host.toml`: снимок дерева (`ls **/*` + mtime) до и после `ygg diff`, `ygg status`, `ygg doctor` идентичен.
* `setup.nu` с `touch <маркер>`: после `ygg diff` маркера нет; с `dry_run_safe = true` — есть.

---

### RFC-046: Атомарная блокировка хоста

* **Компонент:** `src/state.nu` · **Приоритет:** P1

#### Проблема
`acquire-host-lock` ([src/state.nu:286](../../src/state.nu)) проверяет существование файла и затем пишет `save -f` — два процесса захватывают блокировку одновременно. `kill -0` с `EPERM` трактуется как «процесс мёртв». Имя `.state/ygg.lock` совпадает с lockfile `$YGG_HOME/ygg.lock`.

#### Требование
1. Файл блокировки — `$YGG_HOME/.state/host.lock`. Сигнатуры `acquire-host-lock`/`release-host-lock` не меняются.
2. Захват: payload пишется во временный файл `host.lock.<pid>.<rand>`, затем создаётся жёсткая ссылка `host.lock` (Unix: `^ln`; Windows: `cmd /c mklink /H`). Успех ссылки = блокировка взята; временный файл удаляется в любом случае.
3. Перехват устаревшей блокировки: `mv host.lock host.lock.stale.<rand>` (выигрывает один процесс), удаление, одна повторная попытка захвата по п.2.
4. `check-process-alive` на Unix: `kill -0` с stderr, содержащим `Operation not permitted`, означает «жив». На Windows: разбор CSV-вывода `tasklist`, точное сравнение колонки PID.
5. Payload дополняется полем `host` (`sys host | get hostname`). Блокировка с другим `host` не перехватывается автоматически: ошибка с указанием удалить файл вручную.
6. Наследие: при захвате существующий `.state/ygg.lock` с живым PID → отказ; иначе файл удаляется.
7. `release-host-lock` удаляет файл, только если `pid` в нём равен PID текущего процесса.

#### Критерии приёмки
* 8 параллельных процессов `nu`, вызывающих `acquire-host-lock`: успех ровно у одного.
* Блокировка с PID 1 (чужой, живой) не перехватывается.

---

### RFC-047: Безопасный `doctor --fix`

* **Компонент:** `src/doctor.nu`, `bin/ygg.nu` · **Приоритет:** P1

#### Требование
1. `main doctor --fix` берёт блокировку (`acquire-host-lock $ygg_home "doctor-fix"`), вызывает `assert-sandbox-home`, передаёт песочницу:
   ```nu
   export def doctor-fix [ygg_home: string, findings: list<record>, --sandbox: string = ""]: nothing -> list<record>
   ```
2. Находки `orphan_link` получают поле `owned: bool`. `owned = true`, если путь есть в `state.links`/`state.copies` **или** цель ссылки (`readlink`, без разыменования) лежит внутри `$YGG_HOME` либо внутри каталога любого модуля из `host.toml`. `--fix` удаляет только `owned = true`; остальные остаются находками уровня `info` и не влияют на код возврата.
3. Fix `state_orphan`: если путь — ссылка, она удаляется через `remove-link-only`; затем удаляется запись. Копия (`state.copies`) на диске остаётся, в отчёте `action` = `record removed, file left in place`.
4. Fix `perm`: поле `action` отражает фактически выполненное (`chmod 0600` / `icacls …`). Текст `fix` для Windows — валидная команда PowerShell.
5. Заголовочный комментарий `src/doctor.nu` приводится в соответствие.

#### Критерии приёмки
* Битая ссылка в `$YGG_SANDBOX/.config`, указывающая вне `$YGG_HOME`, после `doctor --fix` существует.
* Битая ссылка на удалённый файл модуля удалена.

---

### RFC-048: Системные пакетные менеджеры без TTY

* **Компонент:** `src/pkg.nu` · **Приоритет:** P1

#### Требование
1. `const SUDO_MGRS = ["pacman", "apt", "dnf", "zypper"]`. Проверка `sudo-available` перед установкой и удалением выполняется для всех них; при недоступности менеджер попадает в `failed` с сообщением `sudo requires a password; run 'sudo -v' first or use --skip-packages`. `paru` проверки не требует.
2. Окружение при вызове: `apt` — `DEBIAN_FRONTEND=noninteractive`; `brew` — `HOMEBREW_NO_AUTO_UPDATE=1`, `NONINTERACTIVE=1`.
3. `default-pkg-timeout` для `brew`, `apt`, `dnf`, `zypper` — `1800`.
4. Предпроверка установленного (вне мок-режима) — новая функция:
   ```nu
   def missing-pkgs [mgr: string, pkgs: list<string>]: nothing -> list<string>
   ```
   `pacman`/`paru` — `pacman -T`; `brew` — `brew list --formula -1` и `brew list --cask -1`; `apt` — `dpkg-query -W -f='${Status}'`; `dnf`/`zypper` — `rpm -q`. Для остальных возвращает `pkgs`.
5. Нераспознанный дистрибутив Linux: разрешены только менеджеры, найденные в `PATH`.

#### Критерии приёмки
* Мок `sudo`, возвращающий 1, и `[packages] apt = ["curl"]` на `YGG_HOST_OS_OVERRIDE=ubuntu`: `failed` содержит `apt`, команда установки не запускалась.

---

### RFC-049: Аудит Windows ACL по SID

* **Компонент:** `src/doctor.nu`, `src/env.nu` · **Приоритет:** P1

#### Проблема
`is-windows-acl-insecure` ([src/doctor.nu:106](../../src/doctor.nu)) сопоставляет английские имена групп и одиночные маски `(R|F|M|RX)`. На локализованной Windows и для масок `(GR)`, `(R,W)` находок нет.

#### Требование
1. ACL читается через PowerShell в формате `SID|Rights|Type` по строке на запись:
   ```powershell
   (Get-Acl -LiteralPath $p).Access | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value + '|' + $_.FileSystemRights + '|' + $_.AccessControlType }
   ```
2. Чистая функция:
   ```nu
   export def is-windows-acl-insecure [acl_lines: string]: nothing -> bool
   ```
   Возвращает `true`, если есть строка с типом `Allow` и SID из набора `S-1-1-0` (Everyone), `S-1-5-11` (Authenticated Users), `S-1-5-32-545` (Users), `S-1-5-32-546` (Guests), `S-1-5-7` (Anonymous). Значение прав не анализируется.
3. Проверяются `secrets.toml`, все `env.*` в `.state/env/`, `journal.json`, `private_files`.
4. Общий помощник в `src/state.nu`:
   ```nu
   export def restrict-file-access [path: string]: nothing -> bool
   ```
   Unix: `chmod 0600`. Windows: `icacls <path> /inheritance:r /grant:r "<USERNAME>:F"`. Используется `compile-environment`, `begin-journal-transaction`, `doctor-fix`.

#### Критерии приёмки
* `is-windows-acl-insecure "S-1-5-32-545|ReadAndExecute, Synchronize|Allow"` → `true`.
* `is-windows-acl-insecure "S-1-5-21-1-2-3-1001|FullControl|Allow\nS-1-5-18|FullControl|Allow"` → `false`.
* Строка с `S-1-1-0|…|Deny` → `false`.

---

### RFC-050: `ref`/`rev`, детерминированный `ygg.lock`, код возврата `update`

* **Компонент:** `src/git.nu`, `bin/ygg.nu` · **Приоритет:** P1

#### Проблема
Поля `ref`/`rev` из `host.toml` попадают в план ([src/manifest.nu:764](../../src/manifest.nu)) и нигде не используются. `ygg.lock` перезаписывается при каждом `apply` с текущим временем. `ygg update` при конфликтах завершается с кодом 0.

#### Требование
1. Новая функция:
   ```nu
   export def checkout-module-ref [mod_path: string, ref: string, rev: string]: nothing -> record<status: string, message: string, head: string>
   # status ∈ "ok" | "skipped" | "error"
   ```
   `rev` задан → `git fetch --all --tags`, `git checkout --detach <rev>`. Иначе `ref` задан → `fetch`; если `refs/remotes/origin/<ref>` существует — `checkout <ref>` и `pull --rebase`; иначе (тег) — `checkout --detach <ref>`. Оба пусты → `skipped`. Грязное рабочее дерево → `error` без изменений.
2. `update-module`: `pin = true` → пропуск (как сейчас); иначе при заданных `ref`/`rev` вызывается `checkout-module-ref` вместо `pull --rebase`.
3. `ygg add` для модуля с `ref`/`rev` в `host.toml` вызывает `checkout-module-ref` после клонирования.
4. `update-modules` обходит модули из `host.toml` (включая заданные через `path`), а не каталог `modules/`.
5. `generate-ygg-lock`: `timestamp` = дата коммита (`git show -s --format=%cI HEAD`); модули сортируются по имени; файл записывается через временный файл и `mv`; если содержимое не изменилось — не перезаписывается. В dry-run не вызывается.
6. `verify-ygg-lock`: дополнительная ошибка `Module '<name>' has uncommitted changes`, если `git status --porcelain` непуст.
7. `main update`: при любом результате со статусом `conflict` или `error` — код возврата 1 после вывода таблицы.

#### Критерии приёмки
* Модуль с `rev = <sha первого коммита>` и двумя коммитами в origin: после `ygg update` `HEAD` равен этому sha.
* Два последовательных `apply` без изменений: `ygg.lock` побайтно идентичен.
* `apply --locked` с грязным деревом модуля завершается ошибкой.

---

### RFC-051: Герметичность тестов и CI

* **Компонент:** `tests/`, `.github/workflows/ci.yml` · **Приоритет:** P1

#### Проблема
`test_sandbox_without_mock_skips_installation` падает, если в окружении запуска задан `YGG_MOCK_PKG_LOG` — именно так, как требует AGENTS.md. Тест использует `/tmp/sb`. `actions/checkout@v4` работает на Node 20. Purity-шаг CI содержит личные имена.

#### Требование
1. `tests/run.nu` запускает каждый тест с очищенным окружением: все унаследованные `YGG_*` скрываются, кроме `YGG_RUN_HOST_E2E`.
2. `with-temp-ygg` задаёт `YGG_HOME`, `YGG_SANDBOX` и `YGG_MOCK_PKG_LOG = ""`. Тест, которому нужен мок, задаёт путь лога явно внутри своего временного каталога.
3. В `tests/` нет литеральных путей `/tmp/…`; все пути производны от аргумента `home`.
4. Новый мета-тест: `rtk rg` по `tests/*.nu` не находит `"/tmp/`.
5. CI: `actions/checkout@v5`; остальные actions — на версиях с рантаймом Node 24.
6. Purity-шаг: список запрещённого — только обобщённые шаблоны (regex `/home/[a-z0-9_-]+/`, `/data/projects`, `C:\\Users\\`) и имена сторонних утилит из инварианта §2.2 AGENTS.md. Личные имена модулей из workflow удаляются.
7. CI дополнительно проверяет синтаксис сгенерированных nu-completions: вывод `nu bin/ygg.nu completions nu` сохраняется во временный файл и исполняется `nu -c 'source <файл>'` (см. RFC-052).

#### Критерии приёмки
* `YGG_MOCK_PKG_LOG=/x YGG_HOME=/y nu tests/run.nu` — тот же результат, что и без переменных.

---

### RFC-052: Completions из единой таблицы CLI

* **Компонент:** `bin/ygg.nu` · **Приоритет:** P2

#### Проблема
Nu-completions ([bin/ygg.nu:587](../../bin/ygg.nu)) содержат несуществующие позиционные аргументы и флаги, неверные описания, не содержат `--sandbox` и коротких флагов. `nu-complete ygg-modules` для `[[modules]]` возвращает имена колонок.

#### Требование
1. Единственный источник — функция:
   ```nu
   def cli-signature-table []: nothing -> table<command: string, description: string, flags: table<long: string, short: string, takes_value: bool, description: string>, positionals: list<string>>
   ```
   Строится из `scope commands | where name starts-with "main "`. SDK-подкоманды (`onchange`, `merge-json` и прочие, не перечисленные в `ygg --help`) исключаются.
2. Все пять генераторов (`nu`, `zsh`, `bash`, `fish`, `ps1`) строят вывод только из этой таблицы. Ручные списки флагов удаляются.
3. Описания флагов берутся из комментариев в сигнатурах `main *`; у каждого флага он должен быть.
4. `nu-complete ygg-modules` возвращает `open host.toml | get -o modules | default [] | get -o name`.

#### Критерии приёмки
* Для каждой команды множество флагов в выводе `completions nu` равно множеству флагов `scope commands`.
* Вывод `completions nu` парсится: `nu -c 'source <файл>'` завершается с кодом 0.
* Вывод `completions bash` содержит `--sandbox` и не содержит `--force-system-prune` в ветке `add`.

---

### RFC-053: Устойчивость состояния и GC хэшей

* **Компонент:** `src/state.nu`, `src/sdk.nu` · **Приоритет:** P2

#### Требование
1. `load-state`: при нечитаемом `state.json` — ошибка `Cannot parse <path>: <причина>. Refusing to continue; restore from .state/state.json.bak or delete the file.` Пустое состояние возвращается только при отсутствии файла.
2. `save-state` перед заменой копирует предыдущую версию в `.state/state.json.bak`.
3. `onchange` в SDK сохраняет хэш под ключом `setup:<module>:<key>`, где `<module>` — `basename` от `YGG_MODULE_DIR` или новая переменная `YGG_MODULE_NAME`, которую выставляет `run-module-setup`. При чтении, если нового ключа нет, а старый `<key>` есть, значение переносится под новый ключ (миграция, сохраняет кэш).
4. `collect-active-hash-keys` больше не разбирает `setup.nu`. `gc-state-hashes` получает список активных модулей и удаляет:
   - `pkg:<mgr>`, `on_change:<module>:<key>`, `svc:<mgr>:<svc>` — если ключа нет среди активных;
   - `setup:<module>:*` — только если модуля нет в `host.toml`;
   - ключи без известного префикса не удаляются.

   Сигнатура: `gc-state-hashes [ygg_home: string, active_keys: list<string>, active_modules: list<string>, --dry-run]: nothing -> int`.

#### Критерии приёмки
* `state.json` с содержимым `{broken` → `apply` завершается ошибкой, файл не изменён.
* Хэш `setup:m:build.v2:x` переживает GC, пока модуль `m` в `host.toml`.

---

### RFC-054: Стабильный порядок DAG

* **Компонент:** `src/manifest.nu` · **Приоритет:** P2

#### Проблема
`sort-modules-dag` выдаёт модули волнами. Модуль с зависимостью сдвигается после всех независимых, что меняет `module_rank`, приоритет ссылок и порядок слияния `env`/`aliases`.

#### Требование
1. На каждом шаге выбирается **один** готовый модуль с наименьшим исходным индексом в `host.toml`. Без `depends_on` порядок совпадает с `host.toml`.
2. Правило фиксируется в документации: «модуль располагается на своей позиции из `host.toml`, если все его зависимости стоят раньше; иначе — сразу после последней из них».
3. Сообщение о цикле перечисляет только модули цикла.

#### Критерии приёмки
* `[a, b(depends c), c, d]` → `[a, c, b, d]` (текущая реализация даёт `[a, c, d, b]`).

---

### RFC-055: Ужесточение `[services]`

* **Компонент:** `src/sdk.nu`, `src/link.nu`, `bin/ygg.nu` · **Приоритет:** P2

#### Требование
1. Допустимые менеджеры: `systemd-user`, `systemd-system`, `launchd`, `windows`. Иной ключ — ошибка `preflight-check`; ветка `[$manager, $action, $service]` в `build-service-cmd` удаляется.
2. `systemd-system`: команда с префиксом `sudo`, перед ней проверка RFC-048.
3. `enable` выполняется один раз: после успеха в `state.hashes` пишется `svc:<mgr>:<svc> = "enabled"`; при наличии ключа действие пропускается. `--force` сбрасывает кэш.
4. `service-trigger-matches`: совпадение, если триггер равен `key` ссылки, либо `dest_raw`, либо развёрнутому `dest`. Сопоставления по `basename` и по суффиксу удаляются.
5. Имя сервиса проверяется по `^[A-Za-z0-9@._:-]+$` в `preflight-check`.
6. Действия сервисов — шаг журнала `services`. Сбой любого действия добавляется в итоговый список ошибок `apply` (код возврата 1).

#### Критерии приёмки
* Второй `apply` без изменений не пишет `service:` в мок-лог.
* `[services.rm] enable = ["x"]` → ошибка preflight, мок-лог пуст.

---

### RFC-056: `PATH` и валидация имён в компиляторе окружения

* **Компонент:** `src/env.nu`, `src/link.nu` · **Приоритет:** P2

#### Требование
1. `plan.path` попадает во все шелл-файлы: `env.nu` — `$env.PATH = ($env.PATH | prepend [<...>] | uniq)`; `env.zsh` — `path=(<...> $path); typeset -U path`; `env.fish` — `fish_add_path -g <...>` по записи. Пути разворачиваются через `expand-target-path`.
2. `preflight-check` отклоняет имена переменных окружения, не соответствующие `^[A-Za-z_][A-Za-z0-9_]*$`, и имена алиасов, не соответствующие `^[A-Za-z_][A-Za-z0-9_.-]*$`. Ключ ошибки — `env` / `aliases`.
3. `aliases.nu`: значение алиаса экранируется.

#### Критерии приёмки
* `[env] "A; rm -rf ~" = "x"` → ошибка preflight.
* `path = ["~/.local/bin"]` → `env.fish` содержит `fish_add_path -g <sandbox>/.local/bin`.

---

### RFC-057: Мелкие исправления

* **Приоритет:** P3

1. `main remove` вызывает `assert-sandbox-home`.
2. `check-tools`: версия Nushell сравнивается как пара `(major, minor)` с `(0, 116)` при любом `major`.
3. `eval-scope-expression`: комментарий о порядке `origin_rank` в `resolve-effective-plan` приводится в соответствие (порядок ключей манифеста).
4. `build-service-cmd` для `windows`: имя сервиса передаётся аргументом (`Set-Service -Name $args[0]`), а не интерполяцией в строку команды.

---

### RFC-058: Синхронизация документации

* **Приоритет:** P3

1. В спецификации Фазы 3 статус каждого RFC — `Реализовано (<sha>)` либо `Реализовано частично → RFC-0NN`; в плане Фазы 3 отмечаются чекбоксы.
2. RFC-026 Фазы 3: имя файла `host.lock`, контракт флага `--no-lock` без `: bool = false`.
3. RFC-027 Фазы 3: пометка «заменён RFC-043».
4. Рабочий каталог в планах — «корень репозитория `ygg`» без абсолютного пути.
5. AGENTS.md: ссылки на спеку и план Фазы 4; формулировка об изоляции тестов согласуется с RFC-051 п.2.

---

## 3. Что не входит

* Откат транзакций (rollback) — осознанно заменён roll-forward (RFC-043).
* Защита блокировки от переиспользования PID — принятое ограничение; снижается проверкой `host`.
* Кэширование ответов провайдеров секретов между запусками шелла.
* Новые пакетные менеджеры и новые команды CLI.

## 4. Открытые вопросы (требуют решения владельца)

1. **RFC-042, значение по умолчанию.** `materialize = false` буквально исполняет цель RFC-034, но замедляет старт шелла и может вызывать запрос разблокировки провайдера. Альтернатива — `true` по умолчанию с `warn` в `doctor`.
2. **Таск-раннер.** Репозиторий, AGENTS.md и CI используют `just`; глобальное правило хоста требует `mise` как единственный раннер. В Фазу 4 миграция не включена; план вызывает `nu tests/run.nu` напрямую.
3. **RFC-045 п.3.** Отключение `setup.nu` в dry-run убирает из `ygg diff` строки SDK-операций (`onchange`, `safe-link`) для модулей без `dry_run_safe = true`.

## 5. Порядок внедрения

| Этап | RFC | Результат |
| :--- | :--- | :--- |
| **4.1 Безопасность (P0)** | 051 (п.1–4), 045, 044, 041, 042, 043 | Герметичные тесты; нет исполнения чужих команд, плейнтекста, мутаций из read-only и песочницы |
| **4.2 Надёжность (P1)** | 046, 049, 047, 048, 050 | Атомарная блокировка, корректные ACL, рабочие `ref`/`rev` |
| **4.3 Качество (P2–P3)** | 053, 054, 055, 056, 052, 057, 051 (п.5–7), 058 | Достоверные completions, стабильный порядок, синхронные документы |
