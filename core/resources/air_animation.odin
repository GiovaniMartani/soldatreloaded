package resources

import "core:math"
import "core:strconv"
import "../utils"

// Optional cosmetic clips: never added to Animation_Id or the network state.
Air_Clip_Id :: enum {Jet_Rise, Jet_Fall, Jump_Rise, Jump_Hover, Jump_Fall, Jet_Forward_0, Jet_Forward_1, Jet_Backward_0, Jet_Backward_1, Jump_Anticipation}
AIR_CLIP_FILES := [Air_Clip_Id]string{
    .Jet_Rise="Jet_Rise.poa", .Jet_Fall="Jet_Fall.poa",
    .Jump_Rise="Jump_Rise.poa", .Jump_Hover="Jump_Hover.poa", .Jump_Fall="Jump_Fall.poa",
    .Jet_Forward_0="Jet_Forward_0.poa", .Jet_Forward_1="Jet_Forward_1.poa",
    .Jet_Backward_0="Jet_Backward_0.poa", .Jet_Backward_1="Jet_Backward_1.poa",
    .Jump_Anticipation="Jump_Anticipation.poa",
}
AIR_MAX_FRAMES :: 240
Air_Clip :: struct {frames: [AIR_MAX_FRAMES]Animation_Frame, count: int}
Air_Animations :: [Air_Clip_Id]Air_Clip
Air_Weights :: [Air_Clip_Id]f32
Air_Tuning :: struct {
    jet_forward_speed, jet_backward_speed: f32,
    jet_rise_speed, jet_fall_speed: f32,
    jump_rise_speed, jump_hover_speed, jump_fall_speed: f32,
    jet_direction_blend, jump_jet_blend: f32,
}
AIR_TUNING :: Air_Tuning{
    jet_forward_speed=2.97, jet_backward_speed=2.97,
    jet_rise_speed=3, jet_fall_speed=3,
    jump_rise_speed=1.5, jump_hover_speed=0, jump_fall_speed=1.5,
    jet_direction_blend=0.27, jump_jet_blend=0.22,
}

air_clip_parse :: proc(text: string) -> (clip: Air_Clip) {
    remaining := text
    seen: [MAX_ANIMATION_POINTS]bool
    points := 0
    for tag in utils.next_line(&remaining) {
        if tag == "NEXTFRAME" || tag == "ENDFILE" {
            if points != MAX_ANIMATION_POINTS || clip.count >= AIR_MAX_FRAMES do return {}
            clip.count += 1
            if tag == "ENDFILE" do return
            seen = {}; points = 0
            continue
        }
        index, valid := strconv.parse_int(tag)
        if !valid || index < 1 || index > MAX_ANIMATION_POINTS || clip.count >= AIR_MAX_FRAMES do return {}
        if seen[index-1] do return {}
        xyz: [3]f32
        for &value in xyz {
            line, exists := utils.next_line(&remaining)
            number, ok := strconv.parse_f64(line)
            if !exists || !ok || math.is_nan(number) || math.is_inf(number) || math.abs(number) > 10000 do return {}
            value = f32(number)
        }
        clip.frames[clip.count][index-1] = {-ANIMATION_SCALE*xyz[0]/1.1, -ANIMATION_SCALE*xyz[2]}
        seen[index-1] = true; points += 1
    }
    return {} // incomplete files are optional, so use the legacy pose
}

air_animations_load :: proc(data_dir: string) -> ^Air_Animations {
    clips := new(Air_Animations)
    for file, id in AIR_CLIP_FILES {
        path := utils.temp_path(data_dir, "anims", file)
        if !utils.file_exists(path) do continue
        bytes, ok := utils.read_file(path, context.temp_allocator)
        if ok do clips[id] = air_clip_parse(string(bytes))
    }
    return clips
}

// World Y points down. X is relative to facing; velocity, not input, drives direction.
// At 3 world units/tick the directional pose reaches full strength. At rest jets use Rise.
air_weights :: proc(velocity: utils.Vec2, direction: i32, jet: bool, intent: i32 = 0, full_speed: f32 = 2.97) -> (weights: Air_Weights) {
    if jet {
        if intent != 0 {
            // World-space intent is compared with velocity before facing is applied.
            // Opposite momentum therefore stays at the intent pose until reversal.
            requested: f32 = -1 if intent < 0 else 1
            progress := clamp(velocity.x*requested/max(full_speed,0.01),0,1)
            y := velocity.y/3
            horizontal := 1/(1+math.abs(y))
            forward := requested*f32(direction) > 0
            weights[.Jet_Forward_0 if forward else .Jet_Backward_0] = horizontal*(1-progress)
            weights[.Jet_Forward_1 if forward else .Jet_Backward_1] = horizontal*progress
            weights[.Jet_Rise] = max(0,-y)*horizontal
            weights[.Jet_Fall] = max(0,y)*horizontal
            return
        }
        x := velocity.x * f32(direction) / 3
        y := velocity.y / 3
        total := max(1, math.abs(x)+math.abs(y))
        forward := max(0,x)/total
        backward := max(0,-x)/total
        weights[.Jet_Forward_0] = forward*(1-clamp(x,0,1))
        weights[.Jet_Forward_1] = forward*clamp(x,0,1)
        weights[.Jet_Backward_0] = backward*(1-clamp(-x,0,1))
        weights[.Jet_Backward_1] = backward*clamp(-x,0,1)
        weights[.Jet_Fall] = max(0,y)/total
        weights[.Jet_Rise] = max(0,-y)/total + max(0,1-math.abs(x)-math.abs(y))
    } else {
        y := clamp(velocity.y/1.5, -1, 1)
        weights[.Jump_Rise] = max(0,-y)
        weights[.Jump_Fall] = max(0,y)
        weights[.Jump_Hover] = 1-math.abs(y)
    }
    return
}

air_weights_tuned :: proc(velocity: utils.Vec2, direction: i32, jet: bool, intent: i32, tune: Air_Tuning) -> (weights: Air_Weights) {
    if jet {
        if intent != 0 {
            requested: f32 = -1 if intent < 0 else 1
            forward := requested*f32(direction) > 0
            speed := tune.jet_forward_speed if forward else tune.jet_backward_speed
            progress := clamp(velocity.x*requested/max(speed,0.01),0,1)
            rise := max(0,-velocity.y)/max(tune.jet_rise_speed,0.01)
            fall := max(0,velocity.y)/max(tune.jet_fall_speed,0.01)
            horizontal := 1/(1+rise+fall)
            weights[.Jet_Forward_0 if forward else .Jet_Backward_0] = horizontal*(1-progress)
            weights[.Jet_Forward_1 if forward else .Jet_Backward_1] = horizontal*progress
            weights[.Jet_Rise] = rise*horizontal
            weights[.Jet_Fall] = fall*horizontal
            return
        }
        x := velocity.x*f32(direction)
        rise := max(0,-velocity.y)/max(tune.jet_rise_speed,0.01)
        fall := max(0,velocity.y)/max(tune.jet_fall_speed,0.01)
        forward := max(0,x)/max(tune.jet_forward_speed,0.01)
        backward := max(0,-x)/max(tune.jet_backward_speed,0.01)
        total := max(1,forward+backward+rise+fall)
        weights[.Jet_Forward_0] = forward/max(total,0.01)*(1-clamp(forward,0,1))
        weights[.Jet_Forward_1] = forward/max(total,0.01)*clamp(forward,0,1)
        weights[.Jet_Backward_0] = backward/max(total,0.01)*(1-clamp(backward,0,1))
        weights[.Jet_Backward_1] = backward/max(total,0.01)*clamp(backward,0,1)
        weights[.Jet_Rise] = (rise+max(0,1-forward-backward-rise-fall))/total
        weights[.Jet_Fall] = fall/total
    } else {
        rise := clamp((max(0,-velocity.y)-tune.jump_hover_speed)/max(tune.jump_rise_speed-tune.jump_hover_speed,0.01),0,1)
        fall := clamp((max(0,velocity.y)-tune.jump_hover_speed)/max(tune.jump_fall_speed-tune.jump_hover_speed,0.01),0,1)
        weights[.Jump_Rise] = rise
        weights[.Jump_Fall] = fall
        weights[.Jump_Hover] = 1-rise-fall
    }
    return
}

// A shared two-second cycle keeps differently sized clips in phase at 60 Hz.
// Missing contributors retain their share of the original pose, rather than snapping.
air_sample :: proc(clips: ^Air_Animations, weights: Air_Weights, tick: u32, fallback: Animation_Frame) -> (pose: Animation_Frame, strength: f32) {
    pose = fallback
    if clips == nil do return
    phase := f32(tick % 120)/120
    for weight, id in weights {
        clip := &clips[id]
        if weight <= 0 || clip.count == 0 do continue
        cursor := phase*f32(clip.count)
        a := int(cursor); b := (a+1)%clip.count; t := cursor-f32(a)
        for &point, i in pose {
            sampled := clip.frames[a][i] + (clip.frames[b][i]-clip.frames[a][i])*t
            point += (sampled-fallback[i])*weight
        }
        strength += weight
    }
    return
}
