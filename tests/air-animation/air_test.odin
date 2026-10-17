package air_animation_test

import "core:testing"
import "core:math"
import res "../../core/resources"
import sim "../../core/game"
import draw "../../apps/client/draw"

@(test)
shipped_jump_loading_and_rendering :: proc(t: ^testing.T) {
    clips := res.air_animations_load("assets/data"); defer free(clips)
    for id in ([3]res.Air_Clip_Id{.Jump_Rise,.Jump_Hover,.Jump_Fall}) {
        testing.expectf(t,clips[id].count>0 && clips[id].count<=res.AIR_MAX_FRAMES,"jump asset loaded: %v",id)
    }
    animations := new(res.Animations); defer free(animations)
    for dir in ([2]i32{-1,1}) {
        for leg in ([5]res.Animation_Id{.Jump,.Jump_Side,.Fall,.Run,.Run_Back}) {
            for y in ([5]f32{-3,-0.75,0,0.75,3}) {
                soldier := sim.Soldier{active=true,body={direction=i8(dir),velocity={3,y},jet_fuel=100},controls={aim={100,0}},pose={legs={id=leg,frame=10},body={id=.Stand,frame=1}}}
                expected_frame := clips[.Jump_Hover].frames[0]
                if y<0 {
                    a:=min(-y/1.5,1)
                    for &point,i in expected_frame {point += (clips[.Jump_Rise].frames[0][i]-point)*a}
                } else if y>0 {
                    a:=min(y/1.5,1)
                    for &point,i in expected_frame {point += (clips[.Jump_Fall].frames[0][i]-point)*a}
                }
                expected := sim.soldier_pose(animations,&soldier,{},&expected_frame,&expected_frame)
                actual := draw.visual_soldier_pose(animations,clips,&soldier,{},0)
                for point,i in actual do testing.expect(t,math.abs(point.x-expected[i].x)<0.0001 && math.abs(point.y-expected[i].y)<0.0001)
                // Steering preserves legacy airborne run/side-jump, even with
                // both buttons held or Jet held without usable fuel.
                for buttons in ([4]sim.Buttons{{.Left},{.Right},{.Left,.Right},{.Right,.Jet}}) {
                    soldier.controls.buttons=buttons
                    soldier.body.jet_fuel=0
                    testing.expect(t,draw.visual_soldier_pose(animations,clips,&soldier,{},0)==sim.soldier_pose(animations,&soldier,{}))
                }
                soldier.controls.buttons={}
                soldier.body.jet_fuel=100
                resumed := draw.visual_soldier_pose(animations,clips,&soldier,{},0)
                for point,i in resumed do testing.expect(t,math.abs(point.x-actual[i].x)<0.0001 && math.abs(point.y-actual[i].y)<0.0001)
                soldier.body.on_ground=true
                testing.expect(t,draw.visual_soldier_pose(animations,clips,&soldier,{},0)==sim.soldier_pose(animations,&soldier,{}))
            }
        }
    }
    soldier := sim.Soldier{active=true,body={direction=1,velocity={0,-3},jet_fuel=100},controls={buttons={.Jet},aim={100,0}},pose={legs={id=.Fall,frame=1},body={id=.Stand,frame=1}}}
    frame := &clips[.Jet_Rise].frames[0]
    testing.expect(t,draw.visual_soldier_pose(animations,clips,&soldier,{},0)==sim.soldier_pose(animations,&soldier,{},frame,frame))
    for id in ([3]res.Air_Clip_Id{.Jump_Rise,.Jump_Hover,.Jump_Fall}) {clips[id]={}}
    soldier.controls.buttons={}
    testing.expect(t,draw.visual_soldier_pose(animations,clips,&soldier,{},0)==sim.soldier_pose(animations,&soldier,{}))
}

@(test)
jump_anticipation_replaces_only_early_jump_visuals :: proc(t: ^testing.T) {
    clips := res.air_animations_load("assets/data"); defer free(clips)
    testing.expect(t,clips[.Jump_Anticipation].count==9)
    animations := new(res.Animations); defer free(animations)
    soldier := sim.Soldier{active=true,body={direction=1,on_ground=true},controls={aim={100,0}},pose={legs={id=.Jump,frame=1},body={id=.Stand,frame=1}}}
    for frame in 1..=9 {
        soldier.pose.legs.frame=i32(frame)
        authored := &clips[.Jump_Anticipation].frames[frame-1]
        testing.expect(t,draw.visual_soldier_pose(animations,clips,&soldier,{},0)==sim.soldier_pose(animations,&soldier,{},authored,authored))
    }
    soldier.pose.legs.frame=10
    testing.expect(t,draw.visual_soldier_pose(animations,clips,&soldier,{},0)==sim.soldier_pose(animations,&soldier,{}))
    soldier.pose.legs.frame=2
    soldier.controls.buttons={.Right}
    testing.expect(t,draw.visual_soldier_pose(animations,clips,&soldier,{},0)==sim.soldier_pose(animations,&soldier,{}))
    soldier.controls.buttons={}
    clips[.Jump_Anticipation]={}
    testing.expect(t,draw.visual_soldier_pose(animations,clips,&soldier,{},0)==sim.soldier_pose(animations,&soldier,{}))
}

@(test)
directions_and_speed :: proc(t: ^testing.T) {
    w := res.air_weights({3,-3},1,true)
    testing.expect(t,w[.Jet_Rise]==0.5 && w[.Jet_Forward]==0.5)
    w = res.air_weights({3,-3},-1,true)
    testing.expect(t,w[.Jet_Rise]==0.5 && w[.Jet_Backward]==0.5)
    w = res.air_weights({0,3},1,true)
    testing.expect(t,w[.Jet_Fall]==1)
    w = res.air_weights({0.75,0},1,true)
    testing.expect(t,w[.Jet_Forward]==0.25 && w[.Jet_Rise]==0.75)
    w = res.air_weights({},1,true)
    testing.expect(t,w[.Jet_Rise]==1)
    for velocity in ([3]f32{-1.5,0,1.5}) {
        w = res.air_weights({4,velocity},1,false)
        testing.expect(t,w[.Jump_Rise]+w[.Jump_Hover]+w[.Jump_Fall]==1)
        if velocity==0 do testing.expect(t,w[.Jump_Hover]==1)
    }
}

@(test)
tuned_speed_thresholds_and_transition :: proc(t: ^testing.T) {
    tune := res.Air_Tuning{jet_forward_speed=2,jet_backward_speed=4,jet_rise_speed=3,jet_fall_speed=3,jump_rise_speed=2,jump_hover_speed=0.2,jump_fall_speed=2,jet_direction_blend=0.1,jump_jet_blend=0.1}
    w := res.air_weights_tuned({1,0},1,true,1,tune)
    testing.expect(t,math.abs(w[.Jet_Forward_0]-0.5)<0.0001 && math.abs(w[.Jet_Forward_1]-0.5)<0.0001)
    w = res.air_weights_tuned({-2,0},1,true,-1,tune)
    testing.expect(t,math.abs(w[.Jet_Backward_0]-0.5)<0.0001 && math.abs(w[.Jet_Backward_1]-0.5)<0.0001)
    w = res.air_weights_tuned({0,0.1},1,false,0,tune)
    testing.expect(t,w[.Jump_Hover]==1)
    soldier := sim.Soldier{active=true,body={direction=1,velocity={2,0},jet_fuel=100},controls={buttons={.Jet,.Right}}}
    state: draw.Air_Transition
    draw.air_transition_step(&state,&soldier,tune,1.0/60)
    testing.expect(t,state.mode==2 && state.current[.Jet_Forward_1]==1)
    soldier.controls.buttons={.Jet,.Left}
    draw.air_transition_step(&state,&soldier,tune,1.0/60)
    testing.expect(t,state.mode==3 && state.current[.Jet_Forward_1]>0 && state.current[.Jet_Backward_0]>0)
    for _ in 0..<8 do draw.air_transition_step(&state,&soldier,tune,1.0/60)
    testing.expect(t,state.current[.Jet_Forward_1]==0 && state.current[.Jet_Backward_0]==1)
}

@(test)
air_run_crossfades_into_jet_and_jump_fall :: proc(t: ^testing.T) {
    clips := res.air_animations_load("assets/data"); defer free(clips)
    animations := new(res.Animations); defer free(animations)
    tune := res.AIR_TUNING
    testing.expect(t,tune.jet_direction_blend==0.27 && tune.jump_jet_blend==0.22)
    previous := sim.Soldier{active=true,body={direction=1,velocity={2,1},jet_fuel=100},controls={buttons={.Right},aim={100,0}},pose={legs={id=.Run,frame=1},body={id=.Stand,frame=1}}}
    state: draw.Air_Transition
    draw.air_transition_step(&state,&previous,tune,1.0/60)
    testing.expect(t,state.mode==5 && state.current==res.Air_Weights{})
    jet := previous
    jet.controls.buttons={.Right,.Jet}
    jet.pose.legs.id=.Fall
    draw.air_transition_step(&state,&jet,tune,1.0/60,&previous,animations)
    testing.expect(t,state.mode==2 && state.legacy_source && state.current[.Jet_Forward_0]>0 && state.current[.Jet_Forward_0]<1)
    for _ in 0..<16 do draw.air_transition_step(&state,&jet,tune,1.0/60,&previous,animations)
    testing.expect(t,!state.legacy_source && state.current[.Jet_Forward_0]>0)
    state={}
    draw.air_transition_step(&state,&previous,tune,1.0/60)
    falling := previous
    falling.controls.buttons={}
    falling.body.velocity.y=3
    falling.pose.legs.id=.Fall
    draw.air_transition_step(&state,&falling,tune,1.0/60,&previous,animations)
    testing.expect(t,state.mode==1 && state.legacy_source && state.current[.Jump_Fall]>0 && state.current[.Jump_Fall]<1)
    for _ in 0..<16 do draw.air_transition_step(&state,&falling,tune,1.0/60,&previous,animations)
    testing.expect(t,state.current[.Jump_Fall]==1 && !state.legacy_source)
    pose := draw.visual_soldier_pose(animations,clips,&falling,{},0,&state,&tune)
    frame := &clips[.Jump_Fall].frames[0]
    testing.expect(t,pose==sim.soldier_pose(animations,&falling,{},frame,frame))
}

@(test)
supplied_clips_and_fallback :: proc(t: ^testing.T) {
    sources := [?]string{
        #load("../../assets/data/anims/Jet_Rise.poa"),
        #load("../../assets/data/anims/Jet_Backward.poa"),
        #load("../../assets/data/anims/Jet_Forward.poa"),
        #load("../../assets/data/anims/Jet_Fall.poa"),
    }
    for source in sources {
        clip := res.air_clip_parse(source)
        testing.expect(t,clip.count==60)
    }
    invalid := res.air_clip_parse("1\n0\n0\n0\nENDFILE")
    testing.expect(t,invalid.count==0)
    clips := new(res.Air_Animations); defer free(clips)
    clips[.Jet_Rise]=res.air_clip_parse(sources[0])
    fallback: res.Animation_Frame
    fallback[0]={12,34}
    pose,strength := res.air_sample(clips,res.air_weights({0,-3},1,false),40,fallback)
    testing.expect(t,strength==0 && pose==fallback)
    pose,strength = res.air_sample(clips,res.air_weights({3,-3},1,true),0,fallback)
    testing.expect(t,strength==0.5)
    testing.expect(t,pose[0]==fallback[0]+(clips[.Jet_Rise].frames[0][0]-fallback[0])*0.5)
    clips[.Jump_Hover]=clips[.Jet_Rise]
    _,strength = res.air_sample(clips,res.air_weights({},1,false),0,fallback)
    testing.expect(t,strength==1)
}

@(test)
state_gates_and_gameplay_pose :: proc(t: ^testing.T) {
    animations := new(res.Animations); defer free(animations)
    clips := new(res.Air_Animations); defer free(clips)
    clips[.Jet_Rise]=res.air_clip_parse(#load("../../assets/data/anims/Jet_Rise.poa"))
    soldier := sim.Soldier{active=true,body={direction=1,jet_fuel=100,velocity={0,-3}},controls={buttons={.Jet},aim={100,0}},pose={legs={id=.Fall,frame=1},body={id=.Stand,frame=1}}}
    baseline := sim.soldier_pose(animations,&soldier,{})
    visual := draw.visual_soldier_pose(animations,clips,&soldier,{},0)
    testing.expect(t,visual[0]!=baseline[0])
    testing.expect(t,sim.soldier_pose(animations,&soldier,{})==baseline)
    soldier.body.on_ground=true
    testing.expect(t,draw.visual_soldier_pose(animations,clips,&soldier,{},0)==baseline)
    soldier.body.on_ground=false; soldier.body.jet_fuel=0
    testing.expect(t,draw.visual_soldier_pose(animations,clips,&soldier,{},0)==baseline)
    soldier.body.jet_fuel=100; soldier.pose.legs.id=.Roll
    testing.expect(t,draw.visual_soldier_pose(animations,clips,&soldier,{},0)==sim.soldier_pose(animations,&soldier,{}))
}

@(test)
horizontal_jet_over_airborne_run_states :: proc(t: ^testing.T) {
    animations := new(res.Animations); defer free(animations)
    clips := new(res.Air_Animations); defer free(clips)
    clips[.Jet_Forward]=res.air_clip_parse(#load("../../assets/data/anims/Jet_Forward.poa"))
    clips[.Jet_Backward]=res.air_clip_parse(#load("../../assets/data/anims/Jet_Backward.poa"))
    for dir in ([2]i32{1,-1}) {
        for backwards in ([2]bool{false,true}) {
            soldier := sim.Soldier{active=true,body={direction=i8(dir),jet_fuel=100,velocity={f32(dir)*(-3 if backwards else 3),0}},controls={buttons={.Jet},aim={100,0}},pose={legs={id=.Run_Back if backwards else .Run,frame=1},body={id=.Stand,frame=1}}}
            clip := &clips[.Jet_Backward if backwards else .Jet_Forward]
            expected := sim.soldier_pose(animations,&soldier,{},&clip.frames[0],&clip.frames[0])
            actual := draw.visual_soldier_pose(animations,clips,&soldier,{},0)
            testing.expectf(t,actual==expected,"horizontal jet uses supplied clip: facing %d backwards %v",dir,backwards)
            soldier.body.on_ground=true
            testing.expect(t,draw.visual_soldier_pose(animations,clips,&soldier,{},0)==sim.soldier_pose(animations,&soldier,{}))
            soldier.body.on_ground=false; soldier.body.jet_fuel=0
            testing.expect(t,draw.visual_soldier_pose(animations,clips,&soldier,{},0)==sim.soldier_pose(animations,&soldier,{}))
        }
    }
}

@(test)
intent_reversal_progression :: proc(t: ^testing.T) {
    for dir in ([2]i32{1,-1}) {
        for intent in ([2]i32{-1,1}) {
            zero: res.Air_Clip_Id = .Jet_Forward_0 if dir==intent else .Jet_Backward_0
            one: res.Air_Clip_Id = .Jet_Forward_1 if dir==intent else .Jet_Backward_1
            for speed,i in ([5]f32{-6,0,1.5,3,9}) {
                w := res.air_weights({speed*f32(intent),0},dir,true,intent,3)
                expected_values := [5]f32{0,0,0.5,1,1}
                expected := expected_values[i]
                testing.expect(t,w[zero]==1-expected && w[one]==expected)
                total:f32
                for weight in w { testing.expect(t,weight>=0); total+=weight }
                testing.expect(t,math.abs(total-1)<0.00001)
            }
            vertical := res.air_weights({-3*f32(intent),3},dir,true,intent,3)
            testing.expect(t,vertical[zero]==0.5 && vertical[one]==0 && vertical[.Jet_Fall]==0.5)
            released := res.air_weights({3,0},dir,true,0,3)
            testing.expect(t,released[.Jet_Forward if dir==1 else .Jet_Backward]==1)
            testing.expect(t,res.air_weights({3,0},dir,false,intent,3)[.Jump_Hover]==1)
        }
    }
}

@(test)
intent_clips_reach_renderer_and_legacy_fallback :: proc(t: ^testing.T) {
    animations := new(res.Animations); defer free(animations)
    clips := new(res.Air_Animations); defer free(clips)
    clips[.Jet_Forward_0]=res.air_clip_parse(#load("../../assets/data/anims/Jet_Forward_0.poa"))
    clips[.Jet_Forward_1]=res.air_clip_parse(#load("../../assets/data/anims/Jet_Forward_1.poa"))
    clips[.Jet_Backward_0]=res.air_clip_parse(#load("../../assets/data/anims/Jet_Backward_0.poa"))
    clips[.Jet_Backward_1]=res.air_clip_parse(#load("../../assets/data/anims/Jet_Backward_1.poa"))
    for id in ([4]res.Air_Clip_Id{.Jet_Forward_0,.Jet_Forward_1,.Jet_Backward_0,.Jet_Backward_1}) do testing.expect(t,clips[id].count==60)
    for dir in ([2]i32{1,-1}) { for intent in ([2]i32{-1,1}) {
        for accelerating in ([2]bool{false,true}) {
            soldier := sim.Soldier{active=true,body={direction=i8(dir),jet_fuel=100,velocity={f32(intent)*(10 if accelerating else -10),0}},controls={buttons={.Jet},aim={100,0}},pose={legs={id=.Run,frame=1},body={id=.Stand,frame=1}}}
            soldier.controls.buttons += {.Right} if intent==1 else {.Left}
            id: res.Air_Clip_Id
            if dir==intent {id=.Jet_Forward_1 if accelerating else .Jet_Forward_0}
            else {id=.Jet_Backward_1 if accelerating else .Jet_Backward_0}
            frame := &clips[id].frames[0]
            expected := sim.soldier_pose(animations,&soldier,{},frame,frame)
            testing.expect(t,draw.visual_soldier_pose(animations,clips,&soldier,{},0)==expected)
        }
    }}
    clips[.Jet_Backward]=clips[.Jet_Backward_1]
    clips[.Jet_Backward_0]={}
    frame,strength := res.air_sample(clips,res.air_weights({5,0},1,true,-1),0,{})
    testing.expect(t,strength==1 && frame==clips[.Jet_Backward].frames[0])
}
