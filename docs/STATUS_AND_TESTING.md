# Status and testing

Recommended: v21. The user reported many hours of enjoyable gameplay with this version. This is the retained pre-teleport baseline, not v29.

## Evidence

- Act Mode player HP was confirmed fixed without also making enemies invulnerable.
- Infinite lives worked early. MP and damage required subsequent corrections; no blanket cross-version guarantee is made.
- No Player Hit Detection was reported to work, including avoiding damage and knockback, in v20.
- Settlement scripts were progressively user-tested: SP increase, resources, item counts, champion-related changes, fort/fence limits, and fences. See the v21 feature catalog for exact retained options.
- A normal-map Angel Death Aura was discussed separately from invasion/siege events. The table inventory, not a reconstructed guess, defines what v21 contains.

## Do not use abandoned experiments as upgrades

Act Mode Death/Loot Aura attempts produced unattackable objects, uncollectable or expired drops, and a crash. The user abandoned that direction.

Gold-scroll/statue teleport versions v22-v29 had detection failures, false success reports, crashes, and destinations inside walls. The user explicitly requested scrapping teleport and reverting to the previous best table. These files are retained only as research history. Do not enable them in normal play.

## Future regression checklist

Test each retained feature in its correct mode, test MP once magic is available, confirm enemy damage remains normal when appropriate, and verify siege/champion behavior separately from regular settlement gameplay. Disable broad modifiers around progression-sensitive events.