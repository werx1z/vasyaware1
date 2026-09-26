#ifndef SUBSTRATE_H_
#define SUBSTRATE_H_

#include <objc/objc.h>
#include <objc/runtime.h>

#ifdef __cplusplus
extern "C" {
#endif

extern void MSHookMessageEx(Class class_, SEL message, IMP hook, IMP *old);
extern void MSHookFunction(void *symbol, void *hook, void **old);
extern void MSHookRelease(void *hook);
extern IMP MSGetMessageIMP(Class class_, SEL message);

#ifdef __cplusplus
}
#endif

#endif
