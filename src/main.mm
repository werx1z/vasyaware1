// main.mm — Vasyaware main с CAMetalLayer
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
// METAL СЛОЙ (свой, не трогаем Unity)
// =================================================================

id<MTLDevice> g_device = nil;
id<MTLCommandQueue> g_commandQueue = nil;
CAMetalLayer* g_metalLayer = nil;
UIView* g_metalView = nil;

void SetupMetalLayer() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow* window = [UIApplication sharedApplication].keyWindow;
        if (!window) window = [[UIApplication sharedApplication].windows firstObject];
        if (!window) {
            WriteLog(@"No window for Metal layer!");
            return;
        }

        g_device = MTLCreateSystemDefaultDevice();
        if (!g_device) {
            WriteLog(@"Metal device NOT created!");
            return;
        }
        g_commandQueue = [g_device newCommandQueue];

        // Создаём свой Metal-слой
        g_metalLayer = [CAMetalLayer layer];
        g_metalLayer.device = g_device;
        g_metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        g_metalLayer.framebufferOnly = NO;
        g_metalLayer.frame = window.bounds;

        g_metalView = [[UIView alloc] initWithFrame:window.bounds];
        g_metalView.backgroundColor = [UIColor clearColor];
        g_metalView.userInteractionEnabled = NO;
        g_metalView.opaque = NO;
        [g_metalView.layer addSublayer:g_metalLayer];
        [window addSubview:g_metalView];
        [window bringSubviewToFront:g_metalView];

        WriteLog(@"Metal layer created!");

        // Запускаем цикл отрисовки
        [NSTimer scheduledTimerWithTimeInterval:1.0/60.0 repeats:YES block:^(NSTimer *timer) {
            RenderImGuiFrame();
        }];
    });
}

void RenderImGuiFrame() {
    if (!g_metalLayer || !g_commandQueue || !g_device) return;

    @autoreleasepool {
        // Получаем drawable
        id<CAMetalDrawable> drawable = [g_metalLayer nextDrawable];
        if (!drawable) return;

        // Создаём command buffer
        id<MTLCommandBuffer> commandBuffer = [g_commandQueue commandBuffer];

        // Render pass descriptor
        MTLRenderPassDescriptor* passDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        passDescriptor.colorAttachments[0].texture = drawable.texture;
        passDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);

        // Encoder
        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];

        // Рисуем ImGui
        RenderMenu(commandBuffer, encoder);

        [encoder endEncoding];
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
    }
}

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

        // Логируем модули
        WriteLog(@"--- Loaded modules ---");
        for (int i = 0; i < _dyld_image_count(); i++) {
            const char *name = _dyld_get_image_name(i);
            if (name && (strstr(name, "Chicken") || strstr(name, "Unity"))) {
                WriteLog([NSString stringWithFormat:@"Module: %s", name]);
            }
        }
        WriteLog(@"--- End modules ---");

        // Создаём Metal-слой (свой)
        SetupMetalLayer();

        // Ждём UnityFramework и ставим хуки
        SetupHooks();

        // Жест
        dispatch_async(dispatch_get_main_queue(), ^{
            SetupMenuGesture();
        });

        WriteLog(@"=== VASYWARE LOADED ===");
    }
}
