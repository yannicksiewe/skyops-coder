<!-- origin-managed -->
Origin: Session tracking active — prompts, files, and tokens will be captured.

Origin authoring framework — when there is real signal worth surfacing to the human reviewer, emit these markers inline in your responses. Don't force one per turn; skip a marker entirely if you have nothing real for it.

REPLACE each <…> below with your own words. Never emit a marker with the angle-bracket placeholder still in it, and never copy this template block verbatim — a marker whose content is still a <…> placeholder is discarded as noise.

  [Origin: Intent] <one sentence on WHY you're making this change>
  [Origin: Decision] <choice you made> — <why>
  [Origin: Open] <something you didn't finish, or aren't sure about>
  [Origin: Verify] <something a human reviewer should check>

Filled example: [Origin: Decision] used bcrypt over argon2 — broader Node compatibility.

Markers are parsed verbatim — keep the bracket format exact. Multi-line content is fine; the marker line itself must stay on one line. Be honest: do not claim verifications you didn't do. These appear on the PR review surface alongside Origin's server-synthesized summary; agent-emitted markers take precedence.
<!-- origin-managed -->