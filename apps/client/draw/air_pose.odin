package draw

import sim "../../../core/game"
import res "../../../core/resources"
import "../../../core/utils"

Air_Transition :: struct {
    current, from: res.Air_Weights,
    mode: i32,
    life: u8,
    elapsed: f32,
    duration: f32,
    ready: bool,
    legacy_legs, legacy_body: res.Animation_Frame,
    legacy_source: bool,
}

air_mode :: proc(soldier: ^sim.Soldier) -> i32 {
    if !soldier.active || soldier.vitals.dead || soldier.body.on_ground do return 0
    jet := .Jet in soldier.controls.buttons && soldier.body.jet_fuel > 0
    if !jet {
        if .Left in soldier.controls.buttons || .Right in soldier.controls.buttons do return 5
        return 1
    }
    intent: i32
    if .Left in soldier.controls.buttons do intent -= 1
    if .Right in soldier.controls.buttons do intent += 1
    if intent != 0 do return 2 if intent*i32(soldier.body.direction) > 0 else 3
    return 4
}

air_transition_step :: proc(state: ^Air_Transition, soldier: ^sim.Soldier, tune: res.Air_Tuning, dt: f32, previous: ^sim.Soldier = nil, animations: ^res.Animations = nil) {
    mode := air_mode(soldier)
    if mode == 0 {
        state^ = {}
        return
    }
    intent: i32
    if .Left in soldier.controls.buttons do intent -= 1
    if .Right in soldier.controls.buttons do intent += 1
    target: res.Air_Weights
    if mode != 5 do target = res.air_weights_tuned(soldier.body.velocity, i32(soldier.body.direction), mode != 1, intent, tune)
    if !state.ready || state.life != soldier.vitals.life {
        state^ = {current=target,mode=mode,life=soldier.vitals.life,ready=true}
        return
    }
    if mode != state.mode {
        old_mode := state.mode
        state.from = state.current
        state.elapsed = 0
        state.duration = tune.jet_direction_blend if (mode == 2 && state.mode == 3) || (mode == 3 && state.mode == 2) else tune.jump_jet_blend
        state.mode = mode
        state.legacy_source = old_mode == 5 && previous != nil && animations != nil
        if state.legacy_source {
            state.legacy_legs = res.animation_frame(&animations[previous.pose.legs.id], previous.pose.legs.frame)^
            state.legacy_body = res.animation_frame(&animations[previous.pose.body.id], previous.pose.body.frame)^
        }
    }
    state.elapsed += dt
    alpha := clamp(state.elapsed/max(state.duration,0.001),0,1)
    for &weight, id in state.current do weight = state.from[id]*(1-alpha)+target[id]*alpha
    if alpha == 1 {
        state.from = state.current
        state.legacy_source = false
    }
}

visual_soldier_pose :: proc(animations: ^res.Animations, clips: ^res.Air_Animations, soldier: ^sim.Soldier, pos: utils.Vec2, tick: u32, state: ^Air_Transition = nil, tune: ^res.Air_Tuning = nil) -> sim.Joints {
    if clips == nil || !soldier.active || soldier.vitals.dead || soldier.controls.stance != .Stand {
        return sim.soldier_pose(animations, soldier, pos)
    }
    // The first nine legacy Jump ticks are the wind-up; keep the game state and
    // impulse timing, but display the authored anticipation clip instead of skok.poa.
    jet := .Jet in soldier.controls.buttons && soldier.body.jet_fuel > 0
    if soldier.pose.legs.id == .Jump && soldier.pose.legs.frame >= 1 && soldier.pose.legs.frame <= 9 &&
       !jet && .Left not_in soldier.controls.buttons && .Right not_in soldier.controls.buttons {
        clip := &clips[.Jump_Anticipation]
        if clip.count > 0 {
            frame := &clip.frames[min(int(soldier.pose.legs.frame)-1,clip.count-1)]
            #partial switch soldier.pose.body.id {
            case .Stand, .Aim, .Hands_Up_Aim:
                return sim.soldier_pose(animations, soldier, pos, frame, frame)
            case:
                return sim.soldier_pose(animations, soldier, pos, frame)
            }
        }
    }
    if soldier.body.on_ground do return sim.soldier_pose(animations, soldier, pos)
    #partial switch soldier.pose.legs.id {
    // move_run selects these locomotion states even in the air, after jets_control.
    // Ground contact above, rather than the Run ID, determines whether to blend.
    case .Jump, .Jump_Side, .Fall, .Run, .Run_Back:
    case: return sim.soldier_pose(animations, soldier, pos)
    }
    // Preserve the original airborne locomotion while steering without active jets.
    // Test either button, not net intent: opposing held buttons are still input.
    if !jet && (.Left in soldier.controls.buttons || .Right in soldier.controls.buttons) && (state == nil || !state.ready || state.mode != 5 || state.elapsed >= state.duration) {
        return sim.soldier_pose(animations, soldier, pos)
    }
    intent: i32
    if .Left in soldier.controls.buttons do intent -= 1
    if .Right in soldier.controls.buttons do intent += 1
    // Terminal horizontal air speed under sustained steering, after damping.
    full_speed := sim.FLY_SPEED*sim.SOLDIER_DAMPING/(1-sim.SOLDIER_DAMPING)
    weights := res.air_weights(soldier.body.velocity, i32(soldier.body.direction), jet, intent, full_speed)
    if tune != nil do weights = res.air_weights_tuned(soldier.body.velocity, i32(soldier.body.direction), jet, intent, tune^)
    if state != nil && state.ready do weights = state.current
    old_legs := res.animation_frame(&animations[soldier.pose.legs.id], soldier.pose.legs.frame)
    original_legs := old_legs^
    if state != nil && state.legacy_source do original_legs = state.legacy_legs
    legs, strength := res.air_sample(clips, weights, tick, original_legs)
    if strength == 0 && (state == nil || !state.legacy_source) do return sim.soldier_pose(animations, soldier, pos)
    body: res.Animation_Frame
    body_override: ^res.Animation_Frame
    // Aim is applied after composition. Weapon actions keep their authored upper body.
    #partial switch soldier.pose.body.id {
    case .Stand, .Aim, .Hands_Up_Aim:
        original := res.animation_frame(&animations[soldier.pose.body.id], soldier.pose.body.frame)
        original_body := original^
        if state != nil && state.legacy_source do original_body = state.legacy_body
        body, _ = res.air_sample(clips, weights, tick, original_body)
        body_override = &body
    }
    return sim.soldier_pose(animations, soldier, pos, &legs, body_override)
}
