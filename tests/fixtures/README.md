# Legacy v2 fixtures

Both JSON files were captured by running the unmodified `GameSession.export_state()`
on the repository's pre-refactor master, using Godot 4.7.2.

- `legacy_v2_new_game.json`: immediately after `start_new_game()`; only session_id
  was normalized to `legacy-v2-fixture`.
- `legacy_v2_progress.json`: same game after modifying health, survival, safe position,
  storage, protected inventory, facility, resident state, quest progress, flags,
  discovered escape points, difficulty/override and play time.

Keep these fixtures independent of the new serializer. The runner compares every
saved field, derives a v1 envelope by removing the two v2 additions, and exercises
disk round trips and separate-process restart tests.
