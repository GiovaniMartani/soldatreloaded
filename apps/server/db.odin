package server

import "core:c"
import "core:fmt"
import "core:strings"

import lua "vendor:lua/5.4"

// `db`, as the script sees it: SQLite databases, files in the server's folder, for what a
// script keeps from one start to the next (docs/scripting.md, "Databases").
//
//   local d = db.open("stats.db")       -- nil and why, if it can't be opened
//   d:exec(sql, ...)                     -- every statement in sql; the rows changed, the last id
//   d:query(sql, ...)                    -- one statement's rows, each a table by column name
//   d:first(sql, ...)                    -- its first row, or nil
//   d:transaction(function(d) ... end)   -- all of it, or (an error) none
//   d:close()                            -- as the script ends, if not before
//
// The values go in as `?`s, never into the SQL's text, so a player's name is only ever a
// name. A number goes in as an integer or a real as Lua has it, a boolean as 1 or 0, nil
// as NULL; a column comes back as an integer, a number or a string, NULL as no key. The
// calls run on the server's thread, as everything the script does: quick ones, on a file
// of its own. A database is opened in WAL mode, so one killed mid-write keeps what it had,
// and another program may read it as the server runs. An SQL error is the script's error.

@(private = "file")
DB_METATABLE :: "soldatreloaded.db"

@(private = "file")
Db_Handle :: struct {
	db: ^Sqlite, // nil once closed
}

@(private = "file")
db_module := [?]lua.L_Reg{{"open", l_db_open}, {nil, nil}}

@(private = "file")
db_methods := [?]lua.L_Reg {
	{"exec", l_db_exec},
	{"query", l_db_query},
	{"first", l_db_first},
	{"transaction", l_db_transaction},
	{"close", l_db_close},
	{nil, nil},
}

// The `db` global, and its handles' metatable.
db_open :: proc(L: ^lua.State) {
	lua.L_newmetatable(L, DB_METATABLE)
	lua.createtable(L, 0, len(db_methods) - 1)
	lua.L_setfuncs(L, &db_methods[0], 0)
	lua.setfield(L, -2, "__index")
	lua.pushcfunction(L, l_db_gc)
	lua.setfield(L, -2, "__gc")
	lua.pushcfunction(L, l_db_gc)
	lua.setfield(L, -2, "__close")
	lua.pop(L, 1)
	lua.createtable(L, 0, len(db_module) - 1)
	lua.L_setfuncs(L, &db_module[0], 0)
	lua.setglobal(L, "db")
}

// db.open(path): the database at `path`, made if it isn't there; nil and why if it can't
// be opened.
@(private = "file")
l_db_open :: proc "c" (L: ^lua.State) -> c.int {
	context = script_of(L).ctx
	path := strings.clone_to_cstring(check_string(L, 1), context.temp_allocator)
	db: ^Sqlite
	if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) != SQLITE_OK {
		why := fmt.tprintf("db: %s can't be opened: %s", path, sqlite3_errmsg(db) if db != nil else "no memory")
		sqlite3_close_v2(db)
		lua.pushnil(L)
		push_string(L, why)
		return 2
	}
	sqlite3_busy_timeout(db, 2000) // another program writing it is waited for, a while
	for pragma in ([2]string{"PRAGMA journal_mode = WAL", "PRAGMA foreign_keys = ON"}) {
		run_all(db, pragma, L, 0, 0)
	}
	handle := (^Db_Handle)(lua.newuserdatauv(L, size_of(Db_Handle), 0))
	handle.db = db
	lua.L_setmetatable(L, DB_METATABLE)
	return 1
}

// The open database of the handle at index 1; an error for one closed.
@(private = "file")
check_db :: proc(L: ^lua.State) -> ^Sqlite {
	handle := (^Db_Handle)(lua.L_checkudata(L, 1, DB_METATABLE))
	if handle.db == nil {
		push_string(L, "db: the database is closed")
		lua.error(L)
	}
	return handle.db
}

// What went wrong, raised as the script's error: after whatever had to be let go was.
@(private = "file")
raise :: proc(L: ^lua.State, why: string) -> c.int {
	push_string(L, why)
	lua.error(L)
	return 0
}

// The values at `first` and on, `count` of them, bound to the statement's ?s from 1.
@(private = "file")
bind_values :: proc(L: ^lua.State, stmt: ^Sqlite_Stmt, first, count: c.int) -> (why: string) {
	for i in 0 ..< count {
		at := first + i
		index := i + 1
		rc: c.int
		#partial switch lua.type(L, at) {
		case .NIL:
			rc = sqlite3_bind_null(stmt, index)
		case .BOOLEAN:
			rc = sqlite3_bind_int64(stmt, index, 1 if lua.toboolean(L, at) else 0)
		case .NUMBER:
			if lua.isinteger(L, at) {
				rc = sqlite3_bind_int64(stmt, index, i64(lua.tointeger(L, at)))
			} else {
				rc = sqlite3_bind_double(stmt, index, f64(lua.tonumber(L, at)))
			}
		case .STRING:
			n: c.size_t
			text := lua.tolstring(L, at, &n)
			rc = sqlite3_bind_text(stmt, index, ([^]u8)(text), c.int(n), SQLITE_TRANSIENT)
		case:
			return fmt.tprintf("db: value %d is a %s; a number, a string, a boolean or nil goes in", index, lua.typename(L, lua.type(L, at)))
		}
		if rc != SQLITE_OK do return fmt.tprintf("db: value %d: rc %d", index, rc)
	}
	return ""
}

// The row the statement stands on, as a table by column name, pushed.
@(private = "file")
push_row :: proc(L: ^lua.State, stmt: ^Sqlite_Stmt) {
	columns := sqlite3_column_count(stmt)
	lua.createtable(L, 0, columns)
	for column in 0 ..< columns {
		switch sqlite3_column_type(stmt, column) {
		case SQLITE_INTEGER:
			lua.pushinteger(L, lua.Integer(sqlite3_column_int64(stmt, column)))
		case SQLITE_FLOAT:
			lua.pushnumber(L, lua.Number(sqlite3_column_double(stmt, column)))
		case SQLITE_TEXT:
			text := sqlite3_column_text(stmt, column)
			lua.pushlstring(L, cstring(text), c.size_t(sqlite3_column_bytes(stmt, column)))
		case SQLITE_BLOB:
			blob := sqlite3_column_blob(stmt, column)
			lua.pushlstring(L, cstring(blob), c.size_t(sqlite3_column_bytes(stmt, column)))
		case:
			continue // NULL: no key
		}
		lua.setfield(L, -2, sqlite3_column_name(stmt, column))
	}
}

// Every statement in `sql`, the values from `first` (`count` of them) given to their ?s in
// order: the rows of the last pushed, as a list, if `rows` (then `sql` is one statement,
// and `limit` rows at most, 0 for all). An error's why, with nothing left prepared.
@(private = "file")
run_all :: proc(db: ^Sqlite, sql: string, L: ^lua.State, first, count: c.int, rows := false, limit := 0) -> (why: string) {
	at := raw_data(sql)
	left := len(sql)
	used: c.int
	statements := 0
	if rows do lua.newtable(L)
	for left > 0 {
		stmt: ^Sqlite_Stmt
		tail: [^]u8
		if sqlite3_prepare_v2(db, at, c.int(left), &stmt, &tail) != SQLITE_OK {
			return fmt.tprintf("db: %s", sqlite3_errmsg(db))
		}
		left -= int(uintptr(tail) - uintptr(at))
		at = tail
		if stmt == nil do continue // nothing but space or a comment
		statements += 1
		if rows && statements > 1 {
			sqlite3_finalize(stmt)
			return "db: query takes one statement; exec runs several"
		}
		wanted := sqlite3_bind_parameter_count(stmt)
		if used + wanted > count {
			sqlite3_finalize(stmt)
			return fmt.tprintf("db: the SQL has more ?s than the %d values given", count)
		}
		if bad := bind_values(L, stmt, first + used, wanted); bad != "" {
			sqlite3_finalize(stmt)
			return bad
		}
		used += wanted
		n := 0
		for {
			rc := sqlite3_step(stmt)
			if rc == SQLITE_DONE do break
			if rc != SQLITE_ROW {
				why = fmt.tprintf("db: %s", sqlite3_errmsg(db))
				sqlite3_finalize(stmt)
				return why
			}
			if !rows do continue
			push_row(L, stmt)
			n += 1
			lua.rawseti(L, -2, lua.Integer(n))
			if limit > 0 && n >= limit do break // the rest unread
		}
		sqlite3_finalize(stmt)
	}
	if used < count do return fmt.tprintf("db: %d values given, but the SQL has %d ?s", count, used)
	return ""
}

// d:exec(sql, ...): every statement in `sql`, the values to their ?s in order: the rows
// the last changed, and the last row inserted's id.
@(private = "file")
l_db_exec :: proc "c" (L: ^lua.State) -> c.int {
	context = script_of(L).ctx
	db := check_db(L)
	sql := check_string(L, 2)
	if why := run_all(db, sql, L, 3, lua.gettop(L) - 2); why != "" do return raise(L, why)
	lua.pushinteger(L, lua.Integer(sqlite3_changes(db)))
	lua.pushinteger(L, lua.Integer(sqlite3_last_insert_rowid(db)))
	return 2
}

// d:query(sql, ...): one statement's rows, a list of tables by column name.
@(private = "file")
l_db_query :: proc "c" (L: ^lua.State) -> c.int {
	context = script_of(L).ctx
	db := check_db(L)
	sql := check_string(L, 2)
	if why := run_all(db, sql, L, 3, lua.gettop(L) - 2, rows = true); why != "" do return raise(L, why)
	return 1
}

// d:first(sql, ...): the first of the statement's rows, or nil.
@(private = "file")
l_db_first :: proc "c" (L: ^lua.State) -> c.int {
	context = script_of(L).ctx
	db := check_db(L)
	sql := check_string(L, 2)
	if why := run_all(db, sql, L, 3, lua.gettop(L) - 2, rows = true, limit = 1); why != "" do return raise(L, why)
	lua.rawgeti(L, -1, 1)
	return 1
}

// d:transaction(fn): fn(d) between BEGIN and COMMIT, its results returned; an error in it
// rolls everything back, and is raised again.
@(private = "file")
l_db_transaction :: proc "c" (L: ^lua.State) -> c.int {
	context = script_of(L).ctx
	db := check_db(L)
	lua.L_checktype(L, 2, c.int(lua.Type.FUNCTION))
	lua.settop(L, 2)
	if why := run_all(db, "BEGIN", L, 0, 0); why != "" do return raise(L, why)
	lua.pushvalue(L, 2)
	lua.pushvalue(L, 1)
	if lua.pcall(L, 1, lua.MULTRET, 0) != c.int(lua.OK) {
		run_all(db, "ROLLBACK", L, 0, 0)
		lua.error(L) // the error, as it was
		return 0
	}
	if why := run_all(db, "COMMIT", L, 0, 0); why != "" {
		run_all(db, "ROLLBACK", L, 0, 0)
		return raise(L, why)
	}
	return lua.gettop(L) - 2
}

// d:close(): the database let go; a handle closed may be closed again.
@(private = "file")
l_db_close :: proc "c" (L: ^lua.State) -> c.int {
	context = script_of(L).ctx
	handle := (^Db_Handle)(lua.L_checkudata(L, 1, DB_METATABLE))
	if handle.db != nil {
		sqlite3_close_v2(handle.db)
		handle.db = nil
	}
	return 0
}

// A handle Lua lets go of (the script ending, or it unreachable), or one leaving a
// `local d <close>`: its database closed with it.
@(private = "file")
l_db_gc :: proc "c" (L: ^lua.State) -> c.int {
	handle := (^Db_Handle)(lua.L_testudata(L, 1, DB_METATABLE))
	if handle != nil && handle.db != nil {
		sqlite3_close_v2(handle.db)
		handle.db = nil
	}
	return 0
}
