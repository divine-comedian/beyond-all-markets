#include "../../define.as"
#include "../../unit.as"
#include "../../task.as"


// MKTWAR AI OVERRIDE (2026-07-15) — sea/air commitment.
// Stock BARb returns aiMilitaryMgr.DefaultMakeTask(unit) for every military
// unit. In the sea (SPX/GOLD, teams 2-5) and air (ETH, teams 6/7) lanes that
// default micro makes fleets/aircraft advance to the shore, then retreat under
// the retreat/defend logic instead of crossing the open water — the classic
// "move up then go back repeatedly and never send the boats across" turtling.
// Overnight + live traces (2026-07-15) confirmed GOLD ships oscillating ~750
// elmos around the midpoint rather than committing to the enemy commander.
//
// Fix: for those lanes, force mobile COMBAT units into an ATTACK fight task so
// they commit across the water to the enemy. This changes the UNDERLYING AI
// task selection (the correct layer) rather than fighting it with Lua order
// overrides. The land lane (BTC, teams 0/1) keeps stock behaviour. Builders,
// static, AA, scouts and the commander keep their default jobs so eco, air
// defence, recon and the win-condition unit are untouched.
//
// teamId >= 2 == all sea+air lanes in this game's fixed 0..7 layout
// (BTC 0/1 land, SPX 2/3 sea, GOLD 4/5 sea, ETH 6/7 air). MarketWar-specific.
// Fully reversible: restore scripts/ai-overrides/military.as.orig.

namespace Military {

IUnitTask@ AiMakeTask(CCircuitUnit@ unit)
{
	if (ai.teamId >= 2) {
		const CCircuitDef@ def = unit.circuitDef;
		if (def !is null) {
			const Type role = def.GetMainRole();
			if (role != RT::BUILDER && role != RT::STATIC && role != RT::COMM
					&& role != RT::AA && role != RT::SCOUT) {
				return aiMilitaryMgr.Enqueue(TaskF::Common(Task::FightType::ATTACK));
			}
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
