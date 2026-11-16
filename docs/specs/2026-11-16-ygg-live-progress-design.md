# RFC-060: Однострочный живой прогресс выполнения команд (Live Single-Line Status)

* **Дата:** 2026-11-16
* **Статус:** черновик, на утверждении
* **Затрагивает:** новый `src/progress.nu`, `src/pkg.nu` (`run-with-timeout`, `install-packages`, `prepare-provider-environment`, `prune-unused-packages`), `src/container.nu` (`run-compose`, `run-container-step`, `upgrade-containers`, `down-module-stacks`), `src/git.nu` (`stage-module`, `checkout-module-ref`, `update-module`), `src/sdk.nu` (`run-module-setup`, `run-link-hooks`, `run-service-actions`), `src/link.nu` (`backup-with-notice`), `bin/ygg.nu` (`apply`, `upgrade`, `update`, `add`, `remove`), `tests/`

---

## 1. Зачем

Сейчас долгие операции `ygg` выполняются вслепую:
* `run-with-timeout` ([src/pkg.nu](../../src/pkg.nu#L84-L111)) выполняет команды внутри `job spawn` через `^$bin ...$args | complete`, полностью буферизуя `stdout` и `stderr` до завершения процесса (для контейнеров таймаут по умолчанию — 600 с на стек).
* `git clone`, `git fetch`, `git pull` в [src/git.nu](../../src/git.nu) и `setup.nu` в [src/sdk.nu](../../src/sdk.nu#L352) также используют `| complete` без вывода статуса.
* Оркестратор [apply-plan](../../bin/ygg.nu#L345-L537) и команды `upgrade` / `update` / `add` / `remove` не выводят промежуточных сообщений о фазах и текущем элементе, печатая только итоговую строку после завершения всех шагов.

В результате при скачивании образов (`docker compose pull`), установке пакетов (`pacman` / `paru` / `cargo` / `uv`), клонировании репозиториев или выполнении `setup.nu` пользователь не видит, работает ли `ygg` или завис, и на каком шаге находится процесс.

## 2. Цели, не-цели, анти-цели

**Цели**
1. Работает из коробки при запуске `ygg apply`, `ygg upgrade`, `ygg update`, `ygg add`, `ygg remove` без каких-либо флагов и пользовательской конфигурации.
2. В любой момент времени пользователь видит текущую фазу, обрабатываемый элемент (модуль, пакет/менеджер, стек, репозиторий), прошедшее время и последнюю строку вывода выполняемой команды.
3. Терминал остаётся чистым: активный статус перерисовывается в одной строке (TTY), а полный вывод подпроцесса показывается только при сбое.
4. Работает на Linux, macOS и Windows 11/Server (Non-Admin) на чистом Nushell (`>= 0.116`) без внешних зависимостей.
5. В не-TTY окружении (пайпы, редирект в файл, CI, тесты, `NO_COLOR`) не выводит ANSI-последовательности и сохраняет читаемый построчный лог.

**Не-цели**
* Полноэкранный TUI (alternate screen) и сложные многострочные дашборды.
* Парсинг специфических прогресс-баров отдельных пакетных менеджеров (`pacman`, `cargo`, `docker`).
* Выделение полноценного PTY под дочерние процессы.

**Анти-цели (провал, даже если «работает»)**
* Поломка `stdout` у команд, отдающих данные или отчёты (`ygg status`, `ygg diff`, `ygg doctor`), а также появление вывода прогресса в `--dry-run`.
* Потеря текста `stderr` при ошибках (в `error make` и итоговой сводке), смешивание `stdout`/`stderr` или поломка `kill-job-tree` при таймауте.
* Утечка временных лог-файлов после штатного завершения, ошибки, `Ctrl+C` или таймаута.
* Заметное замедление коротких служебных проверок (`pacman -T`, `compose version`, `git rev-parse`, `git status --porcelain`).

## 3. Ограничения проекта

* **Инвариант №1 (`ZERO HOST MUTATION`):** временные файлы прогресса создаются строго в системном временном каталоге (`mktemp -t --suffix .log ygg-proc-XXXXXX` — системный tmp), никогда внутри `$HOME`, `$YGG_HOME` или каталогов модулей. В песочнице с моками (`YGG_MOCK_PKG_LOG`) прогресс не запускает реальных подпроцессов и не меняет формат мок-логов.
* **Инвариант №4 (Кроссплатформенность):** очистка и возврат каретки `\r\x1b[2K` и определение ширины терминала (`term size`) работают в современных терминалах Linux, macOS и Windows (Windows Terminal / ConPTY) без платформозависимых бинарников. При отсутствии TTY, при `TERM == "dumb"` или при непустом `NO_COLOR` управляющие последовательности не используются.
* **Обратная совместимость контракта:** возвращаемый тип `run-with-timeout` (`record<exit_code: int, stdout: string, stderr: string, timed_out: bool>`) и раздельность потоков `stdout`/`stderr` сохраняются полностью.

## 4. Архитектура решения

Выбран **однострочный inline-статус с хвостом лога (Live Single-Line Status)**.

### 4.1. Канал вывода и автоопределение TTY
Весь прогресс выводится строго в **`stderr`** (`print -e -n` / `print -e`), чтобы не смешиваться с `stdout`.

Определение режима рендеринга в `is-tty-progress`:
* **TTY-режим:** `(is-terminal --stderr)` и `($env.TERM? | default "") != "dumb"` и `($env.NO_COLOR? | default "") == ""`.
* **Plain-режим (non-TTY):** все остальные случаи (редирект, пайп, CI, автоматические тесты, `TERM=dumb`, заданный `NO_COLOR`).

### 4.2. Формат отображения

**В TTY-режиме:**
* Во время выполнения шага перерисовывается одна текущая строка (`\r\x1b[2K`), время округляется до целых секунд `(<elapsed_sec>s)`:
  ```text
  ⠋ [containers] up ai-dotfiles/infra | Pulling postgres:16 ... (14s)
  ```
  (если хвост лога пуст, разделитель `|` опускается: `⠋ [containers] up ai-dotfiles/infra (14s)`).
* Разбор хвоста в `read-last-log-line` / `sanitize-log-line`:
  * Входной срез разбивается по `[\r\n]+` строго **ДО** вызова `ansi strip` (в Nushell 0.116 `ansi strip` удаляет `\r`, из-за чего все промежуточные `\r`-кадры склеились бы в одну строку до выделения последнего кадра).
  * Каждая строка прогоняется через `sanitize-log-line`: `ansi strip`, замена `\t` на пробел, удаление оставшихся управляющих символов и `str trim`; выбирается последний непустой сегмент.
* Ширина строки определяется через `try { (term size).columns } catch { 80 }` с нижней границей (clamp, например `[$cols, 20] | math max`). `format-progress-line` обрезает хвост лога (а на сверх-узких терминалах и префикс) с защитой от отрицательной длины среза, чтобы итоговая строка никогда не переносилась на новую строку и не ломала `\r`.
* По завершении элемента строка перезаписывается (`\r\x1b[2K`) и фиксируется переводом строки (`\n`) с точностью до десятых секунды (`format-progress-done`):
  ```text
  [ok] [containers] up ai-dotfiles/infra (18.4s)
  ```
  или при ошибке:
  ```text
  [fail] [containers] up ai-dotfiles/infra (4.1s)
  ```
* Для быстрых шагов без подпроцессов (например, `preflight`, `links`) печатается компактный статус фазы через `progress-step`.
* **Защита от разрыва строки при промежуточном выводе:** перед любым промежуточным выводом в `stdout` или `stderr` (например, `backup-with-notice` в `src/link.nu`, предупреждения в `run-link-hooks`, `run-service-actions`, `prepare-provider-environment`, `container-warn-down`, а также итоговый вывод и ошибки в `bin/ygg.nu`) активная строка прогресса очищается через `progress-clear-line` (`\r\x1b[2K` в `stderr` только в TTY-режиме; на практике внутри `run-with-timeout` финальная строка уже закрыта `\n`, но `progress-clear-line` гарантирует чистоту вывода для любых асинхронных/промежуточных сообщений).

**В Plain-режиме (non-TTY):**
* При старте долгой операции: `[containers] up ai-dotfiles/infra...`
* По завершении: `[ok] [containers] up ai-dotfiles/infra (18.4s)` (без промежуточных тиков и без `\r\x1b[2K`).

### 4.3. Потоковое чтение в `run-with-timeout`
В Nushell `^$bin ...$args | complete` блокирует доступ к выводу до EOF, а `^$bin ...$args o+e>| lines` теряет точный `$env.LAST_EXIT_CODE` внешней команды при сбоях. Кроме того, в Nu 0.116 файловый редирект `o> ... e> ...` **не подавляет** исключение при ненулевом коде возврата, а в блоке `catch` после ошибки запуска отсутствующего бинарника `$env.LAST_EXIT_CODE` равен `1` (не `127`) и файлы вывода пусты.

Решение строится через опциональные параметры `--label: string = ""` и `--no-tty-progress` в `run-with-timeout`:

1. **Короткие служебные команды (`$label == ""`):**
   * Выполняются по-прежнему без создания временных файлов и без вывода прогресса (`pacman -T`, `compose version`, `compose ls`, `git rev-parse`, `git status --porcelain`, `git show-ref`, `git stash`, `git checkout`).
   * При `$timeout_sec <= 0` и `$label == ""` сохраняется **синхронный путь без `job spawn`** (`| complete` напрямую), что сохраняет совместимость с контрактом и тестами `tests/test_pkg_git.nu`.

2. **Долгие команды с прогрессом (`$label != ""`):**
   * Создаются **два независимых** временных файла в системном tmp кроссплатформенным вызовом uutils `mktemp` (Nu 0.116):
     ```nushell
     let out_log = (mktemp -t --suffix .log ygg-proc-XXXXXX)
     let err_log = (mktemp -t --suffix .log ygg-proc-XXXXXX)
     ```
   * Для уменьшения буферизации дочерних Python/Compose CLI в окружении вызова выставляются `PYTHONUNBUFFERED: "1"` и `COMPOSE_PROGRESS: "plain"` (через `with-env` с сохранением пользовательских переопределений, если заданы).
     > **Ограничение блочной буферизации `stdout`:** при редиректе в обычный файл (не-TTY) C `stdio` и Python переводят `stdout` в блочную буферизацию 4–8 КБ, тогда как `stderr` остаётся небуферизованным. Поэтому прогресс инструментов, пишущих в `stdout` без принудительного `flush`, может обновляться порциями по 4–8 КБ (для `git --progress` и `docker compose` прогресс идёт в `stderr`, обновляясь мгновенно).
   * В `job spawn` запуск оборачивается в `try/catch` с разделением потоков и явной фиксацией кода `127` при отсутствии бинарника:
     ```nushell
     let jid = (job spawn {
         let r = (try {
             ^$bin ...$args o> $out_log e> $err_log
             { exit_code: ($env.LAST_EXIT_CODE? | default 0), spawn_err: "" }
         } catch { |e|
             let code = ($env.LAST_EXIT_CODE? | default 1)
             let missing = (which $bin | is-empty)
             { exit_code: (if $missing { 127 } else { $code }), spawn_err: $e.msg }
         })
         $r | job send 0 --tag $tag
     })
     ```
   * Основной поток входит в polling-цикл с шагом **250 мс** (`job recv --tag $tag --timeout 250ms`):
     * **При `$timeout_sec > 0`:** цикл продолжается до получения результата от `job recv` либо пока `((date now) - $t0) >= ($timeout_sec * 1sec)` (в этом случае вызывается `kill-job-tree $jid`).
     * **При `$timeout_sec <= 0` (отключённый таймаут — например, `cargo`, `paru`, `pacman`, `setup.nu`):** цикл работает без лимита времени до получения сообщения от `job recv`.
     * На каждом тике в TTY-режиме (если не передан `--no-tty-progress`) опрашивается хвост `$err_log` и `$out_log`: читается последняя актуальная непустая строка (при наличии вывода в обоих потоках выбирается поток с более свежим временем модификации либо `$err_log` с fallback на `$out_log`), перерисовывается статусная строка `format-progress-line`.
     * **Безопасное чтение хвоста ~4 КБ (UTF-8):** файл открывается в бинарном режиме (`open --raw`), берётся срез последних ~4096 байт, на левой границе среза отбрасываются ведущие байты продолжения UTF-8 (`0x80..0xBF`, не более 3 байт), чтобы срез по середине многобайтового символа (кириллица, спиннеры/эмодзи) не повреждал декодирование в строку.
   * По завершении (успех, ненулевой код, таймаут или исключение):
     * Независимо считываются `$out_log` и `$err_log` (в поля `stdout` и `stderr` возвращаемой записи соответственно; если `stderr` пуст при ошибке запуска с непустым `spawn_err`, в `stderr` подставляется `$r.spawn_err`). Это сохраняет полную независимость потоков, критичную для `WINGET_OK_CODES` и `run-module-setup`.
     * Оба временных файла удаляются в `try { rm -f $out_log } catch {}` и `try { rm -f $err_log } catch {}`.
     * В `stderr` фиксируется финальная строка (`[ok]` / `[fail]` / `[timeout]`).

### 4.4. Интерактивный ввод (`sudo` / `paru` / `ask-containers`) и `--dry-run` / `diff`
* **Защита интерактивного ввода при `sudo` / `paru`:** при запросе пароля внутри `run-with-timeout` 250-миллисекундный тикер перетирал бы приглашение пароля через `\r\x1b[2K`. Вместо нерабочей «очистки перед вызовом» применяется следующий механизм:
  * При интерактивном `stdin` (`(is-terminal --stdin)` и `($env.YGG_NONINTERACTIVE? | default "") != "1"`) перед выполнением шагов, использующих `SUDO_MGRS` (`pacman`, `apt`, `dnf`, `zypper`), `paru` или `systemd-system` (`sudo systemctl ...`):
    1. Если `^sudo -n true` неуспешен (и `sudo` есть в `PATH`), перед запуском прогресса выполняется явный прогрев кэша прав `^sudo -v` в обычном интерактивном терминале (без тикера и `\r`-отрисовки).
    2. Если `sudo -n true` по-прежнему недоступен или команда сама может потребовать интерактивного подтверждения на TTY (например, `paru` при ревью PKGBUILD / промптах), для такого вызова `run-with-timeout` передаётся `--no-tty-progress` (отключение `\r`-перерисовки с переходом на Plain-формат старт/финиш), чтобы не ломать терминальный ввод.
* **`ask-containers` в `ygg add`:** интерактивный запрос `ask-containers` ([bin/ygg.nu](../../bin/ygg.nu#L170)) выполняется после завершения `stage-module` (клонирования) и строго **до** `apply-plan`, когда ни один тикер прогресса не активен.
* **Полное отключение в `--dry-run` и `ygg diff`:** при флаге `--dry-run` (включая `ygg diff`, `ygg apply --dry-run`, `ygg add --dry-run`, `ygg upgrade --dry-run`) передача `--label` и вызовы `progress-step` полностью отключены; команды не создают временных файлов и не выводят строк прогресса.

## 5. Точки интеграции по подсистемам

Новый модуль `src/progress.nu` экспортирует:
* `is-tty-progress [] -> bool`
* `sanitize-log-line [line: string] -> string`
* `read-last-log-line [path: string] -> string`
* `read-progress-tail [err_path: string, out_path: string] -> string`
* `progress-clear-line [] -> nothing`
* `format-progress-line [spinner: string, label: string, tail: string, elapsed_sec: int, width: int] -> string`
* `format-progress-done [status: string, label: string, elapsed_sec: float] -> string`
* `progress-step [phase: string, msg: string] -> nothing` — для шагов без долгого подпроцесса (`preflight`, `links`, итоговые сводки).

Карта интеграции:

| Подсистема / файл | Операции с `--label` / статусом и особенности |
| :--- | :--- |
| `src/pkg.nu` | • `run-with-timeout`: опциональные `--label: string = ""`, `--no-tty-progress`<br>• `install-packages` (`run-install-argv`): `[packages] <mgr>: <pkgs>`<br>• `prepare-provider-environment` (`mise trust --yes ...`): `[packages] prepare <mgr>`<br>• `prune-unused-packages`: `[packages] prune <mgr>: <pkg>` (`pkg-uninstall-argv`) и `[packages] unuse mise: <pkg>` (`mise unuse`)<br>• Прогрев `^sudo -v` / `--no-tty-progress` для `SUDO_MGRS` и `paru` |
| `src/container.nu` | • `run-compose`: добавление `--label: string = ""`, проброс в `run-with-timeout` с `COMPOSE_PROGRESS=plain`<br>• `run-container-step`: `[containers] <action> <module>/<project>` (`down` / `up`)<br>• `upgrade-containers`: `[containers] <step> <module>/<project>` (`pull` / `build` / `down` / `up`)<br>• `down-module-stacks`: `[containers] down <module>/<project>` |
| `src/git.nu` | • `stage-module`: `git clone --progress` с `--label $"[git] clone ($source)"`<br>• `checkout-module-ref`: `git fetch --progress --all --tags` (`[git] fetch <mod>`) и `git pull --progress --rebase` (`[git] pull <mod>`)<br>• `update-module`: `git pull --progress --rebase` (`[git] pull <name>`)<br>• Короткие команды (`rev-parse`, `status --porcelain`, `show-ref`, `stash`, `checkout`, `rebase --abort`, `reset`) остаются на `\| complete` |
| `src/sdk.nu` | • `run-module-setup`: перевод `^nu -I $ygg_src_dir $setup_script \| complete` на `run-with-timeout ... 0 --label $"[hooks] ($mod_name) setup.nu"` (при `$is_dry == "true"` — без `--label`). Политика вывода: при активном `--label` дублирующий сырой `stdout` на успехе (`exit_code == 0`) подавляется; при сбое (`exit_code != 0`) полный вывод (`stderr`, а при его пустоте `stdout`) печатается в `stderr` и пробрасывается в `error make`<br>• `run-link-hooks`: `run-with-timeout ["nu", "-c", $cmd] 30 --label $"[hooks] ($modules): ($keys \| str join ', ')"`<br>• `run-service-actions`: `run-with-timeout $cmd_argv 30 --label $"[services] ($action) ($svc) \(($mgr)\)"` (с защитой `sudo` для `systemd-system`) |
| `src/link.nu` | • `backup-with-notice`: вызов `progress-clear-line` перед `print "[ygg] Backed up ..."` |
| `bin/ygg.nu` | • `progress-step` для заголовков/итогов фаз в `apply-plan` (строго при `not $dry_run`), `main upgrade` (при `not $dry_run`), `main update`, `main add` (при `not $dry_run`), `main remove`<br>• `progress-clear-line` перед финальным выводом/ошибками |

## 6. Обработка ошибок и отмена (Ctrl+C / таймаут)

* **Таймаут (`$timeout_sec > 0`):** при истечении лимита вызывается `kill-job-tree $jid`; строка статуса в `stderr` фиксируется как `[timeout] <label> (<timeout_sec>s)`; оба временных лог-файла удаляются; возвращается `{ exit_code: 124, stdout: $out_text, stderr: ..., timed_out: true }`.
* **Ошибка команды (`exit_code != 0`):** строка фиксируется как `[fail] <label> (<elapsed>s)`; собранные `stdout` и `stderr` передаются в возвращаемой записи в стандартную обработку ошибок `ygg` (`print -e` / `error make`), чтобы пользователь видел причину сбоя полностью.
* **Прерывание (`Ctrl+C` / исключение в polling-цикле):** весь polling-цикл оборачивается в `try { ... } catch { |e| ... }`. В блоке `catch`:
  1. Гарантированно вызывается `kill-job-tree $jid` для уничтожения дочернего дерева процессов.
  2. В TTY-режиме очищается текущая строка (`progress-clear-line`) и при необходимости фиксируется статус отмены/прерывания (`[aborted] <label> (<elapsed>s)` в `stderr`).
  3. Гарантированно удаляются оба временных файла (`try { rm -f $out_log } catch {}` и `try { rm -f $err_log } catch {}`). **Оговорка для Windows:** при мгновенном завершении через `taskkill /T /F` дочерний процесс может удерживать файловый дескриптор лога доли миллисекунды после возврата; `try/catch` вокруг `rm -f` защищает от падения очистки, если ОС временно заблокировала удаление файла в `$nu.temp-dir`.
  4. Исходное исключение пробрасывается дальше (`error make $e`).

## 7. Тестирование

1. **Юнит-тесты `src/progress.nu`:**
   * `sanitize-log-line`: удаление `\r`, `\n`, `\t`, ANSI CSI-кодов (`\x1b[...m`, `\x1b[2K`).
   * `read-last-log-line`: пустой файл, несуществующий файл, многострочный файл, файл с `\r`-перезаписями без `\n` (проверка, что сплит происходит **до** `ansi strip` и возвращается последний кадр), а также срез хвоста >4 КБ на границе многобайтовых UTF-8 символов.
   * `format-progress-line` и `format-progress-done`: форматирование `(14s)` / `(18.4s)` и корректная обрезка под ширину `width`, включая узкие терминалы (clamp ширины без падения).
   * `is-tty-progress`: проверка возврата `false` при `NO_COLOR=1`, `TERM=dumb` и отсутствии TTY.
2. **Тесты `run-with-timeout --label`:**
   * Возврат точного `exit_code`, раздельных `stdout` / `stderr` (в том числе при ненулевом коде возврата, имитирующем `WINGET_OK_CODES` или частично успешный CLI) и `timed_out: false`.
   * Отсутствующий бинарник: возврат `exit_code: 127`, непустого `stderr` с текстом ошибки и `timed_out: false`.
   * Plain-режим (non-TTY) и `NO_COLOR=1`: проверка через подпроцесс, что в `stderr` выводятся только чистые строки без `\r` и ANSI-последовательностей `\x1b[`.
   * Обработка `\r`-only потока через реальный подпроцесс `nu -c` с `run-with-timeout --label` (поскольку моки `YGG_MOCK_PKG_LOG` обходят `run-with-timeout`, реальный `nu -c` необходим для сквозной проверки чтения хвоста `$err_log`/`$out_log` и разбора `\r`).
   * Работа при `$timeout_sec <= 0` с `--label != ""` (через `job spawn` + polling) и сохранение синхронного пути без `job spawn` при `$timeout_sec <= 0` и `--label == ""`.
   * Возврат `exit_code: 124`, `timed_out: true` и срабатывание `kill-job-tree` при превышении таймаута.
   * Имитация исключения / прерывания (`Ctrl+C`) в цикле опроса: проверка срабатывания `kill-job-tree` и удаления обоих временных файлов.
   * Отсутствие остаточных `ygg-proc-*.log` в `$nu.temp-dir` после успеха, ошибки, таймаута и отмены.
3. **Регрессионный прогон:**
   * Полный прогон `nu tests/run.nu` в изолированной песочнице: проверка, что `stdout` read-only команд (`status`, `diff`, `doctor`) и режим `--dry-run` не содержат строк прогресса, а все существующие тесты проходят без изменений.
