package main
import "core:fmt"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import draw "../../apps/client/draw"
import hair "../../core/poahair"
main :: proc() {
 rl.SetConfigFlags({.WINDOW_HIDDEN})
 rl.InitWindow(256,128,"Hair mirror regression")
 defer rl.CloseWindow()
 image:=rl.GenImageColor(8,8,{0,0,0,0})
 rl.ImageDrawRectangle(&image,0,0,8,2,{255,0,0,255})
 rl.ImageDrawRectangle(&image,0,2,3,4,{0,255,0,255})
 texture:=rl.LoadTextureFromImage(image)
 rl.UnloadImage(image)
 defer rl.UnloadTexture(texture)
 nodes:=[2]hair.Node{{x=-0.5,z=0},{x=0.7,z=1}}
 strands:=[1]hair.Strand{{nodes=nodes[:],width=3,opacity=1,texture={axis="x"},has_texture=true}}
 pkg:=hair.Package{strands=strands[:]}
 h:draw.Poa_Hair
 h.packages[.Dreadlocks]=&pkg
 h.images[.Dreadlocks][0]={texture=texture,uv={0,0},uv_size={1,1}}
 target:=rl.LoadRenderTexture(256,128)
 defer rl.UnloadRenderTexture(target)
 points:draw.Points
 points[11],points[8]={0,0},{0,0.1}
 for axis in ([2]string{"x","y"}) { for flip in ([2]bool{false,true}) {
  strands[0].texture.axis=axis
  strands[0].texture.flip_x=flip
  rl.BeginTextureMode(target)
  rl.ClearBackground({0,0,0,255})
  for dir,i in ([2]i32{1,-1}) {
   rl.BeginMode2D({offset={f32(64+128*i),90},zoom=8})
   rl.BeginBlendMode(.ALPHA_PREMULTIPLY)
   rlgl.DisableBackfaceCulling()
   draw.poa_draw(&h,.Dreadlocks,0,&points,dir,false,255)
   rl.EndBlendMode()
   rlgl.EnableBackfaceCulling()
   rl.EndMode2D()
  }
  rl.EndTextureMode()
  rendered:=rl.LoadImageFromTexture(target.texture)
  pixels:=rl.LoadImageColors(rendered)
  mismatch,visible:=0,0
  for y in 0..<128 {for x in 0..<128 {
   a,b:=pixels[y*256+x],pixels[y*256+255-x]
   if a!=b do mismatch+=1
   if a.r>0||a.g>0 do visible+=1
  }}
  fmt.println("axis",axis,"flip",flip,"visible",visible,"mirror mismatches",mismatch)
  rl.UnloadImageColors(pixels)
  rl.UnloadImage(rendered)
  assert(visible>50)
  assert(mismatch<10,"both directions must reflect the same PNG including its transparent region")
 }}
}

