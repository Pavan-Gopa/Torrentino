# Git Checkpoints — DialGent

## Правила

1. **Idempotent** — существующий тег не перезаписывается.
2. **Scope-guard** — git root должен совпадать с product root (`DialGent/`).
   `git add -A` на родительскую директорию **запрещён**.
3. **Push local by default** — только если remote настроен.
4. **Commit convention:**
   - PRE: `chore(dialgent): checkpoint before <step>`
   - POST: `feat(dialgent): <step> — <summary>`
5. **Full project checkout** — `git add -A` только в product root.
6. **Tags:**
   - PRE: `dialgent/pre-<step>` (e.g. `dialgent/pre-F0`)
   - POST: `dialgent/<step>-done` (e.g. `dialgent/F0-done`)

## Использование

```bash
./AI_Workflow_Kit/script/checkpoint.sh pre F0
./AI_Workflow_Kit/script/checkpoint.sh post F0 "kit bootstrap complete"
./AI_Workflow_Kit/script/checkpoint.sh list
```

## Восстановление

```bash
git checkout dialgent/pre-F0    # откат к началу шага
git checkout dialgent/F0-done   # откат к концу шага
```
