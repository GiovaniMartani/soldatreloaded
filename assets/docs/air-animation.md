# Velocity-driven airborne animation

The client layers optional POA poses over airborne Jump, Jump_Side, Fall, Run and Run_Back states. Horizontal air steering without jets preserves the original airborne Run/Run_Back pose. It preserves the original movement state machines, collision poses, weapon timing, network animation IDs and demo format. The rendered legs and idle/aiming upper body use the new poses; reload, recoil, throwing and other authored upper-body actions retain their original animation. Aim is applied after pose composition. Prone, crouch, rolls, grounded and dead soldiers use the original pose.

## Clips

Place these files in `assets/data/anims/` in the source tree, or `data/anims/` beside the game executable:

| Jetting (jet held, fuel available) | Airborne without jets |
| --- | --- |
| `Jet_Rise.poa` | `Jump_Rise.poa` |
| | `Jump_Anticipation.poa` |
| `Jet_Backward_0.poa`, `Jet_Backward_1.poa` | `Jump_Hover.poa` |
| `Jet_Forward_0.poa`, `Jet_Forward_1.poa` | `Jump_Fall.poa` |
| `Jet_Fall.poa` | |

The `_0` clips are the intent poses and the `_1` clips are the full-speed poses. All four are included. When directional input is released, remaining horizontal velocity continues to blend this same pair; the unsuffixed Jet Forward/Backward files are unused.

The jet clips have 60 frames each. Jump Anticipation has 9 frames; Jump Rise, Hover and Fall have 16, 21 and 7 respectively. The first nine frames of the internal Jump state display Jump Anticipation while its existing movement timing remains intact. With horizontal steering or active jets, the usual running/jetting rules take priority. Missing anticipation art falls back to the original Jump pose. A missing or invalid airborne clip preserves its weighted contribution from the original animation. Files must contain all 20 points in each frame, terminate with ENDFILE and have at most 240 frames. They load when match art loads; restart the game after replacing them.

## Blend

Without active jets, holding Left or Right preserves the original movement pose (including airborne Run and Run_Back). Jump Rise/Hover/Fall apply only when neither horizontal button is held, even if the character still has horizontal momentum. Releasing steering resumes the vertical jump blend. Active jets retain their input-driven blend; holding Jet with no fuel counts as non-jet movement.

X is horizontal velocity relative to the character's facing direction. Soldat's Y increases downward: negative Y selects Rise, positive Y selects Fall. Keys alone do not choose a directional pose. Thus a falling player who activates jets still shows Jet Fall until upward thrust reverses their velocity.

Without horizontal input, jet blending uses velocity relative to the character's facing direction. Remaining weight near zero speed goes to Jet Rise (no neutral jet clip was supplied). At high speeds weights remain normalized. The full-pose speed thresholds are 2.97 for Jet Forward/Backward, 3.0 for Jet Rise/Fall and 1.5 for Jump Rise/Fall; Jump Hover has a zero threshold.

With horizontal input, world-space intent selects Forward or Backward relative to facing. Progress from `_0` to `_1` is `clamp(velocity.x * intent / 2.97, 0, 1)`. When momentum opposes intent, progress is zero; crossing zero does not switch clips. Sustained steering increases the `_1` contribution.

The horizontal pair shares weight `1 / (1 + vertical_speed / 3)`; Rise or Fall receives the rest. Opposing buttons cancel in this visual layer, although movement may already have resolved them. Releasing horizontal input returns to velocity-driven coasting. Changing facing remaps Forward/Backward without changing world-space speed progression. Direction reversal crossfades over 0.27 seconds; Jump ↔ directional Jet crossfades over 0.22 seconds.

Jump blending is vertical: Rise at Y=-1.5, Hover at Y=0, Fall at Y=+1.5, interpolated between those speeds. All clips share a two-second looping phase derived from simulation ticks; their different frame counts are sampled at the same normalized phase.

The selected transition times are fixed at 0.27 seconds for Jet Backward ↔ Jet Forward and 0.22 seconds for Jump ↔ directional Jet. Game pacing remains at its normal speed.

Airborne Run/Run Back blends into directional Jet or Jump Rise/Hover/Fall using the Jump/Jet transition time. The previous run frame is held as the visual source during that short crossfade; reversing back to airborne run also blends. Soldat's original `Fall` animation ID remains in the movement and collision state machine to preserve gameplay and network compatibility. With the supplied jump clips loaded, `Jump_Fall.poa` replaces its visible falling pose at full falling speed. If the optional clip is missing, the original pose remains the fallback.

The blend constants and filenames are in `core/resources/air_animation.odin`. The gameplay POA loader's 40-frame limit is unchanged; these optional visual clips use their own strict 240-frame loader. These are point-pose blends, not a skeletal IK solver: extremes may shorten a limb as with other point interpolation.

## Checks

`odin test tests/air-animation` covers directional weights, facing, speed influence, falling jets, anticipation, missing clips, partial fallback and state gating. The suite is included in CI. Legacy pendant and dread roots follow the visual head pose. The animation system uses no custom hair code or assets.
