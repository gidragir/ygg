# Документация ygg

Спецификации (RFC) и планы реализации в хронологическом порядке. Новые спеки — `docs/specs/YYYY-MM-DD-<тема>-design.md`, планы — `docs/superpowers/plans/` (раньше — `docs/plans/`). Спека по issue указывает его в шапке (`Issues: #N`).

| Тема | Спецификация | План |
|---|---|---|
| Базовая архитектура | [2026-11-07-modular-omni-architecture-design](specs/2026-11-07-modular-omni-architecture-design.md) | [фаза 1: ядро](plans/2026-11-07-ygg-phase1-engine.md) |
| Улучшения и стабилизация ядра (RFC-001..025) | [2026-11-08-ygg-engine-improvements-and-hardening](specs/2026-11-08-ygg-engine-improvements-and-hardening.md) | [фаза 2: улучшения](plans/2026-11-08-ygg-engine-improvements-and-hardening.md), [фаза 2: фиксы](plans/2026-11-08-ygg-phase2-engine-fixes.md), [фаза 2: миграция модулей](plans/2026-11-08-ygg-phase2-modules-migration.md) |
| Устойчивость и экосистема (RFC-026..040) | [2026-11-08-ygg-phase3-resilience-and-ecosystem](specs/2026-11-08-ygg-phase3-resilience-and-ecosystem.md) | [фаза 3](plans/2026-11-08-ygg-phase3-implementation-plan.md) |
| Корректность и безопасность (RFC-041..058) | [2026-11-10-ygg-phase4-correctness-and-security-hardening](specs/2026-11-10-ygg-phase4-correctness-and-security-hardening.md) | [фаза 4](plans/2026-11-10-ygg-phase4-implementation-plan.md) |
| Контейнеры модулей (RFC-059) | [2026-11-15-ygg-module-containers-design](specs/2026-11-15-ygg-module-containers-design.md) | [контейнеры](plans/2026-11-15-ygg-module-containers-plan.md) |
| Живой прогресс (RFC-060) | [2026-11-16-ygg-live-progress-design](specs/2026-11-16-ygg-live-progress-design.md) | [прогресс](superpowers/plans/2026-11-16-ygg-live-progress.md) ([промпт](superpowers/prompts/2026-11-16-ygg-live-progress-prompt.md), [отчёт](superpowers/reports/2026-11-16-rfc060-live-progress-report.md)) |
| Исправления вывода `apply` и Windows (RFC-061) | [2026-11-17-ygg-apply-output-and-windows-fixes-design](specs/2026-11-17-ygg-apply-output-and-windows-fixes-design.md) | [вывод и Windows](superpowers/plans/2026-11-17-ygg-apply-output-and-windows-fixes.md) |
| Проверка модулей: `ygg lint` и CI модулей (RFC-062) | [2026-11-17-ygg-module-lint-and-ci-design](specs/2026-11-17-ygg-module-lint-and-ci-design.md) | — |
| Группировка бэкапов и summary (RFC-063) | [2026-11-17-ygg-backups-grouping-and-summary-design](specs/2026-11-17-ygg-backups-grouping-and-summary-design.md) | [бэкапы](superpowers/plans/2026-11-17-ygg-backups-grouping-and-summary.md) |
| Диагностика сбоев пакетов и `running` shell (RFC-064) | [2026-11-18-pkg-failure-diagnostics-and-running-shell-design](specs/2026-11-18-pkg-failure-diagnostics-and-running-shell-design.md) | [диагностика пакетов](superpowers/plans/2026-11-18-pkg-failure-diagnostics-and-running-shell.md) |

Журнал изменений — [CHANGELOG.md](../CHANGELOG.md), собирается `mise run changelog` из коммитов.
