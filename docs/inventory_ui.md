# Inventory / equipment UI

`I` opens the inventory and `P` opens equipment. `E` remains interaction. Escape
cancels a slot drag or closes the front item window before reaching the game's
pause action. Drag either title bar to move its window. The window and tooltip stay inside the viewport,
including after a viewport resize. Both windows close on Disconnect/session reset
and refuse to open in the menu. Typing into a text field does not toggle windows.

The dark brown/green panels use beige text and a shared supply-pouch placeholder
when an item has no authored icon. Clicking selects a cell for inspection only.
Hover displays the definition, quantity, weight, value, equipment modifiers,
weapon damage/stamina cost and instance durability. Clicking an empty cell
clears selection.

`ui/inventory/inventory_presenter.gd` belongs to GameHUD and reads only the local
owner's InventoryModel, protected inventory and EquipmentModel. Model getters
return stack copies; ItemSlotView also copies its input. It disconnects retired
model signals on New/Load/Disconnect and refreshes from the newly bound owner.
Windows remain under the HUD while SceneRouter replaces WorldLayer scenes.

InventoryWindow renders 6×4 presentation cells. [Stage 2](inventory_slots.md) now
reads fixed memory slots, retaining empty cells and hiding other categories in
place. [Stage 3](inventory_persistence.md) persists and replicates these positions.
Select Main bag or Protected bag to page through that bag's capacity. The footer
shows occupied cells and total capacity for the selected bag.
EquipmentDefinition items go to Equip, food/drink/return items to Use, QUEST
category to Quest, and the rest to Etc. `quest_protected` alone does not move a
return seed out of Use. Equipped items appear in the equipment window only.

EquipmentWindow's scene owns an array of UI-only EquipmentSlotViewDefinition
resources. Entries provide the slot, name, row and optional empty icon. The
shared ItemSlotView renders Main hand, Body, Head and two accessory slots;
empty slots use a muted placeholder unless the entry supplies its own icon.

Save v5 and Protocol v17 preserve slots. Profile v1, equipment slots, ItemStack
serialization and server mutation authority are unchanged. The existing HUD
keeps storage/unsecured loot, crafting, quests, Save/Load and quick consumption;
its duplicate carried/equipment text is replaced with the I/P shortcut hint.

## Slot controls (Stage 4-A)

Drag within the selected bag to move to a free slot, swap different stacks, or
merge compatible stacks up to the target's limit. Hold Shift when starting a
drag onto a free slot to choose a split amount. Shift over the inventory belongs
to the drag gesture; away from the window the usual dodge binding applies.
**Sort whole bag** sorts every category in the selected bag.

A grid cell addresses `page * 24 + cell` within the selected bag. Category tabs
hide contents in place. A hidden occupied cell refuses a drop with an
explanation, and padding outside the current capacity refuses drops. Drag data
holds bag/index/category and the UI gesture generation. The presenter checks
the displayed item revision against the current owner before submitting.

The presenter calls the existing `request_slot_command()` and waits for the
matching `slot_result` sequence. Only one request is pending per window. The
authoritative layout or validated owner mirror drives the display. Rejections
show the current layout with an explanation, and delayed results for other
sequences do not affect the current interaction. World or owner changes
invalidate unfinished gestures. Disconnect resets pending UI and closes the
split dialog.

## Equip, unequip and use (Stage 4-B)

Double-click a piece of equipment in the main bag or drag it to its matching
equipment slot. Double-click worn gear or drag it onto the main bag to
unequip. Unequip uses the first free cell according to the server inventory
policy. The hovered cell is only a drop surface. Double-click an ordinary
consumable in the main bag to use one unit by item ID. A return seed still uses
the Adventure shortcut `Q`.

The presenter uses the existing `request_equip(instance_id)`,
`request_unequip(slot)` and `request_use_item(item_id)` calls and result signals.
The shared pending state blocks overlapping slot and item gestures. The
transport allows one pending result per command type, including quick-item use.
Only owner snapshots update a client's items. A successful equip, unequip or use
keeps the controls pending until the bound owner's item revision advances. Page
and tab changes leave the request in flight. Disconnect drops pending state.
Successful unequip confirms that the server used the first free main-bag slot.
A full bag can still allow an equipment swap when removal of the new item makes space for the old one. A
failed return to the bag leaves both containers and their revisions intact.

When an old save or a new item supplies equipment without an ID, the authority
assigns one as the item enters a playable main bag. Legacy equipped gear keeps
its data until it is returned to the bag, when it receives an ID if needed.
Existing IDs, durability and the fixed slot positions are preserved. Client
mirrors and staged transaction previews retain their input identities.

## Equipment and stat comparison (Stage 5)

Craft `field_gear_recipe` at the starting workbench using two moss fiber and
one rusty scrap from Settlement storage. The server puts a Leaf Hat, Acorn
Necklace and Seed Ring at full durability in the crafter's main bag. The
transaction needs room for all three pieces. The gear adds defense +1, maximum
health +10 and stamina regeneration +2, respectively.

The equipment window reads six final values from the local player's StatBlock
and observes changes to stats and private-state mirrors. Hover or select gear
in the inventory to compare it to the current item in its slot. The tooltip
shows the old and projected final values, including live buffs. The preview
copies the current stats and effects and calls the same gear rebuild as
equipping. It leaves health, timers, inventory and revisions intact. Gear
with zero durability contributes neither modifiers nor equipment effects.

Slots 0 and 1 retain their existing meanings; the new slots are 2 through 4.
Save v5, Protocol v17 and Profile v1 use the same formats. Older saves with
only the first two slots still load. Players in a session using the new gear
need the Stage 5 build so each peer recognizes the expanded content and slots.

## Validation

```powershell
python tools/check_project.py --godot <Godot-4.7.2>
python tools/test_inventory_ui.py --godot <Godot-4.7.2> --rendered
python tools/test_session_recovery.py --godot <Godot-4.7.2> --rendered
python tools/build_windows_demo.py --godot <Godot-4.7.2> --rendered
```

The focused integration suite uses physical-key events and GUI hit-tested mouse
events for tabs, selection, dragging and closing. It exercises all five slot
commands, canceling and rejecting drops, split limits, same-bag enforcement and
the Shift binding. It checks tooltip data and bounds, icons, empty cells, world
replacement, Disconnect cleanup, identity, New Game and Save/Load model rebinding.
The rendered helper uses an isolated profile directory and writes a real viewport
screenshot to `build/validation/inventory-ui/inventory-ui.png`.

The existing three-process lifecycle now exercises I/P, all four tabs, hover and
selection on offline, Host and Client owners. Client drags verify that the layout
remains unchanged while pending, reject during a pending world transition, and
work again after world travel and reattachment. Menu cleanup requires both windows/tooltip closed and models unbound.
The same assertions run inside the actual embedded-PCK Windows release EXE,
headless and rendered. Export content checks explicitly load all four UI scenes
and the SVG placeholder, so missing dynamically loaded UI resources fail release
verification. CI uploads the EXE only after successful existing release checks.

## Stage 1 verification (before fixed slots)

Godot 4.7.2: 50 focused GUI assertions and 5,064 full-suite assertions passed,
including restart read/write and the main-scene smoke check. The existing normal
2/3-player, restart valid/invalid, world/runtime 2/3-player, authority, protocol,
disconnect and presentation-roster E2Es passed. Source and release EXE lifecycle
checks each completed 110 steps in three unchanged processes. The EXE passed
content parity (29 IDs), embedded-PCK checks, and all Editor/EXE Host/Join pairings,
headless and rendered (Compatibility, explicit Dummy audio). The single-process
UI screenshot/input check also passed with the default Forward+ renderer.

Some local Windows runs returned native exit code 3221225477 after PASS output;
they were counted as failures and retained in ignored validation logs. Complete
reruns passed without relaxing exit/error checks. A local three-process Forward+
run timed out during late Join; the Compatibility run completed. CI retains its
existing default-renderer Windows release validation. These automated local ENet
checks do not represent a manual two-PC test or verified audio playback.
