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
