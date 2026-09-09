class_name PlayerAdventureState
extends RefCounted

var peer_id: int
var unsecured_loot: InventoryModel

func _init(p_peer_id: int = 0, resolver: Callable = Callable(), capacity: int = 24) -> void:
	peer_id = p_peer_id
	unsecured_loot = InventoryModel.new(capacity, resolver)
