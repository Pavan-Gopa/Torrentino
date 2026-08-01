# Git Checkpoints — Torrentino

## Правила

1. **Idempotent** — существующий тег не перезаписывается.
2. **Scope-guard** — git root = `Torrentino/`.
   `git add -A` на родительскую директорию **запрещён**.
3. **Push local by default** — только если remote настроен.
4. **Commit convention:**
   - PRE: `chore(torrentino): checkpoint before <WP>`
   - POST: `feat(torrentino): <WP> — <summary>`
5. **Full project checkout** — `git add -A` только в product root.
6. **Tags:**
   - PRE: `torrentino/pre-<WP>` (e.g. `torrentino/pre-WP-01`)
   - POST: `torrentino/<WP>-done` (e.g. `torrentino/WP-01-done`)
   - Backup: `backup/pre-native-macos-<timestamp>`

## Использование

```bash
./AI_Workflow_Kit/script/checkpoint.sh pre WP-01
./AI_Workflow_Kit/script/checkpoint.sh post WP-01 "libtorrent bakeoff complete"
./AI_Workflow_Kit/script/checkpoint.sh list
```

## Восстановление

```bash
git checkout torrentino/pre-WP-01    # откат к началу WP
git checkout torrentino/WP-01-done   # откат к концу WP
git checkout backup/pre-native-macos-20260801  # полный откат до native
```

## Branch

Вся native-работа на ветке `codex/native-macos`.
