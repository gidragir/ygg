# Внешние команды, процессы и job

## 1. Перехват кодов возврата: `complete` вместо `do -i`

В Nushell 0.116 внешние команды с ненулевым кодом выхода автоматически бросают исключение. Флаг `do -i` устарел — используй конвейер `| complete`:

```nushell
# ✅ ПРАВИЛЬНО: безопасный вызов внешней команды с проверкой exit_code
let res = (^git -C $repo_dir pull --rebase | complete)
if $res.exit_code != 0 {
    ^git -C $repo_dir rebase --abort | complete | ignore
    return { status: "conflict", stderr: $res.stderr }
}
```

## 2. Проверка доступности CLI-утилит (`which` guard)

При вызове внешних менеджеров пакетов (`scoop`, `winget`, `paru`, `mise`) или утилит хоста отсутствие команды в PATH не должно фатально ломать весь сценарий `apply`.

```nushell
# ✅ ПРАВИЛЬНО: безопасный вызов с предварительной проверкой
if (which $mgr | is-empty) {
    print -e $"[ygg] Warning: Package manager '($mgr)' not found on PATH. Skipping ($pkgs | length) package(s)."
    continue
}
```

## 3. Атомарные вызовы однопозиционных CLI (WinGet, uv)

Некоторые утилиты синтаксически не поддерживают установку списка пакетов в одном вызове (`winget install --exact pkg1 pkg2` возвращает ошибку синтаксиса). Выполняй команды последовательно по одному пакету. Ненулевой код winget не всегда провал — сверяй с `WINGET_OK_CODES` (контракт `run-with-timeout` — §7).

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

## 4. Уничтожение дерева процессов (`kill-job-tree`)

PID подпроцессов job нужно зафиксировать **до** вызова `job kill`:

```nushell
let pids = (try { job list | where id == $jid | get -o 0.pids | default [] } catch { [] })
job kill $jid | complete | ignore
for pid in $pids {
    try { ^kill -9 $pid | complete | ignore } catch { }
}
```

## 5. Файловое перенаправление (`o>` / `e>` / `o+e>`) и `job spawn`

В Nushell 0.116 редирект вывода внешней команды в файл (`o> $out e> $err` или `o+e> $log`) **не подавляет исключение** при ненулевом коде выхода (в отличие от `| complete`). Внутри `job spawn` неперехваченное исключение прерывает job до `job send`, из-за чего родительский `job recv` зависает до таймаута (или навсегда при `timeout <= 0`).

Правила:
- оборачивай редирект в `try/catch` и разделяй `stdout`/`stderr` через `o>` и `e>`;
- в ветке `try` возвращай `exit_code: 0` явно: успешный запуск с `o>`/`e>` **не сбрасывает** унаследованный `$env.LAST_EXIT_CODE` после предшествующего `error make`;
- в `catch` `$env.LAST_EXIT_CODE` может быть `0` — подменяй на `1`;
- отсутствующий бинарник определяй через `which`: в `catch` при `External command failed` `$env.LAST_EXIT_CODE` равен `1`, а не `127`, и файлы вывода пусты.

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

## 6. Прогресс подпроцессов при редиректе в файл (non-TTY), `\r`-строки и `mktemp`

При перенаправлении `stdout`/`stderr` в обычный файл (без TTY/PTY) дочерние CLI меняют поведение:

1. **`git` подавляет прогресс:** `git clone`, `git fetch`, `git pull` на не-TTY `stderr` не печатают проценты передачи объектов без явного флага `--progress`.
2. **Буферизация `stdout`:** C `stdio` / Python при записи `stdout` в файл переходят на блочную буферизацию (4–8 КБ); `stderr` остаётся небуферизованным. Для Python/Compose передавай `PYTHONUNBUFFERED=1` / `COMPOSE_PROGRESS=plain`.
3. **Разбор `\r`-перезаписей:** `ansi strip` (и удаление `\r`) съедает возвраты каретки. Инструменты (`git --progress`, `curl`, `uv`) обновляют строку через `\r` без `\n` — если вызвать `ansi strip` или удалить `\r` до сплита, все тики склеятся и обрезка по ширине покажет самый старый кадр:
   ```nushell
   # ✅ ПРАВИЛЬНО: сплит по [\r\n]+ СТРОГО ДО `ansi strip`
   let last_line = ($tail_text
       | split row --regex '[\r\n]+'
       | each { |l| $l | ansi strip | str trim }
       | where { |l| $l != "" }
       | last | default "")
   ```
4. **`mktemp` в Nu 0.116 (uutils):** шаблон при `-t` обязан содержать минимум три `X`, а расширение задаётся через `--suffix`:
   ```nushell
   let tmp_log = (mktemp -t --suffix .log ygg-proc-XXXXXX)
   ```
5. **Ширина терминала и хвост лога:** в Nu нет seek по файлу и `tail` на Windows; ширину читай через `try { (term size).columns } catch { 80 }` с нижней границей (clamp), а при побайтовом чтении хвоста учитывай границы UTF-8 (`decode` / потеря неполных байт в начале среза). Подсчёт ширины строки — [syntax.md](syntax.md) §5.

## 7. Контракт `run-with-timeout`

Обёртка запуска внешних команд с таймаутом (пакетные менеджеры, git):

- сохраняет раздельные `stdout` и `stderr`; пустой `stderr` команды не подменяется строкой `"External command had a non-zero exit code"`;
- при отсутствии бинарника возвращает `exit_code: 127`;
- ненулевой код не считается провалом сам по себе: решает вызывающий код (например, `WINGET_OK_CODES`);
- при таймауте возвращает `exit_code: 124` и сохраняет и накопленный `stderr`, и сообщение о таймауте;
- при прерывании (`Ctrl+C`) или таймауте гарантированно вызывает `kill-job-tree` (§4) и удаляет свои временные файлы из системного tmp.
