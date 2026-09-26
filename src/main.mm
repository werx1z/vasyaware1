// main.mm — Vasyaware с хуком на presentDrawable:
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import "substrate.h"

extern BOOL menuVisible;
extern BOOL bhopEnabled;
extern BOOL kickBypassEnabled;

void SetupImGui(void);
void RenderMenu(id<MTLCommandBuffer> commandBuffer, id<MTLRenderCommandEncoder> encoder);
void SetupMenuGesture(void);
void WriteLog(NSString *message);

// RVA из дампа UnityFramework
#define RVA_DAMAGE_RPC          0x3d86f64
#define RVA_CAN_JUMP            0x3d89c34
#define RVA_CHEATER             0x3d8c534
#define RVA_MOVE                0x3d854b0

uintptr_t unityFramework = 0;

// =================================================================
// ОЖИДАНИЕ UNITYFRAMEWORK
// =================================================================

uintptr_t WaitForUnityFramework() {
    WriteLog(@"Waiting for UnityFramework (max 60 seconds)...");
    for (int attempt = 0; attempt < 600; attempt++) {
        for (int i = 0; i < _dyld_image_count(); i++) {
            const char *name = _dyld_get_image_name(i);
            if (name && strstr(name, "UnityFramework")) {
                WriteLog([NSString stringWithFormat:@"Found UnityFramework on attempt %d (%.1f sec): %s",
                          attempt, (float)attempt / 10.0f, name]);
                return (uintptr_t)_dyld_get_image_header(i);
            }
        }
        if (attempt % 50 == 0 && attempt > 0) {
            WriteLog([NSString stringWithFormat:@"Still waiting... (%.0f sec)", (float)attempt / 10.0f]);
        }
        usleep(100000);
    }
    WriteLog(@"UnityFramework NOT found after 60 seconds!");
    return 0;
}

// =================================================================
// ХУК НА presentDrawable:
// =================================================================

typedef void (*PresentDrawableFunc)(id, SEL, id<CAMetalDrawable>);
static PresentDrawableFunc orig_presentDrawable = NULL;

static void hooked_presentDrawable(id self, SEL _cmd, id<CAMetalDrawable> drawable) {
    static BOOL imguiReady = NO;
    if (!imguiReady) {
        WriteLog(@"First presentDrawable - initializing ImGui");
        SetupImGui();
        imguiReady = YES;
    }
    
    if (menuVisible) {
        id<MTLCommandBuffer> commandBuffer = (id<MTLCommandBuffer>)self;
        
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        
        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
        RenderMenu(commandBuffer, encoder);
        [encoder endEncoding];
    }
    
    if (orig_presentDrawable) {
        orig_presentDrawable(self, _cmd, drawable);
    }
}

void SetupMetalHook() {
    Class cmdBufferClass = objc_getClass("MTLCommandBuffer");
    if (!cmdBufferClass) {
        WriteLog(@"MTLCommandBuffer class NOT found!");
        return;
    }
    
    const char* classes[] = {
        "AGXCommandBuffer",
        "AGXG13XFamilyCommandBuffer",
        "AGXG14XFamilyCommandBuffer",
        "AGXG15XFamilyCommandBuffer",
        "MTLCommandBuffer",
        "MTLDebugCommandBuffer"
    };
    
    SEL selector = NSSelectorFromString(@"presentDrawable:");
    
    for (int i = 0; i < 6; i++) {
        Class cls = objc_getClass(classes[i]);
        if (!cls) continue;
        
        Method method = class_getInstanceMethod(cls, selector);
        if (method) {
            IMP imp = method_getImplementation(method);
            orig_presentDrawable = (PresentDrawableFunc)imp;
            method_setImplementation(method, (IMP)hooked_presentDrawable);
            WriteLog([NSString stringWithFormat:@"Metal hook installed on %s", classes[i]]);
            return;
        }
    }
    WriteLog(@"Metal hook NOT installed");
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
    unityFramework = WaitForUnityFramework();
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
// ТОЧКА ВХОДА
// =================================================================

__attribute__((constructor)) static void init() {
    @autoreleasepool {
        WriteLog(@"=== VASYWARE LOADING ===");
        [NSThread sleepForTimeInterval:3.0];

        WriteLog(@"--- Loaded modules ---");
        for (int i = 0; i < _dyld_image_count(); i++) {
            const char *name = _dyld_get_image_name(i);
            if (name && (strstr(name, "Chicken") || strstr(name, "Unity"))) {
                WriteLog([NSString stringWithFormat:@"Module: %s", name]);
            }
        }
        WriteLog(@"--- End modules ---");

        SetupMetalHook();
        SetupHooks();

        dispatch_async(dispatch_get_main_queue(), ^{
            SetupMenuGesture();
        });

        WriteLog(@"=== VASYWARE LOADED ===");
    }
}
