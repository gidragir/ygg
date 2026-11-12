# Баг-репорт: открытые дефекты после Фазы 4

Дата: 2026-11-12. Состояние: `main` @ `69a22e2` (после слияния `phase-4-hardening`), `rtk nu tests/run.nu` → `PASS (225 tests passed)`.
Найдено финальным ревью всей ветки и re-review волны исправлений. Дефекты не блокировали слияние.
Ревью репорта и исправления BUG-1..4: 2026-11-12, `rtk nu tests/run.nu` → `PASS (229 tests passed)`.

---

## BUG-1. Экранирование аргументов ленивых секретов для nu не обрабатывает `"` — ИСПРАВЛЕНО

- **Серьёзность:** Important (класс инъекции, но вход только из собственного `secrets.toml` пользователя).
- **Где:** `src/env.nu`, `quote-lazy-arg`, ветка nu.
- **Суть:** паттерн `'\"'` в одинарных кавычках — сырая строка из двух символов (`\` + `"`), поэтому одиночный `"` не экранировался. Значение `a'b"c\d` давало `"a'b"c\\d"` (`unclosed_delimiter`), значение вида `x'"; touch pwned; "` исполнялось при загрузке `env.nu`.
- **Уточнение ревью:** замена в коде была `'\\\"'` (4 символа), а не `'\"'`. Исправление только паттерна давало парсящуюся, но испорченную строку с лишним `\`. Исправлены оба аргумента: `str replace --all '"' '\"'`.
- **Тесты:** `test_lazy_provider_quotes_mixed_quotes_round_trip` — аргумент с `'`, `"`, `\`, `$(...)` проходит туда-обратно через `source` реальных `env.nu`/`env.zsh`/`env.fish`, маркер не создаётся. Старый тест `test_lazy_provider_quotes_every_argv_element` файлы не загружал, а относительный маркер писался бы в cwd вызывающего; теперь он выполняется с cwd = временный `home`.

## BUG-2. `[services.launchd]` непригоден из-за regex имени сервиса — ИСПРАВЛЕНО

- **Серьёзность:** Important (дефект спеки RFC-055 п.5).
- **Где:** `src/sdk.nu` (`build-service-cmd`), спека RFC-055.
- **Суть:** `launchctl load -w` требует путь к plist, `kickstart -k` — таргет `gui/<uid>/<label>`; regex имени не пропускает `/`. Путь в имени падал в preflight, голый label проходил preflight, но падал в рантайме. Требование `~` из исходной версии неверно: argv идёт без шелла, `~` не раскрылся бы в любом случае.
- **Исправление:** в манифесте указывается только label; `enable` → `launchctl load -w <home>/Library/LaunchAgents/<label>.plist`, `reload`/`restart` → `launchctl kickstart -k gui/<uid>/<label>`. `load -w` оставлен вместо `bootstrap`: `bootstrap` неидемпотентен для уже загруженного агента (повтор после `--force` падает). Спека RFC-055: п.5 закрепляет запрет ведущего `-`, добавлен п.7 и критерий приёмки.
- **Тесты:** `test_service_launchd_label_builds_plist_and_domain_target`, `test_preflight_launchd_accepts_label_rejects_path`. На реальном macOS не проверено.

## BUG-3. `add --dry-run` для git-источника зависит от Unix-утилиты `mktemp` — ИСПРАВЛЕНО

- **Серьёзность:** Minor (кроссплатформенность, инвариант Windows Non-Admin).
- **Где:** `src/git.nu`, временный каталог `ygg-add-*`.
- **Уточнение ревью:** предложенный `$nu.temp-path` в nu 0.116 не существует (есть `$nu.temp-dir`), а `path join` + `random chars` неатомарен.
- **Исправление:** встроенный (uutils) `mktemp --directory --tmpdir ygg-add-XXXXXXXX` — атомарно, без внешней утилиты. Покрыто `test_cli_add_dry_run_and_preflight_rollback`.

## BUG-4. Сбой `git status` трактуется как «дерево чистое» — ИСПРАВЛЕНО

- **Серьёзность:** Important (потеря данных), а не Minor.
- **Уточнение ревью:** косметической части нет: в nu 0.116 `[] | first` возвращает `nothing`, и `| default "unknown error"` в `update-module` уже срабатывает.
- **Суть:** код возврата `git status --porcelain` игнорировался:
  - `update-module`: при сбое status `is_dirty = false`, stash пропускался; при сбое `pull`/`checkout` ветка восстановления делала `reset --hard $head_before` и уничтожала незакоммиченные изменения (обход инварианта «never reset after failed stash»). Пустой `head_before` при сбое `rev-parse` давал `reset --hard ""`.
  - `assert-module-clean`: при сбое status дерево считалось чистым, `remove-module` выполнял `rm -rf` грязного модуля (то же при замене в `add`).
  - `modules-status` и проверка lock-файла молча скрывали сбой.
- **Исправление:** `update-module` возвращает `error` при сбое `rev-parse HEAD` или `status`, ничего не трогая; `assert-module-clean` бросает ошибку; `modules-status` показывает модуль грязным; проверка lock добавляет ошибку `git status failed`.
- **Тест:** `test_failed_git_status_never_destroys_local_changes` (шим `git`, падающий только на `status`): до исправления локальное изменение терялось.

---

## Отложенные замечания (не дефекты, для планирования)

- Файлы окружения (`env.*`) создаются с umask 022 и затем переводятся в 0600: короткое окно 0644 при первом создании с литеральными секретами. Писать через tmp → `restrict-file-access` → `mv`, как журнал.
- `read-windows-acl`: `Translate([SecurityIdentifier])` падает на «осиротевшем» SID, весь вызов даёт ложный `acl_unreadable`. Нужен try на каждую запись ACL.
- `collect-active-hash-keys` (`src/state.nu`) дублирует `parse-services-tree` из `src/link.nu`; ключ `svc:<mgr>:<svc>` должен иметь один источник.
- `ygg doctor` при повреждённом `state.json` завершается сырой ошибкой `Cannot parse …` вместо диагностической строки.
- Тело nu-алиаса: экранируется только перенос строки, `;` и `|` остаются живыми (граница доверия та же, что у `setup.nu`).
- `PATH` не экспортируется в `env.ps1` (спека перечисляет только nu/zsh/fish).
- PowerShell-completions проверены только структурно, в реальном pwsh не запускались.
- Ссылки `ref`/`rev`: `ygg add` при сбое checkout после клонирования оставляет незарегистрированный клон в `modules/`.
- В планах Фазы 1–2 остались ~40 абсолютных путей `/data/projects/ygg` (в командах).
- CI: на ветке не запускался (триггер `push` не покрывает feature-ветки), прогонов Windows/macOS не было; `nushell/setup-nu` заменён на `hustcer/setup-nu@v3` (оригинальная ссылка давала 404).
- `context-init update` внутри worktree записывает имя worktree в `AGENTS.md` и `.context-init/`; запускать из основного чекаута.
