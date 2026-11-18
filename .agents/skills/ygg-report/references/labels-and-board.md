# Метки `area:*` и доска `ygg project`

## Метка `area:*` → код

| Метка | Где код |
|---|---|
| `area:cli` | `bin/ygg.nu`: команды, флаги, конвейер apply, итоговый вывод |
| `area:link` | `src/link.nu`: линковка, `preflight-check`, бэкапы, хуки `on_change`, prune |
| `area:doctor` | `src/doctor.nu` |
| `area:git` | `src/git.nu`: clone/add/update модулей, `ygg.lock` |
| `area:state` | `src/state.nu`: состояние, пути, журнал, `host.lock` |
| `area:manifest` | `src/manifest.nu`: разбор `ygg.toml`, `links.toml`, scopes |
| `area:pkg` | `src/pkg.nu` |
| `area:env` | `src/env.nu`: env, секреты |
| `area:sdk` | `src/sdk.nu`: хелперы для `setup.nu` |
| `area:container`, `area:progress` | `src/container.nu`, `src/progress.nu` |
| `area:ci`, `area:docs` | `.github/`, `scripts/release.nu`; README, `docs/` |

Сомневаешься в области — `context_pack(<subsystem>, mode="toc")` или `rg -n "<текст сообщения>" src bin`.

## Создание issue и карточки

```bash
url=$(gh issue create --repo gidragir/ygg --title "doctor: broken junction reported as OK" \
  --label type:bug --label area:doctor --label os:windows --body-file "$SCRATCH/issue-1.md")
gh project item-add 5 --owner gidragir --url "$url"
```

> **Важно:** на проекте #5 может быть включено авто-добавление новых issues в момент создания. Если `gh project item-add` возвращает `Content already exists in this project`, не падай — получи `item-id` через `gh project item-list 5 --owner gidragir --format json --limit 100` по совпадению `.content.url == $url` и затем проставь `Priority` и `Size`.

## Priority и Size на доске (#5, владелец `gidragir`)

1. ID полей и опций: `gh project field-list 5 --owner gidragir --format json`.
2. ID проекта и карточки: `gh project view 5 --owner gidragir --format json` и `gh project item-list 5 --owner gidragir --format json --limit 100`.
3. Обновление: `gh project item-edit --project-id <proj-id> --id <item-id> --field-id <field-id> --single-select-option-id <opt-id>`.

Ошибка о нехватке скоупа `project` → `gh auth refresh -s project`. Переменная `GITHUB_TOKEN` в окружении перекрывает keyring и мешает `refresh` — её нужно предварительно убрать.
