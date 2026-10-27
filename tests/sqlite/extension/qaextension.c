/* Harmless fixture for PHP's extension-loading APIs. SQLite headers: 3.54.1. */
#include "sqlite3ext.h"
#ifdef _WIN32
#include <windows.h>
#endif
SQLITE_EXTENSION_INIT1
static void qa_double(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL) sqlite3_result_null(ctx);
    else sqlite3_result_double(ctx, sqlite3_value_double(argv[0]) * 2.0);
}
static void qa_library(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc; (void)argv;
#ifdef _WIN32
    char path[32768];
    HMODULE module=GetModuleHandleA("libsqlite3.dll");
    if (module && GetModuleFileNameA(module,path,sizeof(path))) sqlite3_result_text(ctx,path,-1,SQLITE_TRANSIENT);
    else sqlite3_result_error(ctx,"Loaded SQLite DLL path unavailable",-1);
#else
    sqlite3_result_null(ctx);
#endif
}
#ifdef _WIN32
__declspec(dllexport)
#endif
int sqlite3_extension_init(sqlite3 *db, char **error, const sqlite3_api_routines *api) {
    int rc;
    (void)error;
    SQLITE_EXTENSION_INIT2(api);
    rc=sqlite3_create_function(db,"qa_library_path",0,SQLITE_UTF8|SQLITE_DIRECTONLY,0,qa_library,0,0);
    if (rc!=SQLITE_OK) return rc;
    return sqlite3_create_function(db,"qa_extension_double",1,SQLITE_UTF8|SQLITE_DETERMINISTIC|SQLITE_INNOCUOUS,0,qa_double,0,0);
}
