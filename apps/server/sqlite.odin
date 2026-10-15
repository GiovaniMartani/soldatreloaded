package server

import "core:c"

// The few of SQLite's calls the scripts' `db` needs (db.odin). Linked in: on Linux the
// system's, or the static library the release builds (.github/actions/setup); on Windows
// sqlite3.lib, built the same way, found on the linker's path.

when ODIN_OS == .Windows {
	foreign import sqlite "system:sqlite3.lib"
} else {
	foreign import sqlite "system:sqlite3"
}

Sqlite :: struct {}
Sqlite_Stmt :: struct {}

SQLITE_OK :: 0
SQLITE_ROW :: 100
SQLITE_DONE :: 101

SQLITE_OPEN_READWRITE :: 0x00000002
SQLITE_OPEN_CREATE :: 0x00000004

SQLITE_INTEGER :: 1
SQLITE_FLOAT :: 2
SQLITE_TEXT :: 3
SQLITE_BLOB :: 4
SQLITE_NULL :: 5

// A text bound is copied by SQLite at once: the Lua string it came from may go.
SQLITE_TRANSIENT :: rawptr(~uintptr(0))

@(default_calling_convention = "c")
foreign sqlite {
	sqlite3_open_v2 :: proc(filename: cstring, db: ^^Sqlite, flags: c.int, vfs: cstring) -> c.int ---
	sqlite3_close_v2 :: proc(db: ^Sqlite) -> c.int ---
	sqlite3_errmsg :: proc(db: ^Sqlite) -> cstring ---
	sqlite3_busy_timeout :: proc(db: ^Sqlite, ms: c.int) -> c.int ---
	sqlite3_prepare_v2 :: proc(db: ^Sqlite, sql: [^]u8, bytes: c.int, stmt: ^^Sqlite_Stmt, tail: ^[^]u8) -> c.int ---
	sqlite3_finalize :: proc(stmt: ^Sqlite_Stmt) -> c.int ---
	sqlite3_step :: proc(stmt: ^Sqlite_Stmt) -> c.int ---
	sqlite3_bind_parameter_count :: proc(stmt: ^Sqlite_Stmt) -> c.int ---
	sqlite3_bind_int64 :: proc(stmt: ^Sqlite_Stmt, index: c.int, value: i64) -> c.int ---
	sqlite3_bind_double :: proc(stmt: ^Sqlite_Stmt, index: c.int, value: f64) -> c.int ---
	sqlite3_bind_text :: proc(stmt: ^Sqlite_Stmt, index: c.int, text: [^]u8, bytes: c.int, destructor: rawptr) -> c.int ---
	sqlite3_bind_null :: proc(stmt: ^Sqlite_Stmt, index: c.int) -> c.int ---
	sqlite3_column_count :: proc(stmt: ^Sqlite_Stmt) -> c.int ---
	sqlite3_column_name :: proc(stmt: ^Sqlite_Stmt, column: c.int) -> cstring ---
	sqlite3_column_type :: proc(stmt: ^Sqlite_Stmt, column: c.int) -> c.int ---
	sqlite3_column_int64 :: proc(stmt: ^Sqlite_Stmt, column: c.int) -> i64 ---
	sqlite3_column_double :: proc(stmt: ^Sqlite_Stmt, column: c.int) -> f64 ---
	sqlite3_column_text :: proc(stmt: ^Sqlite_Stmt, column: c.int) -> [^]u8 ---
	sqlite3_column_blob :: proc(stmt: ^Sqlite_Stmt, column: c.int) -> rawptr ---
	sqlite3_column_bytes :: proc(stmt: ^Sqlite_Stmt, column: c.int) -> c.int ---
	sqlite3_changes :: proc(db: ^Sqlite) -> c.int ---
	sqlite3_last_insert_rowid :: proc(db: ^Sqlite) -> i64 ---
}
