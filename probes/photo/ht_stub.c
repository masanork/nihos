/* HTJ2K is deliberately unsupported in the bounded Part-1 card profile. */
#include "opj_includes.h"
OPJ_BOOL opj_t1_ht_decode_cblk(opj_t1_t *t1,opj_tcd_cblk_dec_t *block,OPJ_UINT32 orient,OPJ_UINT32 roi,OPJ_UINT32 style,opj_event_mgr_t *manager,opj_mutex_t *mutex,OPJ_BOOL check){
    (void)t1;(void)block;(void)orient;(void)roi;(void)style;(void)manager;(void)mutex;(void)check;return OPJ_FALSE;
}
