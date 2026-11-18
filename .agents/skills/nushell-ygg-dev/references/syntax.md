# Синтаксис и парсер Nushell 0.116

## 1. Parse-time ограничения модулей (`use` и `source`)

`use` и `source` разрешаются **на этапе парсинга** и требуют строковых литералов, а не рантайм-переменных `$path`. Пользовательский `<mod_dir>/setup.nu` по динамическому пути запускай дочерним `^nu`:

```nushell
with-env {
    YGG_HOME: $ygg_home,
    YGG_MODULE_DIR: $mod_dir,
    YGG_MOD_CONFIG: ($mod_cfg | to json -r)
} {
    ^nu -I $ygg_src_dir ($mod_dir | path join "setup.nu")
}
```

## 2. Квадратные скобки и интерполяция (`$"..."` vs конкатенация)

Внутри `$"..."` `[` парсится как открывающий разделитель выражения, а не литерал. Команды с типами PowerShell/.NET (`[bool]`, `[System.IO.FileAttributes]::ReparsePoint`) в интерполяции падают с `nu::parser::unclosed_delimiter`. Собирай такие строки конкатенацией `+`:

```nushell
# ❌ НЕПРАВИЛЬНО: упадёт с nu::parser::unclosed_delimiter
let cmd = $"powershell -Command [bool]((Get-Item '($path)').Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint))"

# ✅ ПРАВИЛЬНО: конкатенация строк
let escaped = ($path | str replace --all "'" "''")
let cmd = ("([System.IO.File]::GetAttributes('" + $escaped + "').HasFlag([System.IO.FileAttributes]::ReparsePoint))")
```

## 3. Необязательные поля (`get -o` вместо `get -i`)

С Nushell 0.106+ флаг `--ignore-errors` (`-i`) устарел и печатает предупреждение `nu::parser::deprecated` в stderr. Используй `--optional` (`-o`) или `$rec.field?`:

```nushell
# ❌ НЕПРАВИЛЬНО: предупреждение nu::parser::deprecated
let val = ($record | get -i non_existent_key | default [])

# ✅ ПРАВИЛЬНО:
let val = ($record | get -o non_existent_key | default [])
```

## 4. Замыкания в `where` (явное `|it|`)

Внутри блока `where { ... }` переменная `$it` не объявляется неявно — обращение к ней даёт `nu::shell::variable_not_found`. Объявляй параметр явно или используй `$in` без фигурных скобок:

```nushell
# ❌ НЕПРАВИЛЬНО: Variable not found $it
$merged_env | transpose k v | where { not (($it.v | describe) starts-with "record") }

# ✅ ПРАВИЛЬНО:
$merged_env | transpose k v | where { |it| not (($it.v | describe) starts-with "record") }
```

## 5. Длина и срез UTF-8 строк (`--grapheme-clusters`)

`str length` и `str substring` по умолчанию работают **по байтам**: длина завышается, а многобайтные символы (`⠋`, кириллица, эмодзи) режутся с появлением `\u{fffd}`. Для UI и прогресса используй графемы:

```nushell
# ❌ НЕПРАВИЛЬНО: байтовый срез рвёт многобайтовый UTF-8
"⠋🚀тест" | str substring 0..<2 # -> "\u{fffd}"

# ✅ ПРАВИЛЬНО: графемный подсчёт и срез
let len = ($text | str length --grapheme-clusters)
let head = ($text | str substring --grapheme-clusters 0..<$cut)
```

Для вычисления относительного пути от базовой директории используй `($exp | path relative-to $home)` вместо ручного среза. Если нужно отрезать первое слово команды через срез, сначала сделай `$cmd | str trim`, иначе ведущие пробелы сместят индекс на длину пробелов.

## 6. Захват `mut`-переменной в замыканиях (`with-env`, `each`)

В Nushell замыкания (`with-env { ... } { ... }`, `each { ... }`) запрещают захват `mut`-переменных на этапе парсинга (`Capture of mutable variable`). Если значение вычисляется через `mut` до входа в блок, затени его неизменяемым `let`:

```nushell
mut refresh = false
if $cond { $refresh = true }

# ❌ НЕПРАВИЛЬНО: nu::parser::expected_keyword (Capture of mutable variable)
with-env { YGG_BACKUP_ID: $bid } {
    install-packages --refresh=$refresh
}

# ✅ ПРАВИЛЬНО: затенение через let до замыкания
let refresh = $refresh
with-env { YGG_BACKUP_ID: $bid } {
    install-packages --refresh=$refresh
}
```

## 7. Аннотации возвращаемого `record` (проверка типов в рантайме)

В Nushell 0.116 аннотация выходного типа `: nothing -> record<a: int, b: string>` проверяется **в рантайме при каждом возврате из функции**. Добавление, удаление или переименование поля в возвращаемом словаре без обновления сигнатуры роняет выполнение с `nu::shell::type_mismatch`.

```nushell
# ❌ НЕПРАВИЛЬНО: добавили поле `warnings`, но забыли обновить сигнатуру -> упадёт в рантайме
export def apply-plan [ygg_home: string]: nothing -> record<applied: int, failed: int> {
    { applied: 1, failed: 0, warnings: [] }
}

# ✅ ПРАВИЛЬНО: сигнатура и возвращаемый record совпадают по всем полям и типам
export def apply-plan [ygg_home: string]: nothing -> record<applied: int, failed: int, warnings: list<string>> {
    { applied: 1, failed: 0, warnings: [] }
}
```

Перед изменением сигнатуры или полей возврата функции обязательно найди всех её потребителей в коде и тестах:
```nushell
^rg -n "имя-функции" src/ bin/ tests/
```
