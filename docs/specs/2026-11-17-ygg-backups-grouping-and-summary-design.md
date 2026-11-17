# RFC-063: Группировка бэкапов запуска, сводка и отображение в `status`

* **Дата:** 2026-11-17
* **Статус:** черновик, на утверждении
* **Issues:** #10
* **Затрагивает:** `src/state.nu` (`backup-existing`, `rotate-backups`, чтение/индекс бэкапов), `src/link.nu` (`backup-with-notice`, `apply-links`, `unlink-module`), `src/sdk.nu` (`run-module-setup`, `safe-link`), `src/git.nu` (`register-staged-module`), `src/progress.nu` (`format-apply-summary`), `bin/ygg.nu` (`main add`, `apply-plan`, `main remove`, `main status`), `tests/`

---

## 1. Зачем

При первой установке модуля (`ygg add`) или применении нескольких модулей (`ygg apply`) существующие на хосте конфиги переносятся в `$YGG_HOME/.state/backups/`. Сейчас `backup-existing` (`src/state.nu`) генерирует новый `timestamp` при каждом вызове. Из-за этого:

* один запуск `add`/`apply` создаёт десятки отдельных каталогов `<timestamp>/`, и поиск нужного конфига (например, `gh`) превращается в перебор папок;
* `rotate-backups` (по умолчанию `max_count = 20`) считает каталоги верхнего уровня и за один крупный прогон вытесняет предыдущие бэкапы;
* в конце `add`/`apply` и в `ygg status` нет компактной сводки того, какие пути и куда были перенесены.

**Критерий успеха:** все бэкапы одного запуска `add`/`apply`/`remove` (включая вызовы `safe-link` из `setup.nu`) складываются в один каталог `.state/backups/<timestamp>/`; в конце запуска печатается компактный список забэкапленных путей; `ygg status` отображает недавние бэкапы без поломки `--json`.

---

## 2. Цели, не-цели, анти-цели

**Цели**
1. Группировать все бэкапы одного мутирующего запуска (`add`, `apply`, `update`, `remove`) в единый каталог `.state/backups/<timestamp>/`.
2. Учитывать верхнеуровневые забэкапленные пути (цели хоста), включая бэкапы из дочерних скриптов `setup.nu` (`safe-link`) и staging-замены каталога модуля (`register-staged-module`).
3. Безопасно разрешать коллизии, если один и тот же путь бэкапится повторно внутри одного запуска.
4. Выводить компактную сводку забэкапленных путей в конце запуска (и при ошибке в середине прогона, если бэкапы уже успели создаться).
5. Показывать последние бэкапы в человекочитаемом выводе `ygg status`.
6. Удалять метаданные индекса синхронно с каталогом бэкапа в `rotate-backups` / `ygg clean`.

**Не-цели**
* Команда автоматического восстановления из бэкапа (`ygg restore`).
* Изменение логики `check-shadow` в `ygg doctor` (она уже ищет `rel_dest` внутри общих `<timestamp>/`-каталогов).
* Изменение значений по умолчанию `max_count` / `max_age_days` в политике ротации.

**Анти-цели**
* Размещение служебных JSON-файлов внутри дерева забэкапленных файлов хоста `<timestamp>/...`.
* Смешивание индекса бэкапов с `state.json` (из-за дочерних процессов `setup.nu` и частичных сбоев).
* Рекурсивное сканирование содержимого бэкапов при каждом вызове `ygg status`.
* Поломка обратной совместимости `ygg status --json` или создание бэкапов/индексов в `--dry-run`.

---

## 3. Ограничения

* **Кроссплатформенность:** Nushell `>= 0.116`, Linux / Windows Non-Admin / macOS. Работа с путями сохраняет нормализацию `to-win32-path` / `path expand -n` и обрезание буквы диска при формировании относительного пути внутри `<timestamp>/`.
* **ZERO HOST MUTATION в тестах:** все проверки работают внутри `with-temp-ygg` (`YGG_HOME`, `YGG_SANDBOX`).
* **TTY / `--dry-run`:** сводка и статусное оформление не должны появляться в `--dry-run`, `diff`, `doctor`; прогресс и предупреждения следуют правилам `stderr`/`NO_COLOR` из `AGENTS.md §2.1`.
* **DoD:** регрессионный тест с `# regression: #10` и коммит с футером `Fixes #10`.

---

## 4. Рассмотренные подходы

| Критерий | Вариант 1: `YGG_BACKUP_ID` + метафайл `<id>.json` (выбран) | Вариант 2: Возврат списков из функций + скан ФС |
|---|---|---|
| Учёт бэкапов из `setup.nu` (`safe-link`) | Полный: дочерний `^nu` наследует `YGG_BACKUP_ID` и пишет в тот же индекс | Теряется: `run-module-setup` запускается в отдельном процессе |
| Скорость `ygg status` | O(N) по последним N метафайлам, без обхода дерева каталогов | Рекурсивный обход подкаталогов бэкапа для поиска верхних путей |
| Чистота дерева `<timestamp>/` | Индекс `<timestamp>.json` лежит рядом (`type == "file"`), не затрагивает `check-shadow` | Без метафайлов |
| Сложность ротации | `rotate-backups` удаляет `<id>/` и парный `<id>.json` | Только удаление `<id>/` |

Выбран **Вариант 1**, так как он покрывает все источники бэкапов (включая `setup.nu` и `ygg add`) и не требует сканировать вложенные файлы при `ygg status`.

---

## 5. Детальный дизайн

### 5.1. Идентификатор запуска и `backup-existing` (`src/state.nu`)

* Вводится хелпер `new-backup-id []: nothing -> string`, возвращающий `(date now | format date "%Y%m%d_%H%M%S_%f")`.
* Сигнатура `backup-existing`:
  ```nu
  export def backup-existing [
      ygg_home: string,
      target_path: string,
      --backup-id: string = ""
  ]: nothing -> string
  ```
* Разрешение `backup_id`:
  1. Явный `--backup-id`, если не пуст.
  2. Иначе `$env.YGG_BACKUP_ID? | default ""`.
  3. Иначе `new-backup-id` (сохраняет обратную совместимость при прямых вызовах и в существующих тестах).
* **Разрешение коллизий внутри одного запуска:** если целевой путь `$dest_path` внутри `$backup_dir` уже существует (например, один путь бэкапится дважды за прогон), добавляется суффикс `.1`, `.2`, ... к конечному сегменту имени до выполнения `mv`.
* **Метафайл индекса:** рядом с каталогом `$ygg_home/.state/backups/<backup_id>/` создаётся/обновляется файл `$ygg_home/.state/backups/<backup_id>.json` (формат JSON):
  ```json
  {
    "id": "20261117_231500_123456",
    "created_at": "2026-11-17T23:15:00Z",
    "entries": [
      {
        "target": "/home/user/.config/gh",
        "backup": "/home/user/.ygg/.state/backups/20261117_231500_123456/home/user/.config/gh",
        "type": "dir"
      }
    ]
  }
  ```
  Размещение `.json` **рядом** с каталогом (а не внутри него) гарантирует, что `ls $bkp_root | where type == "dir"` в `check-shadow` (`src/doctor.nu`) и `rotate-backups` видят только каталоги, а восстановление дерева из `<backup_id>/` не содержит лишних служебных файлов.

### 5.2. Проброс `YGG_BACKUP_ID` в одном запуске

* **`main add` (`bin/ygg.nu`):** генерирует один `backup_id` до вызова `register-staged-module` и выполняет и регистрацию модуля, и последующий `apply-plan` внутри `with-env { YGG_BACKUP_ID: $backup_id }`.
* **`apply-plan` (`bin/ygg.nu`):** если `$env.YGG_BACKUP_ID?` уже задан (вызов из `main add`), использует его; иначе (прямые `ygg apply`, `ygg update`) генерирует новый `backup_id` и оборачивает мутирующую часть (начиная с `begin-journal-transaction`) в `with-env { YGG_BACKUP_ID: $backup_id }`. В `--dry-run` `YGG_BACKUP_ID` не создаётся.
* **`main remove` (`bin/ygg.nu`):** оборачивает `unlink-module` в `with-env { YGG_BACKUP_ID: $backup_id }`.
* **`run-module-setup` (`src/sdk.nu`):** передаёт `YGG_BACKUP_ID: ($env.YGG_BACKUP_ID? | default "")` в `$env_vars` дочернего `^nu`, чтобы вызовы `safe-link` из `setup.nu` попадали в ту же папку бэкапа и в тот же индекс.

### 5.3. Ротация и очистка (`rotate-backups` в `src/state.nu`)

* При удалении каталога `$bkp_root/<id>` `rotate-backups` также удаляет парный файл `$bkp_root/<id>.json`, если он существует.
* Возвращаемый список удалённых элементов (и счётчик для `ygg clean`) по-прежнему отражает количество удалённых каталогов бэкапов.
* Осиротевшие `<id>.json`, для которых каталог `<id>/` отсутствует, удаляются при не-dry-run проходе `rotate-backups` и игнорируются при чтении для `ygg status`.

### 5.4. Сводка бэкапов в конце запуска (`src/state.nu`, `src/progress.nu`, `bin/ygg.nu`)

* Хелпер `read-backup-run [ygg_home: string, backup_id: string]: nothing -> record` читает `<backup_id>.json` (если файл существует и содержит непустой `entries`).
* Хелпер `format-backup-summary [run: record, --limit: int = 10]: nothing -> string` формирует компактный блок:
  ```text
  [ygg] Backed up 3 path(s) -> ~/.ygg/.state/backups/20261117_231500_123456:
    - ~/.config/gh
    - ~/.config/nvim
    - ~/.gitconfig
  ```
  Если путей больше `$limit`, выводятся первые `$limit` и строка `  ... and <M> more`.
* В `apply-plan` (после `format-apply-summary` при успехе, а также в ветке `catch` перед повторным выбросом ошибки, если бэкапы уже были сделаны) и в `main remove` сводка печатается в `stderr` (`print -e`).
* Построчное уведомление в `backup-with-notice` (`src/link.nu`) при сохранении выводится в `stderr` через `progress-clear-line` + `print -e`, чтобы не перемешиваться со строкой `Applied N module(s).` в `stdout`.

### 5.5. Отображение в `ygg status` (`src/state.nu`, `bin/ygg.nu`)

* Хелпер `list-recent-backups [ygg_home: string, --limit: int = 5]: nothing -> list<record>` читает каталоги в `$ygg_home/.state/backups/`, сортирует по убыванию имени (`sort-by name --reverse`), берёт первые `$limit`:
  * если есть парный `<id>.json` — берёт `entries | get target` и `created_at`;
  * если `<id>.json` отсутствует (старые бэкапы до RFC-063) — возвращает `{ id, dir, targets: [], legacy: true }`.
* В `main status`:
  * при `--json`: вывод не меняется — печатается JSON-массив `modules-status` (сохраняется совместимость с внешними скриптами);
  * без `--json`: `main status` явно печатает таблицу модулей (`print ($rows | table)`), а затем (если есть хотя бы один бэкап) компактную секцию:
    ```text
    Recent backups (5 max):
      20261117_231500_123456  (3 path(s)): ~/.config/gh, ~/.config/nvim, ~/.gitconfig
      20261116_190412_000100  (legacy)
    ```
    (длинный список путей в одной строке усекается до 3 путей + `+N more`).

---

## 6. План тестирования

1. **`tests/test_state.nu` (`# regression: #10`):**
   * несколько вызовов `backup-existing` с общим `YGG_BACKUP_ID` (через флаг и через `with-env`) складывают все цели в один каталог `<timestamp>/` и записывают их в `<timestamp>.json`;
   * повторный бэкап того же пути внутри одного `YGG_BACKUP_ID` не перезаписывает первый снимок, а создаёт суффикс `.1`;
   * `rotate-backups` удаляет и каталог `<id>/`, и парный `<id>.json`, а также чистит осиротевший `.json`.
2. **`tests/test_e2e_apply.nu` (`# regression: #10`):**
   * `ygg add` / `ygg apply` с несколькими существующими конфигами (и вызовом `safe-link` из `setup.nu`) создаёт ровно один каталог в `.state/backups/` и выводит сводку с перечислением путей;
   * при сбое на позднем шаге `apply` сводка уже созданных бэкапов всё равно выводится;
   * в `--dry-run` каталоги и `.json`-индексы в `.state/backups/` не создаются.
3. **`tests/test_cli.nu` (`# regression: #10`):**
   * `ygg status` отображает секцию `Recent backups` после таблицы модулей;
   * `ygg status --json` возвращает валидный JSON-массив модулей без постороннего текста.
