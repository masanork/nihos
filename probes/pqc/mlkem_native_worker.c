/* Fixed public vectors only. Not a production KEM or entropy integration. */
#include "mlkem_arena.h"
#include "mlkem_native.h"
#include "expected_test_vectors.h"
#include <string.h>
struct nih_mlkem_result {
    uint32_t key_ok, enc_ok, dec_ok, implicit_ok, oom_ok;
    uint32_t key_peak, enc_peak, dec_peak, allocs, frees, oom_error, live, uncleared;
    uint32_t ticks, foreground0, foreground1;
    uint32_t key_stack, enc_stack, dec_stack, implicit_stack, oom_stack;
};
extern void nih_pqc_observe(uint32_t out[3]);
extern uint32_t nih_sqlite_stack_paint(uint32_t low);
static uint32_t stack_used(uint32_t low, uint32_t painted, uint32_t end) {
    while (low < painted && *(const volatile uint32_t *)(uintptr_t)low == 0x5a7ec319) low += 4;
    return end - low;
}
static void reset(struct nih_mlkem_arena *a) {
    a->used = a->peak = 0; a->attempts = a->fail_at = 0;
}
int nih_mlkem_worker_fixture(uint8_t *workspace, size_t workspace_len,
    uint8_t *io, size_t io_len, uint32_t low, uint32_t end, struct nih_mlkem_result *r) {
    enum { PK = 0, SK = 1184, CT = 3584, SS = 4672, REC = 4704, COINS = 4736, END = 4800 };
    if (!workspace || workspace_len < 256 || ((uintptr_t)workspace & 31) || !io || io_len < END || !r) return 1;
    struct nih_mlkem_arena a = { .bytes = workspace, .capacity = workspace_len };
    uint8_t *pk=io+PK, *sk=io+SK, *ct=io+CT, *ss=io+SS, *rec=io+REC, *coins=io+COINS;
    memcpy(coins, test_vector_d, 32); memcpy(coins+32, test_vector_z, 32);
    uint32_t before[3], after[3]; nih_pqc_observe(before);
    uint32_t painted = nih_sqlite_stack_paint(low);
    int rc = PQCP_MLKEM_NATIVE_MLKEM768_keypair_derand(pk, sk, coins, &a);
    r->key_stack = stack_used(low, painted, end);
    r->key_ok = rc == 0 && memcmp(pk, test_vector_pk, 1184) == 0 && memcmp(sk, test_vector_sk, 2400) == 0;
    r->key_peak = (uint32_t)a.peak;
    if (a.live || a.uncleared) return 2;
    reset(&a);
    painted = nih_sqlite_stack_paint(low);
    rc = PQCP_MLKEM_NATIVE_MLKEM768_enc_derand(ct, ss, pk, test_vector_m, &a);
    r->enc_stack = stack_used(low, painted, end);
    r->enc_ok = rc == 0 && memcmp(ct, test_vector_ct, 1088) == 0 && memcmp(ss, test_vector_ss, 32) == 0;
    r->enc_peak = (uint32_t)a.peak;
    if (a.live || a.uncleared) return 3;
    reset(&a);
    painted = nih_sqlite_stack_paint(low);
    rc = PQCP_MLKEM_NATIVE_MLKEM768_dec(rec, ct, sk, &a);
    r->dec_stack = stack_used(low, painted, end);
    r->dec_ok = rc == 0 && memcmp(rec, ss, 32) == 0;
    r->dec_peak = (uint32_t)a.peak;
    if (a.live || a.uncleared) return 4;
    reset(&a);
    ct[0] ^= 1;
    painted = nih_sqlite_stack_paint(low);
    rc = PQCP_MLKEM_NATIVE_MLKEM768_dec(rec, ct, sk, &a);
    r->implicit_stack = stack_used(low, painted, end);
    r->implicit_ok = rc == 0 && memcmp(rec, ss, 32) != 0;
    ct[0] ^= 1;
    nih_pqc_observe(after);
    r->ticks=after[0]-before[0]; r->foreground0=after[1]-before[1]; r->foreground1=after[2]-before[2];
    if (a.live || a.uncleared) return 5;
    reset(&a); a.fail_at=4;
    painted = nih_sqlite_stack_paint(low);
    rc = PQCP_MLKEM_NATIVE_MLKEM768_dec(rec, ct, sk, &a);
    r->oom_stack = stack_used(low, painted, end);
    r->oom_ok = rc == -2 && a.attempts >= 4 && a.live == 0;
    r->allocs=a.allocs; r->frees=a.frees; r->oom_error=(uint32_t)(rc == -2); r->live=a.live; r->uncleared=a.uncleared;
    return r->key_ok && r->enc_ok && r->dec_ok && r->implicit_ok && r->oom_ok && a.allocs == a.frees && !a.live && !a.uncleared ? 0 : 6;
}
