package poahair_test

import "core:math"
import "core:testing"
import hair "../../core/poahair"

PARITY_EPSILON :: 1e-8

expect_parity :: proc(t: ^testing.T, strand: ^hair.Strand, expected: []hair.Node) {
	state: hair.State
	hair.reset(&state, strand, PARITY_ATTACHMENTS[0])
	for tick in 0..=PARITY_TICKS {
		if tick > 0 do hair.step(&state, strand, PARITY_ATTACHMENTS[tick])
		for i in 0..<len(strand.nodes) {
			want := expected[tick*len(strand.nodes)+i]
			got := state.pos[i]
			testing.expectf(t, math.abs(got.x-want.x) <= PARITY_EPSILON,
				"%s tick %d node %d x: got %.17g expected %.17g", strand.name, tick, i, got.x, want.x)
			testing.expectf(t, math.abs(got.z-want.z) <= PARITY_EPSILON,
				"%s tick %d node %d z: got %.17g expected %.17g", strand.name, tick, i, got.z, want.z)
		}
	}
}

@(test)
javascript_solver_parity_60_ticks :: proc(t: ^testing.T) {
	chain := hair.Strand{
		name = "chain", nodes = PARITY_CHAIN_NODES[:], anchor_index = 0,
		rigidity = 0.37, damping = 0.23, gravity = 0.81,
	}
	ribbon := hair.Strand{
		name = "ribbon", nodes = PARITY_RIBBON_NODES[:], anchor_index = 2,
		rigidity = 0.29, damping = 0.41, gravity = 0.73,
	}
	mesh := hair.Strand{
		name = "mesh", kind = "mesh", nodes = PARITY_MESH_NODES[:], anchor_index = 1,
		mesh = {triangles = PARITY_MESH_TRIANGLES[:]},
		rigidity = 0.34, damping = 0.19, gravity = 0.92,
	}
	expect_parity(t, &chain, PARITY_CHAIN_EXPECTED[:])
	expect_parity(t, &ribbon, PARITY_RIBBON_EXPECTED[:])
	expect_parity(t, &mesh, PARITY_MESH_EXPECTED[:])
}
