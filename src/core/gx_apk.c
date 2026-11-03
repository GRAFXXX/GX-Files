#define _GNU_SOURCE
#include "gx_apk.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static int ends_with(const char *s, const char *suf) {
    size_t a = strlen(s), b = strlen(suf);
    return a >= b && !strcasecmp(s + a - b, suf);
}

static int is_raster(const char *p) {
    return ends_with(p, ".png") || ends_with(p, ".webp") || ends_with(p, ".jpg") || ends_with(p, ".jpeg");
}

static void note_engine(gx_apk_info *s, const char *f) {
    if (!strcmp(f, "libil2cpp.so")) s->il2cpp = 1;
    else if (!strcmp(f, "libunity.so")) s->unity = 1;
    else if (!strcmp(f, "libmonobdwgc-2.0.so") || !strcmp(f, "libmono.so")) s->mono_unity = 1;
    else if (!strcmp(f, "libflutter.so")) s->flutter = 1;
    else if (!strcmp(f, "libyoyo.so")) s->gamemaker = 1;
    else if (!strncmp(f, "libpython", 9)) s->python = 1;
    else if (!strcmp(f, "libreactnativejni.so") || !strcmp(f, "libhermes.so")) s->react = 1;
    else if (!strcmp(f, "libmonosgen-2.0.so") || !strcmp(f, "libmonodroid.so")) s->dotnet = 1;
    else if (!strcmp(f, "libgodot_android.so")) s->godot = 1;
    else if (!strcmp(f, "libUE4.so") || !strcmp(f, "libUnreal.so")) s->unreal = 1;
    else if (!strncmp(f, "libcocos", 8)) s->cocos = 1;
    else if (!strcmp(f, "libgdx.so")) s->gdx = 1;
    else if (!strcmp(f, "libminecraftpe.so")) s->minecraft = 1;
    else if (!strcmp(f, "libSDL3.so")) s->sdl = 1;
    else if (!strcmp(f, "libSDL2.so")) s->sdl2 = 1;
    else if (!strcmp(f, "libmain.so")) s->mainlib = 1;
    else if (!strcmp(f, "libg.so")) s->supercell = 1;
    else if (!strcmp(f, "libGame.so")) s->rockstar_game = 1;
    else if (!strcmp(f, "libopenal.so")) s->openal = 1;
    else if (!strcmp(f, "libVendor_mpg123.so")) s->mpg123 = 1;
    else if (!strcmp(f, "libfmod.so")) s->fmod = 1;
    if (!strncmp(f, "libdxvk", 7)) s->dxvk = 1;
}

const char *gx_apk_engine(const gx_apk_info *s) {
    if (s->rockstar_game && s->openal && s->mpg123) return "Rockstar";
    if ((s->il2cpp || s->unity) && s->unity_library) return NULL;
    if ((s->il2cpp || s->unity) && s->unity6) return "Unity 6";
    if (s->il2cpp) return "Unity (IL2CPP)";
    if (s->unity) return s->mono_unity ? "Unity (Mono)" : "Unity";
    if (s->flutter && !s->supercell) return "Flutter";
    if (s->gamemaker) return "GameMaker";
    if (s->capacitor) return "Capacitor";
    if (s->cordova) return "Cordova";
    if (s->react) return "React Native";
    if (s->dotnet) return ".NET / Xamarin";
    if (s->godot) return "Godot";
    if (s->unreal) return "Unreal Engine";
    if (s->cocos) return "Cocos";
    if (s->minecraft) return "Minecraft";
    if (s->python && s->sdl2 && s->mainlib) return "Python";
    if (s->sdl || (s->sdl2 && s->mainlib)) return "SDL";
    if (s->gdx) return "libGDX";
    if (s->native_activity) return "NativeActivity";
    return NULL;
}

int gx_apk_any_native(const gx_apk_info *i) {
    return i->abi_arm64 || i->abi_v7a || i->abi_armeabi || i->abi_x86 || i->abi_x86_64;
}

const char *gx_apk_route(const gx_apk_info *i) {
    if (i->capacitor || i->cordova) return "web";
    int native = gx_apk_any_native(i);
    if (native && !i->abi_arm64) return NULL;
    const char *eng = gx_apk_engine(i);
    if (!native) return i->dex_count > 0 ? "java" : NULL;
    if (!eng) return i->dex_count > 0 ? "java" : NULL;
    if (!strcmp(eng, "Unity 6")) return "java";
    if (!strncmp(eng, "Unity", 5)) return "unity";
    if (!strcmp(eng, "Cocos")) return i->fmod ? "cocos" : "java";
    if (!strcmp(eng, "Minecraft")) return "minecraft";
    if (!strcmp(eng, "SDL") && i->dxvk) return "sdl";
    if (!strcmp(eng, "SDL") || !strcmp(eng, "Python")) return "java";
    if (!strcmp(eng, "Unreal Engine")) return "ue4";
    if (!strcmp(eng, "Rockstar")) return "gta";
    if (!strcmp(eng, "Godot")) return "godot";
    if (!strcmp(eng, "NativeActivity")) return "nativeactivity";
    if (!strcmp(eng, "Flutter")) return "java";
    if (!strcmp(eng, "GameMaker")) return "gamemaker";
    return "java";
}

static void add_str(char ***arr, int *n, const char *s) {
    *arr = realloc(*arr, sizeof(char *) * (size_t)(*n + 1));
    (*arr)[(*n)++] = strdup(s);
}


static int contains_in_entry(gxz *z, const gxz_entry *e, const char *needle, size_t limit) {
    if (e->usize > limit) return 0;
    uint8_t *d; size_t n;
    if (!gxz_read(z, e, limit, &d, &n)) return 0;
    size_t nl = strlen(needle);
    int found = 0;
    for (size_t i = 0; i + nl <= n && !found; i++) if (d[i] == (uint8_t)needle[0] && !memcmp(d + i, needle, nl)) found = 1;
    free(d);
    return found;
}

// --- разрешение ресурсов иконки ---

typedef struct { gxz *z; gxa_arsc *a; } ctx_t;

static int pick_value(gxa_arsc *a, uint32_t id, gxa_value *best, int depth) {
    if (!a || depth > 5) return 0;
    gxa_value vals[96];
    int n = gxa_arsc_values(a, id, vals, 96);
    int found = 0, best_score = -1;
    for (int i = 0; i < n; i++) {
        gxa_value v = vals[i];
        if (v.type == GXA_T_REF && v.data) {
            gxa_value sub;
            if (pick_value(a, v.data, &sub, depth + 1)) { sub.density = v.density ? v.density : sub.density; v = sub; }
            else continue;
        }
        int score;
        if (v.type == GXA_T_STRING && v.str) {
            int dens = v.density == 0 ? 160 : v.density == 0xFFFF ? 200 : v.density == 0xFFFE ? 0 : v.density;
            score = is_raster(v.str) ? 100000 + dens : 50000 + v.version;
        } else if (v.type >= GXA_T_COLOR_ARGB8 && v.type <= GXA_T_COLOR_RGB4) {
            score = 1000;
        } else continue;
        if (v.night) score -= 10;
        if (v.lang[0]) score -= 5;
        if (score > best_score) { best_score = score; *best = v; found = 1; }
    }
    return found;
}

static void set_layer(gx_icon_layer *l, const gxa_value *v) {
    memset(l, 0, sizeof *l);
    if (v->type == GXA_T_STRING && v->str) snprintf(l->path, sizeof l->path, "%s", v->str);
    else { l->is_color = 1; l->color = v->data; }
}

// Если path — xml, разбираем: adaptive-icon → слои; bitmap/inset → вложенный drawable
static void resolve_xml_drawable(ctx_t *c, gx_icon_layer *layer, gx_apk_info *info, int top) {
    for (int guard = 0; guard < 4; guard++) {
        if (layer->is_color || !layer->path[0] || is_raster(layer->path) || !ends_with(layer->path, ".xml")) return;
        long idx = gxz_find(c->z, layer->path);
        if (idx < 0) return;
        uint8_t *d; size_t n;
        if (!gxz_read(c->z, &c->z->e[idx], 4 << 20, &d, &n)) return;
        gxa_xml x;
        int ok = gxa_xml_parse(&x, d, n);
        free(d);
        if (!ok) return;
        const gxa_elem *root = &x.el[0];
        int changed = 0;
        if (top && !strcmp(root->name, "adaptive-icon")) {
            info->icon_adaptive = 1;
            for (size_t i = 1; i < x.nel; i++) {
                const gxa_elem *e = &x.el[i];
                if (e->depth != 1) continue;
                int fg = !strcmp(e->name, "foreground"), bg = !strcmp(e->name, "background");
                if (!fg && !bg) continue;
                const gxa_attr *at = gxa_find_attr(e, "drawable", 0x01010199);
                gx_icon_layer *dst = fg ? &info->icon_fg : &info->icon_bg;
                if (!at) {
                    // вложенный элемент (<inset>, <bitmap>) — берём первый атрибут drawable/src у потомка
                    for (size_t j = i + 1; j < x.nel && x.el[j].depth > 1; j++) {
                        at = gxa_find_attr(&x.el[j], "drawable", 0x01010199);
                        if (!at) at = gxa_find_attr(&x.el[j], "src", 0x01010119);
                        if (at) break;
                    }
                }
                if (!at) continue;
                gxa_value v;
                memset(&v, 0, sizeof v);
                if (at->type == GXA_T_REF && pick_value(c->a, at->data, &v, 0)) set_layer(dst, &v);
                else if (at->type >= GXA_T_COLOR_ARGB8 && at->type <= GXA_T_COLOR_RGB4) { dst->is_color = 1; dst->color = at->data; }
                resolve_xml_drawable(c, dst, info, 0);
            }
            gxa_xml_free(&x);
            return;
        }
        if (!strcmp(root->name, "bitmap") || !strcmp(root->name, "inset") || !strcmp(root->name, "layer-list") ||
            !strcmp(root->name, "selector") || !strcmp(root->name, "item") || !strcmp(root->name, "nine-patch")) {
            for (size_t i = 0; i < x.nel && !changed; i++) {
                const gxa_attr *at = gxa_find_attr(&x.el[i], "src", 0x01010119);
                if (!at) at = gxa_find_attr(&x.el[i], "drawable", 0x01010199);
                gxa_value v;
                if (at && at->type == GXA_T_REF && pick_value(c->a, at->data, &v, 0)) { set_layer(layer, &v); changed = 1; }
            }
        }
        gxa_xml_free(&x);
        if (!changed) return;   // vector и прочее остаётся xml — его рисует UI
    }
}

static void heuristic_icon(gxz *z, gx_apk_info *info) {
    uint64_t best = 0;
    for (size_t i = 0; i < z->n; i++) {
        const char *n = z->e[i].name;
        if (strncmp(n, "res/mipmap", 10) && strncmp(n, "res/drawable", 12)) continue;
        if (!is_raster(n)) continue;
        const char *b = strrchr(n, '/');
        b = b ? b + 1 : n;
        if (strncmp(b, "ic_launcher", 11) && strncmp(b, "app_icon", 8) && strncmp(b, "icon", 4)) continue;
        if (strstr(b, "foreground") || strstr(b, "background")) continue;
        if (z->e[i].usize > best) { best = z->e[i].usize; snprintf(info->icon.path, sizeof info->icon.path, "%s", n); }
    }
}

int gx_apk_analyze(const char *path, uint64_t base, uint64_t size, gx_apk_info *info) {
    memset(info, 0, sizeof *info);
    gxz z;
    if (!gxz_open(&z, path, base, size)) { snprintf(info->error, sizeof info->error, "%s", z.err); return 0; }
    info->ok = 1;
    info->entries = z.n;
    long libunity = -1, libmain = -1;
    for (size_t i = 0; i < z.n; i++) {
        const gxz_entry *e = &z.e[i];
        const char *n = e->name;
        info->unpacked_bytes += e->usize;
        if (!strncmp(n, "classes", 7) && ends_with(n, ".dex") && !strchr(n, '/')) { info->dex_count++; info->dex_bytes += e->usize; }
        if (!strcmp(n, "assets/capacitor.config.json")) info->capacitor = 1;
        if (!strcmp(n, "assets/www/cordova.js") || !strcmp(n, "assets/www/cordova_plugins.js")) info->cordova = 1;
        if (!strncmp(n, "lib/", 4) && ends_with(n, ".so")) {
            const char *abi = n + 4;
            const char *sl = strchr(abi, '/');
            if (!sl) continue;
            size_t al = (size_t)(sl - abi);
            const char *file = sl + 1;
            if (strchr(file, '/')) continue;
            if (al == 9 && !strncmp(abi, "arm64-v8a", 9)) info->abi_arm64 = 1;
            else if (al == 11 && !strncmp(abi, "armeabi-v7a", 11)) info->abi_v7a = 1;
            else if (al == 7 && !strncmp(abi, "armeabi", 7)) info->abi_armeabi = 1;
            else if (al == 3 && !strncmp(abi, "x86", 3)) info->abi_x86 = 1;
            else if (al == 6 && !strncmp(abi, "x86_64", 6)) info->abi_x86_64 = 1;
            note_engine(info, file);
            info->libs = realloc(info->libs, sizeof(char *) * (size_t)(info->lib_count + 1));
            info->lib_sizes = realloc(info->lib_sizes, sizeof(uint64_t) * (size_t)(info->lib_count + 1));
            info->libs[info->lib_count] = strdup(abi);
            info->lib_sizes[info->lib_count] = e->usize;
            info->lib_count++;
            int arm64 = al == 9 && !strncmp(abi, "arm64-v8a", 9);
            if (arm64 && !strcmp(file, "libunity.so")) libunity = (long)i;
            if (arm64 && !strcmp(file, "libmain.so")) libmain = (long)i;
            if (libunity < 0 && !strcmp(file, "libunity.so")) libunity = (long)i;
            if (libmain < 0 && !strcmp(file, "libmain.so")) libmain = (long)i;
        }
    }
    // Unity 6 и «Unity как библиотека»
    if (libunity >= 0 && contains_in_entry(&z, &z.e[libunity], "UnityPlayerForActivityOrService", 160u << 20)) info->unity6 = 1;
    if (libmain >= 0 && (info->unity || info->il2cpp) && !contains_in_entry(&z, &z.e[libmain], "JNI_OnLoad", 32u << 20)) info->unity_library = 1;

    // Манифест
    long mi = gxz_find(&z, "AndroidManifest.xml");
    gxa_arsc *arsc = NULL;
    long ri = gxz_find(&z, "resources.arsc");
    if (ri >= 0) {
        uint8_t *d; size_t n;
        if (gxz_read(&z, &z.e[ri], 256u << 20, &d, &n)) { arsc = gxa_arsc_parse(d, n); free(d); }
    }
    if (mi >= 0) {
        uint8_t *d; size_t n;
        if (gxz_read(&z, &z.e[mi], 16u << 20, &d, &n)) {
            gxa_xml x;
            if (gxa_xml_parse(&x, d, n)) {
                info->has_manifest = 1;
                if (memmem(d, n, "android.app.NativeActivity", 26)) info->native_activity = 1;
                else {
                    // UTF-16 вариант
                    const char *s = "android.app.NativeActivity";
                    char w[52];
                    for (int k = 0; k < 26; k++) { w[2 * k] = s[k]; w[2 * k + 1] = 0; }
                    if (memmem(d, n, w, 52)) info->native_activity = 1;
                }
                ctx_t c = {&z, arsc};
                int in_main = 0;
                char cur_activity[256] = "";
                for (size_t i = 0; i < x.nel; i++) {
                    const gxa_elem *e = &x.el[i];
                    if (!strcmp(e->name, "manifest")) {
                        const gxa_attr *a = gxa_find_attr(e, "package", 0);
                        if (a && a->str) snprintf(info->package, sizeof info->package, "%s", a->str);
                        a = gxa_find_attr(e, "versionName", 0x0101021c);
                        if (a) {
                            if (a->str) snprintf(info->version_name, sizeof info->version_name, "%s", a->str);
                            else if (a->type == GXA_T_REF) { gxa_value v; if (pick_value(arsc, a->data, &v, 0) && v.str) snprintf(info->version_name, sizeof info->version_name, "%s", v.str); }
                        }
                        a = gxa_find_attr(e, "versionCode", 0x0101021b);
                        if (a) info->version_code = (int)a->data;
                        a = gxa_find_attr(e, "split", 0);
                        if (a && a->str) { info->is_split = 1; snprintf(info->split_name, sizeof info->split_name, "%s", a->str); }
                    } else if (!strcmp(e->name, "uses-sdk")) {
                        const gxa_attr *a = gxa_find_attr(e, "minSdkVersion", 0x0101020c);
                        if (a) info->min_sdk = a->str && a->type == GXA_T_STRING ? atoi(a->str) : (int)a->data;
                        a = gxa_find_attr(e, "targetSdkVersion", 0x01010270);
                        if (a) info->target_sdk = a->str && a->type == GXA_T_STRING ? atoi(a->str) : (int)a->data;
                    } else if (!strcmp(e->name, "uses-permission") || !strcmp(e->name, "uses-permission-sdk-23")) {
                        const gxa_attr *a = gxa_find_attr(e, "name", 0x01010003);
                        if (a && a->str) add_str(&info->perms, &info->nperm, a->str);
                    } else if (!strcmp(e->name, "application")) {
                        const gxa_attr *a = gxa_find_attr(e, "label", 0x01010001);
                        if (a) {
                            if (a->type == GXA_T_STRING && a->str) snprintf(info->label, sizeof info->label, "%s", a->str);
                            else if (a->type == GXA_T_REF && arsc) {
                                gxa_value vals[128];
                                int nv = gxa_arsc_values(arsc, a->data, vals, 128);
                                const char *def = NULL, *ru = NULL, *any = NULL;
                                for (int k = 0; k < nv; k++) {
                                    if (vals[k].type != GXA_T_STRING || !vals[k].str) continue;
                                    if (!vals[k].lang[0] && !def) def = vals[k].str;
                                    if (!strcmp(vals[k].lang, "ru") && !ru) ru = vals[k].str;
                                    if (!any) any = vals[k].str;
                                }
                                const char *pick = ru ? ru : def ? def : any;
                                if (pick) snprintf(info->label, sizeof info->label, "%s", pick);
                            }
                        }
                        const gxa_attr *ic = gxa_find_attr(e, "icon", 0x01010002);
                        const gxa_attr *ric = gxa_find_attr(e, "roundIcon", 0x0101052c);
                        gxa_value v;
                        if (ic && ic->type == GXA_T_REF && pick_value(arsc, ic->data, &v, 0)) set_layer(&info->icon, &v);
                        else if (ric && ric->type == GXA_T_REF && pick_value(arsc, ric->data, &v, 0)) set_layer(&info->icon, &v);
                        resolve_xml_drawable(&c, &info->icon, info, 1);
                        // adaptive без растрового слоя — попробуем roundIcon
                        if (info->icon_adaptive && !info->icon_fg.path[0] && ric && ric->type == GXA_T_REF && pick_value(arsc, ric->data, &v, 0) && is_raster(v.str ? v.str : "")) {
                            info->icon_adaptive = 0;
                            set_layer(&info->icon, &v);
                        }
                    } else if (!strcmp(e->name, "activity") || !strcmp(e->name, "activity-alias")) {
                        const gxa_attr *a = gxa_find_attr(e, "name", 0x01010003);
                        snprintf(cur_activity, sizeof cur_activity, "%s", a && a->str ? a->str : "");
                        in_main = 0;
                    } else if (!strcmp(e->name, "action")) {
                        const gxa_attr *a = gxa_find_attr(e, "name", 0x01010003);
                        if (a && a->str && !strcmp(a->str, "android.intent.action.MAIN")) in_main = 1;
                    } else if (!strcmp(e->name, "category")) {
                        const gxa_attr *a = gxa_find_attr(e, "name", 0x01010003);
                        if (in_main && a && a->str && !strcmp(a->str, "android.intent.category.LAUNCHER") && !info->main_activity[0])
                            snprintf(info->main_activity, sizeof info->main_activity, "%s", cur_activity);
                    }
                }
                gxa_xml_free(&x);
            }
            free(d);
        }
    }
    if (!info->icon_adaptive && !info->icon.path[0] && !info->icon.is_color) heuristic_icon(&z, info);
    gxa_arsc_free(arsc);
    gxz_close(&z);
    return 1;
}

void gx_apk_merge_split(gx_apk_info *b, const gx_apk_info *s) {
    b->abi_arm64 |= s->abi_arm64; b->abi_v7a |= s->abi_v7a; b->abi_armeabi |= s->abi_armeabi;
    b->abi_x86 |= s->abi_x86; b->abi_x86_64 |= s->abi_x86_64;
    b->dex_count += s->dex_count; b->dex_bytes += s->dex_bytes;
#define M(f) b->f |= s->f;
    M(il2cpp) M(unity) M(mono_unity) M(flutter) M(react) M(dotnet) M(godot) M(unreal) M(cocos) M(gdx) M(minecraft) M(sdl) M(sdl2)
    M(mainlib) M(rockstar_game) M(openal) M(mpg123) M(cordova) M(capacitor) M(gamemaker) M(python) M(supercell) M(unity6) M(fmod) M(dxvk)
#undef M
    if (s->unity_library) b->unity_library = 1;
    for (int i = 0; i < s->lib_count; i++) {
        b->libs = realloc(b->libs, sizeof(char *) * (size_t)(b->lib_count + 1));
        b->lib_sizes = realloc(b->lib_sizes, sizeof(uint64_t) * (size_t)(b->lib_count + 1));
        b->libs[b->lib_count] = strdup(s->libs[i]);
        b->lib_sizes[b->lib_count] = s->lib_sizes[i];
        b->lib_count++;
    }
}

void gx_apk_free(gx_apk_info *info) {
    for (int i = 0; i < info->lib_count; i++) free(info->libs[i]);
    free(info->libs); free(info->lib_sizes);
    for (int i = 0; i < info->nperm; i++) free(info->perms[i]);
    free(info->perms);
    info->libs = NULL; info->perms = NULL; info->lib_sizes = NULL;
    info->lib_count = info->nperm = 0;
}

char *gx_apk_xml_text(const char *path, uint64_t base, uint64_t size, const char *entry) {
    gxz z;
    if (!gxz_open(&z, path, base, size)) return NULL;
    char *out = NULL;
    gxa_arsc *arsc = NULL;
    long ri = gxz_find(&z, "resources.arsc");
    if (ri >= 0) { uint8_t *d; size_t n; if (gxz_read(&z, &z.e[ri], 256u << 20, &d, &n)) { arsc = gxa_arsc_parse(d, n); free(d); } }
    long mi = gxz_find(&z, entry);
    if (mi >= 0) {
        uint8_t *d; size_t n;
        if (gxz_read(&z, &z.e[mi], 32u << 20, &d, &n)) {
            gxa_xml x;
            if (gxa_xml_parse(&x, d, n)) { out = gxa_xml_to_text(&x, arsc); gxa_xml_free(&x); }
            free(d);
        }
    }
    gxa_arsc_free(arsc);
    gxz_close(&z);
    return out;
}

char *gx_apk_manifest_text(const char *path, uint64_t base, uint64_t size) {
    return gx_apk_xml_text(path, base, size, "AndroidManifest.xml");
}
