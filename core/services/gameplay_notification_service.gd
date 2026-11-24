class_name GameplayNotificationService
extends RefCounted

# Routes gameplay status text to the player it belongs to.
#
# There is exactly one locally displayed message per process (the HUD status
# line, exposed as GameSession.last_message). Authoritative code that acts on
# behalf of a peer must not write it directly: on a host that would show a
# remote player's private result on the host HUD. Instead:
#
#   notify_local(message)            UI/session text for this process's user.
#   notify_player(player_id, msg)    Private result for one persistent player.
#                                    Shown locally only if that player is the
#                                    local player; otherwise the host sends it
#                                    to that player's own authenticated peer.
#   notify_shared(message, actor)    Settlement-wide event. Shown locally and
#                                    sent to every ready remote peer except the
#                                    actor, who already receives a personal
#                                    command result.
#
# Remote delivery goes through NetworkManager's authority-only notification
# RPC; clients never originate notifications.

# Emitted only when a notification arrives from the host over the network, so
# the HUD can refresh a status line nothing local changed. Local writes keep
# the pre-existing behaviour: callers refresh their own UI, and no UI work runs
# synchronously inside authoritative state transitions or session teardown.
signal remote_message_received(message: String)

var local_message: String:
	get:
		return GameSession.last_message

func notify_local(message: String) -> void:
	GameSession.last_message = message

func receive_remote(message: String) -> void:
	GameSession.last_message = message
	remote_message_received.emit(message)

func clear_local() -> void:
	GameSession.last_message = ""

# `deliver_remote` is false for commands whose requester already receives the
# same text through its own command-result RPC (craft, upgrade, quest reward),
# so a remote requester is not notified twice.
func notify_player(player_id: StringName, message: String, deliver_remote: bool = true) -> void:
	if message.is_empty():
		return
	if is_local_player(player_id):
		notify_local(message)
	elif deliver_remote:
		NetworkManager.send_gameplay_notification(player_id, message)

func notify_peer(peer_id: int, message: String, deliver_remote: bool = true) -> void:
	notify_player(GameSession.get_player_id(peer_id), message, deliver_remote)

func notify_shared(message: String, actor_player_id: StringName = &"") -> void:
	if message.is_empty():
		return
	if actor_player_id.is_empty() or not is_local_player(actor_player_id):
		notify_local(message)
	NetworkManager.broadcast_shared_notification(message, actor_player_id)

func is_local_player(player_id: StringName) -> bool:
	if not NetworkManager.is_multiplayer_active():
		# Offline has a single player; every gameplay actor is the local user.
		return true
	return not player_id.is_empty() and player_id == GameSession.get_local_player_id()
