#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <alpm.h>

typedef int (*orig_alpm_trans_prepare_t)(alpm_handle_t *handle, alpm_list_t **data);
typedef const char *(*orig_alpm_strerror_t)(alpm_errno_t err);

int alpm_trans_prepare(alpm_handle_t *handle, alpm_list_t **data) {
    orig_alpm_trans_prepare_t orig = (orig_alpm_trans_prepare_t)dlsym(RTLD_NEXT, "alpm_trans_prepare");
    
    FILE *f = fopen("/tmp/pamac-debug-trans.log", "a");
    if (f) {
        fprintf(f, ">>> alpm_trans_prepare CALLED (dbpath=%s, root=%s)\n", 
                alpm_option_get_dbpath(handle), alpm_option_get_root(handle));
        fprintf(f, "    defaultsiglevel=%d, localfilesiglevel=%d, remotefilesiglevel=%d\n",
                alpm_option_get_default_siglevel(handle),
                alpm_option_get_local_file_siglevel(handle),
                alpm_option_get_remote_file_siglevel(handle));
        alpm_list_t *dblist = alpm_get_syncdbs(handle);
        int idx = 0;
        while (dblist) {
            alpm_db_t *db = dblist->data;
            fprintf(f, "    [%d] name=%s, siglevel=%d\n", idx, alpm_db_get_name(db), (int)alpm_db_get_siglevel(db));
            idx++;
            dblist = dblist->next;
        }
        fprintf(f, "    num_syncdbs=%d\n", idx);
        fclose(f);
    }
    
    int result = orig(handle, data);
    
    if (result == -1) {
        alpm_errno_t err = alpm_errno(handle);
        orig_alpm_strerror_t strerr = (orig_alpm_strerror_t)dlsym(RTLD_NEXT, "alpm_strerror");
        
        f = fopen("/tmp/pamac-debug-trans.log", "a");
        if (f) {
            fprintf(f, "=== alpm_trans_prepare FAILED ===\n");
            fprintf(f, "err_no = %d (%s)\n", err, strerr ? strerr(err) : "unknown");
            fclose(f);
        }
    } else {
        f = fopen("/tmp/pamac-debug-trans.log", "a");
        if (f) {
            fprintf(f, ">>> alpm_trans_prepare SUCCEEDED\n");
            fclose(f);
        }
    }
    
    return result;
}
