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
* **`environment.d` / `.env`:** двойные кавычки с экранированием `\`, `"`, `$` и переносов строк.

## 6. Изоляция тестов (`tests/helpers.nu`)

Каждый тест обязан работать внутри `with-temp-ygg`, создающего уникальную папку через `mktemp -d -t ygg-test.XXXXXX`, выставляющего `YGG_HOME` и `YGG_SANDBOX` в `with-env` и гарантированно удаляющего временную папку в блоке `try { ... } catch { |e| rm -rf $tmp; error make { msg: $e.msg } }`.
