/* The Turso C ABI for OCaml, in process. Statement steps release the runtime
   lock, so writers on their own connections run in parallel. */
#include <stdio.h>
#include <string.h>
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/callback.h>
#include <caml/threads.h>
#include "turso.h"

typedef struct { const turso_database_t *ptr; } db_handle;
typedef struct { turso_connection_t *ptr; } conn_handle;
#define DB(v) ((db_handle *)Data_custom_val(v))
#define CONN(v) ((conn_handle *)Data_custom_val(v))

static void db_finalize(value v) {
  if (DB(v)->ptr) { turso_database_deinit(DB(v)->ptr); DB(v)->ptr = NULL; }
}
static void conn_finalize(value v) {
  if (CONN(v)->ptr) { turso_connection_deinit(CONN(v)->ptr); CONN(v)->ptr = NULL; }
}
static struct custom_operations db_ops = {
  "firstpair.tursolite.database", db_finalize, custom_compare_default, custom_hash_default,
  custom_serialize_default, custom_deserialize_default, custom_compare_ext_default, custom_fixed_length_default };
static struct custom_operations conn_ops = {
  "firstpair.tursolite.connection", conn_finalize, custom_compare_default, custom_hash_default,
  custom_serialize_default, custom_deserialize_default, custom_compare_ext_default, custom_fixed_length_default };

/* Raises Tursolite_sdk.Turso_error (status, message). */
static void fail_status(turso_status_code_t code, const char *error) {
  CAMLparam0();
  CAMLlocal1(message);
  message = caml_copy_string(error ? error : "no error text");
  if (error) turso_str_deinit(error);
  value args[2] = { Val_int(code), message };
  caml_raise_with_args(*caml_named_value("tursolite_sdk_error"), 2, args);
  CAMLnoreturn;
}
static void fail_misuse(const char *text) {
  CAMLparam0();
  CAMLlocal1(message);
  message = caml_copy_string(text);
  value args[2] = { Val_int(TURSO_MISUSE), message };
  caml_raise_with_args(*caml_named_value("tursolite_sdk_error"), 2, args);
  CAMLnoreturn;
}

CAMLprim value tursolite_version(value unit) {
  CAMLparam1(unit);
  CAMLreturn(caml_copy_string(turso_version()));
}

/* [features] is Turso's comma separated list of experimental features, or "". */
CAMLprim value tursolite_open(value path, value read_only, value features) {
  CAMLparam3(path, read_only, features);
  CAMLlocal1(handle);
  const char *error = NULL; const turso_database_t *db = NULL;
  turso_database_config_t config = { .path = String_val(path), .async_io = 0,
    .experimental_features = caml_string_length(features) ? String_val(features) : NULL,
    .open_flags = Bool_val(read_only) ? TURSO_DATABASE_OPEN_READONLY : TURSO_DATABASE_OPEN_DEFAULT };
  turso_status_code_t code = turso_database_new(&config, &db, &error);
  if (code != TURSO_OK) fail_status(code, error);
  code = turso_database_open(db, &error);
  if (code != TURSO_OK) { turso_database_deinit(db); fail_status(code, error); }
  handle = caml_alloc_custom(&db_ops, sizeof(db_handle), 0, 1);
  DB(handle)->ptr = db;
  CAMLreturn(handle);
}



CAMLprim value tursolite_connect(value database, value busy_ms) {
  CAMLparam2(database, busy_ms);
  CAMLlocal1(handle);
  const char *error = NULL; turso_connection_t *conn = NULL;
  if (!DB(database)->ptr) fail_misuse("Closed Turso database");
  turso_status_code_t code = turso_database_connect(DB(database)->ptr, &conn, &error);
  if (code != TURSO_OK) fail_status(code, error);
  turso_connection_set_busy_timeout_ms(conn, Long_val(busy_ms));
  handle = caml_alloc_custom(&conn_ops, sizeof(conn_handle), 0, 1);
  CONN(handle)->ptr = conn;
  CAMLreturn(handle);
}

CAMLprim value tursolite_close_connection(value connection) {
  CAMLparam1(connection); conn_finalize(connection); CAMLreturn(Val_unit);
}
CAMLprim value tursolite_close_database(value database) {
  CAMLparam1(database); db_finalize(database); CAMLreturn(Val_unit);
}

static turso_status_code_t bind_value(turso_statement_t *stmt, size_t position, value parameter) {
  if (Is_long(parameter)) return turso_statement_bind_positional_null(stmt, position);
  value payload = Field(parameter, 0);
  switch (Tag_val(parameter)) {
    case 0: return turso_statement_bind_positional_int(stmt, position, Int64_val(payload));
    case 1: return turso_statement_bind_positional_double(stmt, position, Double_val(payload));
    case 2: return turso_statement_bind_positional_text(stmt, position, String_val(payload), caml_string_length(payload));
    case 3: return turso_statement_bind_positional_blob(stmt, position, String_val(payload), caml_string_length(payload));
    default: return TURSO_MISUSE;
  }
}

CAMLprim value tursolite_execute(value connection, value sql, value params) {
  CAMLparam3(connection, sql, params);
  CAMLlocal5(list, row, cell, item, payload);
  CAMLlocal2(columns, result);
  const char *error = NULL; turso_statement_t *stmt = NULL;
  if (!CONN(connection)->ptr) fail_misuse("Closed Turso connection");
  turso_status_code_t code = turso_connection_prepare_single(CONN(connection)->ptr, String_val(sql), &stmt, &error);
  if (code != TURSO_OK) fail_status(code, error);
  for (mlsize_t i = 0; i < Wosize_val(params); i++) {
    code = bind_value(stmt, i + 1, Field(params, i));
    if (code != TURSO_OK) { turso_statement_deinit(stmt); fail_status(code, NULL); }
  }
  mlsize_t ncols = turso_statement_column_count(stmt);
  columns = caml_alloc(ncols, 0);
  for (mlsize_t i = 0; i < ncols; i++) Store_field(columns, i, Val_unit);
  for (mlsize_t i = 0; i < ncols; i++) {
    const char *name = turso_statement_column_name(stmt, i);
    item = caml_copy_string(name ? name : "");
    if (name) turso_str_deinit(name);
    Store_field(columns, i, item);
  }
  list = Val_emptylist;
  for (;;) {
    caml_enter_blocking_section();
    code = turso_statement_step(stmt, &error);
    caml_leave_blocking_section();
    if (code == TURSO_DONE) break;
    if (code != TURSO_ROW) { turso_statement_deinit(stmt); fail_status(code, error); }
    mlsize_t count = turso_statement_column_count(stmt);
    row = caml_alloc(count, 0);
    for (mlsize_t i = 0; i < count; i++) Store_field(row, i, Val_unit);
    for (mlsize_t i = 0; i < count; i++) {
      turso_type_t kind = turso_statement_row_value_kind(stmt, i);
      switch (kind) {
        case TURSO_TYPE_NULL: item = Val_int(0); break;
        case TURSO_TYPE_INTEGER:
          payload = caml_copy_int64(turso_statement_row_value_int(stmt, i));
          item = caml_alloc(1, 0); Store_field(item, 0, payload); break;
        case TURSO_TYPE_REAL:
          payload = caml_copy_double(turso_statement_row_value_double(stmt, i));
          item = caml_alloc(1, 1); Store_field(item, 0, payload); break;
        case TURSO_TYPE_TEXT: case TURSO_TYPE_BLOB:
          payload = caml_alloc_initialized_string(turso_statement_row_value_bytes_count(stmt, i),
                                                  turso_statement_row_value_bytes_ptr(stmt, i));
          item = caml_alloc(1, kind == TURSO_TYPE_TEXT ? 2 : 3); Store_field(item, 0, payload); break;
        default: turso_statement_deinit(stmt); fail_misuse("Unknown Turso result type");
      }
      Store_field(row, i, item);
    }
    cell = caml_alloc(2, 0); Store_field(cell, 0, row); Store_field(cell, 1, list); list = cell;
  }
  code = turso_statement_finalize(stmt, &error);
  turso_statement_deinit(stmt);
  if (code != TURSO_DONE && code != TURSO_OK) fail_status(code, error);
  /* Reverse the row list after freeing the native statement. */
  cell = Val_emptylist;
  while (list != Val_emptylist) {
    row = caml_alloc(2, 0); Store_field(row, 0, Field(list, 0)); Store_field(row, 1, cell);
    cell = row; list = Field(list, 1);
  }
  result = caml_alloc(2, 0);
  Store_field(result, 0, columns);
  Store_field(result, 1, cell);
  CAMLreturn(result);
}
