"""A real v18 ENet handshake must never attach to the v19 server."""
import test_multiplayer_world_runtime as harness

harness.SCENE = "res://tests/integration/multiplayer_protocol_probe.tscn"

if __name__ == "__main__":
    raise SystemExit(harness.main())
