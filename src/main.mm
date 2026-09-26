// main.mm — Проверка старых RVA на ChickenGun
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <UIKit/UIKit.h>
#import "substrate.h"

// =================================================================
// ЛОГИ
// =================================================================

void WriteLog(NSString *message) {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *logPath = [docPath stringByAppendingPathComponent:@"vasyaware_log.txt"];
    
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    NSString *logEntry = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];
    
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (fileHandle) {
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[logEntry dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    } else {
        [logEntry writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSLog(@"[VASYWARE] %@", message);
}

// =================================================================
// ПОИСК CHICKENGUN
// =================================================================

uintptr_t chickenGun = 0;

uintptr_t WaitForChickenGun() {
    WriteLog(@"Waiting for ChickenGun...");
    for (int attempt = 0; attempt < 600; attempt++) {
        for (int i = 0; i < _dyld_image_count(); i++) {
            const char *name = _dyld_get_image_name(i);
            if (!name) continue;
            if (strstr(name, "ChickenGun") && !strstr(name, ".dylib")) {
                WriteLog([NSString stringWithFormat:@"Found ChickenGun: %s", name]);
                return (uintptr_t)_dyld_get_image_header(i);
            }
        }
        usleep(100000);
    }
    WriteLog(@"ChickenGun NOT found!");
    return 0;
}

// =================================================================
// RVA ИЗ ДАМПА UNITYFRAMEWORK
// =================================================================

#define RVA_DAMAGE_RPC          0x3d86f64
#define RVA_CAN_JUMP            0x3d89c34
#define RVA_CHEATER             0x3d8c534
#define RVA_MOVE                0x3d854b0

// =================================================================
// ХУКИ (только для проверки)
// =================================================================

static void (*orig_DamageRPC)(void*, float, int);
static void hooked_DamageRPC(void* self, float dmg, int fromWhom) {
    WriteLog(@"DamageRPC called!");
    orig_DamageRPC(self, dmg, fromWhom);
}

static bool (*orig_CanJump)(void*);
static bool hooked_CanJump(void* self) {
    WriteLog(@"CanJump called!");
    return orig_CanJump(self);
}

static bool (*orig_Cheater)(void*);
static bool hooked_Cheater(void* self) {
    WriteLog(@"Cheater called!");
    return orig_Cheater(self);
}

static void (*orig_Move)(void*);
static void hooked_Move(void* self) {
    orig_Move(self);
}

// =================================================================
// УСТАНОВКА ХУКОВ
// =================================================================

void SetupHooks() {
    chickenGun = WaitForChickenGun();
    if (!chickenGun) {
        WriteLog(@"Cannot setup hooks - no ChickenGun");
        return;
    }
    WriteLog([NSString stringWithFormat:@"ChickenGun base: 0x%lx", chickenGun]);

    uintptr_t addr1 = chickenGun + RVA_DAMAGE_RPC;
    WriteLog([NSString stringWithFormat:@"DamageRPC addr: 0x%lx", addr1]);
    MSHookFunction((void*)addr1, (void*)hooked_DamageRPC, (void**)&orig_DamageRPC);
    WriteLog(@"Hook: DamageRPC installed");

    uintptr_t addr2 = chickenGun + RVA_CAN_JUMP;
    WriteLog([NSString stringWithFormat:@"CanJump addr: 0x%lx", addr2]);
    MSHookFunction((void*)addr2, (void*)hooked_CanJump, (void**)&orig_CanJump);
    WriteLog(@"Hook: CanJump installed");

    uintptr_t addr3 = chickenGun + RVA_CHEATER;
    WriteLog([NSString stringWithFormat:@"Cheater addr: 0x%lx", addr3]);
    MSHookFunction((void*)addr3, (void*)hooked_Cheater, (void**)&orig_Cheater);
    WriteLog(@"Hook: Cheater installed");

    uintptr_t addr4 = chickenGun + RVA_MOVE;
    WriteLog([NSString stringWithFormat:@"Move addr: 0x%lx", addr4]);
    MSHookFunction((void*)addr4, (void*)hooked_Move, (void**)&orig_Move);
    WriteLog(@"Hook: Move installed");
}

// =================================================================
// ТОЧКА ВХОДА
// =================================================================

__attribute__((constructor)) static void init() {
    @autoreleasepool {
        WriteLog(@"=== VASYWARE (RVA TEST) ===");
        [NSThread sleepForTimeInterval:3.0];
        SetupHooks();
        WriteLog(@"=== VASYWARE READY ===");
    }
}
