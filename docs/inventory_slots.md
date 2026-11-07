# Fixed inventory slots — Stage 2

InventoryModel now owns an array of exactly `capacity` cells. A cell contains an
ItemStack or `null`; deleting an item leaves its index empty. Ordinary addition,
removal, crafting, storage transfer, equipment replacement and death loss do not
slide unrelated items. Only explicit sorting or bulk initialization/restoration
may rebuild the layout. The UI remains read-only; no drag/drop commands or slot
RPCs have been added.

## API and ownership

| API | Contract |
| --- | --- |
| `get_slot(index)` | Duplicate stack, or null for empty/out-of-range. |
| `slots()` | Deep snapshot of exactly capacity entries, retaining null cells. |
| `stacks()` | Compatible dense snapshot, in occupied-index order. |
| `count()`, `total_weight()` | Ignore empty cells. |
| `move_slot(from, to)` | Move into empty cell; merge compatible ordinary stacks; otherwise swap. Self-move is a no-op for a populated source. |
| `swap_slots(a, b)` | Explicit swap, including empty cells; does not merge. |
| `merge_slots(from, to)` | Same item/durability, no instance IDs or equipment; fill destination to max_stack and retain excess in source. Full target rejects unchanged. |
| `split_stack(from, to, amount)` | Empty target and `0 < amount < source.quantity`; equipment/instances cannot split. |
| `sort_slots()` | Category, item ID, instance ID, durability, descending quantity; merge eligible ordinary stacks and pack from index zero. Deterministic/idempotent. |
| `resize_capacity(size)` | Append empty cells, or remove an entirely empty tail. Reject occupied tail instead of relocating/discarding it. |
| `expand_capacity(amount)` | Positive bounded increment. Runtime sizes are 0–1024, matching the existing owner snapshot ceiling. |
| `initialize(items, capacity=-1)` | Existing dense bulk API; optional capacity replaces old contents and size together. Null input entries reject. |
| `initialize_slots(cells, capacity=-1)` | Guarded in-memory bulk replacement with explicit holes. Not a file/wire decoder. |
| `preview_exchange()` / `exchange()` | Copy full layout, validate inputs/output space, then commit once. Failure preserves exact original holes and contents. |
| `transfer_to(destination, inputs, outputs)` | Stage both inventories and recheck guards/revisions before committing either. Both owners are committed before notifications. |

Mutating commands use the existing mutation guard, return CommandResult, validate
indices and stored stack definitions/quantities/unique instances, and emit one
`changed` notification for an effective mutation (or defer it under begin/end
update). Capacity changes now notify/revise their owner too. The compatible
`capacity = size` setter delegates to safe resizing; use the returned result of
`resize_capacity()` when rejection must be handled. `move_item()` remains a bool
compatibility alias for `move_slot()` using real fixed indices.

Legacy `add_stack()` and `remove_item()` deliberately retain their **partial**
InventoryResult contract. Loot/death-drop recovery uses `changed` and `remainder`
to retain the untransferred items. A full inventory accepts nothing; a partially
filled inventory may accept part of a quantity request and report failure plus
the exact remainder. Use `exchange()` for all-or-nothing quantity transactions.
Legacy bulk equipment requests still allocate separate quantity-one cells;
instanced equipment requires quantity one and unique identity. Equipment never
merges or splits, including anonymous equipment restored from old saves.

## Integration

PlayerItemCommandService transfers use the paired staging helper instead of
committing source removal before a potentially failing destination exchange.
Crafting, progression costs/rewards, pending-loot claims, pickups and drop recovery
retain their existing dense public API and overflow policies. Equip/unequip still
resolve server-owned instance IDs. DeathResolutionService reapplies the existing
per-stack loss policy to each original cell so retained items keep their indices.

PlayerState and SettlementState reset/restore/mirror paths replace contents and
capacity together. They cannot be blocked by an old occupied expanded tail, and
they keep their existing model objects and signal bindings.

InventoryPresenter reads `slots()`, not the compact `stacks()` compatibility view.
Tabs hide other categories in place. The protected bag is displayed after the
main bag's capacity and keeps its own model indices; trailing grid padding is not
extra capacity. Pages cover the actual slot span. Equipment and inventory UI still
issue no gameplay commands.

## Deliberate Save / network limits (Stage 3 is not implemented)

- Save remains **v4**, Profile **v1**, NetworkProtocol **v16**. ItemStack's four
  serialized fields are unchanged. No null cells, indices, layout revisions or new
  capacity fields are added to Save or network DTOs.
- `to_array()` / owner snapshots export only populated cells. Existing restore
  can compact and merge ordinary stacks. Holes, exact indices and split layouts
  therefore do **not** survive Save/Load or owner snapshot application.
- Save v4 does not store inventory expansion; load uses GameStartDefinition
  capacities. Existing restore overflow transfers excess validated items to
  Settlement pending loot, preserving items rather than dropping them.
- Existing v16 owner snapshots already carry capacity, so live expansion can be
  mirrored, but exact slot placement cannot. Host and client may show different
  indices for identical contents. Current commands address item/instance IDs;
  sending these transient indices as network commands would be incorrect.
- Death drops persist their existing dense item records; no drop-slot format is
  introduced. These records and partial-recovery semantics remain compatible.

Stage 3 must explicitly design indexed/null slot encoding, persisted expansion,
version/migration policy, owner-only replication validation, and treatment of
legacy dense saves. It also needs separate inventory identity for main/protected/
storage addressing and conflict rules for positions beyond restored capacity.
No such migration, new RPC, version bump or persistent layout is part of this
stage.

## Verification

`tests/unit/test_inventory_slots.gd` includes fixed-index/hole handling, isolated
getters, merge/split limits, equipment identity, duplicate/invalid definitions,
safe expansion/shrink, exact-layout rollback, paired-transfer guard rejection,
real sparse crafting/storage/equip, death losses, unchanged Save/wire boundaries,
overflow preservation and 200 seeded mixed-operation conservation trials.

```powershell
godot --headless --path . res://tests/test_runner.tscn -- --inventory-slots-only
python tools/check_project.py --godot <Godot-4.7.2>
python tools/test_inventory_ui.py --godot <Godot-4.7.2> --rendered
```

The new API tests failed first on the unmodified model (10 missing operations).
The existing full suite, GUI input tests and sequential multiplayer regressions
remain enabled. Existing UI assertions now check real slot coordinates, and the
item revision regression additionally checks a capacity expansion's notification.

Local Godot 4.7.2 verification passed: 717 focused slot assertions, 5,784 full
assertions, restart read/write and main-scene smoke; 52 rendered GUI assertions;
normal ENet 2/3-player, Host exit, process restart valid/invalid, individual-world
and WorldRuntime 2/3-player, authority, protocol, roster and a rendered 110-step
three-process lifecycle. Disconnect recovery completed in both headless and
rendered modes on the final unchanged implementation.

Two initial local Disconnect probes timed out at different New/Load steps without
an engine diagnostic. The clean starting commit 9b98fd3 was also run for comparison
and returned native exit 3221225477 after completing its gameplay assertions.
Failed logs are retained under ignored validation artifacts; no timeout, engine
error or nonzero-exit checks were weakened for successful reruns. These local
process tests are not a manual two-PC certification.
