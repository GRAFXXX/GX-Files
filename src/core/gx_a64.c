#include "gx_a64.h"
#include <stdio.h>
#include <string.h>
#include <math.h>

static const char *CC[16] = {"eq","ne","hs","lo","mi","pl","vs","vc","hi","ls","ge","lt","gt","le","al","nv"};

static const char *R(int n, int sf, int sp) {
    static char buf[8][8]; static int k;
    char *b = buf[k++ & 7];
    if (n == 31) return sp ? (sf ? "sp" : "wsp") : (sf ? "xzr" : "wzr");
    snprintf(b, 8, "%c%d", sf ? 'x' : 'w', n);
    return b;
}
static const char *V(int n, char t) { static char buf[8][8]; static int k; char *b = buf[k++ & 7]; snprintf(b, 8, "%c%d", t, n); return b; }
static int64_t sext(uint64_t v, int bits) { uint64_t m = 1ull << (bits - 1); v &= (bits == 64 ? ~0ull : (1ull << bits) - 1); return (int64_t)((v ^ m) - m); }
static char ftype(int t) { return t == 0 ? 's' : t == 1 ? 'd' : t == 3 ? 'h' : '?'; }

static int bitmask(int N, int imms, int immr, int sf, uint64_t *out) {
    int x = (N << 6) | (~imms & 0x3F), len = -1;
    for (int i = 6; i >= 0; i--) if (x & (1 << i)) { len = i; break; }
    if (len < 1) return 0;
    int levels = (1 << len) - 1, S = imms & levels, Rr = immr & levels, es = 1 << len;
    if (S == levels) return 0;
    uint64_t e = (S + 1 == 64) ? ~0ull : ((1ull << (S + 1)) - 1);
    uint64_t emask = es == 64 ? ~0ull : ((1ull << es) - 1);
    if (Rr) e = ((e >> Rr) | (e << (es - Rr))) & emask;
    uint64_t r = 0;
    int size = sf ? 64 : 32;
    for (int i = 0; i < size; i += es) r |= e << i;
    *out = sf ? r : (r & 0xFFFFFFFFull);
    return 1;
}

static double fpimm(int imm8) {
    int s = (imm8 >> 7) & 1, bcd = (imm8 >> 4) & 7, f = imm8 & 15;
    int e = bcd < 4 ? bcd + 1 : bcd - 7;
    double v = (16.0 + f) / 16.0 * ldexp(1.0, e);
    return s ? -v : v;
}

static void fmt_imm(char *b, size_t n, int64_t v) {
    if (v >= -9 && v <= 9) snprintf(b, n, "#%lld", (long long)v);
    else if (v < 0) snprintf(b, n, "#-0x%llx", (unsigned long long)-v);
    else snprintf(b, n, "#0x%llx", (unsigned long long)v);
}

int gx_a64_is_adrp(uint32_t ins, uint64_t pc, int *rd, uint64_t *page) {
    if ((ins & 0x9F000000) != 0x90000000) return 0;
    int64_t imm = sext(((ins >> 5) & 0x7FFFF) << 2 | ((ins >> 29) & 3), 21);
    *rd = ins & 31;
    *page = (pc & ~0xFFFull) + ((uint64_t)imm << 12);
    return 1;
}
int gx_a64_is_addimm(uint32_t ins, int *rd, int *rn, uint64_t *imm) {
    if ((ins & 0xFF800000) != 0x91000000) return 0;   // 64-битный ADD imm без флагов
    *rd = ins & 31; *rn = (ins >> 5) & 31;
    *imm = (uint64_t)((ins >> 10) & 0xFFF) << ((ins >> 22) & 1 ? 12 : 0);
    return 1;
}
int gx_a64_is_ldst_uimm(uint32_t ins, int *rt, int *rn, uint64_t *off) {
    if ((ins & 0x3B000000) != 0x39000000) return 0;
    int size = ins >> 30, v = (ins >> 26) & 1, opc = (ins >> 22) & 3, scale = size;
    if (v && (opc & 2)) scale = 4;
    *rt = ins & 31; *rn = (ins >> 5) & 31;
    *off = (uint64_t)((ins >> 10) & 0xFFF) << scale;
    return 1;
}

int gx_a64_dis(uint32_t ins, uint64_t pc, char *o, size_t n, uint64_t *target) {
    char im[40];
    if (target) *target = 0;
    int rd = ins & 31, rn = (ins >> 5) & 31, rm = (ins >> 16) & 31, sf = ins >> 31;
    // переходы
    if ((ins & 0x7C000000) == 0x14000000) {
        uint64_t t = pc + (uint64_t)(sext(ins & 0x3FFFFFF, 26) * 4);
        if (target) *target = t;
        snprintf(o, n, "%s 0x%llx", (ins >> 31) ? "bl" : "b", (unsigned long long)t);
        return (ins >> 31) ? GX_A64_CALL : GX_A64_BRANCH;
    }
    if ((ins & 0xFF000010) == 0x54000000) {
        uint64_t t = pc + (uint64_t)(sext((ins >> 5) & 0x7FFFF, 19) * 4);
        if (target) *target = t;
        snprintf(o, n, "b.%s 0x%llx", CC[ins & 15], (unsigned long long)t);
        return GX_A64_COND;
    }
    if ((ins & 0x7E000000) == 0x34000000) {
        uint64_t t = pc + (uint64_t)(sext((ins >> 5) & 0x7FFFF, 19) * 4);
        if (target) *target = t;
        snprintf(o, n, "%s %s, 0x%llx", (ins >> 24) & 1 ? "cbnz" : "cbz", R(rd, sf, 0), (unsigned long long)t);
        return GX_A64_COND;
    }
    if ((ins & 0x7E000000) == 0x36000000) {
        uint64_t t = pc + (uint64_t)(sext((ins >> 5) & 0x3FFF, 14) * 4);
        int bit = (int)(((ins >> 31) << 5) | ((ins >> 19) & 31));
        if (target) *target = t;
        snprintf(o, n, "%s %s, #%d, 0x%llx", (ins >> 24) & 1 ? "tbnz" : "tbz", R(rd, bit >= 32, 0), bit, (unsigned long long)t);
        return GX_A64_COND;
    }
    if ((ins & 0xFFFFFC1F) == 0xD65F0000) { if (rn == 30) snprintf(o, n, "ret"); else snprintf(o, n, "ret %s", R(rn, 1, 0)); return GX_A64_RET; }
    if (ins == 0xD65F0BFF) { snprintf(o, n, "retaa"); return GX_A64_RET; }
    if (ins == 0xD65F0FFF) { snprintf(o, n, "retab"); return GX_A64_RET; }
    if ((ins & 0xFFFFFC1F) == 0xD61F0000) { snprintf(o, n, "br %s", R(rn, 1, 0)); return GX_A64_RET; }
    if ((ins & 0xFFFFFC1F) == 0xD63F0000) { snprintf(o, n, "blr %s", R(rn, 1, 0)); return GX_A64_NONE; }
    if ((ins & 0xFEFFF800) == 0xD61F0800) { snprintf(o, n, "%s %s", (ins >> 21) & 1 ? "blraa" : "braa", R(rn, 1, 0)); return (ins >> 21) & 1 ? GX_A64_NONE : GX_A64_RET; }
    if ((ins & 0xFFFFF01F) == 0xD503201F) {
        int h = (ins >> 5) & 0x7F;
        const char *nm = h == 0 ? "nop" : h == 1 ? "yield" : h == 2 ? "wfe" : h == 3 ? "wfi" : h == 0x19 ? "paciasp" : h == 0x1D ? "autiasp" : h == 0x1B ? "pacibsp" : h == 0x1F ? "autibsp" : h == 0x20 ? "bti" : h == 0x22 ? "bti c" : h == 0x24 ? "bti j" : h == 0x26 ? "bti jc" : h == 7 ? "xpaclri" : NULL;
        if (nm) snprintf(o, n, "%s", nm); else snprintf(o, n, "hint #%d", h);
        return GX_A64_NONE;
    }
    if ((ins & 0xFFE0001F) == 0xD4000001) { snprintf(o, n, "svc #0x%x", (ins >> 5) & 0xFFFF); return GX_A64_NONE; }
    if ((ins & 0xFFE0001F) == 0xD4200000) { snprintf(o, n, "brk #0x%x", (ins >> 5) & 0xFFFF); return GX_A64_NONE; }
    if ((ins & 0xFFF00000) == 0xD5300000) { snprintf(o, n, "mrs %s, s%d_%d_c%d_c%d_%d", R(rd, 1, 0), 2 + ((ins >> 19) & 1), (ins >> 16) & 7, (ins >> 12) & 15, (ins >> 8) & 15, (ins >> 5) & 7); return GX_A64_NONE; }
    if ((ins & 0xFFF00000) == 0xD5100000) { snprintf(o, n, "msr s%d_%d_c%d_c%d_%d, %s", 2 + ((ins >> 19) & 1), (ins >> 16) & 7, (ins >> 12) & 15, (ins >> 8) & 15, (ins >> 5) & 7, R(rd, 1, 0)); return GX_A64_NONE; }
    if ((ins & 0xFFFFF0FF) == 0xD503309F || (ins & 0xFFFFF0FF) == 0xD50330BF || (ins & 0xFFFFF0FF) == 0xD50330DF) {
        const char *nm = (ins & 0xE0) == 0x80 ? "dsb" : (ins & 0xE0) == 0xA0 ? "dmb" : "isb";
        snprintf(o, n, "%s #%d", nm, (ins >> 8) & 15); return GX_A64_NONE;
    }
    // ADR / ADRP
    if ((ins & 0x1F000000) == 0x10000000) {
        int64_t imm = sext(((ins >> 5) & 0x7FFFF) << 2 | ((ins >> 29) & 3), 21);
        uint64_t t = (ins >> 31) ? (pc & ~0xFFFull) + ((uint64_t)imm << 12) : pc + (uint64_t)imm;
        if (target) *target = t;
        snprintf(o, n, "%s %s, 0x%llx", (ins >> 31) ? "adrp" : "adr", R(rd, 1, 0), (unsigned long long)t);
        return (ins >> 31) ? GX_A64_ADRP : GX_A64_ADR;
    }
    // ADD/SUB immediate
    if ((ins & 0x1F800000) == 0x11000000) {
        int op = (ins >> 30) & 1, S = (ins >> 29) & 1, sh = (ins >> 22) & 1;
        uint64_t imm = (ins >> 10) & 0xFFF;
        if (sh) imm <<= 12;
        fmt_imm(im, sizeof im, (int64_t)imm);
        if (!op && !S && !imm && (rd == 31 || rn == 31)) snprintf(o, n, "mov %s, %s", R(rd, sf, 1), R(rn, sf, 1));
        else if (S && rd == 31) snprintf(o, n, "%s %s, %s", op ? "cmp" : "cmn", R(rn, sf, 1), im);
        else snprintf(o, n, "%s%s %s, %s, %s", op ? "sub" : "add", S ? "s" : "", R(rd, sf, !S), R(rn, sf, 1), im);
        return GX_A64_NONE;
    }
    // логические с immediate
    if ((ins & 0x1F800000) == 0x12000000) {
        int opc = (ins >> 29) & 3; uint64_t v;
        if (!sf && ((ins >> 22) & 1)) goto unk;
        if (!bitmask((ins >> 22) & 1, (ins >> 10) & 63, (ins >> 16) & 63, sf, &v)) goto unk;
        snprintf(im, sizeof im, "#0x%llx", (unsigned long long)v);
        static const char *nm[4] = {"and", "orr", "eor", "ands"};
        if (opc == 1 && rn == 31) snprintf(o, n, "mov %s, %s", R(rd, sf, 1), im);
        else if (opc == 3 && rd == 31) snprintf(o, n, "tst %s, %s", R(rn, sf, 0), im);
        else snprintf(o, n, "%s %s, %s, %s", nm[opc], R(rd, sf, opc != 3), R(rn, sf, 0), im);
        return GX_A64_NONE;
    }
    // MOVN/MOVZ/MOVK
    if ((ins & 0x1F800000) == 0x12800000) {
        int opc = (ins >> 29) & 3, hw = (ins >> 21) & 3;
        uint64_t imm = (ins >> 5) & 0xFFFF;
        if (opc == 1 || (!sf && hw >= 2)) goto unk;
        if (opc == 2) { uint64_t v = imm << (16 * hw); if (!sf) v &= 0xFFFFFFFF; snprintf(o, n, "mov %s, #0x%llx", R(rd, sf, 0), (unsigned long long)v); if (v < 10) snprintf(o, n, "mov %s, #%llu", R(rd, sf, 0), (unsigned long long)v); }
        else if (opc == 0) { uint64_t v = ~(imm << (16 * hw)); if (!sf) v &= 0xFFFFFFFF; int64_t sv = sf ? (int64_t)v : (int32_t)(uint32_t)v; fmt_imm(im, sizeof im, sv); snprintf(o, n, "mov %s, %s", R(rd, sf, 0), im); }
        else snprintf(o, n, "movk %s, #0x%llx%s", R(rd, sf, 0), (unsigned long long)imm, hw ? (hw == 1 ? ", lsl #16" : hw == 2 ? ", lsl #32" : ", lsl #48") : "");
        return GX_A64_NONE;
    }
    // битовые поля
    if ((ins & 0x1F800000) == 0x13000000) {
        int opc = (ins >> 29) & 3, immr = (ins >> 16) & 63, imms = (ins >> 10) & 63, size = sf ? 64 : 32;
        if ((int)((ins >> 22) & 1) != sf || (!sf && (immr >= 32 || imms >= 32))) goto unk;
        if (opc == 2) {
            if (imms == size - 1) snprintf(o, n, "lsr %s, %s, #%d", R(rd, sf, 0), R(rn, sf, 0), immr);
            else if (imms + 1 == immr) snprintf(o, n, "lsl %s, %s, #%d", R(rd, sf, 0), R(rn, sf, 0), size - 1 - imms);
            else if (immr == 0 && imms == 7) snprintf(o, n, "uxtb %s, %s", R(rd, 0, 0), R(rn, 0, 0));
            else if (immr == 0 && imms == 15) snprintf(o, n, "uxth %s, %s", R(rd, 0, 0), R(rn, 0, 0));
            else if (imms < immr) snprintf(o, n, "ubfiz %s, %s, #%d, #%d", R(rd, sf, 0), R(rn, sf, 0), size - immr, imms + 1);
            else snprintf(o, n, "ubfx %s, %s, #%d, #%d", R(rd, sf, 0), R(rn, sf, 0), immr, imms - immr + 1);
        } else if (opc == 0) {
            if (imms == size - 1) snprintf(o, n, "asr %s, %s, #%d", R(rd, sf, 0), R(rn, sf, 0), immr);
            else if (immr == 0 && imms == 7) snprintf(o, n, "sxtb %s, %s", R(rd, sf, 0), R(rn, 0, 0));
            else if (immr == 0 && imms == 15) snprintf(o, n, "sxth %s, %s", R(rd, sf, 0), R(rn, 0, 0));
            else if (immr == 0 && imms == 31) snprintf(o, n, "sxtw %s, %s", R(rd, sf, 0), R(rn, 0, 0));
            else if (imms < immr) snprintf(o, n, "sbfiz %s, %s, #%d, #%d", R(rd, sf, 0), R(rn, sf, 0), size - immr, imms + 1);
            else snprintf(o, n, "sbfx %s, %s, #%d, #%d", R(rd, sf, 0), R(rn, sf, 0), immr, imms - immr + 1);
        } else if (opc == 1) {
            if (imms < immr) snprintf(o, n, "bfi %s, %s, #%d, #%d", R(rd, sf, 0), R(rn, sf, 0), size - immr, imms + 1);
            else snprintf(o, n, "bfxil %s, %s, #%d, #%d", R(rd, sf, 0), R(rn, sf, 0), immr, imms - immr + 1);
        } else goto unk;
        return GX_A64_NONE;
    }
    if ((ins & 0x7FA00000) == 0x13800000) {
        int imms = (ins >> 10) & 63;
        if ((int)((ins >> 22) & 1) != sf || (!sf && imms >= 32)) goto unk;
        if (rn == rm) snprintf(o, n, "ror %s, %s, #%d", R(rd, sf, 0), R(rn, sf, 0), imms);
        else snprintf(o, n, "extr %s, %s, %s, #%d", R(rd, sf, 0), R(rn, sf, 0), R(rm, sf, 0), imms);
        return GX_A64_NONE;
    }
    // логические с регистром
    if ((ins & 0x1F000000) == 0x0A000000) {
        int opc = (ins >> 29) & 3, N = (ins >> 21) & 1, sh = (ins >> 22) & 3, a = (ins >> 10) & 63;
        if (!sf && a >= 32) goto unk;
        static const char *nm[8] = {"and", "orr", "eor", "ands", "bic", "orn", "eon", "bics"};
        static const char *shn[4] = {"lsl", "lsr", "asr", "ror"};
        char s[24] = "";
        if (a) snprintf(s, sizeof s, ", %s #%d", shn[sh], a);
        if (opc == 1 && !N && rn == 31 && !a) snprintf(o, n, "mov %s, %s", R(rd, sf, 0), R(rm, sf, 0));
        else if (opc == 1 && N && rn == 31) snprintf(o, n, "mvn %s, %s%s", R(rd, sf, 0), R(rm, sf, 0), s);
        else if (opc == 3 && !N && rd == 31) snprintf(o, n, "tst %s, %s%s", R(rn, sf, 0), R(rm, sf, 0), s);
        else snprintf(o, n, "%s %s, %s, %s%s", nm[opc | N << 2], R(rd, sf, 0), R(rn, sf, 0), R(rm, sf, 0), s);
        return GX_A64_NONE;
    }
    // ADD/SUB со сдвинутым регистром
    if ((ins & 0x1F200000) == 0x0B000000) {
        int op = (ins >> 30) & 1, S = (ins >> 29) & 1, sh = (ins >> 22) & 3, a = (ins >> 10) & 63;
        if (sh == 3 || (!sf && a >= 32)) goto unk;
        static const char *shn[4] = {"lsl", "lsr", "asr", "?"};
        char s[24] = "";
        if (a) snprintf(s, sizeof s, ", %s #%d", shn[sh], a);
        if (S && rd == 31) snprintf(o, n, "%s %s, %s%s", op ? "cmp" : "cmn", R(rn, sf, 0), R(rm, sf, 0), s);
        else if (op && rn == 31) snprintf(o, n, "neg%s %s, %s%s", S ? "s" : "", R(rd, sf, 0), R(rm, sf, 0), s);
        else snprintf(o, n, "%s%s %s, %s, %s%s", op ? "sub" : "add", S ? "s" : "", R(rd, sf, 0), R(rn, sf, 0), R(rm, sf, 0), s);
        return GX_A64_NONE;
    }
    // ADD/SUB с расширением
    if ((ins & 0x1F200000) == 0x0B200000) {
        int op = (ins >> 30) & 1, S = (ins >> 29) & 1, opt = (ins >> 13) & 7, a = (ins >> 10) & 7;
        if (a > 4 || ((ins >> 22) & 3)) goto unk;
        static const char *ex[8] = {"uxtb", "uxth", "uxtw", "uxtx", "sxtb", "sxth", "sxtw", "sxtx"};
        int msf = (opt & 3) == 3;
        if (S && rd == 31) snprintf(o, n, "%s %s, %s, %s #%d", op ? "cmp" : "cmn", R(rn, sf, 1), R(rm, msf, 0), ex[opt], a);
        else snprintf(o, n, "%s%s %s, %s, %s, %s #%d", op ? "sub" : "add", S ? "s" : "", R(rd, sf, !S), R(rn, sf, 1), R(rm, msf, 0), ex[opt], a);
        return GX_A64_NONE;
    }
    // ADC/SBC
    if ((ins & 0x1FE0FC00) == 0x1A000000) { snprintf(o, n, "%s%s %s, %s, %s", (ins >> 30) & 1 ? "sbc" : "adc", (ins >> 29) & 1 ? "s" : "", R(rd, sf, 0), R(rn, sf, 0), R(rm, sf, 0)); return GX_A64_NONE; }
    // CSEL и родня
    if ((ins & 0x1FE00800) == 0x1A800000) {
        int op = (ins >> 30) & 1, o2 = (ins >> 10) & 1, c = (ins >> 12) & 15;
        if (!op && o2 && rn == 31 && rm == 31) snprintf(o, n, "cset %s, %s", R(rd, sf, 0), CC[c ^ 1]);
        else if (op && !o2 && rn == 31 && rm == 31) snprintf(o, n, "csetm %s, %s", R(rd, sf, 0), CC[c ^ 1]);
        else if (!op && o2 && rn == rm && c < 14) snprintf(o, n, "cinc %s, %s, %s", R(rd, sf, 0), R(rn, sf, 0), CC[c ^ 1]);
        else snprintf(o, n, "%s %s, %s, %s, %s", op ? (o2 ? "csneg" : "csinv") : (o2 ? "csinc" : "csel"), R(rd, sf, 0), R(rn, sf, 0), R(rm, sf, 0), CC[c]);
        return GX_A64_NONE;
    }
    // CCMP/CCMN
    if ((ins & 0x1FE00410) == 0x1A400000) {
        int op = (ins >> 30) & 1, c = (ins >> 12) & 15, nzcv = ins & 15;
        if ((ins >> 11) & 1) snprintf(o, n, "%s %s, #%d, #%d, %s", op ? "ccmp" : "ccmn", R(rn, sf, 0), rm, nzcv, CC[c]);
        else snprintf(o, n, "%s %s, %s, #%d, %s", op ? "ccmp" : "ccmn", R(rn, sf, 0), R(rm, sf, 0), nzcv, CC[c]);
        return GX_A64_NONE;
    }
    // 2 источника
    if ((ins & 0x5FE00000) == 0x1AC00000) {
        int opc = (ins >> 10) & 63;
        const char *nm = opc == 2 ? "udiv" : opc == 3 ? "sdiv" : opc == 8 ? "lsl" : opc == 9 ? "lsr" : opc == 10 ? "asr" : opc == 11 ? "ror" : NULL;
        if (!nm) goto unk;
        snprintf(o, n, "%s %s, %s, %s", nm, R(rd, sf, 0), R(rn, sf, 0), R(rm, sf, 0));
        return GX_A64_NONE;
    }
    // 1 источник
    if ((ins & 0x5FFF0000) == 0x5AC00000) {
        int opc = (ins >> 10) & 63;
        const char *nm = opc == 0 ? "rbit" : opc == 1 ? "rev16" : opc == 2 ? (sf ? "rev32" : "rev") : opc == 3 ? "rev" : opc == 4 ? "clz" : opc == 5 ? "cls" : NULL;
        if (!nm) goto unk;
        snprintf(o, n, "%s %s, %s", nm, R(rd, sf, 0), R(rn, sf, 0));
        return GX_A64_NONE;
    }
    // 3 источника
    if ((ins & 0x1F000000) == 0x1B000000) {
        int op31 = (ins >> 21) & 7, o0 = (ins >> 15) & 1, ra = (ins >> 10) & 31;
        if (op31 == 0) {
            if (ra == 31) snprintf(o, n, "%s %s, %s, %s", o0 ? "mneg" : "mul", R(rd, sf, 0), R(rn, sf, 0), R(rm, sf, 0));
            else snprintf(o, n, "%s %s, %s, %s, %s", o0 ? "msub" : "madd", R(rd, sf, 0), R(rn, sf, 0), R(rm, sf, 0), R(ra, sf, 0));
        } else if (op31 == 1 || op31 == 5) {
            const char *nm = op31 == 1 ? (ra == 31 ? (o0 ? "smnegl" : "smull") : (o0 ? "smsubl" : "smaddl")) : (ra == 31 ? (o0 ? "umnegl" : "umull") : (o0 ? "umsubl" : "umaddl"));
            if (ra == 31) snprintf(o, n, "%s %s, %s, %s", nm, R(rd, 1, 0), R(rn, 0, 0), R(rm, 0, 0));
            else snprintf(o, n, "%s %s, %s, %s, %s", nm, R(rd, 1, 0), R(rn, 0, 0), R(rm, 0, 0), R(ra, 1, 0));
        } else if (op31 == 2 || op31 == 6) snprintf(o, n, "%s %s, %s, %s", op31 == 2 ? "smulh" : "umulh", R(rd, 1, 0), R(rn, 1, 0), R(rm, 1, 0));
        else goto unk;
        return GX_A64_NONE;
    }
    // загрузка литерала
    if ((ins & 0x3B000000) == 0x18000000) {
        int opc = ins >> 30, v = (ins >> 26) & 1;
        uint64_t t = pc + (uint64_t)(sext((ins >> 5) & 0x7FFFF, 19) * 4);
        if (target) *target = t;
        if (v) snprintf(o, n, "ldr %s, 0x%llx", V(rd, opc == 0 ? 's' : opc == 1 ? 'd' : 'q'), (unsigned long long)t);
        else if (opc == 2) snprintf(o, n, "ldrsw %s, 0x%llx", R(rd, 1, 0), (unsigned long long)t);
        else if (opc == 3) snprintf(o, n, "prfm #%d, 0x%llx", rd, (unsigned long long)t);
        else snprintf(o, n, "ldr %s, 0x%llx", R(rd, opc, 0), (unsigned long long)t);
        return GX_A64_LIT;
    }
    // LDP/STP
    if ((ins & 0x3A000000) == 0x28000000) {
        int opc = ins >> 30, v = (ins >> 26) & 1, type = (ins >> 23) & 3, L = (ins >> 22) & 1, rt2 = (ins >> 10) & 31;
        int64_t imm = sext((ins >> 15) & 0x7F, 7);
        if (opc == 3 || (!v && opc == 1 && (!L || type == 0))) goto unk;
        int scale; const char *nm; const char *a, *b;
        if (v) { scale = 2 + opc; char t = opc == 0 ? 's' : opc == 1 ? 'd' : 'q'; a = V(rd, t); b = V(rt2, t); }
        else { scale = opc == 2 ? 3 : 2; a = R(rd, opc == 2, 0); b = R(rt2, opc == 2, 0); }
        imm *= 1 << scale;
        nm = L ? (!v && opc == 1 ? "ldpsw" : type == 0 ? "ldnp" : "ldp") : (type == 0 ? "stnp" : "stp");
        if (type == 1) snprintf(o, n, "%s %s, %s, [%s], #%lld", nm, a, b, R(rn, 1, 1), (long long)imm);
        else if (type == 3) snprintf(o, n, "%s %s, %s, [%s, #%lld]!", nm, a, b, R(rn, 1, 1), (long long)imm);
        else if (imm) snprintf(o, n, "%s %s, %s, [%s, #%lld]", nm, a, b, R(rn, 1, 1), (long long)imm);
        else snprintf(o, n, "%s %s, %s, [%s]", nm, a, b, R(rn, 1, 1));
        return GX_A64_NONE;
    }
    // загрузка/сохранение регистра
    if ((ins & 0x3A000000) == 0x38000000) {
        int size = ins >> 30, v = (ins >> 26) & 1, opc = (ins >> 22) & 3;
        const char *nm; const char *rt; int scale = size;
        if (v) {
            if (size != 0 && (opc & 2)) goto unk;
            char t = size == 0 ? ((opc & 2) ? 'q' : 'b') : size == 1 ? 'h' : size == 2 ? 's' : 'd';
            if (size == 0 && (opc & 2)) scale = 4;
            rt = V(rd, t); nm = (opc & 1) ? "ldr" : "str";
        } else {
            static const char *tbl[4][4] = {{"strb", "ldrb", "ldrsb", "ldrsb"}, {"strh", "ldrh", "ldrsh", "ldrsh"}, {"str", "ldr", "ldrsw", "?"}, {"str", "ldr", "prfm", "?"}};
            nm = tbl[size][opc];
            if (nm[0] == '?') goto unk;
            int x = size == 3 || (opc == 2 && size != 3);
            if (size == 2 && opc == 2) x = 1;
            rt = R(rd, x, 0);
            if (size == 3 && opc == 2) { static char pf[8]; snprintf(pf, sizeof pf, "#%d", rd); rt = pf; }
        }
        if ((ins & 0x01000000)) {      // unsigned offset
            uint64_t off = (uint64_t)((ins >> 10) & 0xFFF) << scale;
            if (off) snprintf(o, n, "%s %s, [%s, #0x%llx]", nm, rt, R(rn, 1, 1), (unsigned long long)off);
            else snprintf(o, n, "%s %s, [%s]", nm, rt, R(rn, 1, 1));
            return GX_A64_NONE;
        }
        if ((ins >> 21) & 1) {
            if (((ins >> 10) & 3) != 2) goto unk;
            int opt = (ins >> 13) & 7, S = (ins >> 12) & 1;
            static const char *ex[8] = {"?", "?", "uxtw", "lsl", "?", "?", "sxtw", "sxtx"};
            if (ex[opt][0] == '?') goto unk;
            if (opt == 3 && !S) snprintf(o, n, "%s %s, [%s, %s]", nm, rt, R(rn, 1, 1), R(rm, 1, 0));
            else if (S) snprintf(o, n, "%s %s, [%s, %s, %s #%d]", nm, rt, R(rn, 1, 1), R(rm, opt & 1, 0), ex[opt], scale);
            else snprintf(o, n, "%s %s, [%s, %s, %s]", nm, rt, R(rn, 1, 1), R(rm, opt & 1, 0), ex[opt]);
            return GX_A64_NONE;
        }
        int64_t imm = sext((ins >> 12) & 0x1FF, 9);
        int mode = (ins >> 10) & 3;
        if (mode == 0) { char nm2[16]; if (!strncmp(nm, "str", 3)) snprintf(nm2, sizeof nm2, "stur%s", nm + 3); else if (!strncmp(nm, "ldr", 3)) snprintf(nm2, sizeof nm2, "ldur%s", nm + 3); else snprintf(nm2, sizeof nm2, "%s", nm);
            if (imm) snprintf(o, n, "%s %s, [%s, #%lld]", nm2, rt, R(rn, 1, 1), (long long)imm); else snprintf(o, n, "%s %s, [%s]", nm2, rt, R(rn, 1, 1)); }
        else if (mode == 1) snprintf(o, n, "%s %s, [%s], #%lld", nm, rt, R(rn, 1, 1), (long long)imm);
        else if (mode == 3) snprintf(o, n, "%s %s, [%s, #%lld]!", nm, rt, R(rn, 1, 1), (long long)imm);
        else goto unk;
        return GX_A64_NONE;
    }
    // атомарные/эксклюзивные — кратко
    if ((ins & 0x3F000000) == 0x08000000) { snprintf(o, n, "%s %s, [%s]", (ins >> 22) & 1 ? "ldxr*" : "stxr*", R(rd, (ins >> 30) == 3, 0), R(rn, 1, 1)); return GX_A64_NONE; }
    // плавающая точка
    if ((ins & 0x5F000000) == 0x1E000000 && (ins & 0x00200000)) {
        int ty = (ins >> 22) & 3;
        int conv = (ins & 0x7F20FC00) == 0x1E200000;   // преобразования int<->fp могут иметь sf
        if (ty == 2 || ((ins >> 29) & 1) || (!conv && (ins >> 31))) goto unk;
    }
    if ((ins & 0xFF200C00) == 0x1E200800) {      // 2 источника
        int t = (ins >> 22) & 3, op = (ins >> 12) & 15;
        static const char *nm[9] = {"fmul", "fdiv", "fadd", "fsub", "fmax", "fmin", "fmaxnm", "fminnm", "fnmul"};
        if (op > 8) goto unk;
        char c = ftype(t);
        snprintf(o, n, "%s %s, %s, %s", nm[op], V(rd, c), V(rn, c), V(rm, c));
        return GX_A64_NONE;
    }
    if ((ins & 0xFF201FE0) == 0x1E201000) {
        int t = (ins >> 22) & 3;
        snprintf(o, n, "fmov %s, #%g", V(rd, ftype(t)), fpimm((ins >> 13) & 0xFF));
        return GX_A64_NONE;
    }
    if ((ins & 0xFF20FC07) == 0x1E202000 || (ins & 0xFF20FC17) == 0x1E202010) {
        int t = (ins >> 22) & 3; char c = ftype(t);
        const char *nm = (ins & 0x10) ? "fcmpe" : "fcmp";
        if ((ins >> 3) & 1) snprintf(o, n, "%s %s, #0.0", nm, V(rn, c));
        else snprintf(o, n, "%s %s, %s", nm, V(rn, c), V(rm, c));
        return GX_A64_NONE;
    }
    if ((ins & 0xFF207C00) == 0x1E204000) {   // 1 источник
        int t = (ins >> 22) & 3, op = (ins >> 15) & 63; char c = ftype(t);
        const char *nm = op == 0 ? "fmov" : op == 1 ? "fabs" : op == 2 ? "fneg" : op == 3 ? "fsqrt" : NULL;
        if (op == 13 || (op == 4 && t == 0) || (op == 5 && t == 1) || (op == 7 && t == 3)) goto unk;
        if (op == 4 || op == 5 || op == 7) { char to = op == 4 ? 's' : op == 5 ? 'd' : 'h'; snprintf(o, n, "fcvt %s, %s", V(rd, to), V(rn, c)); return GX_A64_NONE; }
        if (op >= 8 && op <= 15) { static const char *rn2[8] = {"frintn", "frintp", "frintm", "frintz", "frinta", "?", "frintx", "frinti"}; snprintf(o, n, "%s %s, %s", rn2[op - 8], V(rd, c), V(rn, c)); return GX_A64_NONE; }
        if (!nm) goto unk;
        snprintf(o, n, "%s %s, %s", nm, V(rd, c), V(rn, c));
        return GX_A64_NONE;
    }
    if ((ins & 0x7F200C00) == 0x1E200C00) {     // fcsel
        int t = (ins >> 22) & 3; char c = ftype(t);
        snprintf(o, n, "fcsel %s, %s, %s, %s", V(rd, c), V(rn, c), V(rm, c), CC[(ins >> 12) & 15]);
        return GX_A64_NONE;
    }
    if ((ins & 0x7F20FC00) == 0x1E200000) {     // преобразования int<->fp
        int t = (ins >> 22) & 3, rmode = (ins >> 19) & 3, opc = (ins >> 16) & 7; char c = ftype(t);
        if (rmode == 0 && (opc == 6 || opc == 7) && sf != (t == 1)) goto unk;
        if (rmode == 0 && opc == 7) { snprintf(o, n, "fmov %s, %s", V(rd, c), R(rn, sf, 0)); return GX_A64_NONE; }
        if (rmode == 0 && opc == 6) { snprintf(o, n, "fmov %s, %s", R(rd, sf, 0), V(rn, c)); return GX_A64_NONE; }
        if (rmode == 0 && (opc == 2 || opc == 3)) { snprintf(o, n, "%s %s, %s", opc == 2 ? "scvtf" : "ucvtf", V(rd, c), R(rn, sf, 0)); return GX_A64_NONE; }
        if (opc == 0 || opc == 1) { static const char *m[4] = {"n", "p", "m", "z"}; snprintf(o, n, "fcvt%s%s %s, %s", m[rmode], opc ? "u" : "s", R(rd, sf, 0), V(rn, c)); return GX_A64_NONE; }
        if (rmode == 0 && (opc == 4 || opc == 5)) { snprintf(o, n, "fcvta%s %s, %s", opc == 5 ? "u" : "s", R(rd, sf, 0), V(rn, c)); return GX_A64_NONE; }
        goto unk;
    }
    if ((ins & 0xFF000000) == 0x1F000000) {     // fmadd и т.п.
        int t = (ins >> 22) & 3, o1 = (ins >> 21) & 1, o0 = (ins >> 15) & 1, ra = (ins >> 10) & 31; char c = ftype(t);
        static const char *nm[4] = {"fmadd", "fmsub", "fnmadd", "fnmsub"};
        snprintf(o, n, "%s %s, %s, %s, %s", nm[o1 << 1 | o0], V(rd, c), V(rn, c), V(rm, c), V(ra, c));
        return GX_A64_NONE;
    }
    if ((ins & 0xBFE0FC00) == 0x0EA01C00 && rn == rm) {    // mov vD.16b, vN.16b (orr)
        snprintf(o, n, "mov v%d.%s, v%d.%s", rd, (ins >> 30) & 1 ? "16b" : "8b", rn, (ins >> 30) & 1 ? "16b" : "8b");
        return GX_A64_NONE;
    }
    if ((ins & 0x9FFFFC00) == 0x0F000400 || (ins & 0xBFF8FC00) == 0x0F00E400 || (ins & 0xFFFFFC00) == 0x6F00E400) {
        snprintf(o, n, "movi v%d, #0x%x", rd, (((ins >> 16) & 7) << 5) | ((ins >> 5) & 31));
        return GX_A64_NONE;
    }
unk:
    snprintf(o, n, ".word 0x%08x", ins);
    return GX_A64_NONE;
}

int gx_a64_const(uint32_t ins, int *kind, double *value, int *is64) {
    int sf = ins >> 31;
    if ((ins & 0x1F800000) == 0x12800000) {
        int opc = (ins >> 29) & 3, hw = (ins >> 21) & 3;
        uint64_t imm = (ins >> 5) & 0xFFFF;
        if (opc == 2) {
            uint64_t v = imm << (16 * hw);
            *kind = 1; *value = (double)v; *is64 = sf;
            return 1;
        }
        if (opc == 0) {
            uint64_t v = ~(imm << (16 * hw));
            *kind = 1; *value = sf ? (double)(int64_t)v : (double)(int32_t)(uint32_t)v; *is64 = sf;
            return 1;
        }
        return 0;
    }
    if ((ins & 0x1F800000) == 0x11000000 && ((ins >> 29) & 1) && (ins & 31) == 31) {   // CMP/CMN imm
        uint64_t imm = (ins >> 10) & 0xFFF;
        if ((ins >> 22) & 1) imm <<= 12;
        *kind = 4; *value = (double)imm; *is64 = sf;
        return 1;
    }
    if ((ins & 0xFF201FE0) == 0x1E201000) {
        *kind = 2; *value = fpimm((ins >> 13) & 0xFF); *is64 = (ins >> 22) & 1;
        return 1;
    }
    return 0;
}

int gx_a64_set_const(uint32_t *ins, int kind, double v) {
    uint32_t x = *ins;
    if (kind == 1) {
        int sf = x >> 31;
        if (v != floor(v) || v >= 9.2e18 || v < -9.2e18) return 0;
        int64_t iv = (int64_t)v;
        if (!sf && (iv > 0xFFFFFFFFLL || iv < -0x80000000LL)) return 0;
        uint64_t u = sf ? (uint64_t)iv : (uint64_t)(uint32_t)iv;
        for (int hw = 0; hw < (sf ? 4 : 2); hw++) {
            uint64_t m = 0xFFFFull << (16 * hw);
            if (!(u & ~m)) { *ins = (x & 0x80000000) | 0x52800000 | (uint32_t)hw << 21 | (uint32_t)((u >> (16 * hw)) & 0xFFFF) << 5 | (x & 31); return 1; }
            uint64_t nu = sf ? ~u : (~u & 0xFFFFFFFF);
            if (!(nu & ~m)) { *ins = (x & 0x80000000) | 0x12800000 | (uint32_t)hw << 21 | (uint32_t)((nu >> (16 * hw)) & 0xFFFF) << 5 | (x & 31); return 1; }
        }
        return 0;
    }
    if (kind == 2) {
        for (int i = 0; i < 256; i++) if (fpimm(i) == v) { *ins = (x & ~(0xFFu << 13)) | (uint32_t)i << 13; return 1; }
        return 0;
    }
    if (kind == 4) {
        if (v != floor(v) || v < 0) return 0;
        uint64_t u = (uint64_t)v;
        if (u <= 0xFFF) { *ins = (x & ~(0x1FFFu << 10)) | (uint32_t)u << 10; return 1; }
        if (!(u & 0xFFF) && u <= 0xFFF000) { *ins = (x & ~(0x1FFFu << 10)) | 1u << 22 | (uint32_t)(u >> 12) << 10; return 1; }
        return 0;
    }
    if (kind == 3) {     // mov wN, #hi, lsl #16 — верхние 16 бит float
        float f = (float)v; uint32_t b; memcpy(&b, &f, 4);
        if (b & 0xFFFF) return 0;
        *ins = (x & ~(0xFFFFu << 5)) | (b >> 16) << 5;
        return 1;
    }
    return 0;
}

static uint32_t movz(int sf, int rd, int hw, uint32_t imm) { return (sf ? 0xD2800000u : 0x52800000u) | (uint32_t)hw << 21 | (imm & 0xFFFF) << 5 | rd; }
static uint32_t movk(int sf, int rd, int hw, uint32_t imm) { return (sf ? 0xF2800000u : 0x72800000u) | (uint32_t)hw << 21 | (imm & 0xFFFF) << 5 | rd; }
static uint32_t movn(int sf, int rd, int hw, uint32_t imm) { return (sf ? 0x92800000u : 0x12800000u) | (uint32_t)hw << 21 | (imm & 0xFFFF) << 5 | rd; }

int gx_a64_tpl_ret_int(int64_t v, int wide, uint32_t *out) {
    int k = 0;
    uint64_t u = wide ? (uint64_t)v : (uint64_t)(uint32_t)v;
    int parts = wide ? 4 : 2;
    if (v < 0 && (wide || v >= -0x10000)) {
        uint64_t nu = wide ? ~u : (~u & 0xFFFFFFFF);
        if (nu <= 0xFFFF) { out[k++] = movn(wide, 0, 0, (uint32_t)nu); out[k++] = GX_A64_RETI; return k; }
    }
    int first = 1;
    for (int hw = 0; hw < parts; hw++) {
        uint32_t p = (uint32_t)(u >> (16 * hw)) & 0xFFFF;
        if (!p && !(first && hw == parts - 1)) continue;
        out[k++] = first ? movz(wide, 0, hw, p) : movk(wide, 0, hw, p);
        first = 0;
    }
    if (first) out[k++] = movz(wide, 0, 0, 0);
    out[k++] = GX_A64_RETI;
    return k;
}

int gx_a64_tpl_ret_float(float f, uint32_t *out) {
    uint32_t b; memcpy(&b, &f, 4);
    int k = 0;
    for (int i = 0; i < 256; i++) if ((float)fpimm(i) == f && f != 0) { out[k++] = 0x1E201000u | (uint32_t)i << 13; out[k++] = GX_A64_RETI; return k; }
    uint32_t lo = b & 0xFFFF, hi = b >> 16;
    if (lo) { out[k++] = movz(0, 8, 0, lo); if (hi) out[k++] = movk(0, 8, 1, hi); }
    else out[k++] = movz(0, 8, 1, hi);
    out[k++] = 0x1E270100u;   // fmov s0, w8
    out[k++] = GX_A64_RETI;
    return k;
}

int gx_a64_tpl_ret_double(double f, uint32_t *out) {
    uint64_t b; memcpy(&b, &f, 8);
    int k = 0, first = 1;
    for (int hw = 0; hw < 4; hw++) {
        uint32_t p = (uint32_t)(b >> (16 * hw)) & 0xFFFF;
        if (!p) continue;
        out[k++] = first ? movz(1, 8, hw, p) : movk(1, 8, hw, p);
        first = 0;
    }
    if (first) out[k++] = movz(1, 8, 0, 0);
    out[k++] = 0x9E670100u;   // fmov d0, x8
    out[k++] = GX_A64_RETI;
    return k;
}

int gx_a64_enc_branch(uint64_t pc, uint64_t target, int link, uint32_t *out) {
    int64_t d = (int64_t)(target - pc);
    if (d & 3 || d < -(1LL << 27) || d >= (1LL << 27)) return 0;
    *out = (link ? 0x94000000u : 0x14000000u) | ((uint32_t)(d >> 2) & 0x3FFFFFF);
    return 1;
}
