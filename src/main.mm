// main.mm — Vasyaware main с Metal-хуком
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import "substrate.h"

extern BOOL menuVisible;
extern BOOL bhopEnabled;
extern BOOL kickBypassEnabled;
void SetupImGui(void);
void RenderMenu(id<MTLRenderCommandEncoder> encoder);
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

// =================================================================
// ХУК НА METAL: drawPrimitives
// =================================================================

typedef void (*DrawPrimitivesFunc)(id, SEL, MTLPrimitiveType, NSInteger, NSInteger);
static DrawPrimitivesFunc orig_drawPrimitives = NULL;

static void hooked_drawPrimitives(id self, SEL _cmd, MTLPrimitiveType type, NSInteger vertexStart, NSInteger vertexCount) {
    if (orig_drawPrimitives) {
        orig_drawPrimitives(self, _cmd, type, vertexStart, vertexCount);
    }
    
    static int drawCount = 0;
    drawCount++;
    
    static BOOL imguiReady = NO;
    if (!imguiReady) {
        WriteLog(@"First Metal draw call - initializing ImGui");
        SetupImGui();
        imguiReady = YES;
    }
    
    if (drawCount % 100 == 0) {
        RenderMenu((id<MTLRenderCommandEncoder>)self);
    }
}

// =================================================================
// ХУКИ НА CharacterMotor
// =================================================================

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

// =================================================================
// УСТАНОВКА METAL-ХУКА
// =================================================================

void SetupMetalHook() {
    Class encoderClass = objc_getClass("MTLRenderCommandEncoder");
    if (!encoderClass) {
        WriteLog(@"MTLRenderCommandEncoder NOT found!");
        return;
    }
    
    SEL selector = NSSelectorFromString(@"drawPrimitives:vertexStart:vertexCount:");
    Method method = class_getInstanceMethod(encoderClass, selector);
    
    if (method) {
        IMP imp = method_getImplementation(method);
        orig_drawPrimitives = (DrawPrimitivesFunc)imp;
        method_setImplementation(method, (IMP)hooked_drawPrimitives);
        WriteLog(@"Metal hook installed: drawPrimitives");
    } else {
        WriteLog(@"drawPrimitives method NOT found!");
    }
}

__attribute__((constructor)) static void init() {
    @autoreleasepool {
        WriteLog(@"=== VASYWARE LOADING ===");
        [NSThread sleepForTimeInterval:3.0];

        SetupMetalHook();
        SetupHooks();

        dispatch_async(dispatch_get_main_queue(), ^{
            SetupMenuGesture();
        });

        WriteLog(@"=== VASYWARE LOADED ===");
    }
}
