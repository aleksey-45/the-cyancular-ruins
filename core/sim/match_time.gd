@abstract
class_name MatchTime
extends RefCounted

@abstract func advance(combat: CombatSimulator, inputs: Dictionary, tick: int) -> void
@abstract func account_for(role: int) -> GrainAccount
@abstract func reset_history(role: int) -> void
@abstract func capture() -> Dictionary
@abstract func restore(state: Dictionary) -> void
