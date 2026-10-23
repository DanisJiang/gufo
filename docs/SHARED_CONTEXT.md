# Shared live context (experimental)

Flash-Next can run a configurable number of sessions against one fixed native
KV capacity. For example:

```sh
--sessions 6 --context 262144 --context-pool-tokens 786432
```

The same options support 4, 6 or 8 sessions. Per-request context and aggregate
capacity remain separate limits. Model weights, KV precision, sampling and
attention arithmetic are unchanged.

## Physical ownership

The model allocates the whole configured KV capacity once during startup using
the existing upstream allocation helper. A completed zero-fill and device
synchronization precede readiness. Target keys, values, compressed indexer rows
and MTP rows live in this shared allocation. Sessions own ranges, not additional
full-context buffers.

The arena adds bounded per-session compression/MTP tail space and one 1 MiB
relocation buffer. Private recurrent state, raw indexer rings and speculative
state remain per session and keep upstream allocation behavior. Resource claims
count only that private state per session: shared KV has already been allocated.

Neither admitting a request nor growing its range creates additional KV backing.
Fragmented free space is compacted inside the existing arena. Right-going ranges
move from the end first, then left-going ranges from the beginning. Copies use
the fixed relocation buffer, not another context-sized temporary allocation.
Cache guards preserve borrowed rows before any source is overwritten; graphs
with changed buffer addresses are discarded and rebuilt.

## Admission and cache

Admission reserves the full prompt plus maximum-output envelope. A request
without an output limit reserves its remaining logical context. Exhausted quota
or temporarily non-relocatable state causes waiting, retaining the original
prompt, cancellation and deadline. No fake model token is emitted.

Idle ranges can be reclaimed through the existing guarded cache reset. The
physical allocation stays owned by the model until unload. Cache snapshots do
not become additional native context ranges.

An explicit RAM-cache value remains a logical retention budget. The existing
segmented cache backing still checks real host/heap headroom before committing
physical segments. Its budget is not silently reduced because the shared KV
allocation has already committed. NVMe caching retains its original policy.

The usual queue limits, invalid-request errors and actual device failures remain
distinct from waiting for context capacity. Shared native allocation initially
supports text-only Flash-Next.

## Validation

Hosted CPU checks exercise 10,000 growth/release/compaction histories against
real backing-vector contents, including overlap, both movement directions and
capacity refusal. Separate checks cover configurable concurrency, waiting,
cancellation, live cache reuse and preservation of an explicit RAM-cache budget.

Hosted HIP checks compile production code without running GPU kernels. Hardware
validation must still cover long histories, MTP, cache restore, mixed session
lengths and full-capacity peak memory before a candidate is treated as deployed.
Earlier VMM-allocator measurements do not qualify this implementation.
