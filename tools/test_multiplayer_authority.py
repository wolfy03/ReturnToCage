"""Actual ENet gameplay-authority negative and lifecycle regression suite."""
import test_multiplayer_world_runtime as harness

harness.SCENE = "res://tests/integration/multiplayer_authority_probe.tscn"

if __name__ == "__main__":
    raise SystemExit(harness.main())
