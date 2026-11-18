# Данные: JSON, TOML, хеши, ошибки и экранирование секретов

## 1. JSON, хеши и структурированные ошибки

* **Глубокое слияние словарей (`merge-json`):**
  ```nushell
  let merged = ($live_record | merge deep $fragment_record)
  $merged | to json --indent 2 | save -f $dest_json
  ```
* **SHA-256:**
  ```nushell
  let file_hash = (open --raw $file_path | hash sha256)
  ```
* **Явные структурированные ошибки:**
  ```nushell
  error make { msg: $"Module '($name)' does not support host OS '($host_os.os)'" }
  ```

## 2. Экранирование секретов для разных шеллов

Никогда не подставляй сырые секреты в двойные кавычки шелла без экранирования (строка `pa$$w0rd="foo"` выполнит `$w0rd` в Zsh/Pwsh).

> **Важно о строках Nushell:** в Nushell интерполяция `(...)` и `$var` работает **только** в `$"..."` (с префиксом `$`). Обычные двойные кавычки `"..."` — это буквальные строки (подстановки не выполняются). Замена `"..."` на raw-строку `r#'...'#` создаёт инъекцию, если значение содержит `'#`. Для генерации любых строковых литералов в `.nu`-файлах используйте `($val | to nuon --raw)`.

* **Nushell (`env.nu`):** `$"load-env (($env_map | to nuon))\n"` — `to nuon` экранирует любые спецсимволы.
* **Zsh (`env.zsh`):** одинарные кавычки с заменой `'` → `'\''`:
  ```nushell
  let escaped = ($val | str replace --all "'" "'\\''")
  $"export ($key)='($escaped)'"
  ```
* **PowerShell (`env.ps1`):** одинарные кавычки с удвоением `'` → `''`:
  ```nushell
  let escaped = ($val | str replace --all "'" "''")
  $"$env:($key) = '($escaped)'"
  ```
* **`environment.d`:** двойные кавычки с экранированием `\`, `"`, `$` и переносов строк:
  ```nushell
  let escaped = ($val | str replace --all '\' '\\' | str replace --all '"' '\"' | str replace --all '$' '\$' | str replace --all "\n" '\n')
  $"($key)=\"($escaped)\""
  ```
* **`.env` (dotenv):** одинарные кавычки с экранированием `\` → `\\` и `'` → `\'`:
  ```nushell
  let escaped = ($val | str replace --all '\' '\\' | str replace --all "'" "\\'")
  $"($key)='($escaped)'"
  ```

## 3. ISO-8601 UTC-метки времени (`date to-timezone utc`)

`date now | format date "%Y-%m-%dT%H:%M:%SZ"` подставляет **локальное** время с суффиксом `Z`. Для честного UTC всегда переводи таймзону до форматирования:

```nushell
# ❌ НЕПРАВИЛЬНО: локальное время с буквой Z
let ts = (date now | format date "%Y-%m-%dT%H:%M:%SZ")

# ✅ ПРАВИЛЬНО: явный перевод в UTC
let ts = (date now | date to-timezone utc | format date "%Y-%m-%dT%H:%M:%SZ")
```

## 4. Атомарная запись приватных файлов (без TOCTOU и пустого DACL)

1. Никогда не пиши секреты в целевой файл до установки прав `0600` / Windows ACL, а `$tmp_file` создавай **рядом с `$dest`** (на том же томе NTFS, иначе `mv -f` сбросит ACL).
2. Никогда не вызывай `icacls $win_path /inheritance:r` без непустого `/grant:r $"($user):F"` — сброс наследования без grant оставляет пустой DACL и намертво блокирует владельца файла.

```nushell
# ✅ КОПИПАСТ-РЕЦЕПТ 1: атомарная запись приватного файла (env.*, secrets, tokens, 0600)
let tmp_file = $"($dest).tmp.(random chars --length 8)"
try {
    "" | save -f $tmp_file
    if not (restrict-file-access $tmp_file) {
        error make { msg: $"Failed to restrict permissions on temporary file '($tmp_file)'" }
    }
    $secret_content | save -f $tmp_file
    mv -f $tmp_file $dest
} catch { |err|
    if (($tmp_file | path type) != null) { try { rm -f $tmp_file } catch { } }
    error make { msg: $err.msg }
}

# ✅ КОПИПАСТ-РЕЦЕПТ 2: безопасное ограничение ACL на Windows внутри restrict-file-access
let win_path = (to-win32-path $path)
let raw_user = ($env.USERNAME? | default ($env.USER? | default ""))
let user = if ($raw_user != "") { $raw_user } else { try { ^whoami | complete | get stdout | str trim } catch { "" } }
if ($user == "") {
    return false # ЗАПРЕЩЕНО вызывать /inheritance:r при пустом $user!
}
let res = (^icacls $win_path /inheritance:r $"/grant:r" $"($user):F" | complete)
$res.exit_code == 0
```
