class_name GameplayNotificationChannel
extends Node

# Dedicated RPC node for host -> owner gameplay notifications, created by
# NetworkManager as its child (/root/NetworkManager/GameplayNotifications).
#
# The RPC deliberately does not live on NetworkManager itself: adding any RPC
# method to NetworkManager's existing RPC table made mixed Windows release /
# editor processes crash (0xC0000005) during the ENet export validation, while
# the same logic without that table change passed. Keeping NetworkManager's
# RPC surface unchanged avoids that engine-level fragility.
#
# Multiplayer authority is the server (peer 1, the default), so "authority"
# means a client can never send this to the host or to another client.

const NODE_NAME := &"GameplayNotifications"

@rpc("authority", "call_remote", "reliable")
func _receive(message: String) -> void:
	NetworkManager._receive_gameplay_notification(message)
