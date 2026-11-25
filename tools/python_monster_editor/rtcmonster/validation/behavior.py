"""The state graph.

Module-specific knowledge lives on the module (``raises``, ``terminal``,
``hurt_reaction``, ``checks``); condition-specific knowledge on the condition
(``signal``, ``immediate``). The rules below only read those, so a new module
or condition is validated without touching this file.

What "never waits" means: a transition whose condition is ``immediate`` fires
on the first tick. A *cycle* made only of such transitions is a livelock - the
monster switches state every tick and does nothing. A loop that passes through
a state which waits (a timer, a patrol, a signal) is ordinary behaviour and is
never reported.
"""

from ..schema import condition_leaves
from .context import rule
from .report import AI, FAIL, WARNING, define

define(AI, FAIL, {
    "no_states": "The behaviour has no states.",
    "initial_state_missing": "The initial state does not exist.",
    "unknown_module": "A state names a module that is not registered.",
    "module_not_available": "A state names a module that is reserved but has no contract yet.",
    "state_never_exits": "A non-terminal state has no transition that can ever fire.",
    "immediate_transition_cycle": "Unconditional transitions form a cycle that never waits for anything.",
    "death_state_not_terminal": "The death interrupt points at a state whose module is not terminal.",
    "hurt_state_missing": "The hurt interrupt is enabled but names no state.",
    "no_attack_patterns": "A state runs attack patterns but the document has none.",
})
define(AI, WARNING, {
    "transition_shadowed": "An earlier unconditional transition makes this one unreachable.",
    "transition_never_fires": "The transition waits for a signal its state's module never raises.",
    "completion_unhandled": "The module finishes, but no transition reacts to it.",
    "unreachable_state": "No transition or interrupt leads to this state.",
    "hurt_state_without_hurt_reaction": "The hurt interrupt points at a state that is not a hurt reaction.",
})


def _always_true(context, condition):
    if "all" in condition:
        return all(_always_true(context, part) for part in condition["all"])
    if "any" in condition:
        return any(_always_true(context, part) for part in condition["any"])
    return "not" not in condition and context.registry.conditions[condition["type"]].immediate


def _can_fire(context, condition, raised):
    """False only when the condition provably waits for a signal that is never raised."""
    if "all" in condition:
        return all(_can_fire(context, part, raised) for part in condition["all"])
    if "any" in condition:
        return any(_can_fire(context, part, raised) for part in condition["any"])
    if "not" in condition:
        return True
    signal = context.registry.conditions[condition["type"]].signal
    return not signal or signal in raised


@rule
def state_graph(context):
    behavior = context.data["behavior"]
    states = behavior["states"]
    if not states:
        context.add("no_states", "behavior.states")
        return
    if behavior["initial_state"] not in context.states:
        context.add("initial_state_missing", "behavior.initial_state", behavior["initial_state"])
    hurt, death = behavior["interrupts"]["hurt"], behavior["interrupts"]["death"]
    if hurt["policy"] == "always" and not hurt["state"]:
        context.add("hurt_state_missing", "behavior.interrupts.hurt.state")
    hurt_state, death_state = context.states.get(hurt["state"]), context.states.get(death["state"])
    hurt_module = context.module(hurt_state) if hurt_state else None
    if hurt_state is not None and not getattr(hurt_module, "hurt_reaction", False):
        context.add("hurt_state_without_hurt_reaction", "behavior.interrupts.hurt.state", hurt["state"],
                    subject=hurt["state"])
    death_module = context.module(death_state) if death_state else None
    if death_state is not None and not getattr(death_module, "terminal", False):
        context.add("death_state_not_terminal", "behavior.interrupts.death.state", death["state"],
                    subject=death["state"])
    immediate = {}
    for index, state in enumerate(states):
        path, subject = f"behavior.states[{index}]", state["id"]
        module = context.module(state)
        if module is None:
            reserved = state["module"] in context.registry.reserved_modules
            context.add("module_not_available" if reserved else "unknown_module", f"{path}.module",
                        state["module"] + (" is reserved for a later step" if reserved else ""), subject=subject)
            continue
        for check in module.checks:
            check(context, state, path)
        if module.terminal:
            if state["transitions"]:
                context.add("transition_never_fires", f"{path}.transitions",
                            f"{module.id} never leaves its state", subject=subject)
            continue
        raised = module.raises(state["params"], state["max_seconds"] is not None)
        ordered = sorted(enumerate(state["transitions"]), key=lambda row: (-row[1]["priority"], row[0]))
        usable, shadow = 0, None
        for transition_index, transition in ordered:
            transition_path = f"{path}.transitions[{transition_index}]"
            if shadow is not None:
                context.add("transition_shadowed", transition_path,
                            f"an unconditional transition to {shadow} is evaluated first", subject=subject)
                continue
            if not _can_fire(context, transition["condition"], raised):
                context.add("transition_never_fires", transition_path,
                            f"{module.id} never raises that signal", subject=subject)
                continue
            usable += 1
            if _always_true(context, transition["condition"]):
                shadow = transition["to"]
                immediate[state["id"]] = transition["to"]
        handled = {context.registry.conditions[leaf["type"]].signal
                   for transition in state["transitions"] for _, leaf in condition_leaves(transition["condition"])}
        if usable == 0:
            context.add("state_never_exits", path,
                        f"{subject} has no transition that can fire, so the monster stays there forever",
                        subject=subject)
        elif (raised - {"failed"}) and not (raised - {"failed"}) & handled:
            context.add("completion_unhandled", path, f"{module.id} finishes but no transition reacts to it",
                        subject=subject)
    _reachability(context, behavior, hurt, death)
    _immediate_cycles(context, immediate)


def _reachability(context, behavior, hurt, death):
    frontier = [behavior["initial_state"], death["state"]] + ([hurt["state"]] if hurt["policy"] == "always" else [])
    frontier += [phase["enter_state"] for phase in behavior["phases"]]
    reached = set()
    while frontier:
        state = context.states.get(frontier.pop())
        if state is None or state["id"] in reached:
            continue
        reached.add(state["id"])
        frontier.extend(transition["to"] for transition in state["transitions"])
    for index, state in enumerate(behavior["states"]):
        if state["id"] not in reached:
            context.add("unreachable_state", f"behavior.states[{index}]", state["id"], subject=state["id"])


def _immediate_cycles(context, immediate):
    reported = set()
    for start in immediate:
        trail, current = [], start
        while current in immediate and current not in trail:
            trail.append(current)
            current = immediate[current]
        if current in trail:
            cycle = trail[trail.index(current):]
            if frozenset(cycle) not in reported:
                reported.add(frozenset(cycle))
                context.add("immediate_transition_cycle", "behavior.states",
                            " -> ".join(cycle + [current]) + " never waits for anything",
                            related=tuple(cycle), subject=cycle[0])
