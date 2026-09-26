// main.mm — v4 с логированием OpenGL-функций
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <UIKit/UIKit.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import "substrate.h"

void WriteLog(NSString *message);

// =================================================================
// ХУКИ НА OPENGL ФУНКЦИИ
// =================================================================

static int glDrawArraysCount = 0;
static void (*orig_glDrawArrays)(GLenum, GLint, GLsizei);
static void hooked_glDrawArrays(GLenum mode, GLint first, GLsizei count) {
    glDrawArraysCount++;
    if (glDrawArraysCount % 100 == 0) {
        WriteLog([NSString stringWithFormat:@"glDrawArrays called %d times", glDrawArraysCount]);
    }
    orig_glDrawArrays(mode, first, count);
}

static int glDrawElementsCount = 0;
static void (*orig_glDrawElements)(GLenum, GLsizei, GLenum, const void*);
static void hooked_glDrawElements(GLenum mode, GLsizei count, GLenum type, const void* indices) {
    glDrawElementsCount++;
    if (glDrawElementsCount % 100 == 0) {
        WriteLog([NSString stringWithFormat:@"glDrawElements called %d times", glDrawElementsCount]);
    }
    orig_glDrawElements(mode, count, type, indices);
}

static int glClearCount = 0;
static void (*orig_glClear)(GLbitfield);
static void hooked_glClear(GLbitfield mask) {
    glClearCount++;
    if (glClearCount % 100 == 0) {
        WriteLog([NSString stringWithFormat:@"glClear called %d times", glClearCount]);
    }
    orig_glClear(mask);
}

// =================================================================
// ТОЧКА ВХОДА
// =================================================================

__attribute__((constructor)) static void init() {
    @autoreleasepool {
        WriteLog(@"=== VASYWARE v4 + LOGS ===");
        [NSThread sleepForTimeInterval:3.0];

        // Логируем модули
        WriteLog(@"--- Loaded modules ---");
        for (int i = 0; i < _dyld_image_count(); i++) {
            const char *name = _dyld_get_image_name(i);
            if (name && (strstr(name, "Chicken") || strstr(name, "Unity") || strstr(name, "OpenGL"))) {
                WriteLog([NSString stringWithFormat:@"Module: %s", name]);
            }
        }
        WriteLog(@"--- End modules ---");

        // Ставим хуки на OpenGL
        MSHookFunction((void*)glDrawArrays, (void*)hooked_glDrawArrays, (void**)&orig_glDrawArrays);
        WriteLog(@"Hook: glDrawArrays installed");

        MSHookFunction((void*)glDrawElements, (void*)hooked_glDrawElements, (void**)&orig_glDrawElements);
        WriteLog(@"Hook: glDrawElements installed");

        MSHookFunction((void*)glClear, (void*)hooked_glClear, (void**)&orig_glClear);
        WriteLog(@"Hook: glClear installed");

        WriteLog(@"=== VASYWARE READY ===");
    }
}

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
