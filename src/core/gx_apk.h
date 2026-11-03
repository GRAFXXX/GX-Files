// Анализ APK: манифест, иконка, ABI, игровой движок.
#pragma once
#include <stdint.h>
#include "gx_zip.h"
#include "gx_android.h"

typedef struct {
    // слой иконки: путь внутри APK (растр или xml) либо цвет
    char path[512];
    uint32_t color;
    int is_color;
} gx_icon_layer;

typedef struct {
    int ok;
    char error[160];
    int has_manifest;
    char package[256];
    char version_name[128];
    int version_code;
    int min_sdk, target_sdk;
    char label[256];
    char main_activity[256];
    char split_name[128];          // для split APK
    int is_split;

    // иконка
    int icon_adaptive;
    gx_icon_layer icon;            // растр или xml (если не adaptive)
    gx_icon_layer icon_bg, icon_fg;

    // код
    int abi_arm64, abi_v7a, abi_armeabi, abi_x86, abi_x86_64;
    int dex_count;
    uint64_t dex_bytes;
    int lib_count;
    char **libs;                   // "abi/libname.so"
    uint64_t *lib_sizes;
    char **perms;
    int nperm;
    uint64_t entries, unpacked_bytes;

    // признаки движков
    int il2cpp, unity, mono_unity, flutter, react, dotnet, godot, unreal, cocos, gdx, minecraft, sdl, sdl2, mainlib,
        rockstar_game, openal, mpg123, cordova, capacitor, gamemaker, python, supercell, unity_library, unity6, fmod, dxvk,
        native_activity;
    int has_obb_hint;
} gx_apk_info;

// path — файл, base/size — окно (для APK внутри XAPK). Возвращает 1, если файл прочитан как zip.
int gx_apk_analyze(const char *path, uint64_t base, uint64_t size, gx_apk_info *info);
// Дополнить базовый APK сведениями из split'а (библиотеки/ABI/движок)
void gx_apk_merge_split(gx_apk_info *base, const gx_apk_info *split);
void gx_apk_free(gx_apk_info *info);

const char *gx_apk_engine(const gx_apk_info *i);   // NULL если не распознан
// Тип рантайма: "unity", "java", "cocos", "minecraft", "sdl", "ue4", "gta", "godot", "nativeactivity", "gamemaker", "web" или NULL
const char *gx_apk_route(const gx_apk_info *i);
int gx_apk_any_native(const gx_apk_info *i);

// Читает AndroidManifest.xml как текст (malloc) — для просмотра
char *gx_apk_manifest_text(const char *path, uint64_t base, uint64_t size);
// Бинарный XML внутри APK → текст с разворачиванием ресурсов (malloc)
char *gx_apk_xml_text(const char *path, uint64_t base, uint64_t size, const char *entry);
