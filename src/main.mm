// main.mm — Vasyaware main с логами
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <UIKit/UIKit.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import "substrate.h"

extern BOOL menuVisible;
extern BOOL bhopEnabled;
extern BOOL kickBypassEnabled;
void SetupImGui(void);
void RenderMenu(void);
void SetupMenuGesture(void);
void WriteLog(NSString *message);

// RVA
#define RVA_DAMAGE_RPC          0x3d86f64
#define RVA_CAN_JUMP            0x3d89c34
#define RVA_CHEATER             0x3d8c534
#define RVA_MOVE                0x3d854b0

uintptr_t unityFramework = 0;

uintptr_t GetUnityFramework() {
    for (int i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (strstr(name, "UnityFramework")) {
            WriteLog([NSString stringWithFormat:@"Found UnityFramework: %s", name]);
            return (uintptr_t)_dyld_get_image_header(i);
        }
    }
    WriteLog(@"UnityFramework NOT found!");
    return 0;
}

// Хук на glDrawArrays
static int drawCounter = 0;
static void (*orig_glDrawArrays)(GLenum, GLint, GLsizei);
static void hooked_glDrawArrays(GLenum mode, GLint first, GLsizei count) {
    orig_glDrawArrays(mode, first, count);
    drawCounter++;

    static BOOL firstDraw = NO;
    if (!firstDraw) {
        WriteLog(@"First glDrawArrays call - initializing ImGui");
        SetupImGui();
        firstDraw = YES;
    }

    if (drawCounter % 200 == 0) {
        RenderMenu();
    }
}

// Хуки
static void (*orig_DamageRPC)(void*, float, int);
static void hooked_DamageRPC(void* self, float dmg, int fromWhom) {
    orig_DamageRPC(self, dmg, fromWhom);
}

static bool (*orig_CanJump)(void*);
static bool hooked_CanJump(void* self) {
    if (bhopEnabled) return true;
    return orig_CanJump(self);
}

static bool (*orig_Cheater)(void*);
static bool hooked_Cheater(void* self) {
    if (kickBypassEnabled) return false;
    return orig_Cheater(self);
}

static void (*orig_Move)(void*);
static void hooked_Move(void* self) {
    orig_Move(self);
}

void SetupHooks() {
    unityFramework = GetUnityFramework();
    if (!unityFramework) {
        WriteLog(@"Cannot setup hooks - no UnityFramework");
        return;
    }

    WriteLog([NSString stringWithFormat:@"UnityFramework base: 0x%lx", unityFramework]);

    MSHookFunction((void*)(unityFramework + RVA_DAMAGE_RPC), (void*)hooked_DamageRPC, (void**)&orig_DamageRPC);
    WriteLog(@"Hook: DamageRPC installed");

    MSHookFunction((void*)(unityFramework + RVA_CAN_JUMP), (void*)hooked_CanJump, (void**)&orig_CanJump);
    WriteLog(@"Hook: CanJump installed");

    MSHookFunction((void*)(unityFramework + RVA_CHEATER), (void*)hooked_Cheater, (void**)&orig_Cheater);
    WriteLog(@"Hook: Cheater installed");

    MSHookFunction((void*)(unityFramework + RVA_MOVE), (void*)hooked_Move, (void**)&orig_Move);
    WriteLog(@"Hook: Move installed");
}

__attribute__((constructor)) static void init() {
    @autoreleasepool {
        WriteLog(@"=== VASYWARE LOADING ===");
        [NSThread sleepForTimeInterval:3.0];

        MSHookFunction((void*)glDrawArrays, (void*)hooked_glDrawArrays, (void**)&orig_glDrawArrays);
        WriteLog(@"Hook: glDrawArrays installed");

        SetupHooks();

        dispatch_async(dispatch_get_main_queue(), ^{
            SetupMenuGesture();
        });

        WriteLog(@"=== VASYWARE LOADED ===");
    }
}
