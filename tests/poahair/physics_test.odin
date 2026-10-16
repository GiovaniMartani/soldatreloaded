package poahair_test

import "core:math"
import "core:testing"

import hair "../../core/poahair"

@(test)
world_transform :: proc(t: ^testing.T) {
	n := hair.world({x = 1, z = 0}, {x = 3, z = 4, angle = math.PI/2})
	testing.expect_value(t, n.x, 3.0)
	testing.expect_value(t, n.z, 5.0)
}

@(test)
chain_tick_matches_reference :: proc(t: ^testing.T) {
	strand := hair.Strand{
		nodes = []hair.Node{{x = 0, z = 0}, {x = 0, z = 1}},
		anchor_index = 0,
		kind = "chain",
		rigidity = 0,
		damping = 0,
		gravity = 1,
	}
	state: hair.State
	hair.reset(&state, &strand, {})
	hair.step(&state, &strand, {})
	testing.expect_value(t, state.pos[0].x, 0.0)
	testing.expect_value(t, state.pos[0].z, 0.0)
	testing.expect_value(t, state.pos[1].x, 0.0)
	testing.expect(t, math.abs(state.pos[1].z-1.0) < 1e-12, "chain length stays constrained after gravity")
	testing.expect_value(t, state.prev[1].z, 1.0)
}

@(test)
mesh_pins_configured_anchor :: proc(t: ^testing.T) {
	strand := hair.Strand{
		nodes = []hair.Node{{x = 0, z = 0}, {x = 1, z = 0}},
		anchor_index = 1,
		kind = "mesh",
		mesh = {triangles = {}},
		rigidity = 0,
		damping = 0,
		gravity = 1,
	}
	state: hair.State
	hair.reset(&state, &strand, {})
	hair.step(&state, &strand, {x = 2, z = 3})
	testing.expect_value(t, state.pos[1].x, 3.0)
	testing.expect_value(t, state.pos[1].z, 3.0)
	testing.expect_value(t, state.prev[1].z, 3.0)
	testing.expect(t, state.pos[0].z < 0, "unanchored mesh node receives gravity")
}

@(test)
mesh_pins_multiple_anchors :: proc(t: ^testing.T) {
	strand := hair.Strand{
		nodes = []hair.Node{{x = 0, z = 0}, {x = 1, z = 0}, {x = .5, z = 1}},
		anchor_index = 0,
		anchor_indices = []int{0, 1},
		kind = "mesh",
		mesh = {triangles = [][3]int{{0, 1, 2}}},
		rigidity = 0,
		damping = 0,
		gravity = 1,
	}
	state: hair.State
	hair.reset(&state, &strand, {})
	hair.step(&state, &strand, {x = 2, z = 3})
	testing.expect_value(t, state.pos[0].x, 2.0)
	testing.expect_value(t, state.pos[0].z, 3.0)
	testing.expect_value(t, state.pos[1].x, 3.0)
	testing.expect_value(t, state.pos[1].z, 3.0)
	testing.expect(t, state.pos[2].z < 4.0, "free mesh node remains simulated")
}

@(test)
rigidity_one_tracks_rest_pose :: proc(t: ^testing.T) {
	strand := hair.Strand{
		nodes = []hair.Node{{x = 0, z = 0}, {x = 0, z = 1}},
		rigidity = 1,
		damping = .4,
		gravity = 1,
	}
	state: hair.State
	hair.reset(&state, &strand, {})
	hair.step(&state, &strand, {x = 2, z = -1})
	testing.expect_value(t, state.pos[0].x, 2.0)
	testing.expect_value(t, state.pos[1].x, 2.0)
	testing.expect_value(t, state.pos[1].z, 0.0)
	testing.expect_value(t, state.prev[1].z, 0.0)
}
