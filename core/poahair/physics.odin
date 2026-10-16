package poahair

import "core:math"

MAX_NODES :: 64
RATE :: 60.0

Attachment :: struct { x, z, angle: f64 }
State :: struct {
	pos:   [MAX_NODES]Node,
	prev:  [MAX_NODES]Node,
	count: int,
}

world :: proc(n: Node, a: Attachment) -> Node {
	c, s := math.cos(a.angle), math.sin(a.angle)
	return {a.x + n.x*c - n.z*s, a.z + n.x*s + n.z*c}
}

reset :: proc(state: ^State, strand: ^Strand, attachment: Attachment) {
	state.count = min(len(strand.nodes), MAX_NODES)
	for i in 0..<state.count {
		p := world(strand.nodes[i], attachment)
		state.pos[i] = p
		state.prev[i] = p
	}
}

Edge :: struct { a, b: int }

add_edge :: proc(edges: ^[384]Edge, count: ^int, a, b: int) {
	lo, hi := min(a, b), max(a, b)
	for i in 0..<count^ {
		if edges[i].a == lo && edges[i].b == hi do return
	}
	if count^ < len(edges) {
		edges[count^] = {lo, hi}
		count^ += 1
	}
}

strand_is_pin :: proc(strand: ^Strand, index, fallback: int) -> bool {
	if len(strand.anchor_indices) > 0 {
		for value in strand.anchor_indices do if value == index do return true
		return false
	}
	return index == fallback
}

mesh_step :: proc(state: ^State, strand: ^Strand, desired: [MAX_NODES]Node) {
	pin := strand.anchor_index
	if pin < 0 || pin >= state.count do pin = 0
	rigidity := strand.rigidity
	if rigidity >= 1 {
		for i in 0..<state.count { state.pos[i], state.prev[i] = desired[i], desired[i] }
		return
	}
	damping := math.exp(-strand.damping*12/RATE)
	spring := 1 - math.exp(-(rigidity*rigidity*90+strand.elasticity*12)/RATE)
	for i in 0..<state.count {
		if strand_is_pin(strand, i, pin) {
			state.pos[i], state.prev[i] = desired[i], desired[i]
			continue
		}
		old, prev := state.pos[i], state.prev[i]
		x := old.x + (old.x-prev.x)*damping
		z := old.z + (old.z-prev.z)*damping - strand.gravity*strand.weight*9.8/(RATE*RATE)
		x += (desired[i].x-x)*spring
		z += (desired[i].z-z)*spring
		state.prev[i] = old
		state.pos[i] = {x, z}
	}
	edges: [384]Edge
	edge_count := 0
	if strand.kind == "mesh" {
		for tri in strand.mesh.triangles {
			add_edge(&edges, &edge_count, tri[0], tri[1])
			add_edge(&edges, &edge_count, tri[1], tri[2])
			add_edge(&edges, &edge_count, tri[2], tri[0])
		}
	} else {
		for i in 0..<state.count-1 { add_edge(&edges, &edge_count, i, i+1) }
	}
	strength := .15 + rigidity*.8 + strand.elasticity*.5
	for _ in 0..<6 {
		for ei in 0..<edge_count {
			i, j := edges[ei].a, edges[ei].b
			if i >= state.count || j >= state.count do continue
			a, b, ra, rb := state.pos[i], state.pos[j], desired[i], desired[j]
			rest_len := math.hypot(rb.x-ra.x, rb.z-ra.z)
			dx, dz := b.x-a.x, b.z-a.z
			length := math.hypot(dx, dz)
			if length < 1e-10 do continue
			error := (length-rest_len)/length*strength
			wa, wb := 1.0, 1.0
			if strand_is_pin(strand, i, pin) do wa = 0
			if strand_is_pin(strand, j, pin) do wb = 0
			sum := wa + wb
			if sum == 0 do continue
			if wa != 0 { a.x += dx*error*wa/sum; a.z += dz*error*wa/sum }
			if wb != 0 { b.x -= dx*error*wb/sum; b.z -= dz*error*wb/sum }
			state.pos[i], state.pos[j] = a, b
		}
		for i in 0..<state.count {
			if strand_is_pin(strand, i, pin) do state.pos[i] = desired[i]
		}
	}
}

// step advances one fixed 60 Hz simulation tick. Call reset when input geometry
// changes or the timeline rewinds; animation sampling and cache replay stay with the caller.
step :: proc(state: ^State, strand: ^Strand, attachment: Attachment) {
	if state.count <= 0 || state.count != min(len(strand.nodes), MAX_NODES) {
		reset(state, strand, attachment)
		return
	}
	desired: [MAX_NODES]Node
	for i in 0..<state.count { desired[i] = world(strand.nodes[i], attachment) }
	if strand.kind == "mesh" || len(strand.anchor_indices) > 0 || (strand.anchor_index != 0) {
		mesh_step(state, strand, desired)
		return
	}
	if strand.rigidity >= 1 {
		for i in 0..<state.count { state.pos[i], state.prev[i] = desired[i], desired[i] }
		return
	}
	damping := math.exp(-strand.damping*12/RATE)
	spring := 1 - math.exp(-(strand.rigidity*strand.rigidity*90+strand.elasticity*12)/RATE)
	state.pos[0], state.prev[0] = desired[0], desired[0]
	for i in 1..<state.count {
		old, prev, parent := state.pos[i], state.prev[i], state.pos[i-1]
		x := old.x + (old.x-prev.x)*damping
		z := old.z + (old.z-prev.z)*damping - strand.gravity*strand.weight*9.8/(RATE*RATE)
		dx, dz := desired[i].x-desired[i-1].x, desired[i].z-desired[i-1].z
		x += (parent.x+dx-x)*spring
		z += (parent.z+dz-z)*spring
		length, distance := math.hypot(dx, dz), math.hypot(x-parent.x, z-parent.z)
		state.prev[i] = old
		if distance > 1e-10 {
			state.pos[i] = {parent.x+(x-parent.x)*length/distance, parent.z+(z-parent.z)*length/distance}
		} else {
			state.pos[i] = {parent.x+dx, parent.z+dz}
		}
	}
}
