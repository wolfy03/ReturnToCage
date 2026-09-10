# Session stability baseline

This document records the earlier pre-multiplayer stabilization patch, which kept save format version 3. The current production format is Save v4; see `save_format.md`.

## 1. Confirmed problems

Legacy setters could replace connected models independently. Retained old effect/stat models could still call PlayerState after reset. Instance stacks could split, duplicate IDs could restore across containers, pending loot could accept unknown content, and direct state restoration did not consistently clamp vitals. Bulk inventory restore emitted per stack. Synchronous storage signals could re-enter reward claims. Death resolution dereferenced invalid start content, and retired actors lacked a life generation check.

## 2. Changes

StackValidation provides shared runtime and save boundaries. PlayerState explicitly disconnects retired effects/stat callbacks. State-specific restoration reports recoverable warnings before SessionSnapshot commits a replacement session. Phase transitions and actor life tokens protect death/respawn boundaries. Reward claims have transient re-entry guards.

## 3. Compatibility API

The deprecated state-property facade (`player_inventory`, `player_stats`, `settlement_storage`, `quest_states`, and related aliases) was removed after production and tests moved to typed owners. `GameSession.player` remains the local-player compatibility view and resolves to the same canonical object as the active peer attachment. New code uses typed state and domain methods.

## 4. ItemStack policy

A non-empty instance_id requires quantity 1. Runtime insertion rejects invalid/duplicate instances without mutation and never splits an instance. Save restoration keeps the first valid occurrence and warns for subsequent copies. Priority is player inventory, equipment (sorted slots), protected inventory, settlement storage including overflow, pending loot, then death drops in array order. The ID table exists only during restoration; no global instance repository was introduced.

Durability -1 remains the existing unspecified sentinel. Other negative saved values become 0 with a warning; equipment durability above its definition maximum is clamped. Runtime creation rejects invalid durability. Starting content validates explicit IDs, types, quantities and capacity before initialization.

## 5. Save stability

At that historical baseline the version remained 3. Current tests migrate v1/v2/v3 inputs to Save v4. String, fractional, negative, future, null and non-finite versions fail safely. Fatal container errors leave the current session unchanged. Recoverable records produce load warnings.

Direct PlayerState restoration clamps health to 0..max_health. Settlement snapshot loading retains the existing living-resume policy (zero becomes 1). Survival uses configured maxima. Invalid overrides are ignored. Positions require two finite components, including after Vector2 conversion. Unknown pending items are excluded with warnings; unavailable death-drop content remains recoverable under the existing policy.

## 6. Transactions

Inventory exchange stages all inputs/outputs and commits once; explicit instance inputs match the exact item and instance ID. Failed exchanges leave inventory unchanged. Initialize and restore emit changed once. Overflow transfers once into pending loot after validation. Pending claims are all-or-nothing and resist signal re-entry. Quest rewards become claimed only after storage succeeds. Failure to start a follow-up quest does not roll back an already paid reward; this preserves the existing policy.

## 7. Verification

Godot 4.7.2:

```sh
python tools/check_project.py --godot <godot-executable>
godot --path . --rendering-method gl_compatibility res://tests/visual_smoke.tscn
```

Full project check: import/parse passed, 29 content Resources passed, 729 test assertions passed, restart write/read passed (1 + 25 assertions), main scene smoke passed. Total: 755 assertions, zero failures. Rendered OpenGL smoke also passed. No hands-on manual play session is claimed.

New suites retain the existing runner: unit/test_inventory_stability.gd, unit/test_player_state_restore.gd, unit/test_settlement_state_restore.gd, unit/test_save_migration.gd, integration/test_session_stability.gd. Existing tests were not weakened.

## 8. CI

The existing push/pull_request workflow remains unchanged, pins .godot-version (4.7.2), downloads the official binary and runs tools/check_project.py with failure exit codes. Local validation uses the same entry point. Per-commit remote results are available in GitHub Actions; consult the run attached to the stabilization commit.

## 9. Known limits

Typed domain objects and collection getters remain mutable for compatibility; callers must use domain operations rather than replace internals. There is no global live ItemInstance repository. Missing scene/content configuration is reported; a failed respawn transition can be retried after repair rather than silently selecting a substitute scene. Manual gameplay verification remains separate from automated integration/rendered checks.

## 10. Next architecture phase

The automated stability baseline is ready for subsequent work. Preserve state ownership, shared input validation, staged restore, and atomic inventory operations. Full adventure resolution separation, quest event decoupling, and instance/slot redesign remain separate tasks.

## Review follow-up: synchronous save boundaries

A subsequent review reproduced duplicate reward persistence from synchronous
storage observers and silent quest progress coercion. The follow-up patch holds
inventory notifications until reward source/claim state commits, removes the
extra pending-claim facade notification, and validates progress before casting.
The new save/load/reclaim regression suite verifies both pending and quest
rewards. Updated full check: 759 main + 26 restart assertions, 785 total; content
validation remains 29 Resources. Save format was v3 at the time of that review.
