## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

When the user types `/graphify`, use the installed graphify skill or instructions before doing anything else.

Rules:
- Graphify is navigation evidence (workflow R20). Use `graphify query "<question>" --graph graphify-out/graph.json --budget 1500`, `graphify path "<A>" "<B>"` or `graphify explain "<concept>"` for unfamiliar code, cross-file behaviour and blast radius; for a known symbol use LSP/grep/read. Verify real source in both cases.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- Graph freshness is Main's job: Main refreshes the graph after Coder handoffs. Workers never run `graphify update` or rebuilds; they report a stale graph instead.
