# Indexed inventory persistence — Stage 3

Save **v5** and NetworkProtocol **v19** preserve capacity, gaps, quantity,
instance identity and durability. Profile **v1** and the persistent `player_id`
remain unchanged. Stage 4-A binds inventory controls to the existing intent API.

## Save format and migration

Save v4 used dense stack arrays at `player_state.player_inventory`,
`player_state.protected_inventory` and `shared.settlement.settlement_storage`.
Save v5 retains the shared/player-ID envelope and uses an indexed object at each
of those paths:

```json
{
  "capacity": 24,
  "slots": [
    {"index": 2, "stack": {"item_id": "berry", "quantity": 6, "instance_id": "", "durability": -1}},
    {"index": 8, "stack": {"item_id": "twig_sword", "quantity": 1, "instance_id": "sword-123", "durability": 40}}
  ]
}
```

Omitted cells are empty; record order has no effect on their indices. Equipment
retains the existing equipment-slot dictionary. Pending loot and death-drop
item lists remain dense because they are records, not fixed inventories. No
runtime revision, sequence, peer ID, world readiness or attachment is saved.

The migration chain is v1 → v2 → v3 → v4 → v5. The last step copies each dense
record unchanged to its zero-based position, without merging or inventing an
instance ID. Because v4 did not store expansion, inferred capacity is the larger
of the configured capacity and the number of old records. The 1024-cell ceiling
prevents unbounded allocation. Original fixture and user files are read-only
during migration, Load and Host Save; a later explicit Save writes v5 through
the existing temporary/backup transaction.

Valid legacy stacks retain exact quantities and identities. Legacy files with
recoverable corrupt stack records keep the existing salvage/warning policy
(for example, splitting an oversized ordinary stack without losing quantity).
This fallback is selected from the original file version, never by a field in
v5. Duplicate persistent instances remain fatal even in legacy files. Profile
identity inspection accepts primary v4 and v5 files; selected identity recovery
still stages the whole save before profile commit and does not apply live state.

The shared decoder validates capacity, record count, integer indices, range,
duplicate indices, known items, positive quantity, max_stack, equipment quantity
one, durability and instance uniqueness. JSON integer-equivalent numbers are
accepted; native wire fields must be actual integers. The existing global
instance registry spans both bags, equipment, all players, storage, pending loot
and death drops. A malformed v5 inventory or equipment record fails detached
staging; invalid files cannot partly apply or rewrite themselves. The writer
preflights the full v5 envelope before opening the temporary file.

## Wire format and authority

v16 carried dense `inventory`, `protected_inventory` and shared `storage` arrays.
v17 keeps their existing capacity fields and changes the occupied entries to
`{"index": int, "stack": {...}}`. Native snapshots reconstruct nullable cell
arrays and apply only validated revisions to the existing model objects. Main
and protected bags and equipment are prevalidated together before applying the
owner mirror. Storage remains shared Settlement data; neither private inventory
nor equipment is broadcast to other clients. v16 peers fail the normal protocol
handshake; legacy v16 snapshot bodies are not a v17 fallback.

The inventory presenter uses the root PlayerItemReplicationService's
`request_slot_command(action, inventory_kind, from, to, amount)`. The supported
commands are MOVE, SWAP, MERGE, SPLIT and SORT in the owner's
main or protected bag. Shared storage retains its existing transfer intents;
capacity expansion is an authoritative model operation, not a client grant.

A command carries owner ID, session ID, world ID/revision, item revision, a
sequence shared with existing item commands, action/bag/index/amount and exact
source/target stack fingerprints (empty dictionary for an empty slot). The server
derives the peer from ENet, checks its active attachment and owner, consumes the
sequence, validates current world readiness and the live authoritative actor,
then checks the item revision, bounds, fingerprints and quantity. Hurt, dodge,
return channel, death and pending transition prevent the command. Sorting uses
`from = to = -1`, amount zero and empty fingerprints. Only the server mutates
the InventoryModel. Successful revisions are sent only to the owner; result
messages contain the sequence, success and reason. Rejections leave the entire
layout and revision unchanged.

## Verification

- `--inventory-persistence-only`: v4 migration without rewriting input bytes,
  v5 disk round trip, exact capacities/gaps/instances, malformed save rollback,
  owner snapshot validation and Profile v1 preservation.
- Existing v1/v2 fixtures and v3/v4 identity/legacy restoration tests remain.
- Session lifecycle uses actual two- and three-process ENet slot intents,
  including forged owner/session/instance, stale revision/world/sequence,
  out-of-range and oversized split requests. It checks a third client's privacy,
  world transitions, saved host layout and same-process reattachment. The same
  checks run inside the release Windows EXE.
- Process-restart Host Save tests seed expanded sparse bags/storage and compare
  exact indices, instance IDs, quantities and owner-private state across restart.
  `tools/test_multiplayer_restart.py --rendered` can run the same assertions on
  Windows Compatibility; CI keeps its default headless probes.
- Protocol mismatch E2E submits v18 to the v19 server and requires rejection.

## Data stability boundaries (Stage 6-A)

New canonical starting equipment receives a fresh identity for each grant,
including worn gear and gear in protected or shared storage. A nonempty ID in
starting content is a template, while a nonempty ID in a save, transfer, or
death drop is the identity of an existing piece. New crafted and awarded gear
receives IDs on authority. Loading older saves preserves their legacy identity
rules, and clients only apply server snapshots.

A transfer spends a concrete ID, the selected anonymous legacy gear with its
matching durability, or an anonymous stackable quantity. Type-based exchanges
cannot spend an identified stack. The staged transfer checks both layouts;
equipped items, protected inventory, and pending Settlement loot are checked
for conflicts with the moving identity. Invalid loot also blocks the offline
escape before the expedition is retired.

Equipment stat sources follow the actual occupied slots. An unchanged piece
retains its persistent effect timer. Temporary and worn effects have separate
runtime keys, even when their effect ID and source label match. Previewing
operates on detached copies. Respawn health uses the maximum after equipment
loss or breakage, even when item observers are deferred until after death.
