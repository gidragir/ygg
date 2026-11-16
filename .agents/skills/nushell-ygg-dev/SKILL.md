---
name: nushell-ygg-dev
description: Mandatory Nushell 0.116+ idioms and filesystem safety patterns for developing and testing the ygg CLI engine in /data/projects/ygg. Read before writing or reviewing any .nu files in src/, bin/, or tests/.
---

# Разработка `ygg` на Nushell 0.116+ (Проверенные идиомы и защита от граблей)

Используй эти проверенные на `nu 0.116.1` паттерны при написании `src/*.nu`, `bin/ygg.nu` и `tests/*.nu`, чтобы избежать типичных ошибок смешения синтаксиса Bash и устаревших версий Nushell.

## 1. Симлинки, битые ссылки (Dangling Symlinks) и проверка существования

В Nushell `($path | path exists)` выполняет `stat` с переходом по ссылке и возвращает **`false` для битого (dangling) симлинка**! При этом `($path | path type)` использует `lstat` и возвращает `"symlink"` даже для битой ссылки (и `null`, если пути вообще не существует).

```nushell
# ✅ ПРАВИЛЬНО: проверка симлинка (включая битый dangling symlink)
let ptype = ($dest | path type)
let is_symlink = ($ptype == "symlink")

# ❌ НЕПРАВИЛЬНО: упадёт на битом симлинке при последующем ln -s
if ($dest | path exists) { ... }
```

* На Windows для проверки NTFS Junction (ReparsePoint) без следования внутрь папки проверяй `($dest | path type)` / атрибуты `ReparsePoint` через `ls -D` или PowerShell `(Get-Item -LiteralPath $dest -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)`.
* Удаление только ссылки без риска удалить содержимое папки:
  * Unix: `^rm $dest` (без `-r`!).
  * Windows Junction: `^cmd /c rmdir $dest` (строго без `/S`!).

## 2. Внешние команды и перехват кодов возврата (`complete` вместо `do -i`)

В Nushell 0.116 внешние команды с ненулевым кодом выхода автоматически бросают исключение. Флаг `do -i` устарел — используй конвейер `| complete`:

```nushell
# ✅ ПРАВИЛЬНО: безопасный вызов внешней команды с проверкой exit_code
let res = (^git -C $repo_dir pull --rebase | complete)
if $res.exit_code != 0 {
    ^git -C $repo_dir rebase --abort | complete | ignore
    return { status: "conflict", stderr: $res.stderr }
}
```

## 3. Parse-time ограничения модулей (`use` и `source`)

* `use` и `source` в Nushell разрешаются **на этапе парсинга (parse-time)** и требуют строковых литералов (констант), а не рантайм-переменных `$path`.
* Для запуска пользовательского скрипта `<mod_dir>/setup.nu` по динамическому пути запускай дочерний процесс `^nu`:
  ```nushell
  with-env {
      YGG_HOME: $ygg_home,
      YGG_MODULE_DIR: $mod_dir,
      YGG_MOD_CONFIG: ($mod_cfg | to json -r)
  } {
      ^nu -I $ygg_src_dir ($mod_dir | path join "setup.nu")
  }
  ```

## 4. Работа с JSON, TOML, хешами и ошибками

* **Глубокое слияние словарей (`merge-json`):**
  ```nushell
  let merged = ($live_record | merge deep $fragment_record)
  $merged | to json --indent 2 | save -f $dest_json
  ```
* **SHA-256 хеширование:**
  ```nushell
  let file_hash = (open --raw $file_path | hash sha256)
  ```
* **Явные структурированные ошибки:**
  ```nushell
  error make { msg: $"Module '($name)' does not support host OS '($host_os.os)'" }
  ```

## 5. Строгое экранирование секретов для разных шеллов

Никогда не подставляй сырые секреты в двойные кавычки шелла без экранирования (строка вида `pa$$w0rd="foo"` выполнит `$w0rd` в Zsh/Pwsh!):
* **Nushell (`env.nu`):** `$"load-env (($env_map | to nuon))\n"` — `to nuon` экранирует любые спецсимволы на 100% безопасно.
* **Zsh (`env.zsh`):** одинарные кавычки с заменой `'` -> `'\''`:
  ```nushell
  let escaped = ($val | str replace --all "'" "'\\''")
  $"export ($key)='($escaped)'"
  ```
* **PowerShell (`env.ps1`):** одинарные кавычки с удвоением `'` -> `''`:
  ```nushell
  let escaped = ($val | str replace --all "'" "''")
  $"$env:($key) = '($escaped)'"
  ```
* **`environment.d`:** двойные кавычки с экранированием `\`, `"`, `$` и переносов строк:
  ```nushell
  let escaped = ($val | str replace --all '\' '\\' | str replace --all '"' '\"' | str replace --all '$' '\$' | str replace --all "\n" '\n')
  $"($key)=\"($escaped)\""
  ```
* **`.env` (dotenv):** одинарные кавычки с экранированием `\` -> `\\` и `'` -> `\'`:
  ```nushell
  let escaped = ($val | str replace --all '\' '\\' | str replace --all "'" "\\'")
  $"($key)='($escaped)'"
  ```

## 6. Изоляция тестов (`tests/helpers.nu`)

Каждый тест обязан работать внутри `with-temp-ygg`, создающего уникальную папку через `mktemp -d -t ygg-test.XXXXXX`, выставляющего `YGG_HOME` и `YGG_SANDBOX` в `with-env` и гарантированно удаляющего временную папку в блоке `try { ... } catch { |e| rm -rf $tmp; error make { msg: $e.msg } }`.

* **Параллелизм `tests/run.nu` (`par-each --threads 4`) и `$nu.temp-dir`:** `mktemp -t` использует `$nu.temp-dir`, который кешируется при старте `nu`. Не проверяй глобальный `$nu.temp-dir` на отсутствие `ygg-proc-*` — запускай тестируемую команду в дочернем `^nu` с `TMPDIR`/`TEMP`/`TMP` на каталог `with-temp-ygg`:
  ```nushell
  # ✅ ПРАВИЛЬНО: изолированный temp-dir для проверки очистки временных файлов
  with-temp-ygg { |tmp|
      with-env { TMPDIR: $tmp, TEMP: $tmp, TMP: $tmp } {
          ^nu -I $src_dir -c '...' | complete
          assert equal (ls $tmp | where { |f| ($f.name | path basename) starts-with "ygg-proc-" } | length) 0
      }
  }
  ```

## 7. Квадратные скобки и строковая интерполяция (`$"..."` vs конкатенация)

В Nushell внутри `$"..."` квадратные скобки `[` парсятся парсером как открывающийся разделитель выражений/индексов, а не литерал. При передаче команд с типами PowerShell/.NET (например, `[bool]`, `[System.IO.FileAttributes]::ReparsePoint`) интерполяция падает с `nu::parser::unclosed_delimiter`.
* **Всегда используй строковую конкатенацию через `+`** для команд с литеральными скобками:
  ```nushell
  # ❌ НЕПРАВИЛЬНО: упадёт с nu::parser::unclosed_delimiter
  let cmd = $"powershell -Command [bool]((Get-Item '($path)').Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint))"

  # ✅ ПРАВИЛЬНО: конкатенация строк
  let escaped = ($path | str replace --all "'" "''")
  let cmd = ("([System.IO.File]::GetAttributes('" + $escaped + "').HasFlag([System.IO.FileAttributes]::ReparsePoint))")
  ```

## 8. Безопасное чтение полей (`get -o` вместо устаревшего `get -i`)

Начиная с Nushell 0.106+, флаг `--ignore-errors` (`-i`) объявлен устаревшим и генерирует предупреждение в stderr.
* **Используй флаг `--optional` (`-o`):**
  ```nushell
  # ❌ НЕПРАВИЛЬНО: предупреждение nu::parser::deprecated
  let val = ($record | get -i non_existent_key | default [])

  # ✅ ПРАВИЛЬНО:
  let val = ($record | get -o non_existent_key | default [])
  ```

## 9. Замыкания в фильтрах `where` (явное связывание `|it|`)

Внутри блока `where { ... }` переменная `$it` не объявляется неявно — обращение к `$it` вызовет `nu::shell::variable_not_found`.
* **Всегда явно объявляй параметр блока `|it|` либо используй `$in` без фигурных скобок:**
  ```nushell
  # ❌ НЕПРАВИЛЬНО: Variable not found $it
  $merged_env | transpose k v | where { not (($it.v | describe) starts-with "record") }

  # ✅ ПРАВИЛЬНО:
  $merged_env | transpose k v | where { |it| not (($it.v | describe) starts-with "record") }
  ```

## 10. Нормализация глоб-таргетов `dest_raw` (защита от папок со звездочкой `*`)

Если пользователь указывает маску директории назначения в `ygg.toml` со звёздочкой на конце (`"scripts/*" = "~/.zsh/scripts/*"`), вызов `expand-target-path` создаст литеральную папку `*`.
* **Всегда отсекай суффикс `/*` или `\*` перед разрешением целевой директории:**
  ```nushell
  let clean_dest_raw = ($dest_raw | str replace --regex '[\\/]\*$' '')
  let dest_dir = (expand-target-path $clean_dest_raw --sandbox $effective_sandbox | str trim -r -c "/" | str trim -r -c "\\")
  ```


## 11. Защита Win32 File API от wildcard-масок (`*`, `?`) и порядок вычисления условий

В Nushell на Windows вызов `($path | path exists)` или `($path | path type)` на пути, содержащем подстановочные знаки (например, `cfg/*.yaml`), вызывает системную ошибку Win32 API `ERROR_INVALID_NAME` (`nu::shell::io::invalid_filename: Invalid filename`).
Кроме того, в выражениях вида `(($p | path exists)) and not ($p | str contains "*")` левая часть вычисляется **до** проверки на wildcard!

* **Всегда проверяй наличие wildcard-символов ДО вызова `path exists` или `path type`:**
  ```nushell
  # ❌ НЕПРАВИЛЬНО: падает на Windows с nu::shell::io::invalid_filename
  if (($resolved | path exists) or (($resolved | path type) != null)) and not ($resolved | str contains "*") { ... }

  # ✅ ПРАВИЛЬНО: проверка строки перед обращением к Win32 API
  let has_wildcard = ($resolved | str contains "*") or ($resolved | str contains "?")
  let is_exact = if not $has_wildcard {
      try { ($resolved | path exists) or (($resolved | path type) != null) } catch { false }
  } else {
      false
  }
  ```

## 12. Кроссплатформенная проверка доступности CLI-утилит (`which` guard)

При вызове внешних менеджеров пакетов (`scoop`, `winget`, `paru`, `mise`) или утилит хоста отсутствие команды в PATH не должно фатально ломать весь сценарий `apply`.
* **Всегда проверяй наличие бинарника через `which` перед выполнением:**
  ```nushell
  # ✅ ПРАВИЛЬНО: безопасный вызов с предварительной проверкой
  if (which $mgr | is-empty) {
      print -e $"[ygg] Warning: Package manager '($mgr)' not found on PATH. Skipping ($pkgs | length) package(s)."
      continue
  }
  ```

## 13. Ограничения внешних CLI: атомарные вызовы (WinGet и uv)

Некоторые утилиты командной строки синтаксически не поддерживают установку списка пакетов в одном аргументе (`winget install --exact pkg1 pkg2` возвращает ошибку синтаксиса).
* **Для однопозиционных утилит (WinGet, uv tool) выполняй команды последовательно по одному пакету:**
  ```nushell
  # ✅ ПРАВИЛЬНО: поштучная установка с изоляцией сбоев
  for pkg in $pkgs {
      let cmd = $"winget install --exact --accept-source-agreements --accept-package-agreements ($pkg)"
      let res = (^nu -c $cmd | complete)
      if $res.exit_code != 0 {
          $failed = ($failed | append { mgr: "winget", stderr: $res.stderr })
      }
  }
  ```

## 14. Каскадный Fallback для Windows Junctions (`UNC & ReparsePoints`)

Команда `^cmd /c mklink /J` завершается фатальной ошибкой Win32 на сетевых UNC-путях (`\\server\share\...`) или файловых системах без поддержки Reparse Points. В Nushell вызов внешней команды с ненулевым кодом выхода без `| complete` аварийно прерывает выполнение.
* **Всегда перехватывай результат `mklink /J` через `| complete` и делай каскадный fallback:**
  ```nushell
  # ✅ ПРАВИЛЬНО: Junction -> Directory Symlink -> Recursive Copy
  let res_j = (^cmd /c mklink /J $win_dest $win_src | complete)
  if $res_j.exit_code != 0 {
      let res_d = (^cmd /c mklink /D $win_dest $win_src | complete)
      if $res_d.exit_code != 0 {
          cp -r $src_path $dest
      }
  }
  ```

## 15. Сохранение путей симлинков на Windows (`to-win32-path` и `path expand -n`)

Обычный `path expand` на Windows разыменовывает симлинки до реального пути. Для команд удаления ссылок (`rmdir`, `del`) это приводит к удалению содержимого целевого каталога вместо самой ссылки.
* **Всегда используй `path expand -n` при конвертации в Win32:**
  ```nushell
  export def to-win32-path [p: string]: nothing -> string {
      $p | path expand -n | str replace -a "/" "\\"
  }
  ```

## 16. Префикс-гарды для деструктивных файловых операций

При удалении временных рабочих каталогов (например, клонов репозиториев) проверяй принадлежность пути служебной поддиректории:
```nushell
let safe_subpath = ([".state", "tmp"] | path join)
if ($tmp != "") and ($tmp | path exists) and ($tmp | str contains $safe_subpath) {
    rm -rf $tmp
}
```

## 17. Чтение режимов файлов и бита исполнения (`ls -lD` в Nu 0.116)

В Nushell 0.116 колонка `mode` вывода `ls -lD` возвращает 9 символов прав (`rwxr-xr-x`) без начального символа типа (`-`/`d`/`l`).
* Для проверки прав владельца на исполнение проверяй последние 9 символов:
  ```nushell
  let mode_tail = ($mode | str substring (($mode | str length) - 9)..)
  let is_exec = ($mode_tail =~ '^..x')
  ```

## 18. Надежное уничтожение дерева процессов (`kill-job-tree`)

Внешний запуск подпроцессов в Nushell через `job` требует фиксации PID **до** вызова `job kill`:
```nushell
let pids = (try { job list | where id == $jid | get -o 0.pids | default [] } catch { [] })
job kill $jid | complete | ignore
for pid in $pids {
    try { ^kill -9 $pid | complete | ignore } catch { }
}
```

## 19. Кроссплатформенность фич `ygg` и внешних утилит (No Unix-Only Assumptions)

`ygg` — кроссплатформенный менеджер (Linux, Windows 11/Server Non-Admin, macOS).
* **Не проектируй ядро и модульные паттерны вокруг Unix-only механизмов** (`systemd`, `dockcheck`, `podman-auto-update`, `bash`-скрипты, `/var/run/docker.sock` как единственный транспорт).
* Любая автоматизация в ядре `ygg`, `setup.nu` и `bin/` реализуется на кроссплатформенном Nushell либо через кроссплатформенные CLI, работающие одинаково на Linux, Windows и macOS. Платформозависимые шаги изолируются через `$nu.os-info.name` или `[scope.linux]` / `[scope.windows]`.

## 20. Файловое перенаправление внешних команд (`o>` / `e>` / `o+e>`) и `job spawn`

В Nushell 0.116 редирект вывода внешней команды в файл (`o> $out e> $err` или `o+e> $log`) **не подавляет исключение** при ненулевом коде выхода (в отличие от `| complete`). Внутри `job spawn` неперехваченное исключение прерывает job до `job send`, из-за чего родительский `job recv` зависает до таймаута (или навсегда при `timeout <= 0`).

* **Всегда оборачивай редирект в `try/catch` и разделяй `stdout`/`stderr` через `o>` и `e>`**, в ветке `try` возвращай `exit_code: 0` явно (в Nu 0.116 успешный запуск с `o>`/`e>` **не сбрасывает** унаследованный `$env.LAST_EXIT_CODE` после предшествующего `error make`), а ошибку запуска отсутствующего бинарника проверяй через `which` (в `catch` при `External command failed` переменная `$env.LAST_EXIT_CODE` равна `1`, а не `127`, и файлы вывода пусты):
  ```nushell
  # ❌ НЕПРАВИЛЬНО: падает на exit_code != 0 до `job send`, сливает stderr в stdout, теряет code=127
  job spawn {
      ^$bin ...$args o+e> $tmp_log
      { exit_code: $env.LAST_EXIT_CODE } | job send 0 --tag $tag
  }

  # ✅ ПРАВИЛЬНО: раздельные потоки + явный 0 в try + защита job send + явный 127 при отсутствии бинарника
  job spawn {
      let r = (try {
          ^$bin ...$args o> $out_log e> $err_log
          { exit_code: 0, spawn_err: "" }
      } catch { |e|
          let raw_code = ($env.LAST_EXIT_CODE? | default 1)
          let code = if $raw_code == 0 { 1 } else { $raw_code }
          let missing = (which $bin | is-empty)
          let spawn_err = if (not $missing) and ($e.msg == "External command had a non-zero exit code") { "" } else { $e.msg }
          { exit_code: (if $missing { 127 } else { $code }), spawn_err: $spawn_err }
      })
      $r | job send 0 --tag $tag
  }
  ```

## 21. Прогресс подпроцессов при редиректе в файл (non-TTY), `\r`-строки и `mktemp`

При перенаправлении `stdout`/`stderr` в обычный файл (без TTY/PTY) дочерние CLI меняют поведение:
1. **`git` подавляет прогресс:** `git clone`, `git fetch`, `git pull` на не-TTY `stderr` не печатают проценты передачи объектов без явного флага `--progress`.
2. **Буферизация `stdout`:** C `stdio` / Python при записи `stdout` в файл переходят на блочную буферизацию (4–8 КБ); `stderr` остаётся небуферизованным. Для Python/Compose передавай `PYTHONUNBUFFERED=1` / `COMPOSE_PROGRESS=plain`.
3. **Разбор `\r`-перезаписей:** встроенный `ansi strip` (и удаление `\r`) съедает возвраты каретки. Инструменты (`git --progress`, `curl`, `uv`) обновляют строку через `\r` без `\n` — если вызвать `ansi strip` или удалить `\r` до сплита, все тики склеятся и обрезка по ширине покажет самый старый кадр:
   ```nushell
   # ✅ ПРАВИЛЬНО: сплит по [\r\n]+ СТРОГО ДО `ansi strip`
   let last_line = ($tail_text
       | split row --regex '[\r\n]+'
       | each { |l| $l | ansi strip | str trim }
       | where { |l| $l != "" }
       | last | default "")
   ```
4. **Кроссплатформенный `mktemp` в Nu 0.116 (uutils):** шаблон при `-t` обязан содержать минимум три `X`, а расширение задаётся через `--suffix`:
   ```nushell
   let tmp_log = (mktemp -t --suffix .log ygg-proc-XXXXXX)
   ```
5. **Ширина терминала и хвост лога:** в Nu нет seek по файлу и `tail` на Windows; ширину читай через `try { (term size).columns } catch { 80 }` с нижней границей (clamp), а при побайтовом чтении хвоста учитывай границы UTF-8 (`decode` / потеря неполных байт в начале среза).
6. **Подсчёт ширины и обрезка UTF-8 строк (`--grapheme-clusters`):** в Nu 0.116 `str length` и `str substring` по умолчанию работают **по байтам** (не по символам), что завышает длину и разрезает многобайтные символы (`⠋`, кириллица, эмодзи) с появлением `\u{fffd}`. Для UI/прогресса всегда используй графемы:
   ```nushell
   # ❌ НЕПРАВИЛЬНО: байтовый срез рвёт многобайтовый UTF-8
   "⠋🚀тест" | str substring 0..<2 # -> "\u{fffd}"

   # ✅ ПРАВИЛЬНО: графемный подсчёт и срез
   let len = ($text | str length --grapheme-clusters)
   let head = ($text | str substring --grapheme-clusters 0..<$cut)
   ```


