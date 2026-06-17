# Frankengit: Git for unreasonable repositories

Frankengit is a performance-focused Git build for giant monorepos, many
linked worktrees, and agent-heavy development. It attacks repeated
filesystem traversal, object decompression, ancestry walks, and index
parsing instead of hoping compiler flags will save us.

The goal is simple: common Git commands should remain interactive even
when the repository has nearly a million tracked files and several agents
are querying it concurrently.

## Representative wins

Measured on large real or synthetic repositories, primarily on a 16-core
Apple M4 Max with 128 GB RAM:

| Workload | Before | Frankengit |
|---|---:|---:|
| `git branch -r --contains` over 62k refs | 104.4 s | 468 ms |
| `git ls-files --others --exclude-standard` | 21.0 s | 170 ms |
| `git status --porcelain -uall` | 19.1 s | 270 ms |
| `git add -N -- '*/AGENTS.md'` | 10.1 s | 152 ms |
| `git ls-files --deleted -- README.md` | 60.7 s | 1.06 s |
| Repeated revision grep with no matches | 448 ms | 15 ms |
| `git diff --name-only <revision>` | 6.62 s | 564 ms |
| Clean `git status` | 817 ms | 75 ms |
| `git log --follow -- revision.c` | 1.14 s | 103 ms |
| `git diff --stat` on a large modified file | 467 ms | 176 ms |
| `git write-tree` without optional persistence | 150 ms | 41 ms |
| Path-focused `git blame` | 724 ms | 454 ms |
| 6,310-to-1 `git range-diff` | >45 CPU-hours, unfinished | 31.7 s |

These are representative measurements, not universal guarantees. The
larger and more repetitive the repository workload, the more Frankengit
tends to win.

## Search at agent scale

`git grep` is the centerpiece.

- Persistent trigram content indexes reject blobs that cannot match before
  reading or decompressing them.
- Index segments are shared across linked worktrees.
- The fsmonitor daemon keeps hot indexes in memory.
- Concurrent grep processes share a worker budget instead of each claiming
  every core.
- Unchanged worktree files can be read through their indexed blobs, avoiding
  repeated filesystem reads.
- Repeated no-result scans are memoized across revisions.
- Negative indexed results are cached and stale indexes are overlaid in
  memory.
- Split-index rewrites and ordinary index rewrites recover existing cache
  observations.
- Small literal pathsets bypass full-index traversal.
- Large literal and basename pathsets use indexed candidate selection.
- `--untracked` searches reuse the untracked cache.
- Quiet threaded searches stop promptly after finding a match.

Content-index acceleration covers much more than fixed strings:

- Case-insensitive searches
- BRE and ERE required literals
- Grouped alternatives
- Word boundaries and character classes
- Escaped punctuation and bracket expressions
- Simple PCRE groups, lookarounds, word classes, and bounded wildcards
- Multiple-pattern `--all-match` intersections

Unsupported or uncertain queries fall back to normal Git semantics.

## Faster history searches

Frankengit extends content indexing into `git log -S` and
`git log -G`.

- Impossible blob pairs are rejected before reading either side.
- Regex pickaxe searches use indexed required literals.
- Commit-edge indexes can reject commits before constructing tree diffs.
- Path-limited searches query only relevant edge batches.
- Exact `-S` occurrence counts are reused when blobs recur across
  adjacent commits.
- Saturated caches continue querying conservatively instead of silently
  losing acceleration.

This matters especially for generated agent queries that search large
revision ranges repeatedly.

## Status that stays interactive

The untracked cache is treated as a pruning index rather than merely a
replay cache.

- Entire valid empty caches can be skipped.
- Empty subtrees are pruned even when other parts contain untracked files.
- Negative summaries are reused across `-unormal` and `-uall`.
- Invalidated directories are validated in parallel.
- Lost negative summaries are repaired after complete scans.
- Name-hash construction is avoided when cached traversal does not need it.
- Pathspec-constrained status scans avoid unrelated untracked directories.
- Darwin fsmonitor rescans invalidate only the affected subtree when
  possible.

Clean and nearly-clean worktrees benefit most.

## Faster `git add`

- Wildcard intent-to-add commands reuse negative untracked-cache summaries.
- Pathspec scans avoid traversing subtrees that cannot contain candidates.
- Pathless add workflows reuse the normal untracked cache.
- Ignored-path diagnostics remain intact for explicit paths.

This directly targets commands such as:

```sh
git add -N -- '*/AGENTS.md'
```

## Faster `ls-files`

- Single pathspecs are matched before expensive `lstat()` calls.
- `--deleted` and `--modified` honor fsmonitor-valid entries.
- Full untracked enumeration prunes known-empty subtrees.
- Lazy cache-tree parsing remains lazy.
- Literal, wildcard, and pathless workloads avoid unrelated filesystem work.

## Faster diffs and shows

- Worktree diffs skip cache-tree subtrees proven unchanged by fsmonitor.
- `diff --stat` and `diff --check` reuse file contents already
  loaded by earlier diff stages.
- `git show --no-patch` avoids constructing a diff it will never
  display.
- Worktree contents and object metadata are reused instead of repeatedly
  cleaned, hashed, and read.

## Faster logs and blame

Changed-path Bloom filters are used more aggressively:

- `git log --follow` skips tree diffs for commits that definitely did
  not touch the followed path.
- TREESAME side branches are pruned while preserving rename-following
  semantics.
- Long Bloom-negative runs are collapsed instead of processed commit by
  commit.
- `git blame` jumps across unchanged first-parent spans.
- Bloom filters work across shallow boundaries and shallow commit-graph
  layers.
- Basename-aware filters accelerate leading `**/literal` pathspecs.
- Revision traversal uses a priority queue instead of linear insertion for
  wide histories.
- Decoration ref iteration is scoped and object lookup is deferred.

## Ref-heavy repositories

Repositories with thousands of branches and tags receive dedicated
treatment:

- `git branch --contains` and `git for-each-ref --contains`
  reuse ancestry results.
- Generation numbers bound negative ancestry walks.
- Shallow contains walks are memoized.
- Prefix-scoped ref iteration avoids enumerating unrelated namespaces.
- `git describe` defaults directly to tag refs.
- Ref metadata and object headers are reused across candidates.
- Committer dates can come directly from the commit graph.
- Direct refs avoid redundant filesystem stats.

## Index and plumbing improvements

- Parallel index loading is enabled through EOIE and IEOT extensions.
- Cache-tree extensions are parsed only when requested.
- Split-index additions merge linearly.
- Shared-index identities avoid unnecessary full-file hashing.
- Worktree blob cache identity survives split-index and index rewrites safely.
- `git write-tree` can avoid persisting an optional cache-tree update.
- Large client IPC queries are serialized once and divided efficiently.

## Shallow repositories and packing

- Commit-graph records and Bloom data remain usable in shallow repositories.
- Shallow commit-graph writes preserve useful changed-path information.
- Pack generation can choose cheaper shallow-edge handling when CPU matters
  more than transfer size.
- Cruft-pack revision state is released promptly.

## Pathological cases fixed

Frankengit also removes several accidental complexity cliffs:

- One-sided `range-diff` comparisons avoid constructing enormous
  assignment matrices.
- Large revision frontiers no longer use quadratic sorted-list insertion.
- Saturated grep caches rotate rather than remaining permanently ineffective.
- Simple fsmonitor misses avoid hashing the entire index.
- Stale or missing acceleration data always falls back to ordinary Git
  behavior.

## Recommended setup

```sh
git config --global core.fsmonitor true
git config --global feature.manyFiles true
git config --global index.threads true
git config --global status.aheadBehind false
git config --global commitGraph.changedPaths true
git config --global commitGraph.changedPathsVersion 3
```

Rewrite each worktree index once:

```sh
git update-index --index-version 4 --force-write-index
```

Rebuild changed-path Bloom filters:

```sh
git commit-graph write --reachable --changed-paths \
  --max-new-filters=-1 --split=replace
```

Build the shared content index:

```sh
git grep-index
```

Historical grep and pickaxe workloads can optionally hydrate more history:

```sh
git grep-index --reachable HEAD
git grep-index --commit-edges HEAD~20000..HEAD
```

Do not index unlimited history blindly: reachable content indexes can consume
substantial time and disk space in a giant repository.

## Bottom line

Frankengit is Git with memory:

- It remembers which files are unchanged.
- It remembers which blobs cannot match.
- It shares that knowledge across worktrees and concurrent agents.
- It prunes directories, revisions, refs, and object reads before paying for
  them.
- When acceleration data is unavailable or uncertain, it falls back to normal
  Git behavior.

The result is not one benchmark trick. It is a broad removal of repeated work
from the commands developers and coding agents run all day.
