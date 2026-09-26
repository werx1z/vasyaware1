// main.mm — Vasyaware main
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <UIKit/UIKit.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import "substrate.h"

extern BOOL menuVisible;
extern BOOL silentAimEnabled;
extern BOOL kickBypassEnabled;
extern BOOL hitMarkerEnabled;
extern BOOL hitSoundsEnabled;
extern BOOL hitMarkerActive;
extern float hitMarkerTimer;
extern BOOL bhopEnabled;
extern BOOL speedHackEnabled;
extern BOOL fogEnabled;
extern float speedMultiplier;
extern float fogDensity;

void SetupImGui(void);
void RenderMenu(void);
void SetupMenuGesture(void);

// RVA
#define RVA_START_SHOOT         0x3d89c6c
#define RVA_MOVE                0x3d854b0
#define RVA_CAN_JUMP            0x3d89c34
#define RVA_CHEATER             0x3d8c534
#define RVA_APPLY_DAMAGE        0x3d86618
#define RVA_JUMP                0x3d8a73c
#define RVA_IS_GROUNDED         0x3d89c50
#define RVA_PUSH_BULLET         0x3d77000
#define RVA_SET_GUN_TARGET      0x3d8984c
#define RVA_DAMAGE_RPC          0x3d86f64
#define RVA_GET_FOG             0x695c77c
#define RVA_SET_FOG             0x695c7bc
#define RVA_GET_FOG_DENSITY     0x695ca38
#define RVA_SET_FOG_DENSITY     0x695ca78
#define RVA_GET_FOG_COLOR       0x695c8dc
#define RVA_SET_FOG_COLOR       0x695c980

uintptr_t unityFramework = 0;

uintptr_t GetUnityFramework() {
    for (int i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (strstr(name, "UnityFramework")) {
            return (uintptr_t)_dyld_get_image_header(i);
        }
    }
    return 0;
}

// Хук на glDrawArrays
static int drawCounter = 0;
static void (*orig_glDrawArrays)(GLenum, GLint, GLsizei);
static void hooked_glDrawArrays(GLenum mode, GLint first, GLsizei count) {
    orig_glDrawArrays(mode, first, count);
    drawCounter++;

    static BOOL ready = NO;
    if (!ready) {
        SetupImGui();
        ready = YES;
    }

    if (drawCounter % 200 == 0) {
        RenderMenu();
    }
}

// Хук на DamageRPC (Hit Marker)
static void (*orig_DamageRPC)(void*, float, int);
static void hooked_DamageRPC(void* self, float dmg, int fromWhom) {
    if (dmg > 0 && hitMarkerEnabled) {
        hitMarkerActive = YES;
        hitMarkerTimer = 0.3f;
    }
    orig_DamageRPC(self, dmg, fromWhom);
}

// Хук на CanJump (Bhop)
static bool (*orig_CanJump)(void*);
static bool hooked_CanJump(void* self) {
    if (bhopEnabled) return true;
    return orig_CanJump(self);
}

// Хук на Cheater (Kick Bypass)
static bool (*orig_Cheater)(void*);
static bool hooked_Cheater(void* self) {
    if (kickBypassEnabled) return false;
    return orig_Cheater(self);
}

// Хук на Move (Speed Hack)
static void (*orig_Move)(void*);
static void hooked_Move(void* self) {
    orig_Move(self);
}

// Хук на туман
static bool (*orig_GetFog)(void);
static bool hooked_GetFog(void) {
    if (fogEnabled) return true;
    return orig_GetFog();
}
static void (*orig_SetFog)(bool);
static void hooked_SetFog(bool value) {
    if (fogEnabled) value = true;
    orig_SetFog(value);
}
static float (*orig_GetFogDensity)(void);
static float hooked_GetFogDensity(void) {
    if (fogEnabled) return fogDensity;
    return orig_GetFogDensity();
}
static void (*orig_SetFogDensity)(float);
static void hooked_SetFogDensity(float value) {
    if (fogEnabled) value = fogDensity;
    orig_SetFogDensity(value);
}

void SetupHooks() {
    unityFramework = GetUnityFramework();
    if (!unityFramework) return;

    MSHookFunction((void*)(unityFramework + RVA_DAMAGE_RPC), (void*)hooked_DamageRPC, (void**)&orig_DamageRPC);
    MSHookFunction((void*)(unityFramework + RVA_CAN_JUMP), (void*)hooked_CanJump, (void**)&orig_CanJump);
    MSHookFunction((void*)(unityFramework + RVA_CHEATER), (void*)hooked_Cheater, (void**)&orig_Cheater);
    MSHookFunction((void*)(unityFramework + RVA_MOVE), (void*)hooked_Move, (void**)&orig_Move);
    MSHookFunction((void*)(unityFramework + RVA_GET_FOG), (void*)hooked_GetFog, (void**)&orig_GetFog);
    MSHookFunction((void*)(unityFramework + RVA_SET_FOG), (void*)hooked_SetFog, (void**)&orig_SetFog);
    MSHookFunction((void*)(unityFramework + RVA_GET_FOG_DENSITY), (void*)hooked_GetFogDensity, (void**)&orig_GetFogDensity);
    MSHookFunction((void*)(unityFramework + RVA_SET_FOG_DENSITY), (void*)hooked_SetFogDensity, (void**)&orig_SetFogDensity);
}

__attribute__((constructor)) static void init() {
    @autoreleasepool {
        NSLog(@"[VASYWARE] Loading...");
        [NSThread sleepForTimeInterval:3.0];

        MSHookFunction((void*)glDrawArrays, (void*)hooked_glDrawArrays, (void**)&orig_glDrawArrays);
        SetupHooks();

        dispatch_async(dispatch_get_main_queue(), ^{
            SetupMenuGesture();
        });

        NSLog(@"[VASYWARE] Loaded!");
    }
}
