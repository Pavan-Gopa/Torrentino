# libtorrent patches

**Currently empty — libtorrent 2.1.0 and 2.0.13 build unmodified on arm64
macOS 13+.** That is a deliberate project goal: the plan forbids forking
libtorrent, and an unpatched upstream is what makes a version bump cheap.

If a patch ever becomes unavoidable:

1. Put it in `patches/libtorrent-<version>/NNNN-short-description.patch`
   (`git format-patch` style, applied with `patch -p1`). `build.sh` picks up
   every `*.patch` in that directory automatically, in lexical order, and
   records a stamp file so re-runs stay idempotent.
2. Document in the patch header: why it exists, the upstream issue/PR link, and
   the condition under which it can be dropped.
3. Add a line to `../DEPENDENCIES.md` — a patched dependency is no longer the
   thing the SHA-256 describes, and reviewers must see that immediately.

A patch that cannot name the upstream issue it works around is not acceptable:
it becomes an invisible fork the next maintainer has to re-discover.
