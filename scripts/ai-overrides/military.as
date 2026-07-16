#include "../../define.as"
#include "../../unit.as"
#include "../../task.as"


// MKTWAR AI OVERRIDE (2026-07-16) — all-lane combat commitment.
// Stock BARb returns aiMilitaryMgr.DefaultMakeTask(unit) for every military
// unit, whose default micro makes units advance toward the front, then retreat
// under the retreat/defend logic instead of crossing to the enemy. The result
// is the classic MarketWar turtling: sea/air fleets oscillate at the shoreline
// (GOLD ships traced oscillating ~750 elmos around the midpoint, 2026-07-15),
// and the land lanes MASS combat units in a defensive "bee-hive" grid at base
// and never push the choke.
//
// Fix: for EVERY lane, force mobile COMBAT units into an ATTACK fight task so
// they commit to the enemy. This changes the UNDERLYING AI task selection (the
// correct layer) rather than fighting it with Lua order overrides. Builders,
// static, AA, scouts and the commander keep their default jobs so eco, air
// defence, recon and the win-condition unit are untouched.
//
// Applies to all 8 teams (BTC 0/1 land, SPX 2/3 sea, GOLD 4/5 sea, ETH 6/7 air).
// The prior revision gated this on `teamId >= 2` (sea/air only), which left the
// BTC mid land lane turtling; that gate is removed here on request (2026-07-16).
// Fully reversible: restore scripts/ai-overrides/military.as.orig.

namespace Military {

IUnitTask@ AiMakeTask(CCircuitUnit@ unit)
{
	const CCircuitDef@ def = unit.circuitDef;
	if (def !is null) {
		const Type role = def.GetMainRole();
		if (role != RT::BUILDER && role != RT::STATIC && role != RT::COMM
				&& role != RT::AA && role != RT::SCOUT) {
			return aiMilitaryMgr.Enqueue(TaskF::Common(Task::FightType::ATTACK));
		}
	}
	return aiMilitaryMgr.DefaultMakeTask(unit);
}

void AiTaskAdded(IUnitTask@ task)
{
}

void AiTaskRemoved(IUnitTask@ task, bool done)
{
}

void AiUnitAdded(CCircuitUnit@ unit, Unit::UseAs usage)
{
}

void AiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
{
}

void AiLoad(IStream& istream)
{
}

void AiSave(OStream& ostream)
{
}

void AiMakeDefence(int cluster, const AIFloat3& in pos)
{
	if ((ai.frame > 5 * MINUTE)
		|| (aiEconomyMgr.metal.income > 10.f)
		|| (aiEnemyMgr.mobileThreat > 0.f))
	{
		aiMilitaryMgr.DefaultMakeDefence(cluster, pos);
	}
}

}  // namespace Military
