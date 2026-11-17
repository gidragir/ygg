# Файловая система, ссылки и Windows

## 1. Симлинки, битые ссылки и проверка существования

`($path | path exists)` выполняет `stat` с переходом по ссылке и возвращает **`false` для битого (dangling) симлинка**. `($path | path type)` использует `lstat` и возвращает `"symlink"` даже для битой ссылки (и `null`, если пути нет).

```nushell
# ✅ ПРАВИЛЬНО: проверка симлинка (включая битый dangling symlink)
let ptype = ($dest | path type)
let is_symlink = ($ptype == "symlink")

# ❌ НЕПРАВИЛЬНО: упадёт на битом симлинке при последующем ln -s
if ($dest | path exists) { ... }
```

* На Windows NTFS Junction (ReparsePoint) проверяй без следования внутрь папки: `($dest | path type)` / атрибуты `ReparsePoint` через `ls -D` или PowerShell `(Get-Item -LiteralPath $dest -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)` (строку команды собирай конкатенацией — [syntax.md](syntax.md) §2).
* Удаление только ссылки без риска удалить содержимое папки:
  * Unix: `^rm $dest` (без `-r`!).
  * Windows Junction: `^cmd /c rmdir $dest` (строго без `/S`!), путь — через `to-win32-path` (§5).

## 2. Нормализация глоб-таргетов `dest_raw` (папка со звёздочкой `*`)

Если маска директории назначения в `ygg.toml` оканчивается звёздочкой (`"scripts/*" = "~/.zsh/scripts/*"`), `expand-target-path` создаст литеральную папку `*`. Отсекай суффикс `/*` или `\*` перед разрешением целевой директории:

```nushell
let clean_dest_raw = ($dest_raw | str replace --regex '[\\/]\*$' '')
let dest_dir = (expand-target-path $clean_dest_raw --sandbox $effective_sandbox | str trim -r -c "/" | str trim -r -c "\\")
```

## 3. Win32 File API и wildcard-маски (`*`, `?`)

На Windows `($path | path exists)` или `($path | path type)` на пути с подстановочными знаками (`cfg/*.yaml`) вызывает ошибку Win32 `ERROR_INVALID_NAME` (`nu::shell::io::invalid_filename: Invalid filename`). В выражении `(($p | path exists)) and not ($p | str contains "*")` левая часть вычисляется **до** проверки на wildcard. Проверяй строку до обращения к файловой системе:

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

## 4. Каскадный fallback для Windows Junctions (UNC и ReparsePoints)

`^cmd /c mklink /J` завершается ошибкой на сетевых UNC-путях (`\\server\share\...`) и файловых системах без Reparse Points; без `| complete` это прерывает выполнение. Перехватывай результат и спускайся по каскаду:

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

## 5. Пути симлинков на Windows (`to-win32-path` и `path expand -n`)

Обычный `path expand` на Windows разыменовывает симлинки до реального пути. Для удаления ссылок (`rmdir`, `del`) это приводит к удалению содержимого целевого каталога вместо самой ссылки. Используй `path expand -n`:

```nushell
export def to-win32-path [p: string]: nothing -> string {
    $p | path expand -n | str replace -a "/" "\\"
}
```

## 6. Префикс-гарды для деструктивных операций

При удалении временных рабочих каталогов (например, клонов репозиториев) проверяй принадлежность пути служебной поддиректории:

```nushell
let safe_subpath = ([".state", "tmp"] | path join)
if ($tmp != "") and ($tmp | path exists) and ($tmp | str contains $safe_subpath) {
    rm -rf $tmp
}
```

## 7. Режимы файлов и бит исполнения (`ls -lD`)

В Nushell 0.116 колонка `mode` вывода `ls -lD` возвращает 9 символов прав (`rwxr-xr-x`) без символа типа (`-`/`d`/`l`). Для проверки исполнения владельцем бери последние 9 символов:

```nushell
let mode_tail = ($mode | str substring (($mode | str length) - 9)..)
let is_exec = ($mode_tail =~ '^..x')
```
