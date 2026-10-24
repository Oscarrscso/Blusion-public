# Performance changes

Implemented on top of `9c2aa99`. The title logo size, action-row side margins, and shortened scroll-indicator track are preserved.

## Changes

1. Stream quality is parsed once per received release. Release and Auto Pick regexes are compiled once. Empty/unchanged probes do not rerank the list, and the picker caches its groups and recommendation between changes.
2. Individual stream rows are direct children of the lazy scroll layout through sections; addon groups no longer wrap every row in an eager stack.
3. Ready/buffering states cannot satisfy the startup deadline. Playback that stops advancing for 20 seconds tries the next candidate at the last reported position. Pausing cancels stall detection; teardown cancels its timer.
4. Setting-based autoplay and next-episode selection have a five-second overall selection window and do not await every format probe. The open picker continues receiving later answers. Cancellation invalidates older loads and stops obsolete probes.
5. AVEngine explicitly invalidates its header loader. Finite byte requests finish and cancel as soon as enough data arrives; content-information-only requests finish at the headers. A server ignoring a nonzero byte range fails the candidate rather than downloading and discarding the movie from byte zero. Playlist buffering is bounded to 1 MiB.
6. Rating cache reads bypass the three network workers. Detail requests move ahead of queued poster requests. Library filtering coalesces rating changes and requests only the selected provider, using known catalog IMDb scores immediately.
7. Home/detail heroes use TMDb's original-resolution assets, decoded up to 4096 pixels once per URL. Pull-down stretching changes the frame without restarting image loads or fades. Logos use high-priority downloads and share their decoded cache between Home and Detail. Image downloads are limited to six, with one slot reserved for logos; identical requests are shared, and the last departing consumer cancels pending work.
8. Search publishes cumulative per-addon results as each catalog answers, preserving catalog/addon order and deduplication. Existing callers collecting one final response can retain that behavior.
9. Home hero/row requests share the full addon page regardless of their display limits. Trakt retains its server-side page/limit distinctions. Shared requests survive cancellation of one consumer and stop when none remain. Cache invalidation cannot restore a cancelled request's old entry.
10. Progress stores support targeted batch reads, saves, and removals. Library stores support batch additions. Detail watched-state refresh, show/season watched actions, and Trakt import use these operations. Watched actions use episode identities directly rather than calculating a playback successor for every episode. Trakt's independent remote reads run concurrently.
11. Detail no longer repeats every failed metadata lookup after a 500 ms delay. It displays the first fallback answer and permits an explicit refresh.
12. Home reuses one progress read for its local continue-watching lists. Root navigation combines its initial/tab/revision refresh trigger and shares progress records with its resume accessory and title actions.

## Measurements

Optimized Swift harnesses use the actual package sources with synthetic inputs on the Mac. These are isolated timings, not iPhone frame timings or complete user-session benchmarks.

| Operation | Before | After |
| --- | ---: | ---: |
| Initial listing of 1,000 releases | 534–538 ms | 31 ms |
| 20 container-probe updates over 1,000 releases | 10.6–10.8 s cumulative | 32 ms cumulative |
| First search result: sibling catalogs take 20/500 ms | 526 ms | 26 ms |
| Same-source hero plus row transport requests | 2 | 1 |
| Fresh cached detail score behind 30 older lookups | 1,056 ms | Available at the 30 ms check |
| Construct watched records for 1,000 episodes | 435–443 ms through playback requests | 0.24 ms directly |
| Insert 1,000 progress records, sequential versus batch in the same updated harness | 629 ms sequential | 104 ms batch |
| Read those 1,000 records, individual versus targeted batch | 141 ms individual | 28 ms batch |

The probe timing is cumulative synchronous rebuilding work, not a claim that the previous UI froze continuously for eleven seconds. Parsed metadata is reused; full ranking is still recomputed when a container actually changes.

The buffering-only reproduction now exhausts its two candidates under their startup deadlines instead of reporting successful playback forever. The invalidated header loader releases its session/delegate. A separate native AVEngine check generated a local H.264 clip, played it through the HTTP-header loader, and successfully sought to 15 seconds.

## Validation and limits

- StremioKit, PlayerKit, Persistence, and Features host test suites pass with compiler warnings treated as errors. Regression coverage includes buffering timeout/failover, pause behavior, loader lifetime, cached ratings behind busy workers, partial search, automatic-selection deadlines, shared-request cancellation, and batch persistence.
- iOS device and Mac Catalyst builds pass. SwiftLint passes for every changed Swift file, and `git diff --check` passes.
- Mock-server tests report 12 passes, one fixture-dependent skip, and no failures.
- There is no installed iOS simulator runtime. Six existing AV media-fixture tests are skipped because ffmpeg/generated fixtures are absent; the separate native header-playback/seek check covers the changed loader's basic media path. Phone frame rate, peak memory, and poor-network playback still need device profiling.
- The localization check has the same ten missing pre-existing entries at `9c2aa99`; no new entries are introduced by this change. Project-spec validation reports that PyYAML is unavailable. A strict Catalyst build also encounters the pre-existing `UIScreen.main` deprecation in `App/BlusionApp.swift`; the normal Catalyst build passes.

Automatic selection can choose an available stream before a later, better answer arrives. Servers that ignore byte ranges can now fail over on a seek instead of spending bandwidth reading from the beginning. These are intentional behavior changes.

The existing shelf scrolling/haptic behavior is preserved. No historical freeze reports are used as evidence for these changes.
