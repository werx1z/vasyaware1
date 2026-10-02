#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#include "sounds.h"
#import <QuartzCore/QuartzCore.h>
static void Log(NSString* s);

// ===== Звуки + конфиг =====

// Sounds.h - хитсаунды (fatality / neverlose / skeet) и киллсаунд (odin), вшитые в dylib
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>


// ---------- конфиг ----------
// Хранится в NSMutableDictionary -> легко сохранять/загружать как JSON.
// Цвет: @[r,g,b,a] (0..1). Режим градиента: key.mode (0 solid, 1 gradient), цвета key.c1 / key.c2
@interface Cfg : NSObject
+ (NSMutableDictionary*)d;
+ (BOOL)b:(NSString*)k;
+ (float)f:(NSString*)k;
+ (int)i:(NSString*)k;
+ (void)set:(id)v for:(NSString*)k;
+ (NSArray<NSNumber*>*)rgba:(NSString*)k;      // для ESP-рендера
+ (NSString*)dir;
+ (NSArray<NSString*>*)list;
+ (BOOL)save:(NSString*)name;
+ (BOOL)load:(NSString*)name;
@end

@implementation Cfg
+ (NSMutableDictionary*)d { static NSMutableDictionary* x; static dispatch_once_t o; dispatch_once(&o, ^{ x = [NSMutableDictionary new]; }); return x; }
+ (BOOL)b:(NSString*)k { @synchronized(self.d) { return [[self d][k] boolValue]; } }
+ (float)f:(NSString*)k { @synchronized(self.d) { return [[self d][k] floatValue]; } }
+ (int)i:(NSString*)k { @synchronized(self.d) { return [[self d][k] intValue]; } }
+ (void)set:(id)v for:(NSString*)k { @synchronized(self.d) { self.d[k] = v; } }
+ (NSArray<NSNumber*>*)rgba:(NSString*)k { return [self d][k] ?: @[@1,@1,@1,@1]; }
+ (NSString*)dir {
    NSString* p = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"Configs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil];
    return p;
}
+ (NSArray<NSString*>*)list {
    NSMutableArray* r = [NSMutableArray new];
    for (NSString* f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[self dir] error:nil])
        if ([f.pathExtension isEqualToString:@"json"]) [r addObject:f.stringByDeletingPathExtension];
    return r;
}
+ (BOOL)save:(NSString*)name {
    NSData* j = [NSJSONSerialization dataWithJSONObject:[self d] options:NSJSONWritingPrettyPrinted error:nil];
    return j && [j writeToFile:[[self dir] stringByAppendingPathComponent:[name stringByAppendingString:@".json"]] atomically:YES];
}
+ (BOOL)load:(NSString*)name {
    NSData* j = [NSData dataWithContentsOfFile:[[self dir] stringByAppendingPathComponent:[name stringByAppendingString:@".json"]]];
    id o = j ? [NSJSONSerialization JSONObjectWithData:j options:0 error:nil] : nil;
    if (![o isKindOfClass:NSDictionary.class]) return NO;
    [[self d] addEntriesFromDictionary:o];
    return YES;
}
@end

// ---------- звуки ----------
namespace Snd {
inline NSArray<NSString*>* HitNames() { return @[@"Fatality", @"Neverlose", @"Skeet"]; }

inline AVAudioPlayer* Make(const unsigned char* d, size_t n) {
    NSData* data = [NSData dataWithBytes:d length:n];
    AVAudioPlayer* p = [[AVAudioPlayer alloc] initWithData:data error:nil];
    [p prepareToPlay];
    return p;
}
inline void Play(AVAudioPlayer* p, float vol) {
    if (!p) return;
    p.volume = vol;
    p.currentTime = 0;
    [p play];
}
inline void PlayHit(int idx) {
    static AVAudioPlayer* pl[3];
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        pl[0] = Make(snd_fatality, snd_fatality_len);
        pl[1] = Make(snd_neverlose, snd_neverlose_len);
        pl[2] = Make(snd_skeet, snd_skeet_len);
    });
    if (idx < 0 || idx > 2) idx = 0;
    Play(pl[idx], [Cfg f:@"snd.volume"]);
}
inline void PlayKill() {
    static AVAudioPlayer* p; static dispatch_once_t o;
    dispatch_once(&o, ^{ p = Make(snd_odin, snd_odin_len); });
    Play(p, [Cfg f:@"snd.volume"]);
}
// вызывать из хуков: Hit -> OnHit(), DieViaServer (когда убил ты) -> OnKill()
inline void OnHit()  { if ([Cfg b:@"hitsound"])  dispatch_async(dispatch_get_main_queue(), ^{ PlayHit([Cfg i:@"hitsound.idx"]); }); }
inline void OnKill() { if ([Cfg b:@"killsound"]) dispatch_async(dispatch_get_main_queue(), ^{ PlayKill(); }); }
}

// ===== Доступ к игре =====
// Оффсеты из дампа. (?) = догадка, проверить в игре.
#include <cstdint>
#include <cstring>
#include <vector>
#include <unordered_map>
#include <initializer_list>
#include <math.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>

struct Vec3 { float x, y, z; };
struct Col4 { float r, g, b, a; };

namespace OFF {
    // PlayerController
    constexpr uintptr_t PC_Team = 0x49, PC_Biped = 0x30, PC_Movement = 0x68, PC_Weaponry = 0x58,
        PC_PhotonPlayer = 0x120, PC_HpA = 0x118, PC_HpB = 0x11C;       // (?) какой из двух HP
    constexpr uintptr_t PMC_Camera = 0x18, PMC_Transform = 0x30, PMC_Player = 0x40;   // PlayerMainCamera
    constexpr uintptr_t RVA_PMC_GetInstance = 0x1AB1E48;                             // static
    constexpr uintptr_t PP_Nick = 0x18;                                              // PhotonPlayer.nameField
    constexpr uintptr_t WC_Current = 0x90;                                           // (?) WeaponryController -> текущее оружие
    constexpr uintptr_t RVA_WeaponId = 0x1918F58;                                    // (?) WeaponController.NGBBPDDCMAC -> DFBFMIHOHPG
    constexpr uintptr_t HC_Player = 0x78;                                            // HitController -> PlayerController (жертва)
    constexpr uintptr_t MC_Input = 0x70, MC_CharCtrl = 0x80;                         // MovementController
    constexpr uintptr_t PC_Aim = 0x50, AC_Fps = 0x70, AC_Cam = 0x80, AC_AimData = 0x90;   // PlayerController -> AimController: FPSCamera/camTransform/aimingData
    constexpr uintptr_t WPN_Owner = 0x18;                                            // WeaponController -> PlayerController
    constexpr uintptr_t MI_Move = 0x10, MI_Jump = 0x24;                              // (?) MLGFJPPLONI: вектор движения, флаг прыжка
    constexpr uintptr_t RVA_MC_Speed = 0x1AAA3DC;                                    // (?) MovementController.AJDCAMCKEMB(float)
}

namespace G {
inline uintptr_t base = 0;
inline bool inited = false;
inline char status[300] = "init";

inline void Init() {
    if (base) return;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char* n = _dyld_get_image_name(i);
        if (n && strstr(n, "UnityFramework")) { base = (uintptr_t)_dyld_get_image_header(i); break; }
    }
}
inline bool Valid(uintptr_t p) { return p > 0x100000000ULL && p < 0x1000000000ULL; }
// чтение через vm_read: висячий указатель не роняет игру
inline bool RdBytes(uintptr_t a, void* out, size_t n) {
    if (!Valid(a)) return false;
    vm_size_t sz = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)a, n, (vm_address_t)out, &sz) == KERN_SUCCESS && sz == n;
}
template <class T> inline T Rd(uintptr_t a) { T v{}; RdBytes(a, &v, sizeof(T)); return v; }
inline uintptr_t Ptr(uintptr_t a) { return Rd<uintptr_t>(a); }
template <class T> inline void Wr(uintptr_t a, T v) { if (Valid(a)) memcpy((void*)a, &v, sizeof(T)); }
inline NSString* Str(uintptr_t s) {          // il2cpp string: длина 0x10, символы 0x14
    if (!Valid(s)) return @"";
    int len = Rd<int>(s + 0x10); if (len <= 0 || len > 40) return @"";
    unichar b[48] = {0}; if (!RdBytes(s + 0x14, b, len * 2)) return @"";
    return [NSString stringWithCharacters:b length:len];
}

// ---- Unity icall'ы: пробуем несколько имён, т.к. зависят от версии Unity ----
using ResolveFn = void* (*)(const char*);
inline ResolveFn resolve = nullptr;
inline void* IC(std::initializer_list<const char*> l, const char** hit = nullptr) {
    for (auto n : l) { void* p = resolve(n); if (p) { if (hit) *hit = n; return p; } }
    return nullptr;
}
inline void (*i_posInj)(void*, Vec3*) = nullptr;
inline Vec3 (*i_posRet)(void*) = nullptr;
inline void (*i_w2sInj)(void*, Vec3*, int, Vec3*) = nullptr;
inline Vec3 (*i_w2sRet)(void*, Vec3, int) = nullptr;
inline int  (*i_sw)() = nullptr;
inline int  (*i_sh)() = nullptr;
inline void (*i_setAspect)(void*, float) = nullptr;
inline void (*i_resetAspect)(void*) = nullptr;
inline void (*i_setClear)(void*, int) = nullptr;
inline void (*i_setBg)(void*, Col4*) = nullptr;
inline void (*i_fog)(bool) = nullptr;
inline void (*i_fogCol)(Col4*) = nullptr;
inline void (*i_fogMode)(int) = nullptr;
inline void (*i_fogStart)(float) = nullptr;
inline void (*i_fogEnd)(float) = nullptr;
inline bool (*i_grounded)(void*) = nullptr;
inline void (*i_getRot)(void*, float*) = nullptr;   // Transform.rotation (x,y,z,w)
inline void (*i_setRot)(void*, float*) = nullptr;

inline void InitUnity() {
    if (inited) return;
    resolve = (ResolveFn)dlsym(RTLD_DEFAULT, "il2cpp_resolve_icall");
    if (!resolve) { snprintf(status, sizeof status, "il2cpp_resolve_icall not exported"); return; }
    const char *a = 0, *b = 0;
    i_posInj = (decltype(i_posInj))IC({"UnityEngine.Transform::get_position_Injected", "UnityEngine.Transform::INTERNAL_get_position"}, &a);
    if (!i_posInj) i_posRet = (decltype(i_posRet))IC({"UnityEngine.Transform::get_position"}, &a);
    i_w2sInj = (decltype(i_w2sInj))IC({"UnityEngine.Camera::WorldToScreenPoint_Injected", "UnityEngine.Camera::INTERNAL_CALL_WorldToScreenPoint"}, &b);
    if (!i_w2sInj) i_w2sRet = (decltype(i_w2sRet))IC({"UnityEngine.Camera::WorldToScreenPoint"}, &b);
    i_sw = (decltype(i_sw))IC({"UnityEngine.Screen::get_width"});
    i_sh = (decltype(i_sh))IC({"UnityEngine.Screen::get_height"});
    i_setAspect   = (decltype(i_setAspect))IC({"UnityEngine.Camera::set_aspect"});
    i_resetAspect = (decltype(i_resetAspect))IC({"UnityEngine.Camera::ResetAspect"});
    i_setClear    = (decltype(i_setClear))IC({"UnityEngine.Camera::set_clearFlags"});
    i_setBg       = (decltype(i_setBg))IC({"UnityEngine.Camera::set_backgroundColor_Injected", "UnityEngine.Camera::INTERNAL_set_backgroundColor"});
    i_fog         = (decltype(i_fog))IC({"UnityEngine.RenderSettings::set_fog"});
    i_fogCol      = (decltype(i_fogCol))IC({"UnityEngine.RenderSettings::set_fogColor_Injected", "UnityEngine.RenderSettings::INTERNAL_set_fogColor"});
    i_fogMode     = (decltype(i_fogMode))IC({"UnityEngine.RenderSettings::set_fogMode"});
    i_fogStart    = (decltype(i_fogStart))IC({"UnityEngine.RenderSettings::set_fogStartDistance"});
    i_fogEnd      = (decltype(i_fogEnd))IC({"UnityEngine.RenderSettings::set_fogEndDistance"});
    i_grounded    = (decltype(i_grounded))IC({"UnityEngine.CharacterController::get_isGrounded"});
    i_getRot = (decltype(i_getRot))IC({"UnityEngine.Transform::get_rotation_Injected", "UnityEngine.Transform::get_rotation_Injected(UnityEngine.Quaternion&)", "UnityEngine.Transform::INTERNAL_get_rotation"});
    i_setRot = (decltype(i_setRot))IC({"UnityEngine.Transform::set_rotation_Injected", "UnityEngine.Transform::set_rotation_Injected(UnityEngine.Quaternion&)", "UnityEngine.Transform::INTERNAL_set_rotation"});
    Log([NSString stringWithFormat:@"icall: rot get=%d set=%d", i_getRot != 0, i_setRot != 0]);
    Log([NSString stringWithFormat:@"icall: pos=%s w2s=%s screen=%d aspect=%d fog=%d sky=%d grounded=%d", a ? a : "NO", b ? b : "NO",
         i_sw && i_sh, i_setAspect != 0, i_fog && i_fogCol, i_setClear && i_setBg, i_grounded != 0]);
    if (!(i_posInj || i_posRet) || !(i_w2sInj || i_w2sRet) || !i_sw || !i_sh) {
        snprintf(status, sizeof status, "icall missing: pos=%s w2s=%s", a ? a : "NO", b ? b : "NO"); return;
    }
    snprintf(status, sizeof status, "OK pos=%s w2s=%s", a, b);
    inited = true;
}

inline bool Pos(uintptr_t t, Vec3& o) {
    if (!Valid(t)) return false;
    if (i_posInj) { i_posInj((void*)t, &o); return true; }
    if (i_posRet) { o = i_posRet((void*)t); return true; }
    return false;
}
// r.x/r.y в пикселях Unity (начало снизу), r.z > 0 = перед камерой
inline bool W2SRaw(uintptr_t cam, Vec3 w, Vec3& r) {
    if (!Valid(cam)) return false;
    if (i_w2sInj) { i_w2sInj((void*)cam, &w, 2 /*Mono*/, &r); return true; }
    if (i_w2sRet) { r = i_w2sRet((void*)cam, w, 2); return true; }
    return false;
}

// ---- локальный игрок и камера ----
// Последний тик PlayerController.Update (ставит хук). Нет свежих тиков = лобби/загрузка, мира ещё нет.
inline double lastPC = 0;
inline bool InMatch() { return CACurrentMediaTime() - lastPC < 1.0; }

// GetInstance - managed-метод: если инстанса нет, il2cpp кидает C++ исключение (NullReference).
// Раньше его никто не ловил -> terminate -> abort. Теперь: ловим и не дёргаем метод 1 секунду.
inline uintptr_t PMC() {
    if (!base) return 0;
    static double retryAt = 0;
    double now = CACurrentMediaTime();
    if (now < retryAt) return 0;
    using Fn = uintptr_t (*)();
    try {
        uintptr_t p = ((Fn)(base + OFF::RVA_PMC_GetInstance))();
        return Valid(p) ? p : 0;
    } catch (...) {
        retryAt = now + 1.0;
        return 0;
    }
}
inline uintptr_t LocalPlayer() { uintptr_t p = PMC(); return Valid(p) ? Ptr(p + OFF::PMC_Player) : 0; }
inline uintptr_t UnityCamera() { uintptr_t p = PMC(); return Valid(p) ? Ptr(p + OFF::PMC_Camera) : 0; }

inline uint8_t TeamOf(uintptr_t pc) { return Rd<uint8_t>(pc + OFF::PC_Team); }   // 1=Tr 2=Ct
inline uintptr_t BoneT(uintptr_t pc, int i) { return Ptr(Ptr(pc + OFF::PC_Biped) + 0x18 + 8 * i); }

// Aspect / Fog / Sky: применяем каждый кадр, при выключении один раз возвращаем
inline void ApplyWorldImpl();
inline void ApplyWorld() {
    if (!inited || !InMatch()) return;      // в лобби камеры/мира нет
    try { ApplyWorldImpl(); } catch (...) {}  // icall'ы Camera/RenderSettings тоже кидают, если камера уже уничтожена
}
inline void ApplyWorldImpl() {
    static bool wasA = false, wasF = false, wasS = false;
    uintptr_t cam = UnityCamera();
    bool a = [Cfg b:@"aspect"], s = [Cfg b:@"sky"], f = [Cfg b:@"fog"];
    if (Valid(cam)) {
        if (a && i_setAspect && i_sw && i_sh) {
            float v = [Cfg f:@"aspect.val"]; if (v < 0.3f) v = 1.f;
            i_setAspect((void*)cam, (float)i_sw() / (float)i_sh() * v); wasA = true;
        } else if (wasA && i_resetAspect) { i_resetAspect((void*)cam); wasA = false; }
        if (s && i_setClear && i_setBg) {
            NSArray* c = [Cfg rgba:@"sky.c1"]; Col4 k = { [c[0] floatValue], [c[1] floatValue], [c[2] floatValue], 1.f };
            i_setClear((void*)cam, 2 /*SolidColor*/); i_setBg((void*)cam, &k); wasS = true;
        } else if (wasS && i_setClear) { i_setClear((void*)cam, 1 /*Skybox*/); wasS = false; }
    }
    if (f && i_fog && i_fogCol) {
        NSArray* c = [Cfg rgba:@"fog.c1"]; Col4 k = { [c[0] floatValue], [c[1] floatValue], [c[2] floatValue], 1.f };
        i_fog(true); i_fogCol(&k); if (i_fogMode) i_fogMode(1 /*Linear*/); if (i_fogStart) i_fogStart(0.f); if (i_fogEnd) i_fogEnd(60.f);
        wasF = true;
    } else if (wasF && i_fog) { i_fog(false); wasF = false; }
}
}   // namespace G

// ===== Игроки, ESP и эффекты (UIKit-слои, без Metal) =====
namespace PS {                                   // состояние игроков
inline std::unordered_map<uintptr_t, double> seen;   // PlayerController* -> время последнего Update (хук)
inline uintptr_t lastVictim = 0; inline double lastHitT = 0;
}

static const char* WeaponName(uint8_t id) {
    switch (id) {
    case 11:return "G22";case 12:return "USP";case 13:return "P350";case 15:return "Deagle";case 16:return "Tec-9";case 17:return "FiveSeven";
    case 32:return "UMP45";case 34:return "MP7";case 35:return "P90";case 36:return "MP5";case 37:return "MAC-10";
    case 43:return "M4A1";case 44:return "AKR";case 45:return "AKR12";case 46:return "M4";case 47:return "M16";case 48:return "FAMAS";case 49:return "FN FAL";
    case 51:return "AWM";case 52:return "M40";case 53:return "M110";
    case 62:return "SM1014";case 63:return "FabM";case 64:return "M60";case 65:return "SPAS";
    case 70:case 71:case 72:case 73:case 75:case 77:case 78:case 79:case 80:case 81:case 82:return "Knife";
    case 91:return "HE";case 92:return "Smoke";case 93:return "Flash";case 100:return "Bomb";
    default:return "";
    }
}

struct EP {
    uintptr_t pc = 0; CGPoint p[19]; bool ok[19]; int hp = 0, hpA = 0, hpB = 0; uint8_t team = 0, wid = 0;
    NSString* name = @""; float dist = 0; bool enemy = true; Vec3 hip{0,0,0}; bool hasHip = false;
};

static bool BuildPlayers(std::vector<EP>& out, CGSize vs) {
    out.clear();
    if (!G::InMatch()) return false;
    uintptr_t pmc = G::PMC(); if (!G::Valid(pmc)) return false;
    uintptr_t cam = G::Ptr(pmc + OFF::PMC_Camera), local = G::Ptr(pmc + OFF::PMC_Player);
    if (!G::Valid(cam) || !G::i_sw || !G::i_sh) return false;
    float sw = (float)G::i_sw(), sh = (float)G::i_sh(); if (sw < 1 || sh < 1) return false;
    Vec3 camPos{0,0,0}; G::Pos(G::Ptr(pmc + OFF::PMC_Transform), camPos);
    uint8_t lteam = G::Valid(local) ? G::TeamOf(local) : 0;
    bool showTeam = [Cfg b:@"esp.team"], swapHp = [Cfg b:@"hpswap"], dbg = [Cfg b:@"debug"], wantW = [Cfg b:@"esp.weapon"];
    double now = CACurrentMediaTime();
    for (auto it = PS::seen.begin(); it != PS::seen.end();) {
        if (now - it->second > 0.5) { it = PS::seen.erase(it); continue; }   // перестал обновляться = мёртв/удалён
        uintptr_t pc = it->first; ++it;
        if (pc == local || out.size() >= 12) continue;
        EP e; e.pc = pc; e.team = G::TeamOf(pc);
        if (e.team != 1 && e.team != 2) continue;
        e.enemy = (lteam == 0) || (e.team != lteam);
        if (!e.enemy && !showTeam) continue;
        e.hpA = G::Rd<int>(pc + OFF::PC_HpA); e.hpB = G::Rd<int>(pc + OFF::PC_HpB);
        e.hp = swapHp ? e.hpB : e.hpA;
        if (e.hp <= 0 && !dbg) continue;
        uintptr_t biped = G::Ptr(pc + OFF::PC_Biped); if (!G::Valid(biped)) continue;
        bool any = false; Vec3 anyW{0,0,0};
        for (int i = 0; i < 19; i++) {
            e.ok[i] = false;
            Vec3 w; if (!G::Pos(G::Ptr(biped + 0x18 + 8 * i), w)) continue;
            Vec3 r; if (!G::W2SRaw(cam, w, r)) continue;
            if (i == 12) { e.hip = r; e.hasHip = true; }
            if (r.z <= 0.01f) continue;
            e.p[i] = CGPointMake(r.x * vs.width / sw, (sh - r.y) * vs.height / sh); e.ok[i] = true;
            if (!any) { any = true; anyW = w; }
        }
        if (!any && !e.hasHip) continue;
        float dx = anyW.x - camPos.x, dy = anyW.y - camPos.y, dz = anyW.z - camPos.z; e.dist = sqrtf(dx*dx + dy*dy + dz*dz);
        e.name = G::Str(G::Ptr(G::Ptr(pc + OFF::PC_PhotonPlayer) + OFF::PP_Nick));
        if (wantW) {
            uintptr_t wc = G::Ptr(pc + OFF::PC_Weaponry), cur = G::Valid(wc) ? G::Ptr(wc + OFF::WC_Current) : 0;
            if (G::Valid(cur)) e.wid = ((uint8_t (*)(void*, void*))(G::base + OFF::RVA_WeaponId))((void*)cur, nullptr);
        }
        out.push_back(e);
    }
    return true;
}

// экранная точка таза игрока (для эффекта убийства)
static CGPoint ScreenOf(uintptr_t pc, CGSize vs) {
    uintptr_t cam = G::UnityCamera(); Vec3 w, r;
    if (G::i_sw && G::Pos(G::BoneT(pc, 12), w) && G::W2SRaw(cam, w, r) && r.z > 0) {
        float sw = (float)G::i_sw(), sh = (float)G::i_sh();
        return CGPointMake(r.x * vs.width / sw, (sh - r.y) * vs.height / sh);
    }
    return CGPointMake(vs.width / 2, vs.height / 2);
}

static UIColor* ColK(NSString* key, NSString* sfx) {
    NSArray* a = [Cfg rgba:[key stringByAppendingString:sfx]];
    return [UIColor colorWithRed:[a[0] floatValue] green:[a[1] floatValue] blue:[a[2] floatValue] alpha:[a[3] floatValue]];
}
static CAGradientLayer* MkG(CALayer* parent, BOOL fill, CAShapeLayer** mo) {
    CAGradientLayer* g = [CAGradientLayer layer]; CAShapeLayer* m = [CAShapeLayer layer];
    m.fillColor = (fill ? UIColor.whiteColor : UIColor.clearColor).CGColor;
    m.strokeColor = (fill ? UIColor.clearColor : UIColor.whiteColor).CGColor;
    m.lineWidth = 1.4; m.lineJoin = kCALineJoinRound; m.lineCap = kCALineCapRound;
    g.mask = m; g.hidden = YES; [parent addSublayer:g]; *mo = m; return g;
}
static CATextLayer* MkT(CALayer* p, NSString* align) {
    CATextLayer* t = [CATextLayer layer]; t.fontSize = 10; t.alignmentMode = align; t.contentsScale = UIScreen.mainScreen.scale;
    t.foregroundColor = UIColor.whiteColor.CGColor; t.shadowOpacity = 1; t.shadowRadius = 1.2; t.shadowOffset = CGSizeZero; t.shadowColor = UIColor.blackColor.CGColor;
    t.hidden = YES; [p addSublayer:t]; return t;
}
static CAShapeLayer* MkS(CALayer* p) { CAShapeLayer* s = [CAShapeLayer layer]; s.hidden = YES; [p addSublayer:s]; return s; }

@interface EspSlot : NSObject
@property (nonatomic) CAGradientLayer *boxG, *cornG, *skelG, *hatG;
@property (nonatomic) CAShapeLayer *boxM, *cornM, *skelM, *hatM, *hp, *hpBg, *glow;
@property (nonatomic) CATextLayer *nick, *dist, *wep, *dbg;
- (instancetype)initIn:(CALayer*)p;
- (void)hide;
@end
@implementation EspSlot
- (instancetype)initIn:(CALayer*)p {
    self = [super init]; CAShapeLayer *a, *b, *c, *d;
    _glow = MkS(p); _glow.fillColor = UIColor.clearColor.CGColor; _glow.lineWidth = 1; _glow.shadowOffset = CGSizeZero; _glow.shadowOpacity = 1;
    _boxG = MkG(p, NO, &a); _boxM = a; _cornG = MkG(p, NO, &b); _cornM = b; _skelG = MkG(p, NO, &c); _skelM = c; _hatG = MkG(p, YES, &d); _hatM = d;
    _hpBg = MkS(p); _hpBg.fillColor = [UIColor colorWithWhite:0 alpha:0.6].CGColor; _hp = MkS(p);
    _nick = MkT(p, kCAAlignmentCenter); _dist = MkT(p, kCAAlignmentCenter); _wep = MkT(p, kCAAlignmentCenter); _dbg = MkT(p, kCAAlignmentLeft);
    return self;
}
- (void)hide {
    for (CALayer* l in @[_boxG, _cornG, _skelG, _hatG, _hp, _hpBg, _glow, _nick, _dist, _wep, _dbg]) l.hidden = YES;
}
@end

static const int kSlots = 12;
static const int kBn[][2] = {{0,1},{1,3},{3,2},{2,12},{1,4},{4,5},{5,6},{6,7},{1,8},{8,9},{9,10},{10,11},{12,13},{13,14},{14,15},{12,16},{16,17},{17,18}};

static void SetG(CAGradientLayer* g, NSString* key, CGRect fr, CGSize vs) {
    UIColor *c1 = ColK(key, @".c1"), *c2 = ColK(key, @".c2"); BOOL grad = [Cfg i:[key stringByAppendingString:@".mode"]] == 1;
    g.frame = CGRectMake(0, 0, vs.width, vs.height); ((CAShapeLayer*)g.mask).frame = g.bounds;
    g.colors = @[(id)c1.CGColor, (id)(grad ? c2 : c1).CGColor];
    CGFloat y0 = fr.origin.y / vs.height, y1 = (fr.origin.y + fr.size.height) / vs.height; if (y1 - y0 < 0.01) y1 = y0 + 0.01;
    g.startPoint = CGPointMake(0.5, y0); g.endPoint = CGPointMake(0.5, y1); g.hidden = NO;
}

@interface EspView : UIView
+ (instancetype)shared;
- (void)hitMarker;
- (void)logLine:(NSString*)s;
- (void)killFxAt:(CGPoint)p;
@end

@implementation EspView {
    NSMutableArray<EspSlot*>* _slots; CAShapeLayer *_arrows, *_hm; CATextLayer *_log, *_stat;
    CFTimeInterval _hmT; NSMutableArray* _logs; int _n; UIImage* _dot;
}
+ (instancetype)shared { static EspView* v; static dispatch_once_t o; dispatch_once(&o, ^{ v = [[EspView alloc] initWithFrame:UIScreen.mainScreen.bounds]; }); return v; }
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f]; self.userInteractionEnabled = NO; self.backgroundColor = UIColor.clearColor;
    _slots = [NSMutableArray new]; _logs = [NSMutableArray new];
    for (int i = 0; i < kSlots; i++) [_slots addObject:[[EspSlot alloc] initIn:self.layer]];
    _arrows = MkS(self.layer);
    _hm = MkS(self.layer); _hm.strokeColor = UIColor.whiteColor.CGColor; _hm.lineWidth = 1.6; _hm.fillColor = nil;
    _log = MkT(self.layer, kCAAlignmentLeft); _log.fontSize = 11; _log.frame = CGRectMake(56, 12, 300, 90);
    _stat = MkT(self.layer, kCAAlignmentLeft); _stat.fontSize = 10;
    CADisplayLink* dl = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)]; dl.preferredFramesPerSecond = 60;
    [dl addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    return self;
}
- (void)hitMarker { _hmT = CACurrentMediaTime(); }
- (void)logLine:(NSString*)s { [_logs addObject:@[s, @(CACurrentMediaTime())]]; if (_logs.count > 6) [_logs removeObjectAtIndex:0]; }
- (UIImage*)dot {
    if (_dot) return _dot;
    UIGraphicsImageRenderer* r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(32, 32)];
    _dot = [r imageWithActions:^(UIGraphicsImageRendererContext* c) {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB(); CGFloat comps[8] = {1,1,1,1, 1,1,1,0}; CGFloat loc[2] = {0,1};
        CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, loc, 2);
        CGContextDrawRadialGradient(c.CGContext, g, CGPointMake(16,16), 0, CGPointMake(16,16), 16, 0);
        CGGradientRelease(g); CGColorSpaceRelease(cs); }];
    return _dot;
}
- (void)killFxAt:(CGPoint)pt {
    CAEmitterLayer* e = [CAEmitterLayer layer]; e.emitterPosition = pt; e.emitterShape = kCAEmitterLayerPoint; e.renderMode = kCAEmitterLayerAdditive;
    CAEmitterCell* c = [CAEmitterCell emitterCell]; c.contents = (id)[self dot].CGImage; c.birthRate = 160; c.lifetime = 0.9;
    c.velocity = 150; c.velocityRange = 80; c.emissionRange = M_PI * 2; c.scale = 0.2; c.scaleRange = 0.1; c.scaleSpeed = -0.15;
    c.alphaSpeed = -1.0; c.yAcceleration = 140; c.color = ColK(@"killparticle", @".c1").CGColor;
    e.emitterCells = @[c]; [self.layer addSublayer:e];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ e.birthRate = 0; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [e removeFromSuperlayer]; });
}
- (void)tick {
    CGSize vs = self.bounds.size; if (vs.width < 1) return;
    if (!G::inited && (_n++ % 120) == 0) { G::Init(); G::InitUnity(); }
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    G::ApplyWorld();
    CFTimeInterval now = CACurrentMediaTime();
    // --- hitmarker ---
    CGFloat ha = [Cfg b:@"hitmarker"] ? MAX(0, 1 - (now - _hmT) / 0.3) : 0;
    _hm.hidden = ha <= 0;
    if (ha > 0) {
        CGPoint c = CGPointMake(vs.width / 2, vs.height / 2); UIBezierPath* p = [UIBezierPath bezierPath]; CGFloat a = 4, b = 11;
        for (int sx = -1; sx <= 1; sx += 2) for (int sy = -1; sy <= 1; sy += 2) { [p moveToPoint:CGPointMake(c.x + sx*a, c.y + sy*a)]; [p addLineToPoint:CGPointMake(c.x + sx*b, c.y + sy*b)]; }
        _hm.path = p.CGPath; _hm.opacity = ha;
    }
    // --- hitlog ---
    while (_logs.count && now - [((NSArray*)_logs[0])[1] doubleValue] > 3.5) [_logs removeObjectAtIndex:0];
    if ([Cfg b:@"hitlog"] && _logs.count) {
        NSMutableArray* ls = [NSMutableArray new]; for (NSArray* l in _logs) [ls addObject:l[0]];
        _log.string = [ls componentsJoinedByString:@"\n"]; _log.hidden = NO;
    } else _log.hidden = YES;
    // --- ESP ---
    std::vector<EP> ps; bool ok = false;
    if ([Cfg b:@"esp"]) { try { ok = BuildPlayers(ps, vs); } catch (...) { ok = false; ps.clear(); } }
    bool dbg = [Cfg b:@"debug"];
    _stat.hidden = !dbg;
    if (dbg) { _stat.string = [NSString stringWithFormat:@"%s | players:%d", G::status, (int)ps.size()]; _stat.frame = CGRectMake(12, vs.height - 20, vs.width - 24, 14); }
    UIBezierPath* arr = [UIBezierPath bezierPath]; bool arrowsOn = [Cfg b:@"esp.arrows"]; CGFloat glowK = [Cfg f:@"esp.glow"];
    for (int i = 0; i < kSlots; i++) {
        EspSlot* s = _slots[i];
        if (!ok || i >= (int)ps.size()) { [s hide]; continue; }
        const EP& e = ps[i];
        CGFloat minx = 1e9, miny = 1e9, maxx = -1e9, maxy = -1e9;
        for (int b = 0; b < 19; b++) if (e.ok[b]) { minx = MIN(minx, e.p[b].x); maxx = MAX(maxx, e.p[b].x); miny = MIN(miny, e.p[b].y); maxy = MAX(maxy, e.p[b].y); }
        bool vis = e.ok[0] && (e.ok[12] || e.ok[15] || e.ok[18]);
        if (!vis) {
            [s hide];
            if (arrowsOn && e.enemy && e.hasHip) {      // стрелка за экраном
                float sw = (float)G::i_sw(), sh = (float)G::i_sh();
                CGPoint c = CGPointMake(vs.width / 2, vs.height / 2), q = CGPointMake(e.hip.x * vs.width / sw, (sh - e.hip.y) * vs.height / sh);
                CGFloat dx = q.x - c.x, dy = q.y - c.y; if (e.hip.z <= 0) { dx = -dx; dy = -dy; }
                CGFloat l = hypot(dx, dy); if (l < 1) l = 1; dx /= l; dy /= l;
                CGFloat R = MIN(vs.width, vs.height) * 0.38; CGPoint a = CGPointMake(c.x + dx * R, c.y + dy * R);
                [arr moveToPoint:CGPointMake(a.x + dx*16, a.y + dy*16)];
                [arr addLineToPoint:CGPointMake(a.x - dx*6 - dy*11, a.y - dy*6 + dx*11)];
                [arr addLineToPoint:CGPointMake(a.x - dx*6 + dy*11, a.y - dy*6 - dx*11)]; [arr closePath];
            }
            continue;
        }
        CGFloat h = maxy - miny, top = miny - h * 0.12, bot = maxy + h * 0.04; h = bot - top;
        CGFloat cx = (minx + maxx) / 2, w = h * 0.5, x0 = cx - w / 2, x1 = cx + w / 2;
        CGRect rect = CGRectMake(x0, top, w, h);
        UIBezierPath* sk = [UIBezierPath bezierPath];
        for (auto& bn : kBn) if (e.ok[bn[0]] && e.ok[bn[1]]) { [sk moveToPoint:e.p[bn[0]]]; [sk addLineToPoint:e.p[bn[1]]]; }
        UIBezierPath* bx = [UIBezierPath bezierPathWithRect:rect];
        // box
        s.boxG.hidden = ![Cfg b:@"esp.box"];
        if (!s.boxG.hidden) { SetG(s.boxG, @"esp.box", rect, vs); s.boxM.path = bx.CGPath; }
        // corner
        s.cornG.hidden = ![Cfg b:@"esp.corner"];
        if (!s.cornG.hidden) {
            UIBezierPath* co = [UIBezierPath bezierPath]; CGFloat lw = w * 0.28, lh = h * 0.18;
            auto cor = [&](CGPoint c, CGFloat dx, CGFloat dy) { [co moveToPoint:CGPointMake(c.x + dx*lw, c.y)]; [co addLineToPoint:c]; [co addLineToPoint:CGPointMake(c.x, c.y + dy*lh)]; };
            cor(CGPointMake(x0, top), 1, 1); cor(CGPointMake(x1, top), -1, 1); cor(CGPointMake(x0, bot), 1, -1); cor(CGPointMake(x1, bot), -1, -1);
            SetG(s.cornG, @"esp.corner", rect, vs); s.cornM.path = co.CGPath;
        }
        // skeleton
        s.skelG.hidden = ![Cfg b:@"esp.skel"];
        if (!s.skelG.hidden) { SetG(s.skelG, @"esp.skel", rect, vs); s.skelM.path = sk.CGPath; }
        // china hat
        s.hatG.hidden = ![Cfg b:@"esp.hat"];
        if (!s.hatG.hidden) {
            CGPoint hp = e.p[0]; CGFloat r = h * 0.11; UIBezierPath* ht = [UIBezierPath bezierPath]; CGPoint apex = CGPointMake(hp.x, hp.y - h * 0.20);
            [ht moveToPoint:apex];
            for (int k = 0; k <= 24; k++) { CGFloat an = k * 2 * M_PI / 24; [ht addLineToPoint:CGPointMake(hp.x + cos(an) * r, hp.y - h * 0.05 + sin(an) * r * 0.3)]; }
            [ht closePath];
            CGRect hr = CGRectMake(hp.x - r, apex.y, r * 2, h * 0.15); SetG(s.hatG, @"esp.hat", hr, vs); s.hatM.path = ht.CGPath;
        }
        // glow: свечение по контуру box + skeleton
        s.glow.hidden = glowK <= 0;
        if (!s.glow.hidden) {
            UIBezierPath* gp = [UIBezierPath bezierPath]; if ([Cfg b:@"esp.box"]) [gp appendPath:bx]; if ([Cfg b:@"esp.skel"]) [gp appendPath:sk]; if (![Cfg b:@"esp.box"] && ![Cfg b:@"esp.skel"]) [gp appendPath:bx];
            UIColor* gc = ColK([Cfg b:@"esp.box"] ? @"esp.box" : @"esp.skel", @".c1");
            s.glow.path = gp.CGPath; s.glow.strokeColor = gc.CGColor; s.glow.shadowColor = gc.CGColor; s.glow.shadowRadius = glowK / 6.0;
        }
        // hp
        s.hp.hidden = s.hpBg.hidden = ![Cfg b:@"esp.hp"];
        if (!s.hp.hidden) {
            CGFloat f = MAX(0, MIN(1, e.hp / 100.0)), bxx = x0 - 6;
            s.hpBg.path = [UIBezierPath bezierPathWithRect:CGRectMake(bxx - 1, top - 1, 4, h + 2)].CGPath;
            s.hp.path = [UIBezierPath bezierPathWithRect:CGRectMake(bxx, bot - h * f, 2, h * f)].CGPath;
            s.hp.fillColor = [UIColor colorWithRed:1 - f green:f blue:0.15 alpha:1].CGColor;
        }
        // текст
        s.nick.hidden = ![Cfg b:@"esp.nick"] || e.name.length == 0;
        if (!s.nick.hidden) { s.nick.string = e.name; s.nick.foregroundColor = ColK(@"esp.nick", @".c1").CGColor; s.nick.frame = CGRectMake(cx - 70, top - 13, 140, 12); }
        CGFloat by = bot + 1;
        s.dist.hidden = ![Cfg b:@"esp.dist"];
        if (!s.dist.hidden) { s.dist.string = [NSString stringWithFormat:@"%dm", (int)e.dist]; s.dist.frame = CGRectMake(cx - 40, by, 80, 12); by += 11; }
        const char* wn = WeaponName(e.wid);
        s.wep.hidden = ![Cfg b:@"esp.weapon"] || !*wn;
        if (!s.wep.hidden) { s.wep.string = @(wn); s.wep.foregroundColor = [UIColor colorWithRed:1 green:.86 blue:.47 alpha:1].CGColor; s.wep.frame = CGRectMake(cx - 50, by, 100, 12); }
        s.dbg.hidden = !dbg;
        if (dbg) { s.dbg.string = [NSString stringWithFormat:@"A:%d B:%d T:%d", e.hpA, e.hpB, e.team]; s.dbg.frame = CGRectMake(x1 + 4, top, 90, 12); }
    }
    _arrows.hidden = !arrowsOn || arr.isEmpty;
    if (!_arrows.hidden) { _arrows.path = arr.CGPath; _arrows.fillColor = ColK(@"esp.arrows", @".c1").CGColor; }
    [CATransaction commit];
}
@end

// ---- события боя: вызываются из хуков ----
static void EvHit(NSString* victim, NSString* extra) {
    Snd::OnHit();
    dispatch_async(dispatch_get_main_queue(), ^{
        EspView* v = [EspView shared];
        if ([Cfg b:@"hitmarker"]) [v hitMarker];
        if ([Cfg b:@"hitlog"]) [v logLine:[NSString stringWithFormat:@"Hit %@ %@", victim, extra]];
    });
}
static void EvKill(uintptr_t victim) {
    Snd::OnKill();
    dispatch_async(dispatch_get_main_queue(), ^{
        EspView* v = [EspView shared];
        if ([Cfg b:@"killparticle"]) [v killFxAt:ScreenOf(victim, v.bounds.size)];
    });
}

// ---- Bhop / скорость: вызывается из хука PlayerController.Update ----
static void SetSpeed(uintptr_t mc, float v) { ((void (*)(void*, float, void*))(G::base + OFF::RVA_MC_Speed))((void*)mc, v, nullptr); }
static void TickLocal(uintptr_t self) {
    static float lastSpeed = 1.f; static bool wasOn = false; static int cnt = 0;
    bool on = [Cfg b:@"bhop"];
    if (!on && !wasOn) return;
    if (self != G::LocalPlayer()) return;
    uintptr_t mc = G::Ptr(self + OFF::PC_Movement); if (!G::Valid(mc)) return;
    if (!on) { SetSpeed(mc, 1.f); wasOn = false; lastSpeed = 1.f; return; }
    wasOn = true;
    uintptr_t in = G::Ptr(mc + OFF::MC_Input);
    if (G::Valid(in)) {
        Vec3 mv = G::Rd<Vec3>(in + OFF::MI_Move); bool moving = fabsf(mv.x) + fabsf(mv.y) + fabsf(mv.z) > 0.1f;
        uintptr_t cc = G::Ptr(mc + OFF::MC_CharCtrl);
        bool gr = (G::i_grounded && G::Valid(cc)) ? G::i_grounded((void*)cc) : true;
        if (moving && gr) G::Wr<uint8_t>(in + OFF::MI_Jump, 1);
    }
    float sp = [Cfg f:@"bhop.speed"]; if (sp < 1.f) sp = 1.f;
    if (fabsf(sp - lastSpeed) > 0.01f || (++cnt % 120) == 0) { if (sp != 1.f || lastSpeed != 1.f) SetSpeed(mc, sp); lastSpeed = sp; }
}

// ===== Меню (UIKit, матовое стекло) =====
// Menu.mm - меню в стиле матового стекла на UIKit (iOS 14+)
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <vector>


enum { T_Toggle, T_Slider, T_Color, T_Gradient, T_Segment, T_Header };
struct Item { int type; NSString* key; NSString* title; float mn, mx; NSArray* opts; };

static const std::vector<std::vector<Item>>& Pages() {   // порядок = вкладки
    static const std::vector<std::vector<Item>> p = {
    // VISUALS
    { {T_Toggle,@"esp",@"ESP"}, {T_Toggle,@"esp.team",@"Show Teammates"}, {T_Gradient,@"esp.box",@"ESP Box"}, {T_Gradient,@"esp.corner",@"ESP Corner"},
       {T_Gradient,@"esp.hat",@"China Hat"}, {T_Toggle,@"esp.hp",@"HP Bar"}, {T_Gradient,@"esp.skel",@"Skeleton"},
       {T_Toggle,@"esp.weapon",@"Weapon"}, {T_Color,@"esp.nick",@"Nickname"}, {T_Toggle,@"esp.dist",@"Distance"},
       {T_Color,@"esp.arrows",@"Offscreen Arrows"}, {T_Slider,@"esp.glow",@"Glow ESP",0,100},
       {T_Color,@"chams",@"Chams"}, {T_Color,@"chams.weapon",@"Weapon Chams"} },
    // AIM
    { {T_Toggle,@"silent",@"Silent Aim"}, {T_Toggle,@"silent360",@"Silent Aim 360"},
       {T_Slider,@"silent.fov",@"Silent FOV",1,180}, {T_Color,@"silent.fovcol",@"FOV Color"},
       {T_Toggle,@"silent.fovview",@"FOV View"} },
    // RAGE
    { {T_Toggle,@"aa",@"Anti-Aim"}, {T_Segment,@"aa.mode",@"Mode",0,0,@[@"Jitter",@"Random",@"Static",@"Spin"]},
       {T_Slider,@"aa.spin",@"Spin Speed",1,100}, {T_Slider,@"aa.angle",@"AA Angle",0,180},
       {T_Slider,@"aa.yaw",@"Yaw",-180,180}, {T_Slider,@"aa.pitch",@"Pitch",-90,90},
       {T_Slider,@"aa.jitter",@"Jitter Offset",0,90},
       {T_Toggle,@"bhop",@"Bhop"}, {T_Slider,@"bhop.speed",@"Bhop Speed",1,10},
       {T_Toggle,@"tp",@"Thirdperson"}, {T_Toggle,@"nospread",@"No Spread"},
       {T_Toggle,@"norecoil",@"No Recoil"}, {T_Toggle,@"dt",@"Doubletap"} },
    // MISC
    { {T_Toggle,@"aspect",@"Aspect Ratio"}, {T_Slider,@"aspect.val",@"Stretch",0.5,2},
       {T_Color,@"tracers",@"Bullet Tracers"},
       {T_Toggle,@"killsound",@"Kill Sound"}, {T_Toggle,@"hitsound",@"Hit Sound"},
       {T_Segment,@"hitsound.idx",@"Hit Sound",0,0,Snd::HitNames()},
       {T_Slider,@"snd.volume",@"Volume",0,1},
       {T_Toggle,@"hitmarker",@"Hitmarker"}, {T_Toggle,@"hitlog",@"Hitlog"},
       {T_Color,@"killparticle",@"Kill Particle"}, {T_Color,@"fog",@"Custom Fog"}, {T_Color,@"sky",@"Custom Sky"}, {T_Toggle,@"probe",@"Probe (log.txt)"}, {T_Toggle,@"hpswap",@"Swap HP (0x118/0x11C)"}, {T_Toggle,@"debug",@"ESP Debug"} },
    };
    return p;
}
static NSArray* TabNames() { return @[@"Visuals", @"Aim", @"Rage", @"Misc", @"Config"]; }

static const void* kKey = &kKey; static const void* kLbl = &kLbl;
static NSString* KeyOf(id v) { return objc_getAssociatedObject(v, kKey); }
static UIColor* Col(NSArray* a) { return [UIColor colorWithRed:[a[0] floatValue] green:[a[1] floatValue] blue:[a[2] floatValue] alpha:[a[3] floatValue]]; }
static NSArray* Arr(UIColor* c) { CGFloat r,g,b,a; [c getRed:&r green:&g blue:&b alpha:&a]; return @[@(r),@(g),@(b),@(a)]; }

@interface PassWindow : UIWindow @end
@implementation PassWindow
- (UIView*)hitTest:(CGPoint)p withEvent:(UIEvent*)e {
    UIView* v = [super hitTest:p withEvent:e];
    return (v == self || v == self.rootViewController.view) ? nil : v;   // клики проходят в игру
}
@end

@interface GlassMenu : UIViewController
@property UIVisualEffectView* panel; @property UIStackView* stack; @property UIScrollView* scroll;
@property UISegmentedControl* tabs; @property int tab;
@end

@implementation GlassMenu
- (void)viewDidLoad {
    [super viewDidLoad];
    [self defaults];
    self.view.backgroundColor = UIColor.clearColor;
    EspView* ev = [EspView shared]; ev.frame = self.view.bounds;
    ev.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; [self.view addSubview:ev];

    CGFloat w = MIN(UIScreen.mainScreen.bounds.size.width * 0.62, 380), h = MIN(UIScreen.mainScreen.bounds.size.height * 0.8, 440);
    _panel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    _panel.frame = CGRectMake(40, 40, w, h);
    _panel.layer.cornerRadius = 22; _panel.clipsToBounds = YES;
    _panel.layer.borderWidth = 0.6; _panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
    _panel.contentView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.18];     // матовость
    _panel.hidden = YES;
    [self.view addSubview:_panel];

    // перетаскивание за шапку
    UIView* head = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 34)];
    UILabel* t = [[UILabel alloc] initWithFrame:CGRectMake(16, 6, w - 32, 22)];
    t.text = @"STANDARLING"; t.textColor = [UIColor colorWithWhite:1 alpha:0.9];
    t.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [head addSubview:t]; [_panel.contentView addSubview:head];
    [head addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];

    _tabs = [[UISegmentedControl alloc] initWithItems:TabNames()];
    _tabs.frame = CGRectMake(12, 36, w - 24, 30); _tabs.selectedSegmentIndex = 0;
    _tabs.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [_tabs addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
    [_panel.contentView addSubview:_tabs];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 74, w, h - 74)];
    _stack = [UIStackView new]; _stack.axis = UILayoutConstraintAxisVertical; _stack.spacing = 6;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_scroll addSubview:_stack]; [_panel.contentView addSubview:_scroll];
    [NSLayoutConstraint activateConstraints:@[
        [_stack.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:4],
        [_stack.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-12],
        [_stack.leadingAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.leadingAnchor constant:12],
        [_stack.trailingAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.trailingAnchor constant:-12]]];
    [self rebuild];

    // плавающая кнопка открытия
    UIVisualEffectView* fab = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    fab.frame = CGRectMake(8, 8, 36, 36); fab.layer.cornerRadius = 18; fab.clipsToBounds = YES;
    fab.layer.borderWidth = 0.6; fab.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor;
    [fab addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggle)]];
    [fab addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
    [self.view addSubview:fab];
}
- (void)drag:(UIPanGestureRecognizer*)g {
    UIView* v = g.view.superview == _panel.contentView ? _panel : g.view;
    CGPoint d = [g translationInView:self.view]; v.center = CGPointMake(v.center.x + d.x, v.center.y + d.y);
    [g setTranslation:CGPointZero inView:self.view];
}
- (void)toggle { _panel.hidden = !_panel.hidden; }
- (void)tabChanged { _tab = (int)_tabs.selectedSegmentIndex; [self rebuild]; }

- (void)defaults {   // значения по умолчанию, не затираем загруженные
    NSDictionary* def = @{ @"snd.volume": @0.8, @"silent.fov": @30, @"aa.spin": @20, @"aa.angle": @60, @"bhop.speed": @1,
                           @"aspect.val": @1.0, @"hitsound.idx": @0, @"esp.glow": @0, @"esp": @YES, @"esp.box": @YES, @"esp.hp": @YES, @"esp.nick": @YES, @"esp.dist": @YES, @"esp.weapon": @YES, @"esp.skel": @YES, @"esp.arrows": @YES, @"hitmarker": @YES, @"hitlog": @YES, @"killparticle": @YES,
        @"esp.box.c1": @[@1,@0.25,@0.25,@1], @"esp.box.c2": @[@1,@0.85,@0.2,@1], @"esp.corner.c1": @[@1,@1,@1,@1], @"esp.corner.c2": @[@0.4,@0.7,@1,@1], @"esp.skel.c1": @[@1,@1,@1,@1], @"esp.skel.c2": @[@0.4,@0.7,@1,@1], @"esp.hat.c1": @[@1,@0.4,@0.8,@1], @"esp.hat.c2": @[@0.5,@0.3,@1,@0.8], @"esp.nick.c1": @[@1,@1,@1,@1], @"esp.arrows.c1": @[@1,@0.2,@0.2,@1], @"killparticle.c1": @[@1,@0.8,@0.3,@1], @"fog.c1": @[@0.5,@0.5,@0.6,@1], @"sky.c1": @[@0.1,@0.1,@0.2,@1] };
    for (NSString* k in def) if (![Cfg d][k]) [Cfg set:def[k] for:k];
}

// ---------- сборка строк ----------
- (UIStackView*)card {
    UIStackView* r = [UIStackView new]; r.axis = UILayoutConstraintAxisHorizontal; r.alignment = UIStackViewAlignmentCenter;
    r.spacing = 8; r.layoutMarginsRelativeArrangement = YES; r.layoutMargins = UIEdgeInsetsMake(8, 12, 8, 12);
    UIView* bg = [[UIView alloc] initWithFrame:CGRectZero]; bg.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    bg.layer.cornerRadius = 12; bg.translatesAutoresizingMaskIntoConstraints = NO; bg.userInteractionEnabled = NO;
    [r insertSubview:bg atIndex:0];
    [NSLayoutConstraint activateConstraints:@[[bg.topAnchor constraintEqualToAnchor:r.topAnchor], [bg.bottomAnchor constraintEqualToAnchor:r.bottomAnchor],
        [bg.leadingAnchor constraintEqualToAnchor:r.leadingAnchor], [bg.trailingAnchor constraintEqualToAnchor:r.trailingAnchor]]];
    return r;
}
- (UILabel*)label:(NSString*)s {
    UILabel* l = [UILabel new]; l.text = s; l.textColor = [UIColor colorWithWhite:1 alpha:0.92];
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium]; [l setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    return l;
}
- (UIColorWell*)well:(NSString*)key {
    UIColorWell* w = [UIColorWell new]; w.supportsAlpha = YES; w.title = @"Color";
    NSArray* a = [Cfg d][key]; w.selectedColor = a ? Col(a) : UIColor.whiteColor;
    objc_setAssociatedObject(w, kKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [w addTarget:self action:@selector(colorChanged:) forControlEvents:UIControlEventValueChanged];
    if (!a) [Cfg set:Arr(w.selectedColor) for:key];
    return w;
}
- (UISwitch*)toggle:(NSString*)key {
    UISwitch* sw = [UISwitch new]; sw.onTintColor = [UIColor colorWithRed:.45 green:.55 blue:1 alpha:1]; sw.on = [Cfg b:key];
    objc_setAssociatedObject(sw, kKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [sw addTarget:self action:@selector(switched:) forControlEvents:UIControlEventValueChanged];
    return sw;
}
- (void)rebuild {
    for (UIView* v in _stack.arrangedSubviews) { [_stack removeArrangedSubview:v]; [v removeFromSuperview]; }
    if (_tab == 4) { [self buildConfig]; return; }
    for (const Item& it : Pages()[_tab]) {
        UIStackView* r = [self card]; r.tag = 0;
        switch (it.type) {
        case T_Toggle: {
            UISwitch* s = [UISwitch new]; s.onTintColor = [UIColor colorWithRed:.45 green:.55 blue:1 alpha:1];
            s.on = [Cfg b:it.key]; objc_setAssociatedObject(s, kKey, it.key, OBJC_ASSOCIATION_COPY_NONATOMIC);
            [s addTarget:self action:@selector(switched:) forControlEvents:UIControlEventValueChanged];
            [r addArrangedSubview:[self label:it.title]]; [r addArrangedSubview:s]; break; }
        case T_Slider: {
            r.axis = UILayoutConstraintAxisVertical; r.alignment = UIStackViewAlignmentFill; r.spacing = 2;
            UILabel* val = [self label:@""]; val.textAlignment = NSTextAlignmentRight; val.textColor = [UIColor colorWithWhite:1 alpha:0.6];
            UIStackView* top = [UIStackView new]; [top addArrangedSubview:[self label:it.title]]; [top addArrangedSubview:val];
            UISlider* s = [UISlider new]; s.minimumValue = it.mn; s.maximumValue = it.mx;
            s.value = [Cfg d][it.key] ? [Cfg f:it.key] : it.mn; val.text = [NSString stringWithFormat:@"%.1f", s.value];
            objc_setAssociatedObject(s, kKey, it.key, OBJC_ASSOCIATION_COPY_NONATOMIC); objc_setAssociatedObject(s, kLbl, val, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [s addTarget:self action:@selector(slid:) forControlEvents:UIControlEventValueChanged];
            [r addArrangedSubview:top]; [r addArrangedSubview:s]; break; }
        case T_Color: {
            [r addArrangedSubview:[self label:it.title]]; [r addArrangedSubview:[self toggle:it.key]];
            [r addArrangedSubview:[self well:[it.key stringByAppendingString:@".c1"]]]; break; }
        case T_Gradient: {
            r.axis = UILayoutConstraintAxisVertical; r.alignment = UIStackViewAlignmentFill; r.spacing = 6;
            UIStackView* top = [UIStackView new]; top.spacing = 8; top.alignment = UIStackViewAlignmentCenter;
            [top addArrangedSubview:[self label:it.title]]; [top addArrangedSubview:[self toggle:it.key]];
            [top addArrangedSubview:[self well:[it.key stringByAppendingString:@".c1"]]];
            [top addArrangedSubview:[self well:[it.key stringByAppendingString:@".c2"]]];
            UISegmentedControl* m = [[UISegmentedControl alloc] initWithItems:@[@"Solid", @"Gradient"]];
            NSString* mk = [it.key stringByAppendingString:@".mode"]; m.selectedSegmentIndex = [Cfg i:mk];
            objc_setAssociatedObject(m, kKey, mk, OBJC_ASSOCIATION_COPY_NONATOMIC);
            [m addTarget:self action:@selector(segged:) forControlEvents:UIControlEventValueChanged];
            m.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
            [r addArrangedSubview:top]; [r addArrangedSubview:m]; break; }
        case T_Segment: {
            r.axis = UILayoutConstraintAxisVertical; r.alignment = UIStackViewAlignmentFill;
            UISegmentedControl* m = [[UISegmentedControl alloc] initWithItems:it.opts]; m.selectedSegmentIndex = [Cfg i:it.key];
            m.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
            objc_setAssociatedObject(m, kKey, it.key, OBJC_ASSOCIATION_COPY_NONATOMIC);
            [m addTarget:self action:@selector(segged:) forControlEvents:UIControlEventValueChanged];
            [r addArrangedSubview:[self label:it.title]]; [r addArrangedSubview:m]; break; }
        }
        [_stack addArrangedSubview:r];
    }
}
- (void)buildConfig {
    UIStackView* bar = [UIStackView new]; bar.spacing = 8; bar.distribution = UIStackViewDistributionFillEqually;
    for (NSString* t in @[@"CFG SAVE", @"CFG LOAD"]) {
        UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem]; [b setTitle:t forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12]; b.layer.cornerRadius = 12; b.tintColor = UIColor.whiteColor;
        [b.heightAnchor constraintEqualToConstant:40].active = YES;
        [b addTarget:self action:([t hasSuffix:@"SAVE"] ? @selector(cfgSave) : @selector(cfgLoad)) forControlEvents:UIControlEventTouchUpInside];
        [bar addArrangedSubview:b];
    }
    [_stack addArrangedSubview:bar];
    NSString* sel = objc_getAssociatedObject(self, @selector(cfgLoad));
    for (NSString* n in [Cfg list]) {                       // таблица конфигов
        UIStackView* r = [self card]; [r addArrangedSubview:[self label:n]];
        UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem]; b.tintColor = UIColor.whiteColor;
        [b setTitle:[n isEqualToString:sel] ? @"● selected" : @"select" forState:UIControlStateNormal];
        objc_setAssociatedObject(b, kKey, n, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [b addTarget:self action:@selector(cfgPick:) forControlEvents:UIControlEventTouchUpInside];
        [r addArrangedSubview:b]; [_stack addArrangedSubview:r];
    }
}
// ---------- действия ----------
- (void)switched:(UISwitch*)s { [Cfg set:@(s.on) for:KeyOf(s)]; }
- (void)slid:(UISlider*)s { [Cfg set:@(s.value) for:KeyOf(s)]; ((UILabel*)objc_getAssociatedObject(s, kLbl)).text = [NSString stringWithFormat:@"%.1f", s.value]; }
- (void)segged:(UISegmentedControl*)m {
    [Cfg set:@(m.selectedSegmentIndex) for:KeyOf(m)];
    if ([KeyOf(m) isEqualToString:@"hitsound.idx"]) Snd::PlayHit((int)m.selectedSegmentIndex);   // предпрослушка
}
- (void)colorChanged:(UIColorWell*)w { [Cfg set:Arr(w.selectedColor) for:KeyOf(w)]; }
- (void)cfgPick:(UIButton*)b { objc_setAssociatedObject(self, @selector(cfgLoad), KeyOf(b), OBJC_ASSOCIATION_COPY_NONATOMIC); [self rebuild]; }
- (void)cfgLoad {
    NSString* n = objc_getAssociatedObject(self, @selector(cfgLoad));
    if (n && [Cfg load:n]) [self rebuild];
}
- (void)cfgSave {
    UIAlertController* a = [UIAlertController alertControllerWithTitle:@"Config name" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:nil];
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
        NSString* n = a.textFields.firstObject.text; if (n.length) { [Cfg save:n]; [self rebuild]; } }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

// ---------- запуск ----------
static PassWindow* gWin;
static void MenuInit() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        UIWindowScene* sc = nil;
        for (UIScene* s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:UIWindowScene.class] && s.activationState == UISceneActivationStateForegroundActive) { sc = (UIWindowScene*)s; break; }
        gWin = sc ? [[PassWindow alloc] initWithWindowScene:sc] : [[PassWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        gWin.windowLevel = UIWindowLevelAlert + 100; gWin.backgroundColor = UIColor.clearColor;
        gWin.rootViewController = [GlassMenu new]; gWin.hidden = NO;
    });
}

// =====================================================================
//  ХУКИ: подмена methodPointer (MethodInfo) и записей vtable. Код не патчится, MSHook не нужен.
//  RVA - от базы UnityFramework, только для этой сборки клиента.
// =====================================================================
#include <dlfcn.h>
#include <fcntl.h>

static NSString* DocPath(NSString* n) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:n];
}
static void Log(NSString* s) {      // Documents/log.txt, открывается через приложение "Файлы"
    NSLog(@"[SW] %@", s);
    NSString* p = DocPath(@"log.txt"); NSString* line = [s stringByAppendingString:@"\n"];
    NSFileHandle* h = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!h) { [line writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
    [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
}

// ---------- il2cpp API ----------
static void*  (*il_domain_get)(void);
static void** (*il_domain_get_assemblies)(void*, size_t*);
static void*  (*il_assembly_get_image)(void*);
static const char* (*il_image_get_name)(void*);
static uint32_t (*il_image_get_class_count)(void*);
static void*  (*il_image_get_class)(void*, uint32_t);
static void*  (*il_class_get_method)(void*, const char*, int);
static const char* (*il_class_get_name)(void*);

static void* FindImage(const char* sub) {
    size_t n = 0; void** as = il_domain_get_assemblies(il_domain_get(), &n);
    for (size_t i = 0; i < n; i++) {
        void* img = il_assembly_get_image(as[i]); const char* nm = img ? il_image_get_name(img) : NULL;
        if (nm && strstr(nm, sub)) return img;
    }
    return NULL;
}
// Ищем класс по имени во ВСЕХ сборках (раньше брали первую сборку с "Assembly-CSharp" в имени -
// это мог быть Assembly-CSharp-firstpass, где игровых классов нет).
static void* FindClass(void* /*img*/, const char* name) {
    size_t n = 0; void** as = il_domain_get_assemblies(il_domain_get(), &n);
    for (size_t j = 0; j < n; j++) {
        void* img = il_assembly_get_image(as[j]); if (!img) continue;
        uint32_t cnt = il_image_get_class_count(img);
        for (uint32_t i = 0; i < cnt; i++) {
            void* k = il_image_get_class(img, i); const char* nm = k ? il_class_get_name(k) : NULL;
            if (nm && !strcmp(nm, name)) return k;
        }
    }
    return NULL;
}
// Диагностика: какие сборки есть, сколько в них классов, и какие классы похожи на нужные
static void DumpDiag() {
    size_t n = 0; void** as = il_domain_get_assemblies(il_domain_get(), &n);
    Log([NSString stringWithFormat:@"assemblies: %zu", n]);
    int shown = 0;
    for (size_t j = 0; j < n; j++) {
        void* img = il_assembly_get_image(as[j]); if (!img) continue;
        uint32_t cnt = il_image_get_class_count(img);
        const char* in = il_image_get_name(img);
        if (cnt > 200 || (in && strstr(in, "Assembly"))) Log([NSString stringWithFormat:@"  %s: %u классов", in ? in : "?", cnt]);
        for (uint32_t i = 0; i < cnt && shown < 40; i++) {
            void* k = il_image_get_class(img, i); const char* nm = k ? il_class_get_name(k) : NULL;
            if (nm && (strstr(nm, "Player") || strstr(nm, "Weapon") || strstr(nm, "Gun") || strstr(nm, "Hit")) && in && !strstr(in, "UnityEngine") && !strstr(in, "Photon")) {
                Log([NSString stringWithFormat:@"  class %s (%s)", nm, in]); shown++;
            }
        }
    }
}

// ---------- реестр оригиналов ----------
struct OrigE { void* mi; void* fn; };
static OrigE g_orig[96]; static int g_nOrig;
static void  regOrig(void* mi, void* fn) { if (g_nOrig < 96) g_orig[g_nOrig++] = { mi, fn }; }
static void* origOf(void* mi) { for (int i = 0; i < g_nOrig; i++) if (g_orig[i].mi == mi) return g_orig[i].fn; return NULL; }

// ---------- защита от краша: если упали на патче, при следующем запуске он пропускается ----------
static NSMutableSet<NSString*>* g_skip;
static void WriteState(NSString* t) { [t writeToFile:DocPath(@"sw_state.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
static void LoadSkip() {
    g_skip = [NSMutableSet set];
    for (NSString* l in [[NSString stringWithContentsOfFile:DocPath(@"sw_skip.txt") encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"])
        if (l.length) [g_skip addObject:l];
    NSString* prev = [NSString stringWithContentsOfFile:DocPath(@"sw_state.txt") encoding:NSUTF8StringEncoding error:nil];
    if ([prev hasPrefix:@"crash-at:"]) {
        [g_skip addObject:[prev substringFromIndex:9]];
        [[g_skip.allObjects componentsJoinedByString:@"\n"] writeToFile:DocPath(@"sw_skip.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Log([NSString stringWithFormat:@"prev launch crashed at %@ -> skipped", [prev substringFromIndex:9]]);
    }
}

// MethodInfo.methodPointer = первое поле. Работает для вызовов через runtime_invoke (RPC, Update/Start и т.п.)
static bool PatchMI(const char* tag, void* mi, uintptr_t rva, void* rep, NSString** why) {
    void* cur = *(void**)mi;
    if ((uintptr_t)cur != G::base + rva) { *why = @"ptr mismatch"; return false; }
    if (origOf(mi)) return true;
    WriteState([NSString stringWithFormat:@"crash-at:%s", tag]);
    regOrig(mi, cur);
    *(void**)mi = rep;
    WriteState([NSString stringWithFormat:@"ok:%s", tag]);
    return true;
}
// Запись vtable: VirtualInvokeData {methodPtr, method}. Нужна для виртуальных/интерфейсных вызовов.
// Класс должен быть уже проинициализирован (vtable заполнена), поэтому ставим с повторами.
static bool PatchVT(const char* tag, void* klass, void* mi, uintptr_t rva, void* rep, NSString** why) {
    uintptr_t want = G::base + rva, base = (uintptr_t)klass; int n = 0;
    WriteState([NSString stringWithFormat:@"crash-at:%s", tag]);
    for (uintptr_t off = 0x100; off < 0x1000; off += 8) {
        uintptr_t* p = (uintptr_t*)(base + off);
        if (p[0] == (uintptr_t)mi && p[-1] == want) {
            if (!origOf(mi)) regOrig(mi, (void*)want);
            p[-1] = (uintptr_t)rep; n++;
        }
    }
    WriteState([NSString stringWithFormat:@"ok:%s", tag]);
    if (!n) { *why = @"vtable entry not found (класс ещё не инициализирован?)"; return false; }
    return true;
}

// ---------- обработчики ----------
// NoRecoil / NoSpread: WeaponController.HBOKJJPJPGI (virtual) -> AccuracyData {AccuracyAngle 0x10, RecoilAngle 0x14}
typedef void* (*fn_acc_t)(void*, void*);
static void* h_acc(void* self, void* mi) {
    fn_acc_t o = (fn_acc_t)origOf(mi);
    void* r = o ? o(self, mi) : NULL;
    if (r && G::Valid((uintptr_t)r)) {
        float* f = (float*)((uintptr_t)r + 0x10);
        if ([Cfg b:@"nospread"]) f[0] = 0.f;
        if ([Cfg b:@"norecoil"]) f[1] = 0.f;
    }
    return r;
}

// ПРОБЫ: пишут в log.txt, какой метод сработал (тумблер Misc -> Probe). MethodInfo* лежит последним аргументом,
// поэтому ищем его среди 8 регистровых аргументов по реестру оригиналов.
typedef void* (*fn8_t)(void*, void*, void*, void*, void*, void*, void*, void*);
static void* FindMi(void** a) { for (int i = 0; i < 8; i++) if (a[i] && origOf(a[i])) return a[i]; return NULL; }
#define PROBE(NAME)                                                                                   \
    static void* h_##NAME(void* a, void* b, void* c, void* d, void* e, void* f, void* g, void* h) {   \
        void* args[8] = { a, b, c, d, e, f, g, h }; void* mi = FindMi(args);                          \
        if ([Cfg b:@"probe"]) Log(@"probe: " #NAME);                                                  \
        void* o = mi ? origOf(mi) : NULL;                                                             \
        return o ? ((fn8_t)o)(a, b, c, d, e, f, g, h) : NULL;                                         \
    }
PROBE(HitOverride) PROBE(MDBP) PROBE(HitViaServer)
#undef PROBE

// ---------- боевые обработчики ----------
typedef void (*fn_v_t)(void*, void*);
typedef void (*fn_adpg_t)(void*, void*, void*, void*);

// Список игроков: вызываем оригинал и запоминаем this. Заодно тик локального игрока (bhop).
static void h_PCUpdate(void* self, void* mi) {
    fn_v_t o = (fn_v_t)origOf(mi); if (o) o(self, mi);
    PS::seen[(uintptr_t)self] = CACurrentMediaTime();
    G::lastPC = CACurrentMediaTime();
    TickLocal((uintptr_t)self);
}
// Попадание по игроку (this = PlayerHitController жертвы). pp = PhotonPlayer, предположительно стрелок (?)
static void h_ADPG(void* self, void* hit, void* pp, void* mi) {
    fn_adpg_t o = (fn_adpg_t)origOf(mi); if (o) o(self, hit, pp, mi);
    uintptr_t local = G::LocalPlayer(), lpp = G::Valid(local) ? G::Ptr(local + OFF::PC_PhotonPlayer) : 0;
    bool mine = lpp && (uintptr_t)pp == lpp;
    uintptr_t victim = G::Ptr((uintptr_t)self + OFF::HC_Player);
    uintptr_t arr = G::Ptr((uintptr_t)hit + 0x38);                          // EKPAEOPMDOM.DJHLCPDPDAA (AMCGODIMMFF[])
    int n = G::Valid(arr) ? G::Rd<int>(arr + 0x18) : 0; if (n > 8) n = 8;
    float first = 0; uint8_t wid = G::Rd<uint8_t>((uintptr_t)hit + 0x28);
    for (int i = 0; i < n; i++) {
        uintptr_t e = G::Ptr(arr + 0x20 + 8 * i); if (i == 0) first = G::Rd<float>(e + 0x28);
        if ([Cfg b:@"probe"]) Log([NSString stringWithFormat:@"ADPG e%d: f28=%.2f i2C=%d f30=%.2f bone=%d b38=%d", i, G::Rd<float>(e + 0x28), G::Rd<int>(e + 0x2C), G::Rd<float>(e + 0x30), G::Rd<int>(e + 0x34), G::Rd<uint8_t>(e + 0x38)]);
    }
    if ([Cfg b:@"probe"]) Log([NSString stringWithFormat:@"probe: ADPG mine=%d victim=%p n=%d", mine, (void*)victim, n]);
    if (!mine) return;
    if ([Cfg b:@"silent"] || [Cfg b:@"silent360"]) Log([NSString stringWithFormat:@"SILENT: моё попадание registered, victim=%p", (void*)victim]);
    PS::lastVictim = victim; PS::lastHitT = CACurrentMediaTime();
    NSString* nm = G::Str(G::Ptr(G::Ptr(victim + OFF::PC_PhotonPlayer) + OFF::PP_Nick));
    EvHit(nm.length ? nm : @"?", [NSString stringWithFormat:@"[%s] %.0f", WeaponName(wid), first]);
}
// Смерть игрока. Убийцу не знаем -> засчитываем, если это жертва моего последнего попадания (<1.5 c)
static void h_Die(void* self, void* mi) {
    fn_v_t o = (fn_v_t)origOf(mi); if (o) o(self, mi);
    if ([Cfg b:@"probe"]) Log(@"probe: DieViaServer");
    if ((uintptr_t)self == PS::lastVictim && CACurrentMediaTime() - PS::lastHitT < 1.5) { PS::lastVictim = 0; EvKill((uintptr_t)self); }
}



// ===== Silent Aim =====
// Все хуки тут data-only (MethodInfo / vtable): inline-хук на устройстве без JIT не поставить.
// Выстрел считается внутри ПРИВАТНЫХ методов GunController (прямые вызовы, подменить нельзя),
// но запускается из ВИРТУАЛЬНЫХ методов того же класса (их vtable-запись патчится).
// Принцип как в чите для другой игры (направление правится в момент выстрела): на время такого вызова
// поворачиваем камеру/прицел на цель, после вызова возвращаем -> на экране ничего не дёргается.
namespace SA {
struct Quat4 { float x, y, z, w; };
inline Quat4 LookQ(Vec3 f) {          // эквивалент Quaternion.LookRotation(f, up)
    float l = sqrtf(f.x*f.x + f.y*f.y + f.z*f.z); if (l < 1e-6f) return {0, 0, 0, 1};
    f.x /= l; f.y /= l; f.z /= l;
    Vec3 r = { f.z, 0.f, -f.x };      // cross(up, f)
    float rl = sqrtf(r.x*r.x + r.z*r.z);
    if (rl < 1e-5f) r = { 1.f, 0.f, 0.f }; else { r.x /= rl; r.z /= rl; }
    Vec3 u = { f.y*r.z - f.z*r.y, f.z*r.x - f.x*r.z, f.x*r.y - f.y*r.x };   // cross(f, r)
    float m00 = r.x, m01 = u.x, m02 = f.x, m10 = r.y, m11 = u.y, m12 = f.y, m20 = r.z, m21 = u.z, m22 = f.z;
    float tr = m00 + m11 + m22; Quat4 q;
    if (tr > 0)                       { float s = sqrtf(tr + 1.f) * 2.f;               q = { (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, 0.25f * s }; }
    else if (m00 > m11 && m00 > m22)  { float s = sqrtf(1.f + m00 - m11 - m22) * 2.f; q = { 0.25f * s, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s }; }
    else if (m11 > m22)               { float s = sqrtf(1.f + m11 - m00 - m22) * 2.f; q = { (m01 + m10) / s, 0.25f * s, (m12 + m21) / s, (m02 - m20) / s }; }
    else                              { float s = sqrtf(1.f + m22 - m00 - m11) * 2.f; q = { (m02 + m20) / s, (m12 + m21) / s, 0.25f * s, (m10 - m01) / s }; }
    return q;
}

struct Tgt { bool ok = false; Vec3 aim{0,0,0}; Vec3 cam{0,0,0}; uintptr_t pc = 0; float score = 0; };

// Цель: враг, жив. Обычный режим - ближайший к центру экрана в пределах FOV, 360 - ближайший по расстоянию.
inline Tgt Pick() {
    Tgt t;
    if (!G::InMatch() || !G::i_sw || !G::i_sh) return t;
    uintptr_t pmc = G::PMC(); if (!G::Valid(pmc)) return t;
    uintptr_t cam = G::Ptr(pmc + OFF::PMC_Camera), local = G::LocalPlayer();
    if (!G::Valid(cam) || !G::Valid(local)) return t;
    G::Pos(G::Ptr(pmc + OFF::PMC_Transform), t.cam);
    bool all = [Cfg b:@"silent360"], swapHp = [Cfg b:@"hpswap"];
    uint8_t lteam = G::TeamOf(local);
    float sw = (float)G::i_sw(), sh = (float)G::i_sh(); if (sw < 1 || sh < 1) return t;
    float fov = [Cfg f:@"silent.fov"]; if (fov < 1) fov = 1;
    float fovPx = (sh * 0.5f) * tanf(fov * 0.0174533f) / 0.41421f;   // вертикальный FOV камеры = 45 градусов
    if (fovPx > 1e5f) fovPx = 1e5f;
    float best = 1e30f; double now = CACurrentMediaTime();
    for (auto& kv : PS::seen) {
        if (now - kv.second > 0.5) continue;
        uintptr_t pc = kv.first; if (pc == local) continue;
        uint8_t tm = G::TeamOf(pc); if (tm != 1 && tm != 2) continue;
        if (lteam != 0 && tm == lteam) continue;
        if (G::Rd<int>(pc + (swapHp ? OFF::PC_HpB : OFF::PC_HpA)) <= 0) continue;
        uintptr_t biped = G::Ptr(pc + OFF::PC_Biped); if (!G::Valid(biped)) continue;
        Vec3 w; if (!G::Pos(G::Ptr(biped + 0x18), w)) continue;      // 0x18 = Head
        float score;
        if (all) { float dx = w.x - t.cam.x, dy = w.y - t.cam.y, dz = w.z - t.cam.z; score = dx*dx + dy*dy + dz*dz; }
        else {
            Vec3 r; if (!G::W2SRaw(cam, w, r) || r.z <= 0.01f) continue;
            float dx = r.x - sw * 0.5f, dy = r.y - sh * 0.5f; score = sqrtf(dx*dx + dy*dy);
            if (score > fovPx) continue;
        }
        if (score < best) { best = score; t.ok = true; t.aim = w; t.pc = pc; t.score = score; }
    }
    return t;
}

// RAII: на время вызова оригинала камера/прицел смотрят на цель; деструктор всё возвращает (даже при исключении il2cpp)
struct Scope {
    struct Saved { uintptr_t t; Quat4 q; };
    Saved s[3]; int n = 0;
    Scope(uintptr_t gun, const char* tag) {
        try {
            if (![Cfg b:@"silent"] && ![Cfg b:@"silent360"]) return;
            if (!G::i_getRot || !G::i_setRot) { static bool w; if (!w) { w = true; Log(@"silent: нет icall get/set_rotation (см. 'icall: rot' выше)"); } return; }
            uintptr_t local = G::LocalPlayer();
            if (!G::Valid(local) || G::Ptr(gun + OFF::WPN_Owner) != local) return;   // только оружие самого игрока
            Tgt tg = Pick(); if (!tg.ok) return;
            Vec3 d = { tg.aim.x - tg.cam.x, tg.aim.y - tg.cam.y, tg.aim.z - tg.cam.z };
            Quat4 q = LookQ(d);
            uintptr_t aim = G::Ptr(local + OFF::PC_Aim), pmc = G::PMC();
            uintptr_t c[3] = { G::Valid(aim) ? G::Ptr(aim + OFF::AC_Cam) : 0, G::Valid(aim) ? G::Ptr(aim + OFF::AC_Fps) : 0,
                               G::Valid(pmc) ? G::Ptr(pmc + OFF::PMC_Transform) : 0 };
            static int logn = 0;
            for (uintptr_t tr : c) {
                if (!G::Valid(tr)) continue;
                bool dup = false; for (int i = 0; i < n; i++) if (s[i].t == tr) dup = true;
                if (dup) continue;
                Quat4 cur; G::i_getRot((void*)tr, (float*)&cur);
                s[n].t = tr; s[n].q = cur; n++;
                if (logn < 8) {   // диагностика: сверка углов камеры с aimingData (для запасного варианта через углы)
                    float fx = 2*(cur.x*cur.z + cur.w*cur.y), fy = 2*(cur.y*cur.z - cur.w*cur.x), fz = 1 - 2*(cur.x*cur.x + cur.y*cur.y);
                    uintptr_t ad = G::Valid(aim) ? G::Ptr(aim + OFF::AC_AimData) : 0;
                    Log([NSString stringWithFormat:@"silentdiag[%s] tr=%p yaw=%.1f pitch=%.1f | aimingData f0=%.3f f1=%.3f", tag, (void*)tr,
                         atan2f(fx, fz) * 57.29578f, -asinf(fy) * 57.29578f, ad ? G::Rd<float>(ad + 0x10) : 0.f, ad ? G::Rd<float>(ad + 0x14) : 0.f]);
                }
                G::i_setRot((void*)tr, (float*)&q);
            }
            if (logn < 8) { logn++; Log([NSString stringWithFormat:@"silent[%s]: цель pc=%p, поворотов=%d", tag, (void*)tg.pc, n]); }
        } catch (...) {}
    }
    ~Scope() { try { for (int i = n - 1; i >= 0; i--) G::i_setRot((void*)s[i].t, (float*)&s[i].q); } catch (...) {} }
};
}   // namespace SA

typedef void (*fn_gv0_t)(void*, void*);
typedef void (*fn_gtick_t)(void*, float, void*);
typedef void (*fn_gin_t)(void*, void*, float, float, void*);
// Виртуальные методы GunController, из которых может запускаться выстрел (какой именно - покажет log.txt: строки silent[...])
static void h_GunV0(void* self, void* mi)  { fn_gv0_t o = (fn_gv0_t)origOf(mi); if (!o) return; SA::Scope s((uintptr_t)self, "v0"); o(self, mi); }
static void h_GunTick(void* self, float dt, void* mi) { fn_gtick_t o = (fn_gtick_t)origOf(mi); if (!o) return; SA::Scope s((uintptr_t)self, "tick"); o(self, dt, mi); }
static void h_GunInput(void* self, void* in, float t, float dt, void* mi) { fn_gin_t o = (fn_gin_t)origOf(mi); if (!o) return; SA::Scope s((uintptr_t)self, "input"); o(self, in, t, dt, mi); }

// ---------- таблица патчей ----------
struct HookDef { const char* tag; const char* cls; const char* meth; int argc; uintptr_t rva; bool vt; void* rep; bool done; };
static HookDef g_hooks[] = {
    { "ACC.gun",   "GunController",       "HBOKJJPJPGI", 0,  0x1913D78, true,  (void*)h_acc,           false },
    { "ACC.base",  "WeaponController",    "HBOKJJPJPGI", 0,  0x191DE68, true,  (void*)h_acc,           false },
    { "P.HitOv",   "PlayerHitController", "GDDPDFEGECG", 2,  0x1AA3440, true,  (void*)h_HitOverride,   false },
    { "P.Upd",     "PlayerController",    "Update",       0,  0x1AB01B0, false, (void*)h_PCUpdate,      false },
    { "P.ADPG",    "PlayerHitController", "ADPGMPBILJE", 2,  0x1AA2DC4, true,  (void*)h_ADPG,          false },
    { "P.MDBP",    "PlayerHitController", "MDBPFBOOPGP", 2,  0x1AA3E30, true,  (void*)h_MDBP,          false },
    { "P.HitVS",   "PlayerHitController", "HitViaServer", 5, 0x1AA2B84, false, (void*)h_HitViaServer,  false },
    { "P.Die",     "PlayerController",    "DieViaServer", 0,  0x1AAE87C, false, (void*)h_Die,           false },
    { "GUN.Input", "GunController",       "DANAHKIIPHK", 3,  0x190E338, true,  (void*)h_GunInput,      false },
    { "GUN.Tick",  "GunController",       "CCDAKKENGBH", 1,  0x1914044, true,  (void*)h_GunTick,       false },
    { "GUN.V13",   "GunController",       "ELEOJFHKLDC", 0,  0x1911EB4, true,  (void*)h_GunV0,         false },
    { "GUN.V11",   "GunController",       "LCIFHNLNDNE", 0,  0x1912FB0, true,  (void*)h_GunV0,         false },
};
static const int kHooks = sizeof(g_hooks) / sizeof(g_hooks[0]);
static int g_attempt;

static void TryInstall() {
    g_attempt++;
    if (!il_domain_get) {
        void* h = dlopen(NULL, RTLD_NOW);
#define SYM(v, n) v = (decltype(v))dlsym(h, n)
        SYM(il_domain_get, "il2cpp_domain_get"); SYM(il_domain_get_assemblies, "il2cpp_domain_get_assemblies");
        SYM(il_assembly_get_image, "il2cpp_assembly_get_image"); SYM(il_image_get_name, "il2cpp_image_get_name");
        SYM(il_image_get_class_count, "il2cpp_image_get_class_count"); SYM(il_image_get_class, "il2cpp_image_get_class");
        SYM(il_class_get_method, "il2cpp_class_get_method_from_name"); SYM(il_class_get_name, "il2cpp_class_get_name");
#undef SYM
    }
    G::Init();
    void* img = (G::base && il_domain_get && il_class_get_name) ? FindImage("Assembly-CSharp") : NULL;
    if (!img) { if (g_attempt == 1) Log(@"il2cpp API / Assembly-CSharp не найдены, повторю"); goto again; }
    if (g_attempt == 1 || g_attempt == 6) DumpDiag();
    {
        int left = 0;
        for (int i = 0; i < kHooks; i++) {
            HookDef& H = g_hooks[i]; if (H.done) continue;
            if ([g_skip containsObject:[NSString stringWithUTF8String:H.tag]]) { H.done = true; Log([NSString stringWithFormat:@"skip %s", H.tag]); continue; }
            NSString* why = nil;
            void* k = FindClass(img, H.cls);
            void* mi = k ? il_class_get_method(k, H.meth, H.argc) : NULL;
            bool ok = false;
            if (!k) why = @"class not found"; else if (!mi) why = @"method not found";
            else ok = H.vt ? PatchVT(H.tag, k, mi, H.rva, H.rep, &why) : PatchMI(H.tag, mi, H.rva, H.rep, &why);
            if (ok) { H.done = true; Log([NSString stringWithFormat:@"patched %s (попытка %d)", H.tag, g_attempt]); }
            else { left++; if (g_attempt % 6 == 1) Log([NSString stringWithFormat:@"%s: %@", H.tag, why]); }
        }
        if (!left) { Log(@"все патчи установлены"); return; }
    }
again:
    if (g_attempt < 60)   // классы инициализируются по мере захода в матч - повторяем каждые 5 секунд
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ TryInstall(); });
    else Log(@"патчи установлены не полностью, см. строки выше");
}

__attribute__((constructor)) static void Entry() {
    LoadSkip();
    Log([NSString stringWithFormat:@"=== build %s %s (v3: FindClass по всем сборкам, DumpDiag) ===", __DATE__, __TIME__]);
    MenuInit();   // само откладывает показ окна на 5 секунд
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ TryInstall(); });
}
