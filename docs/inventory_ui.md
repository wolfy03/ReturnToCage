# Inventory / equipment UI — Stage 1

`I` opens the inventory; `P` opens equipment. `E` remains interaction. Drag either
title bar to move its window; the window and tooltip stay inside the viewport,
including after a viewport resize. Both windows close on Disconnect/session reset
and refuse to open in the menu. Typing into a text field does not toggle windows.

The dark brown/green panels use beige text and a shared supply-pouch placeholder
when an item has no authored icon. Clicking selects a cell for inspection only.
Hover displays the definition, quantity, weight, value, equipment modifiers,
weapon damage/stamina cost and instance durability. There are no use/equip/move/
drop actions, drag-and-drop transfers, or item command RPCs in these components.

`ui/inventory/inventory_presenter.gd` belongs to GameHUD and reads only the local
owner's InventoryModel, protected inventory and EquipmentModel. Model getters
return stack copies; ItemSlotView also copies its input. It disconnects retired
model signals on New/Load/Disconnect and refreshes from the newly bound owner.
Windows remain under the HUD while SceneRouter replaces WorldLayer scenes.

InventoryWindow renders 6×4 presentation cells. [Stage 2](inventory_slots.md) now
reads fixed memory slots, retaining empty cells and hiding other categories in
place. These positions are not yet persisted or replicated. Starting capacity
remains 12, and the protected bag follows the main bag in the read-only view.
The footer reports both real capacities and pages through the full slot span.
EquipmentDefinition items go to Equip, food/drink/return items to Use, QUEST
category to Quest, and the rest to Etc. `quest_protected` alone does not move a
return seed out of Use. Equipped items appear in the equipment window only.

EquipmentWindow's scene owns an array of UI-only EquipmentSlotViewDefinition
resources. Its current entries reference MAIN_HAND and BODY; future UI entries
can reuse this layout without changing the model in this stage. ItemSlotView and
ItemTooltip are separate scenes reusable by future storage/shop views.

Save v4, Profile v1, NetworkProtocol v16, equipment slots, ItemStack
serialization and server mutation authority are unchanged. The existing HUD
keeps storage/unsecured loot, crafting, quests, Save/Load and quick consumption;
its duplicate carried/equipment text is replaced with the I/P shortcut hint.

## Validation

```powershell
python tools/check_project.py --godot <Godot-4.7.2>
python tools/test_inventory_ui.py --godot <Godot-4.7.2> --rendered
python tools/test_session_recovery.py --godot <Godot-4.7.2> --rendered
python tools/build_windows_demo.py --godot <Godot-4.7.2> --rendered
```

The focused integration suite uses physical-key events and GUI hit-tested mouse
events for tabs, selection, dragging and closing; checks tooltip bounds and data,
empty cells, placeholder/custom icons, pagination, read-only snapshots, world
replacement, Disconnect cleanup, identity, New Game and Save/Load model rebinding.
The rendered helper uses an isolated profile directory and writes a real viewport
screenshot to `build/validation/inventory-ui/inventory-ui.png`.

The existing three-process lifecycle now exercises I/P, all four tabs, hover and
selection on offline, Host and Client owners, before/after New/Load and map
transitions. Menu cleanup requires both windows/tooltip closed and models unbound.
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
