class_name DifficultyDefinition
extends ContentDefinition

enum InventoryLoss { NONE, HALF, ALL }
enum EquipmentLoss { PROTECT, DAMAGE, LOSE }
enum RecoveryPolicy { DROP_AT_DEATH, NO_RECOVERY }
enum EscapeDisplay { ALWAYS, DISCOVERED, HIDDEN }

@export var display_name: String = ""
@export_range(0.1, 10.0, 0.05) var enemy_health_multiplier: float = 1.0
@export_range(0.1, 10.0, 0.05) var enemy_damage_multiplier: float = 1.0
@export_range(0.0, 10.0, 0.05) var survival_drain_multiplier: float = 1.0
@export_range(0.0, 10.0, 0.05) var loot_multiplier: float = 1.0
@export var inventory_loss: InventoryLoss = InventoryLoss.HALF
@export var equipment_loss: EquipmentLoss = EquipmentLoss.PROTECT
@export var recovery_policy: RecoveryPolicy = RecoveryPolicy.NO_RECOVERY
@export var escape_display: EscapeDisplay = EscapeDisplay.DISCOVERED
