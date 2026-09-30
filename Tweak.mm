// ChickenMenu - HvH для закрытого лобби. Все офсеты из dump.cs ТВОЕЙ версии игры.
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#include "sounds.h"   // hit_wav (fatality), kill_wav (odin svinya)
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <math.h>
#include <string.h>
#include <stdint.h>
#include <ctype.h>
#include <string.h>
#include <math.h>
#include <stddef.h>
#include <fcntl.h>
#include <unistd.h>

struct Vec3 { float x, y, z; };
struct Quat { float x, y, z, w; };
struct Col  { float r, g, b, a; };
static Col hsvCol(const float *c) {   // h,s,v в 0..1 -> RGB
    float h = c[0] * 6.f, s = c[1], v = c[2], fl = floorf(h), f = h - fl; int i = (int)fl % 6;
    float p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f)); Col o = {0, 0, 0, 1};
    switch (i) { case 0: o.r = v; o.g = t; o.b = p; break; case 1: o.r = q; o.g = v; o.b = p; break; case 2: o.r = p; o.g = v; o.b = t; break;
                 case 3: o.r = p; o.g = q; o.b = v; break; case 4: o.r = t; o.g = p; o.b = v; break; default: o.r = v; o.g = p; o.b = q; break; }
    return o;
}

// ---------------- настройки ----------------
static struct {
    bool fog = true, sky = true, hitm = true, hitsnd = true, killsnd = true, esp = true;
    bool silent = true, nospread = true, dtap = true, bhop = true, aa = false;
    float bhopMul = 1.25f;   // множитель SpeedValue
    float aaOff   = 60.f;    // диапазон джиттера +- (градусы)
    float aaBase  = 0.f;     // базовый поворот по yaw
    float aaSpin  = 40.f;    // градусов за тик отправки (режим Spin)
    float aaPitch = 90.f;    // наклон модели: 90 = смотрит вниз, -90 = вверх
    int   aaMode  = 1;       // 0 jitter, 1 spin, 2 static, 3 random
    bool  killmsg   = true;   // плашка "killed <ник>" сверху
    float fogC[3] = {0, 0, 0}, skyC[3] = {0, 0, 0};   // HSV, по умолчанию чёрный
    // цвета ESP (HSV 0..1): верх / низ градиента, по умолчанию белый сверху -> чёрный снизу
    float boxTop[3] = {0, 0, 1}, boxBot[3] = {0, 0, 0}, barTop[3] = {0, 0, 1}, barBot[3] = {0, 0, 0};
    bool  aspectOn  = false;  // растянутое разрешение
    float aspect    = 1.33f;  // пропорция камеры (4:3 = 1.33)
    bool  hpbar     = true;   // хп-бар у ESP
    bool  glow      = true;   // свечение вокруг ESP-рамки
    bool  sparks    = true;   // искры при убийстве
    bool  ownAA     = true;   // видеть свой антиаим на своей модели (камера остаётся)
    float headH   = 0.9f;    // высота головы над ногами (умножается на масштаб)
} C;

// ---------------- офсеты ----------------
#define RVA_CM_Start        0x3D84098
#define RVA_CM_OnDestroy    0x3D8AC44
#define RVA_CM_Update       0x3D85350
#define RVA_CM_get_HP       0x3D8B7D0
#define RVA_CM_IsAlive     0x3D7AE6C
#define RVA_CM_ViewID       0x3D8B9CC
#define RVA_CM_IsGrounded   0x3D89C50
#define RVA_CM_Jump         0x3D8A73C
#define RVA_CM_PushBullet   0x3D77000
#define RVA_CM_MakeKill     0x3D8BACC
#define RVA_CM_Serialize    0x3D88214
#define RVA_DR_Damage       0x3D8DA38
#define RVA_MBP_photonView  0x5D89D44
#define RVA_PS_SendNext     0x5D836FC
#define RVA_BB_UpdatePos    0x3DC025C

#define OFF_CM_Speed   0x4C
#define OFF_CM_Team    0xF4
#define OFF_CM_PWM     0xB8
#define OFF_CM_Scale   0x168
#define OFF_CM_Frags   0x5C
#define OFF_CM_LastShoot 0x22C
#define OFF_PWM_Weapon 0x30
#define OFF_PWM_Target 0x48
#define OFF_W_Ammo     0x7C
#define OFF_W_GunInfo  0x100
#define OFF_GI_ErrDelta 0x38
#define OFF_GI_Params   0x30
#define OFF_PV_IsMine  0x68
#define OFF_PV_Owner   0x80
#define OFF_PL_Nick    0x20
#define OFF_PS_Writing 0x24
#define OFF_BUL_Owner  0x34
#define OFF_BUL_Orig   0x45
#define OFF_BUL_Life   0x50
#define OFF_BUL_Tr     0x58
#define OFF_BUL_Dir    0x60

// ---------------- утилиты ----------------
static uintptr_t B;
#define FN(rva, ret, ...) ((ret (*)(__VA_ARGS__))(B + (rva)))
static NSMutableSet<NSNumber *> *g_players;
static void *g_local;
static double g_hitTime; static float g_hitDmg;
static int g_gameFrames;   // кадры игры (для фпс в ватермарке)
static AVAudioPlayer *g_hitP, *g_killP;
static void initSounds() {
    g_hitP  = [[AVAudioPlayer alloc] initWithData:[NSData dataWithBytes:hit_wav length:hit_wav_len] error:nil];
    g_killP = [[AVAudioPlayer alloc] initWithData:[NSData dataWithBytes:kill_wav length:kill_wav_len] error:nil];
    g_hitP.volume = 1.0; g_killP.volume = 1.0; [g_hitP prepareToPlay]; [g_killP prepareToPlay];
}
static dispatch_queue_t g_sndQ;
static void playSnd(AVAudioPlayer *p) {   // не в игровом потоке: play() на нём даёт микрофриз при каждом попадании
    if (!p) return;
    if (!g_sndQ) g_sndQ = dispatch_queue_create("cm.snd", DISPATCH_QUEUE_SERIAL);
    dispatch_async(g_sndQ, ^{ p.currentTime = 0; [p play]; });
}

static uintptr_t getBase(const char *name) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (n && strstr(n, name)) return (uintptr_t)_dyld_get_image_header(i);
    }
    return 0;
}

// icall
static void *(*resolve_icall)(const char *);
static void *(*il2cpp_object_get_class)(void *);
static const char *(*il2cpp_class_get_name)(void *);
#define ICALL(var, name) var = (decltype(var))resolve_icall(name)

static void *(*Cam_main)(void);
static void *(*Comp_get_tr)(void *);
static void (*Tr_get_pos)(void *, Vec3 *);
static void (*Tr_set_rot)(void *, Quat *);
static void (*Tr_get_rot)(void *, Quat *);
static void (*Quat_Look)(Vec3 *, Vec3 *, Quat *);
static void (*Cam_w2s)(void *, Vec3 *, int, Vec3 *);
static int (*Scr_w)(void), (*Scr_h)(void);
static void (*RS_fog)(bool), (*RS_fogMode)(int), (*RS_fogDens)(float), (*RS_fogCol)(Col *), (*RS_skybox)(void *);
static void (*Cam_clear)(void *, int), (*Cam_bg)(void *, Col *);
static void (*Cam_setAsp)(void *, float), (*Cam_resetAsp)(void *);

static NSString *il2cppStr(void *s) {
    if (!s) return @"";
    int len = *(int *)((uintptr_t)s + 0x10);
    if (len <= 0 || len > 64) return @"";
    return [NSString stringWithCharacters:(unichar *)((uintptr_t)s + 0x14) length:len];
}

static void *pvOf(void *p)  { return FN(RVA_MBP_photonView, void *, void *, void *)(p, NULL); }
static bool isMine(void *p) { void *pv = pvOf(p); return pv && *(bool *)((uintptr_t)pv + OFF_PV_IsMine); }
static float getHP(void *p) { return FN(RVA_CM_get_HP, float, void *, void *)(p, NULL); }
static bool alive(void *p)  { return FN(RVA_CM_IsAlive, bool, void *, void *)(p, NULL); }
static int viewID(void *p)  { return FN(RVA_CM_ViewID, int, void *, void *)(p, NULL); }
static NSString *nickOf(void *p) {
    void *pv = pvOf(p); void *ow = pv ? *(void **)((uintptr_t)pv + OFF_PV_Owner) : NULL;
    return ow ? il2cppStr(*(void **)((uintptr_t)ow + OFF_PL_Nick)) : @"?";
}
static Vec3 posOf(void *o) {
    Vec3 v = {0, 0, 0}; void *t = Comp_get_tr ? Comp_get_tr(o) : NULL;
    if (t && Tr_get_pos) Tr_get_pos(t, &v); return v;
}
static float scaleOf(void *p) { float s = *(float *)((uintptr_t)p + OFF_CM_Scale); return (s > 0.01f && s < 20.f) ? s : 1.f; }

// ---------------- цель ----------------
static Vec3 g_aim; static bool g_hasTarget;
static void updateTarget() {
    g_hasTarget = false; if (!g_local) return;
    Vec3 me = posOf(g_local); int myTeam = *(int *)((uintptr_t)g_local + OFF_CM_Team);
    float best = 1e18f; NSArray *all; @synchronized (g_players) { all = g_players.allObjects; }
    for (NSNumber *n in all) {
        void *p = (void *)n.unsignedLongValue; if (p == g_local || !alive(p)) continue;
        if (myTeam != 0 && *(int *)((uintptr_t)p + OFF_CM_Team) == myTeam) continue; // проверь значение "без команды"
        Vec3 q = posOf(p); float dx = q.x - me.x, dy = q.y - me.y, dz = q.z - me.z, d = dx*dx + dy*dy + dz*dz;
        if (d < best) { best = d; g_aim = (Vec3){q.x, q.y + C.headH * scaleOf(p), q.z}; g_hasTarget = true; }
    }
}

// ---------------- хлебные крошки (место падения) ----------------
static int g_bcFd = -1;
static void bc(const char *s) {
    if (g_bcFd < 0) return;
    char b[40]; memset(b, ' ', sizeof b); size_t n = strlen(s); if (n > 38) n = 38;
    memcpy(b, s, n); b[39] = '\n'; pwrite(g_bcFd, b, sizeof b, 0);
}
static void *pickCamera();
static void applyOwnAA(void *root);
static void dumpHierarchy();
static bool g_hasLate;

// ---------------- таблица оригинальных указателей ----------------
struct OrigE { void *mi; void *fn; };
static OrigE g_orig[128]; static int g_nOrig;
static void regOrig(void *mi, void *fn) { if (g_nOrig < 128) g_orig[g_nOrig++] = (OrigE){mi, fn}; }
static void *origOf(void *mi) { for (int i = 0; i < g_nOrig; i++) if (g_orig[i].mi == mi) return g_orig[i].fn; return NULL; }
typedef void (*fn_v_t)(void *, void *);
typedef void (*fn_dmg_t)(void *, float, int, void *);
typedef void (*fn_ser_t)(void *, void *, void *, void *);

static Quat qmul(Quat a, Quat b) {
    return (Quat){ a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y,
                   a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,
                   a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w,
                   a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z };
}

// ---------------- обработчики ----------------
// ---------------- плашка "killed <ник>" ----------------
static NSString *g_killNick; static double g_killT;
static double g_fragT, g_deathT; static NSString *g_deathNick; static Vec3 g_deathPos; static bool g_fragPend, g_deathFresh;
static NSMutableDictionary<NSNumber *, NSNumber *> *g_aliveMap;
// ---------------- искры при убийстве (мировые частицы, проецируются в 2D) ----------------
struct Spark { Vec3 p, v; double born; float life, size; };
static Spark g_sparks[160]; static int g_nSparks;
static float frand(float a, float b) { return a + (float)arc4random_uniform(10001) / 10000.f * (b - a); }
static void spawnSparks(Vec3 c) {
    g_nSparks = 0; double now = CACurrentMediaTime();
    for (int i = 0; i < 90 && g_nSparks < 160; i++) {
        float th = frand(0, 2 * (float)M_PI), up = frand(-0.15f, 1.0f), r = sqrtf(fmaxf(0, 1 - up * up)), sp = frand(2.5f, 9.f);
        g_sparks[g_nSparks++] = (Spark){ c, {cosf(th) * r * sp, up * sp * 0.9f + 1.5f, sinf(th) * r * sp}, now, frand(0.45f, 1.1f), frand(1.0f, 2.2f) };
    }
}
static void showKill(NSString *n, const Vec3 *at) {
    g_fragPend = false; g_deathFresh = false;
    if (at && C.sparks) spawnSparks(*at);
    if (!C.killmsg) return;
    g_killNick = n.length ? n : @"?"; g_killT = CACurrentMediaTime();
}
static void onFrag() {
    double now = CACurrentMediaTime();
    if (g_deathFresh && now - g_deathT < 1.0) showKill(g_deathNick, &g_deathPos); else { g_fragPend = true; g_fragT = now; }
}
static void onDeath(void *p) {
    double now = CACurrentMediaTime(); NSString *n = nickOf(p);
    Vec3 pos = posOf(p); pos.y += C.headH * scaleOf(p) * 0.6f;   // примерно центр тела
    if (g_fragPend && now - g_fragT < 1.0) showKill(n, &pos); else { g_deathNick = n; g_deathPos = pos; g_deathT = now; g_deathFresh = true; }
}
static void trackDeaths() {   // ищем игроков, которые только что умерли
    if (!g_aliveMap) return;
    NSArray *all; @synchronized (g_players) { all = g_players.allObjects; }
    for (NSNumber *n in all) {
        void *p = (void *)n.unsignedLongValue; if (p == g_local) continue;
        bool a = alive(p); NSNumber *prev = g_aliveMap[n];
        if (prev && prev.boolValue && !a) onDeath(p);
        g_aliveMap[n] = @(a);
    }
    if (g_fragPend && CACurrentMediaTime() - g_fragT > 0.6) showKill(@"player", g_hasTarget ? &g_aim : NULL);   // ник не определился
}

static void h_Start(void *self, void *mi) {
    fn_v_t o = (fn_v_t)origOf(mi); if (o) o(self, mi);
    @synchronized (g_players) { [g_players addObject:@((uintptr_t)self)]; }
    [g_aliveMap removeObjectForKey:@((uintptr_t)self)];
    if (isMine(self)) g_local = self;
}
static void h_Destroy(void *self, void *mi) {
    @synchronized (g_players) { [g_players removeObject:@((uintptr_t)self)]; }
    [g_aliveMap removeObjectForKey:@((uintptr_t)self)];
    if (g_local == self) g_local = NULL;
    fn_v_t o = (fn_v_t)origOf(mi); if (o) o(self, mi);
}

static void applyVisuals() {
    if (C.fog && RS_fog && RS_fogCol && RS_fogMode && RS_fogDens) { Col k = hsvCol(C.fogC); RS_fog(true); RS_fogCol(&k); RS_fogMode(2); RS_fogDens(0.1f); }
    if (C.sky && Cam_clear && Cam_bg) {
        if (RS_skybox) RS_skybox(NULL);
        void *cam = pickCamera(); Col k = hsvCol(C.skyC);
        if (cam) { Cam_clear(cam, 2); Cam_bg(cam, &k); }
    }
}

static bool g_aspOn;
static void applyAspect() {   // растянутое разрешение: подменяем aspect основной камеры, при выключении возвращаем
    if (!Cam_setAsp) return;
    if (C.aspectOn) { void *cam = pickCamera(); if (cam) { Cam_setAsp(cam, fmaxf(0.5f, C.aspect)); g_aspOn = true; } }
    else if (g_aspOn) { void *cam = pickCamera(); if (cam && Cam_resetAsp) Cam_resetAsp(cam); g_aspOn = false; }
}
static float g_baseSpeed, g_lastShoot; static int g_lastFrags = -1; static double g_dtT; static int g_dtLog;
static void h_Update(void *self, void *mi) {
    fn_v_t o = (fn_v_t)origOf(mi); if (o) o(self, mi);
    if (!g_local && isMine(self)) g_local = self;
    if (self != g_local) return;
    g_gameFrames++;
    bc("tgt"); updateTarget(); bc("vis"); applyVisuals(); bc("kill"); trackDeaths(); bc("idle");

    void *pwm = *(void **)((uintptr_t)self + OFF_CM_PWM);
    void *w = pwm ? *(void **)((uintptr_t)pwm + OFF_PWM_Weapon) : NULL;
    if (pwm && C.silent && g_hasTarget) *(Vec3 *)((uintptr_t)pwm + OFF_PWM_Target) = g_aim;
    if (w && C.nospread) {
        void *gi = *(void **)((uintptr_t)w + OFF_W_GunInfo);
        if (gi) { Vec3 *e = (Vec3 *)((uintptr_t)gi + OFF_GI_ErrDelta); e->x = e->y = e->z = 0; }
    }

    // double tap: выстрел определяем по смене lastShootTime, повторяем PushBullet
    float lst = *(float *)((uintptr_t)self + OFF_CM_LastShoot);
    if (lst != g_lastShoot) {
        bool fresh = g_lastShoot != 0; g_lastShoot = lst;
        if (g_dtLog < 12) { g_dtLog++; NSLog(@"[DT] lastShootTime=%f", lst); }
        double now = CACurrentMediaTime();
        if (C.dtap && fresh && w && *(int *)((uintptr_t)w + OFF_W_Ammo) > 0 && now - g_dtT > 0.08) {
            g_dtT = now;
            FN(RVA_CM_PushBullet, void, void *, void *)(self, NULL);
            g_lastShoot = *(float *)((uintptr_t)self + OFF_CM_LastShoot);
        }
    }

    // килсаунд: растёт счётчик фрагов
    int fc = *(int *)((uintptr_t)self + OFF_CM_Frags);
    if (g_lastFrags >= 0 && fc > g_lastFrags) { if (C.killsnd) playSnd(g_killP); onFrag(); }
    g_lastFrags = fc;

    // bhop
    if (C.bhop) {
        float *sp = (float *)((uintptr_t)self + OFF_CM_Speed);
        if (g_baseSpeed == 0) g_baseSpeed = *sp;
        *sp = g_baseSpeed * C.bhopMul;
        if (FN(RVA_CM_IsGrounded, bool, void *, void *)(self, NULL)) FN(RVA_CM_Jump, void, void *, void *)(self, NULL);
    } else if (g_baseSpeed != 0) { *(float *)((uintptr_t)self + OFF_CM_Speed) = g_baseSpeed; }
    if (!g_hasLate) { applyOwnAA(self); applyAspect(); }
}

static void h_Late(void *self, void *mi) {
    fn_v_t o = (fn_v_t)origOf(mi); if (o) o(self, mi);
    if (self == g_local) { applyOwnAA(self); applyAspect(); }
}

// silent aim на самой пуле (Update у BaseBulletScript и подклассов)
static int g_bulLog;
static void h_BulUpdate(void *self, void *mi) {
    if (g_local && C.silent && g_hasTarget && *(bool *)((uintptr_t)self + OFF_BUL_Orig)) {
        int owner = *(int *)((uintptr_t)self + OFF_BUL_Owner);
        float life = *(float *)((uintptr_t)self + OFF_BUL_Life);
        if (life < 0.05f && owner == viewID(g_local)) {
            bc("bul:enter");
            Vec3 *dir = (Vec3 *)((uintptr_t)self + OFF_BUL_Dir);
            if (g_bulLog < 10) { g_bulLog++; NSLog(@"[BUL] owner=%d dir=%f %f %f aim=%f %f %f", owner, dir->x, dir->y, dir->z, g_aim.x, g_aim.y, g_aim.z); }
            void *tr = *(void **)((uintptr_t)self + OFF_BUL_Tr);
            if (tr && Tr_get_pos) {
                bc("bul:pos"); Vec3 p; Tr_get_pos(tr, &p);
                Vec3 d = {g_aim.x - p.x, g_aim.y - p.y, g_aim.z - p.z};
                float l = sqrtf(d.x*d.x + d.y*d.y + d.z*d.z);
                if (l > 0.001f && isfinite(l)) {
                    d.x /= l; d.y /= l; d.z /= l; *dir = d;
                    if (Quat_Look && Tr_set_rot) {
                        bc("bul:look"); Vec3 up = {0, 1, 0}; Quat q; Quat_Look(&d, &up, &q);
                        bc("bul:setrot"); Tr_set_rot(tr, &q);
                    }
                }
            }
            bc("idle");
        }
    }
    fn_v_t o = (fn_v_t)origOf(mi); if (o) o(self, mi);
}

// хитмаркер / хитсаунд (DamageReciver2.Damage, vtable)
static int g_dmgLog;
static void h_Damage(void *self, float dmg, int from, void *mi) {
    bc("dmg:orig");
    fn_dmg_t o = (fn_dmg_t)origOf(mi); if (o) o(self, dmg, from, mi);
    bc("dmg:post");
    if (g_dmgLog < 15) { g_dmgLog++; NSLog(@"[HIT] dmg=%f from=%d local=%d", dmg, from, g_local ? viewID(g_local) : -1); }
    if (g_local && from == viewID(g_local)) {
        double now = CACurrentMediaTime();
        g_hitDmg = (now - g_hitTime < 0.25) ? g_hitDmg + dmg : dmg;   // dtap / несколько пуль складываем
        g_hitTime = now;
        if (C.hitsnd) playSnd(g_hitP);
    }
    bc("idle");
}

// anti-aim: на время сериализации поворачиваем трансформ, потом возвращаем
static int g_aaTick; static float g_aaSpin, g_aaLastYaw, g_serRate = 10.f; static double g_serT;
static bool g_inSer, g_cap; static int g_snLog; static NSMutableString *g_snText;
static float aaYawDeg() {
    float y = C.aaBase;
    switch (C.aaMode) {
        case 0: y += (g_aaTick & 1) ? C.aaOff : -C.aaOff; break;                     // jitter
        case 1: g_aaSpin = fmodf(g_aaSpin + C.aaSpin, 360.f); y += g_aaSpin; break;  // spin
        case 2: break;                                                                // static
        case 3: y += ((float)arc4random_uniform(2001) / 1000.f - 1.f) * C.aaOff; break; // random
    }
    return y;
}
static void h_Ser(void *self, void *stream, void *info, void *mi) {
    fn_ser_t o = (fn_ser_t)origOf(mi);
    bool ours = self == g_local && stream && *(bool *)((uintptr_t)stream + OFF_PS_Writing);
    void *tr = NULL; Quat saved = {0, 0, 0, 1};
    if (C.aa && ours && Comp_get_tr && Tr_get_rot && Tr_set_rot) {
        bc("ser:aa");
        tr = Comp_get_tr(self);
        if (tr) {
            Tr_get_rot(tr, &saved); g_aaTick++;
            float yd = aaYawDeg(); g_aaLastYaw = yd;
            double nowT = CACurrentMediaTime();
            if (g_serT > 0) { double d = nowT - g_serT; if (d > 0.01 && d < 1.0) g_serRate = g_serRate * 0.8f + (float)(1.0 / d) * 0.2f; }
            g_serT = nowT;
            float a = yd * (float)M_PI / 180.f;
            Quat qy = {0, sinf(a / 2), 0, cosf(a / 2)};
            float pr = C.aaPitch * (float)M_PI / 180.f; Quat qx = {sinf(pr / 2), 0, 0, cosf(pr / 2)};
            Quat q = qmul(qy, qmul(saved, qx));   // yaw вокруг мировой Y, pitch вокруг локальной X
            Tr_set_rot(tr, &q);
        }
    }
    if (ours && g_cap) { g_inSer = true; g_snLog = 0; [g_snText setString:@""]; }
    if (o) o(self, stream, info, mi);
    if (g_inSer) { g_inSer = false; g_cap = false; }
    if (tr) { Tr_set_rot(tr, &saved); bc("idle"); }
}

// диагностика: что именно игра пишет в поток при синхронизации (PhotonStream.SendNext)
typedef void (*fn_send_t)(void *, void *, void *);
static void h_SendNext(void *self, void *obj, void *mi) {
    fn_send_t o = (fn_send_t)origOf(mi);
    if (g_inSer && obj && g_snLog < 40 && il2cpp_object_get_class && il2cpp_class_get_name) {
        void *k = il2cpp_object_get_class(obj);
        const char *nm = k ? il2cpp_class_get_name(k) : NULL;
        if (nm) {
            float *f = (float *)((uintptr_t)obj + 0x10);
            NSString *v = @"";
            if (!strcmp(nm, "Quaternion")) v = [NSString stringWithFormat:@"%.2f %.2f %.2f %.2f", f[0], f[1], f[2], f[3]];
            else if (!strcmp(nm, "Vector3")) v = [NSString stringWithFormat:@"%.2f %.2f %.2f", f[0], f[1], f[2]];
            else if (!strcmp(nm, "Single")) v = [NSString stringWithFormat:@"%.2f", f[0]];
            else if (!strcmp(nm, "Int32")) v = [NSString stringWithFormat:@"%d", *(int *)f];
            else if (!strcmp(nm, "Boolean")) v = *(bool *)f ? @"true" : @"false";
            g_snLog++;
            [g_snText appendFormat:@"%d:%s %@  |  ", g_snLog, nm, v];
        }
    }
    if (o) o(self, obj, mi);
}

// ---------------- ESP ----------------
static UIFont *gsF(CGFloat s);
// ---------------- текст ESP / хитмаркера (обычный жирный шрифт с тенью) + чёрно-белый градиент ----------------
static UIFont *esFont(CGFloat sz) {
    static NSMutableDictionary<NSNumber *, UIFont *> *cache; if (!cache) cache = [NSMutableDictionary new];
    UIFont *f = cache[@(sz)]; if (!f) { f = [UIFont boldSystemFontOfSize:sz]; cache[@(sz)] = f; } return f;
}
static CGFloat esWidth(NSString *t, CGFloat sz) { return [t sizeWithAttributes:@{NSFontAttributeName: esFont(sz)}].width; }
static void esText(NSString *t, CGFloat x, CGFloat y, CGFloat sz, CGFloat al) {
    UIFont *f = esFont(sz);
    [t drawAtPoint:CGPointMake(x + 1, y + 1) withAttributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: [UIColor colorWithWhite:0 alpha:0.85 * al]}];
    [t drawAtPoint:CGPointMake(x, y) withAttributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:al]}];
}
static CGGradientRef mkGrad(const float *top, const float *bot) {   // loc 0 = низ (bot), loc 1 = верх (top); освобождать через CGGradientRelease
    static CGColorSpaceRef cs; if (!cs) cs = CGColorSpaceCreateDeviceRGB();
    Col a = hsvCol(bot), b = hsvCol(top); CGFloat comps[] = {a.r, a.g, a.b, 1, b.r, b.g, b.b, 1}; CGFloat locs[] = {0, 1};
    return CGGradientCreateWithColorComponents(cs, comps, locs, 2);
}
static CGGradientRef bwGrad() {   // 0 = чёрный, 1 = белый
    static CGGradientRef g; if (!g) {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray(); CGFloat comps[] = {0, 1, 1, 1}; CGFloat locs[] = {0, 1};
        g = CGGradientCreateWithColorComponents(cs, comps, locs, 2); CGColorSpaceRelease(cs);
    } return g;
}

@interface ESPView : UIView @end
@implementation ESPView
- (void)drawRect:(CGRect)r {
    CGContextRef c = UIGraphicsGetCurrentContext(); CGSize S = self.bounds.size;
    if (C.hitm) {
        double age = CACurrentMediaTime() - g_hitTime; CGFloat cx = S.width / 2, cy = S.height / 2, a = 4, b = 10;
        if (age < 0.25) {
            CGContextSetStrokeColorWithColor(c, UIColor.whiteColor.CGColor); CGContextSetLineWidth(c, 1);
            for (int sx = -1; sx <= 1; sx += 2) for (int sy = -1; sy <= 1; sy += 2) {
                CGContextMoveToPoint(c, cx + sx * a, cy + sy * a); CGContextAddLineToPoint(c, cx + sx * b, cy + sy * b);
            }
            CGContextStrokePath(c);
        }
        if (age < 0.8) {   // надпись слева от хитмаркера
            CGFloat al = age > 0.5 ? (0.8 - age) / 0.3 : 1.0, fs = 10;
            NSString *t = [NSString stringWithFormat:@"SHOOT -%d", (int)lroundf(g_hitDmg)];
            esText(t, cx - b - 5 - esWidth(t, fs), cy - fs * 0.6, fs, al);
        }
    }
    if (g_killNick) {
        double age = CACurrentMediaTime() - g_killT;
        if (age >= 0 && age < 1.0) {
            CGFloat al = age > 0.8 ? (1.0 - age) / 0.2 : (age < 0.08 ? age / 0.08 : 1.0);
            UIFont *f2 = [UIFont fontWithName:@"Verdana-Bold" size:11] ?: gsF(11);
            NSDictionary *a1 = @{NSFontAttributeName: gsF(10), NSForegroundColorAttributeName: [UIColor colorWithWhite:0.6 alpha:al]};
            NSDictionary *a2 = @{NSFontAttributeName: f2, NSForegroundColorAttributeName: [UIColor colorWithWhite:0.96 alpha:al]};
            NSString *s1 = @"killed  ";
            CGFloat w1 = [s1 sizeWithAttributes:a1].width, w2 = [g_killNick sizeWithAttributes:a2].width;
            CGFloat bw = w1 + w2 + 28, bh = 26, bx = (S.width - bw) / 2, by = 12;
            CGRect box = CGRectMake(bx, by, bw, bh);
            CGContextSetFillColorWithColor(c, [UIColor colorWithWhite:0.04 alpha:0.92 * al].CGColor); CGContextFillRect(c, box);
            CGContextSetLineWidth(c, 1);
            CGContextSetStrokeColorWithColor(c, [UIColor colorWithWhite:0.19 alpha:al].CGColor); CGContextStrokeRect(c, CGRectInset(box, 0.5, 0.5));
            CGContextSetStrokeColorWithColor(c, [UIColor colorWithWhite:0.10 alpha:al].CGColor); CGContextStrokeRect(c, CGRectInset(box, 3.5, 3.5));
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
            CGFloat comps[] = {0.18, al, 0.96, al, 0.18, al}; CGFloat locs[] = {0, 0.5, 1};
            CGGradientRef gr = CGGradientCreateWithColorComponents(cs, comps, locs, 3);
            CGContextSaveGState(c); CGContextClipToRect(c, CGRectMake(bx + 1, by + 1, bw - 2, 2));
            CGContextDrawLinearGradient(c, gr, CGPointMake(bx + 1, by), CGPointMake(bx + bw - 1, by), 0);
            CGContextRestoreGState(c); CGGradientRelease(gr); CGColorSpaceRelease(cs);
            [s1 drawAtPoint:CGPointMake(bx + 14, by + 7) withAttributes:a1];
            [g_killNick drawAtPoint:CGPointMake(bx + 14 + w1, by + 6) withAttributes:a2];
        }
    }
    if (g_nSparks && Cam_w2s && Scr_w && Scr_h) {
        void *cam = pickCamera(); float sw = Scr_w(), sh = Scr_h(); double now = CACurrentMediaTime(); int alive_n = 0;
        if (cam && sw > 1 && sh > 1) {
            CGContextSaveGState(c); CGContextSetBlendMode(c, kCGBlendModePlusLighter); CGContextSetLineCap(c, kCGLineCapRound);
            for (int i = 0; i < g_nSparks; i++) {
                Spark &k = g_sparks[i]; float t = (float)(now - k.born); if (t < 0 || t > k.life) continue; alive_n++;
                const float G = -14.f;
                auto at = [&](float tt) { return (Vec3){k.p.x + k.v.x * tt, k.p.y + k.v.y * tt + 0.5f * G * tt * tt, k.p.z + k.v.z * tt}; };
                Vec3 w0 = at(fmaxf(0, t - 0.05f)), w1 = at(t), s0, s1;
                Cam_w2s(cam, &w0, 2, &s0); Cam_w2s(cam, &w1, 2, &s1);
                if (s0.z <= 0 || s1.z <= 0) continue;
                CGPoint p0 = CGPointMake(s0.x / sw * S.width, (1 - s0.y / sh) * S.height), p1 = CGPointMake(s1.x / sw * S.width, (1 - s1.y / sh) * S.height);
                float f = 1.f - t / k.life;   // 1 -> 0
                CGContextSetRGBStrokeColor(c, 0.8f, 0.9f, 1, 0.20f * f); CGContextSetLineWidth(c, 3.4f);     // свечение
                CGContextMoveToPoint(c, p0.x, p0.y); CGContextAddLineToPoint(c, p1.x, p1.y); CGContextStrokePath(c);
                CGContextSetRGBStrokeColor(c, 1, 1, 1, fminf(1.f, f * 1.4f)); CGContextSetLineWidth(c, 0.45f + 0.2f * k.size * f);   // тонкое белое ядро
                CGContextMoveToPoint(c, p0.x, p0.y); CGContextAddLineToPoint(c, p1.x, p1.y); CGContextStrokePath(c);
            }
            CGContextRestoreGState(c);
        }
        if (!alive_n) g_nSparks = 0;
    }
    if (!C.esp || !g_local || !Cam_w2s || !Scr_w || !Scr_h) return;
    bc("esp"); void *cam = pickCamera(); if (!cam) { bc("idle"); return; }
    float sw = Scr_w(), sh = Scr_h(); if (sw < 1 || sh < 1) { bc("idle"); return; }
    NSArray *all; @synchronized (g_players) { all = g_players.allObjects; }
    CGGradientRef gBox = mkGrad(C.boxTop, C.boxBot), gBar = mkGrad(C.barTop, C.barBot); Col glowC = hsvCol(C.boxTop);
    for (NSNumber *n in all) {
        void *p = (void *)n.unsignedLongValue; if (p == g_local || !alive(p)) continue;
        Vec3 f = posOf(p), h = f; h.y += C.headH * scaleOf(p) * 1.3f;
        Vec3 sf, shd; Cam_w2s(cam, &f, 2, &sf); Cam_w2s(cam, &h, 2, &shd);
        if (sf.z <= 0 || shd.z <= 0) continue;
        CGFloat fx = sf.x / sw * S.width,  fy = (1 - sf.y / sh) * S.height;
        CGFloat hx = shd.x / sw * S.width, hy = (1 - shd.y / sh) * S.height;
        CGFloat bh = fabs(fy - hy), bw = bh * 0.7, x = (fx + hx) / 2 - bw / 2, y = MIN(fy, hy);
        if (bh < 4) continue;
        { CGFloat mid = y + bh / 2; bh *= 1.15; bw = bh * 0.75 * ((C.aspectOn && C.aspect > 0.1f) ? (sw / sh) / C.aspect : 1.f); x = (fx + hx) / 2 - bw / 2; y = mid - bh / 2; }   // рамка чуть крупнее
        CGRect box = CGRectMake(x, y, bw, bh); float hp = fmaxf(0, fminf(100, getHP(p)));
        if (C.glow) {   // мягкое белое свечение: несколько расширяющихся полупрозрачных обводок с аддитивным смешиванием
            CGPathRef gp = CGPathCreateWithRoundedRect(box, 3, 3, NULL);
            CGContextSaveGState(c); CGContextSetBlendMode(c, kCGBlendModePlusLighter); CGContextSetLineJoin(c, kCGLineJoinRound);
            for (int gi = 0; gi < 4; gi++) {
                CGContextSetRGBStrokeColor(c, glowC.r, glowC.g, glowC.b, 0.16f - gi * 0.035f); CGContextSetLineWidth(c, 4 + gi * 4);
                CGContextAddPath(c, gp); CGContextStrokePath(c);
            }
            CGContextRestoreGState(c); CGPathRelease(gp);
        }
        // подложка, чтобы чёрный конец градиента был виден на тёмном фоне
        CGContextSetStrokeColorWithColor(c, [UIColor colorWithWhite:0.22 alpha:0.7].CGColor); CGContextSetLineWidth(c, 3); CGContextStrokeRect(c, box);
        // рамка с градиентом: снизу чёрный -> сверху белый
        CGContextSaveGState(c); CGContextSetLineWidth(c, 1.2); CGContextAddRect(c, box); CGContextReplacePathWithStrokedPath(c); CGContextClip(c);
        CGContextDrawLinearGradient(c, gBox, CGPointMake(0, y + bh), CGPointMake(0, y), 0); CGContextRestoreGState(c);
        if (C.hpbar) {
        // хп-бар слева: чёрный снизу, белый сверху
        CGFloat bx = x - 6, bwid = 2.5, fh = bh * hp / 100.f;
        CGContextSetFillColorWithColor(c, [UIColor colorWithWhite:0.10 alpha:0.85].CGColor); CGContextFillRect(c, CGRectMake(bx - 1, y - 1, bwid + 2, bh + 2));
        CGContextSaveGState(c); CGContextClipToRect(c, CGRectMake(bx, y + bh - fh, bwid, fh));
        CGContextDrawLinearGradient(c, gBar, CGPointMake(0, y + bh), CGPointMake(0, y), 0); CGContextRestoreGState(c);
        CGContextSetStrokeColorWithColor(c, [UIColor colorWithWhite:0.32 alpha:1].CGColor); CGContextSetLineWidth(c, 1);
        CGContextStrokeRect(c, CGRectMake(bx - 0.5, y - 0.5, bwid + 1, bh + 1));
        // текст: хп у уровня бара, ник над боксом
        NSString *hs = [NSString stringWithFormat:@"%d", (int)hp];
        CGFloat hy2 = fmax(y - 2, fmin(y + bh - 8, y + bh - fh - 4));
        esText(hs, bx - 3 - esWidth(hs, 8), hy2, 8, 1);
        }
        NSString *nk = nickOf(p); if (nk.length > 16) nk = [nk substringToIndex:16];
        esText(nk, x + bw / 2 - esWidth(nk, 9) / 2, y - 13, 9, 1);
    }
    CGGradientRelease(gBox); CGGradientRelease(gBar);
    bc("idle");
}
@end

// ---------------- меню (стиль gamesense, чёрно-белое) ----------------
#define GSC(v) [UIColor colorWithWhite:(v) / 255.0 alpha:1]
static UIFont *gsF(CGFloat s) {
    static NSMutableDictionary<NSNumber *, UIFont *> *cache; if (!cache) cache = [NSMutableDictionary new];
    UIFont *f = cache[@(s)]; if (f) return f;
    f = [UIFont fontWithName:@"Verdana" size:s] ?: [UIFont systemFontOfSize:s]; cache[@(s)] = f; return f;
}

@interface GSCheck : UIView
@property (nonatomic) bool *p; @property (nonatomic, copy) NSString *title;
@end
@implementation GSCheck
- (void)drawRect:(CGRect)r {
    bool on = _p && *_p; CGFloat cy = self.bounds.size.height / 2;
    CGRect box = CGRectMake(0.5, cy - 4.5, 9, 9);
    [GSC(on ? 232 : 20) setFill]; UIRectFill(box);
    UIBezierPath *b = [UIBezierPath bezierPathWithRect:box]; b.lineWidth = 1; [GSC(on ? 255 : 62) setStroke]; [b stroke];
    [_title drawAtPoint:CGPointMake(17, cy - 6.5) withAttributes:@{NSFontAttributeName: gsF(10), NSForegroundColorAttributeName: GSC(on ? 235 : 135)}];
}
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    if (_p && CGRectContainsPoint(self.bounds, [t.anyObject locationInView:self])) { *_p = !*_p; [self setNeedsDisplay]; }
}
@end

@interface GSSlider : UIView
@property (nonatomic) float *p; @property (nonatomic) float mn, mx, step; @property (nonatomic, copy) NSString *title, *fmt;
@end
@implementation GSSlider
- (void)drawRect:(CGRect)r {
    CGFloat W = self.bounds.size.width; float v = _p ? *_p : 0;
    [_title drawAtPoint:CGPointMake(0, 0) withAttributes:@{NSFontAttributeName: gsF(9), NSForegroundColorAttributeName: GSC(150)}];
    NSString *vs = [NSString stringWithFormat:_fmt, (double)v];
    NSDictionary *va = @{NSFontAttributeName: gsF(9), NSForegroundColorAttributeName: GSC(235)};
    [vs drawAtPoint:CGPointMake(W - [vs sizeWithAttributes:va].width, 0) withAttributes:va];
    CGRect bar = CGRectMake(0.5, 15.5, W - 1, 8);
    [GSC(20) setFill]; UIRectFill(bar);
    UIBezierPath *b = [UIBezierPath bezierPathWithRect:bar]; b.lineWidth = 1; [GSC(62) setStroke]; [b stroke];
    CGFloat f = (_mx > _mn) ? (v - _mn) / (_mx - _mn) : 0; f = MAX(0.0, MIN(1.0, f));
    CGFloat fw = (W - 3) * f;
    [GSC(240) setFill]; UIRectFill(CGRectMake(1.5, 16.5, fw, 3));
    [GSC(170) setFill]; UIRectFill(CGRectMake(1.5, 19.5, fw, 3));
}
- (void)applyTouch:(UITouch *)u {
    CGFloat W = self.bounds.size.width; CGFloat f = ([u locationInView:self].x - 1.5) / (W - 3); f = MAX(0.0, MIN(1.0, f));
    float v = _mn + (float)f * (_mx - _mn); if (_step > 0) v = roundf(v / _step) * _step;
    if (_p) *_p = v; [self setNeedsDisplay];
}
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self applyTouch:t.anyObject]; }
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self applyTouch:t.anyObject]; }
@end

@interface GSCombo : UIView
@property (nonatomic) int *p; @property (nonatomic, strong) NSArray<NSString *> *opts; @property (nonatomic, copy) NSString *title;
@end
@implementation GSCombo
- (void)drawRect:(CGRect)r {
    CGFloat W = self.bounds.size.width;
    [_title drawAtPoint:CGPointMake(0, 0) withAttributes:@{NSFontAttributeName: gsF(9), NSForegroundColorAttributeName: GSC(150)}];
    CGRect box = CGRectMake(0.5, 13.5, W - 1, 17);
    [GSC(20) setFill]; UIRectFill(box);
    UIBezierPath *b = [UIBezierPath bezierPathWithRect:box]; b.lineWidth = 1; [GSC(62) setStroke]; [b stroke];
    int i = _p ? *_p : 0; NSString *s = (i >= 0 && i < (int)_opts.count) ? _opts[i] : @"";
    [s drawAtPoint:CGPointMake(6, 16.5) withAttributes:@{NSFontAttributeName: gsF(10), NSForegroundColorAttributeName: GSC(220)}];
    UIBezierPath *a = [UIBezierPath bezierPath];
    [a moveToPoint:CGPointMake(W - 14, 19.5)]; [a addLineToPoint:CGPointMake(W - 6, 19.5)]; [a addLineToPoint:CGPointMake(W - 10, 24.5)]; [a closePath];
    [GSC(150) setFill]; [a fill];
}
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    if (_p && _opts.count && CGRectContainsPoint(self.bounds, [t.anyObject locationInView:self])) { *_p = (*_p + 1) % (int)_opts.count; [self setNeedsDisplay]; }
}
@end

@interface GSBtn : UIView
@property (nonatomic, copy) NSString *title; @property (nonatomic, copy) void (^act)(void);
@end
@implementation GSBtn { BOOL _down; }
- (void)drawRect:(CGRect)r {
    CGRect box = CGRectInset(self.bounds, 0.5, 0.5);
    [GSC(_down ? 45 : 20) setFill]; UIRectFill(box);
    UIBezierPath *b = [UIBezierPath bezierPathWithRect:box]; b.lineWidth = 1; [GSC(70) setStroke]; [b stroke];
    NSDictionary *a = @{NSFontAttributeName: gsF(10), NSForegroundColorAttributeName: GSC(235)};
    CGSize sz = [_title sizeWithAttributes:a];
    [_title drawAtPoint:CGPointMake((self.bounds.size.width - sz.width) / 2, (self.bounds.size.height - sz.height) / 2) withAttributes:a];
}
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { _down = YES; [self setNeedsDisplay]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { _down = NO; [self setNeedsDisplay]; }
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    _down = NO; [self setNeedsDisplay];
    if (_act && CGRectContainsPoint(self.bounds, [t.anyObject locationInView:self])) _act();
}
@end

static UIView *g_panel; static ESPView *g_esp; static UILabel *g_snLabel; static UIView *g_mark; static UILabel *g_markLbl; static CAGradientLayer *g_markGrad;
static int g_linkFrames; static double g_fpsT;
static void markUpdate(int fps) {
    NSMutableAttributedString *s = [NSMutableAttributedString new];
    UIFont *fb = [UIFont fontWithName:@"Verdana-Bold" size:11] ?: gsF(11), *fn = gsF(10);
    void (^add)(NSString *, UIFont *, CGFloat) = ^(NSString *x, UIFont *f, CGFloat w) {
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:x attributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: [UIColor colorWithWhite:w alpha:1]}]];
    };
    add(@"vasya", fb, 0.96); add(@" ware", fb, 0.62); add(@"  |  ", fn, 0.35); add([NSString stringWithFormat:@"%d fps", fps], fn, 0.9);
    g_markLbl.attributedText = s; [g_markLbl sizeToFit];
    CGFloat lw = g_markLbl.frame.size.width, w = lw + 22;
    g_markLbl.frame = CGRectMake(11, 0, lw, 24);
    CGRect f = g_mark.frame; f.size.width = w; g_mark.frame = f; g_markGrad.frame = CGRectMake(0, 0, w, 2);
}
static NSMutableArray<UIView *> *g_pages; static NSMutableArray<UIButton *> *g_tabBtns;
static void selectTab(int idx) {
    for (int i = 0; i < (int)g_pages.count; i++) {
        BOOL on = (i == idx); g_pages[i].hidden = !on;
        UIButton *b = g_tabBtns[i]; b.backgroundColor = on ? GSC(24) : UIColor.clearColor;
        [b setTitleColor:(on ? GSC(245) : GSC(125)) forState:UIControlStateNormal];
        [b viewWithTag:99].hidden = !on;
    }
}
@interface MenuH : NSObject
- (void)tap:(id)b; - (void)tab:(UIButton *)b; - (void)pan:(UIPanGestureRecognizer *)g; - (void)fabPan:(UIPanGestureRecognizer *)g; - (void)markTick:(CADisplayLink *)l;
@end
@implementation MenuH
- (void)tap:(id)b {
    g_panel.hidden = !g_panel.hidden;
    g_mark.layer.borderColor = (g_panel.hidden ? GSC(48) : GSC(235)).CGColor;
}
- (void)markTick:(CADisplayLink *)l {
    g_linkFrames++; double now = CACurrentMediaTime(); if (g_fpsT == 0) g_fpsT = now;
    if (now - g_fpsT >= 0.5) {
        double dt = now - g_fpsT; int gf = g_gameFrames;
        int fps = gf > 0 ? (int)lround(gf / dt) : (int)lround(g_linkFrames / dt);   // фпс игры; если игрока нет, то частота экрана
        g_gameFrames = 0; g_linkFrames = 0; g_fpsT = now; markUpdate(fps);
    }
}
- (void)fabPan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view; CGPoint tr = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + tr.x, v.center.y + tr.y); [g setTranslation:CGPointZero inView:v.superview];
}
- (void)tab:(UIButton *)b { selectTab((int)b.tag); }
- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *sv = g_panel.superview; CGPoint t = [g translationInView:sv];
    g_panel.center = CGPointMake(g_panel.center.x + t.x, g_panel.center.y + t.y); [g setTranslation:CGPointZero inView:sv];
}
@end
static MenuH *g_h;

static UIWindow *keyWin() {
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
        if ([sc isKindOfClass:UIWindowScene.class])
            for (UIWindow *w in ((UIWindowScene *)sc).windows) if (w.isKeyWindow) return w;
    return UIApplication.sharedApplication.windows.firstObject;
}

@interface GSColor : UIView
@property (nonatomic) float *hsv; @property (nonatomic, copy) NSString *title; @property (nonatomic) int active; @property (nonatomic, copy) void (^changed)(void);
@end
@implementation GSColor
- (void)drawRect:(CGRect)r {
    if (!_hsv) return; CGFloat W = self.bounds.size.width, bw = W - 3;
    [_title drawAtPoint:CGPointMake(0, 0) withAttributes:@{NSFontAttributeName: gsF(9), NSForegroundColorAttributeName: GSC(150)}];
    Col cc = hsvCol(_hsv); CGRect sw = CGRectMake(W - 24.5, 0.5, 24, 10);
    [[UIColor colorWithRed:cc.r green:cc.g blue:cc.b alpha:1] setFill]; UIRectFill(sw);
    UIBezierPath *sb = [UIBezierPath bezierPathWithRect:sw]; sb.lineWidth = 1; [GSC(90) setStroke]; [sb stroke];
    for (int i = 0; i < 3; i++) {
        CGFloat by = 14 + i * 9;
        [GSC(20) setFill]; UIRectFill(CGRectMake(0.5, by, W - 1, 8));
        for (CGFloat px = 0; px < bw; px += 2) {
            float f = (float)(px / bw), t[3] = {_hsv[0], _hsv[1], _hsv[2]};
            if (i == 0) { t[0] = f; t[1] = 1; t[2] = 1; } else if (i == 1) { t[1] = f; t[2] = 1; } else { t[2] = f; }
            Col k = hsvCol(t); [[UIColor colorWithRed:k.r green:k.g blue:k.b alpha:1] setFill]; UIRectFill(CGRectMake(1.5 + px, by + 1.5, 2, 5));
        }
        UIBezierPath *b = [UIBezierPath bezierPathWithRect:CGRectMake(0.5, by + 0.5, W - 1, 7)]; b.lineWidth = 1; [GSC(62) setStroke]; [b stroke];
        CGFloat mx = 1.5 + bw * _hsv[i];
        [GSC(0) setFill]; UIRectFill(CGRectMake(mx - 1.5, by, 3, 8)); [GSC(245) setFill]; UIRectFill(CGRectMake(mx - 0.5, by, 1, 8));
    }
}
- (void)applyTouch:(UITouch *)u {
    CGFloat f = ([u locationInView:self].x - 1.5) / (self.bounds.size.width - 3); f = MAX(0.0, MIN(1.0, f));
    if (_hsv) _hsv[_active] = (float)f; [self setNeedsDisplay]; if (_changed) _changed();
}
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    int i = (int)(([t.anyObject locationInView:self].y - 12) / 9); _active = MAX(0, MIN(2, i)); [self applyTouch:t.anyObject];
}
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self applyTouch:t.anyObject]; }
@end
static UIView *gsGroup(UIView *parent, NSString *title, CGFloat y, CGFloat w) {
    UIView *g = [[UIView alloc] initWithFrame:CGRectMake(0, y, w, 40)];
    g.backgroundColor = GSC(13); g.layer.borderColor = GSC(46).CGColor; g.layer.borderWidth = 1;
    UILabel *l = [UILabel new]; l.text = [NSString stringWithFormat:@" %@ ", title.lowercaseString];
    l.font = gsF(9); l.textColor = GSC(235); l.backgroundColor = GSC(10); [l sizeToFit];
    l.frame = CGRectMake(8, -7, l.frame.size.width, 13);
    [g addSubview:l]; [parent addSubview:g]; return g;
}
static CGFloat gsCheck(UIView *g, CGFloat y, const char *nm, bool *p) {
    GSCheck *c = [[GSCheck alloc] initWithFrame:CGRectMake(10, y, g.bounds.size.width - 20, 20)];
    c.backgroundColor = UIColor.clearColor; c.p = p; c.title = [NSString stringWithUTF8String:nm]; [g addSubview:c]; return y + 21;
}
static CGFloat gsSlider(UIView *g, CGFloat y, const char *nm, float *p, float mn, float mx, float step, NSString *fmt) {
    GSSlider *s = [[GSSlider alloc] initWithFrame:CGRectMake(10, y, g.bounds.size.width - 20, 28)];
    s.backgroundColor = UIColor.clearColor; s.p = p; s.mn = mn; s.mx = mx; s.step = step; s.fmt = fmt;
    s.title = [NSString stringWithUTF8String:nm]; [g addSubview:s]; return y + 31;
}
static UIView *g_pop; static float *g_popHSV;
@interface GSSwatch : UIView
@property (nonatomic) float *c1, *c2; @property (nonatomic, weak) UIView *host; @property (nonatomic, copy) NSString *title;
@end
@implementation GSSwatch
- (void)drawRect:(CGRect)r {
    int n = _c2 ? 2 : 1;
    for (int i = 0; i < n; i++) {
        float *h = i == 0 ? _c1 : _c2; Col k = hsvCol(h); CGRect sq = CGRectMake(1.5 + i * 27, 1.5, 24, 10);
        [[UIColor colorWithRed:k.r green:k.g blue:k.b alpha:1] setFill]; UIRectFill(sq);
        UIBezierPath *b = [UIBezierPath bezierPathWithRect:sq]; b.lineWidth = 1; [(g_pop && g_popHSV == h ? GSC(245) : GSC(90)) setStroke]; [b stroke];
    }
}
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    CGPoint p = [t.anyObject locationInView:self]; if (!CGRectContainsPoint(self.bounds, p)) return;
    float *h = (_c2 && p.x > 27) ? _c2 : _c1;
    BOOL same = g_pop && g_popHSV == h;
    [g_pop removeFromSuperview]; g_pop = nil; g_popHSV = NULL;
    if (!same && _host) {
        CGRect row = [self convertRect:self.bounds toView:_host]; CGFloat pw = 220, ph = 54;
        CGFloat x = MIN(_host.bounds.size.width - pw - 2, CGRectGetMaxX(row) - pw), y = CGRectGetMaxY(row) + 3;
        if (y + ph > _host.bounds.size.height) y = CGRectGetMinY(row) - ph - 3;
        UIView *pop = [[UIView alloc] initWithFrame:CGRectMake(x, y, pw, ph)];
        pop.backgroundColor = GSC(17); pop.layer.borderColor = GSC(80).CGColor; pop.layer.borderWidth = 1;
        GSColor *pk = [[GSColor alloc] initWithFrame:CGRectMake(8, 7, pw - 16, 40)]; pk.backgroundColor = UIColor.clearColor; pk.hsv = h;
        pk.title = _c2 ? [NSString stringWithFormat:@"%@ - %@", _title, h == _c1 ? @"color 1 (top)" : @"color 2 (bottom)"] : [NSString stringWithFormat:@"%@ color", _title];
        __weak GSSwatch *ws = self; pk.changed = ^{ [ws setNeedsDisplay]; };
        [pop addSubview:pk]; [_host addSubview:pop]; [_host bringSubviewToFront:pop]; g_pop = pop; g_popHSV = h;
    }
    [self setNeedsDisplay];
}
@end
static void gsSwatch(UIView *g, UIView *host, CGFloat rowY, const char *nm, float *c1, float *c2) {   // квадратики цвета справа в строке
    CGFloat w = c2 ? 54 : 27; GSSwatch *sw = [[GSSwatch alloc] initWithFrame:CGRectMake(g.bounds.size.width - 10 - w, rowY + 4, w, 13)];
    sw.backgroundColor = UIColor.clearColor; sw.c1 = c1; sw.c2 = c2; sw.host = host; sw.title = [NSString stringWithUTF8String:nm]; [g addSubview:sw];
}
static CGFloat gsColor(UIView *g, CGFloat y, const char *nm, float *hsv) {
    GSColor *c = [[GSColor alloc] initWithFrame:CGRectMake(10, y, g.bounds.size.width - 20, 40)];
    c.backgroundColor = UIColor.clearColor; c.hsv = hsv; c.title = [NSString stringWithUTF8String:nm]; [g addSubview:c]; return y + 43;
}
static CGFloat gsCombo(UIView *g, CGFloat y, const char *nm, int *p, NSArray<NSString *> *opts) {
    GSCombo *c = [[GSCombo alloc] initWithFrame:CGRectMake(10, y, g.bounds.size.width - 20, 32)];
    c.backgroundColor = UIColor.clearColor; c.p = p; c.opts = opts; c.title = [NSString stringWithUTF8String:nm]; [g addSubview:c]; return y + 36;
}
static CGFloat gsFit(UIView *g, CGFloat y) {
    CGRect f = g.frame; f.size.height = y + 6; g.frame = f; return CGRectGetMaxY(f) + 12;
}

static void buildUI() {
    UIWindow *w = keyWin(); if (!w) return; g_h = [MenuH new];
    g_esp = [[ESPView alloc] initWithFrame:w.bounds]; g_esp.userInteractionEnabled = NO; g_esp.layer.drawsAsynchronously = YES;
    g_esp.backgroundColor = UIColor.clearColor; g_esp.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [w addSubview:g_esp];
    CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:g_esp selector:@selector(setNeedsDisplay)]; [dl addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

    const CGFloat PW = 430, PH = 282, TAB = 74, HDR = 22, CW = PW - TAB - 14;
    g_panel = [[UIView alloc] initWithFrame:CGRectMake(10, 38, PW, PH)];
    g_panel.backgroundColor = GSC(10); g_panel.layer.borderColor = GSC(48).CGColor; g_panel.layer.borderWidth = 1; g_panel.hidden = YES;
    UIView *inner = [[UIView alloc] initWithFrame:CGRectInset(g_panel.bounds, 3, 3)];
    inner.userInteractionEnabled = NO; inner.layer.borderColor = GSC(26).CGColor; inner.layer.borderWidth = 1; [g_panel addSubview:inner];
    CAGradientLayer *gl = [CAGradientLayer layer]; gl.frame = CGRectMake(1, 1, PW - 2, 2);
    gl.startPoint = CGPointMake(0, 0.5); gl.endPoint = CGPointMake(1, 0.5);
    gl.colors = @[(id)GSC(45).CGColor, (id)GSC(245).CGColor, (id)GSC(45).CGColor]; [g_panel.layer addSublayer:gl];
    UIView *hdr = [[UIView alloc] initWithFrame:CGRectMake(0, 0, PW, HDR)];
    UILabel *ht = [[UILabel alloc] initWithFrame:CGRectMake(12, 7, 200, 12)]; ht.text = @"vasyaware"; ht.font = gsF(9); ht.textColor = GSC(150);
    [hdr addSubview:ht];
    [hdr addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:g_h action:@selector(pan:)]];
    [g_panel addSubview:hdr];

    UIView *tabBg = [[UIView alloc] initWithFrame:CGRectMake(6, HDR + 2, TAB - 6, PH - HDR - 8)];
    tabBg.backgroundColor = GSC(13); tabBg.layer.borderColor = GSC(46).CGColor; tabBg.layer.borderWidth = 1; [g_panel addSubview:tabBg];
    NSArray *names = @[@"RAGE", @"ANTI-AIM", @"VISUALS", @"MISC", @"DEBUG"];
    g_pages = [NSMutableArray new]; g_tabBtns = [NSMutableArray new];
    for (int i = 0; i < (int)names.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom]; b.frame = CGRectMake(7, HDR + 10 + i * 28, TAB - 8, 26); b.tag = i;
        [b setTitle:names[i] forState:UIControlStateNormal]; b.titleLabel.font = gsF(9);
        [b addTarget:g_h action:@selector(tab:) forControlEvents:UIControlEventTouchUpInside];
        UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 2, 26)]; bar.backgroundColor = GSC(245); bar.tag = 99; bar.userInteractionEnabled = NO; [b addSubview:bar];
        [g_panel addSubview:b]; [g_tabBtns addObject:b];
        UIView *pg = [[UIView alloc] initWithFrame:CGRectMake(TAB + 6, HDR + 8, CW, PH - HDR - 16)]; [g_panel addSubview:pg]; [g_pages addObject:pg];
    }

    { // RAGE
        UIView *pg = g_pages[0]; UIView *g = gsGroup(pg, @"aimbot", 8, CW); CGFloat y = 14;
        y = gsCheck(g, y, "Silent Aim 360", &C.silent);
        y = gsCheck(g, y, "Double Tap", &C.dtap);
        y = gsCheck(g, y, "No Spread", &C.nospread);
        gsFit(g, y);
    }
    { // ANTI-AIM
        UIView *pg = g_pages[1]; UIView *g = gsGroup(pg, @"anti-aim", 8, CW); CGFloat y = 14;
        y = gsCheck(g, y, "Enabled", &C.aa);
        y = gsCheck(g, y, "Show on own model (camera stays)", &C.ownAA);
        y = gsCombo(g, y, "Mode", &C.aaMode, @[@"Jitter", @"Spin", @"Static", @"Random"]);
        y = gsSlider(g, y, "Pitch (90 = down)", &C.aaPitch, -90, 90, 5, @"%.0f°");
        y = gsSlider(g, y, "Yaw offset", &C.aaBase, 0, 360, 5, @"%.0f°");
        y = gsSlider(g, y, "Jitter / random range", &C.aaOff, 0, 180, 5, @"%.0f°");
        y = gsSlider(g, y, "Spin speed", &C.aaSpin, 1, 90, 1, @"%.0f°/tick");
        gsFit(g, y);
    }
    { // VISUALS
        UIView *pg = g_pages[2]; UIView *g = gsGroup(pg, @"esp", 8, CW); CGFloat y = 14, y0;
        y0 = y; y = gsCheck(g, y, "ESP box / nick", &C.esp); gsSwatch(g, pg, y0, "Box", C.boxTop, C.boxBot);
        y0 = y; y = gsCheck(g, y, "HP bar", &C.hpbar);       gsSwatch(g, pg, y0, "HP bar", C.barTop, C.barBot);
        y = gsCheck(g, y, "Glow", &C.glow);
        CGFloat ny = gsFit(g, y);
        g = gsGroup(pg, @"world", ny, CW); y = 14;
        y0 = y; y = gsCheck(g, y, "Fog", &C.fog); gsSwatch(g, pg, y0, "Fog", C.fogC, NULL);
        y0 = y; y = gsCheck(g, y, "Sky", &C.sky); gsSwatch(g, pg, y0, "Sky", C.skyC, NULL);
        y = gsCheck(g, y, "Aspect ratio (stretched)", &C.aspectOn);
        y = gsSlider(g, y, "Aspect", &C.aspect, 1.0f, 2.4f, 0.01f, @"%.2f");
        gsFit(g, y);
    }
    { // MISC
        UIView *pg = g_pages[3]; UIView *g = gsGroup(pg, @"movement", 8, CW); CGFloat y = 14;
        y = gsCheck(g, y, "Bhop", &C.bhop);
        y = gsSlider(g, y, "Speed multiplier", &C.bhopMul, 1.0f, 3.0f, 0.05f, @"%.2fx");
        CGFloat ny = gsFit(g, y);
        g = gsGroup(pg, @"feedback", ny, CW); y = 14;
        y = gsCheck(g, y, "Hitmarker", &C.hitm);
        y = gsCheck(g, y, "Hitsound", &C.hitsnd);
        y = gsCheck(g, y, "Killsound", &C.killsnd);
        y = gsCheck(g, y, "Kill message", &C.killmsg);
        y = gsCheck(g, y, "Kill sparks", &C.sparks);
        gsFit(g, y);
    }
    { // DEBUG
        UIView *pg = g_pages[4]; UIView *g = gsGroup(pg, @"photon stream", 8, CW);
        GSBtn *cap = [[GSBtn alloc] initWithFrame:CGRectMake(10, 14, 150, 22)]; cap.backgroundColor = UIColor.clearColor;
        cap.title = @"capture next sync"; cap.act = ^{ g_cap = true; [g_snText setString:@""]; };
        [g addSubview:cap];
        GSBtn *dmp = [[GSBtn alloc] initWithFrame:CGRectMake(170, 14, 150, 22)]; dmp.backgroundColor = UIColor.clearColor;
        dmp.title = @"dump hierarchy"; dmp.act = ^{ dumpHierarchy(); };
        [g addSubview:dmp];
        g_snLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 44, CW - 20, 150)];
        g_snLabel.font = [UIFont fontWithName:@"Menlo" size:8]; g_snLabel.textColor = GSC(190); g_snLabel.numberOfLines = 0;
        g_snLabel.lineBreakMode = NSLineBreakByWordWrapping; g_snLabel.text = @"press capture and wait 1-2 sec";
        [g addSubview:g_snLabel];
        gsFit(g, 44 + 150);
    }

    g_mark = [[UIView alloc] initWithFrame:CGRectMake(10, 10, 150, 24)];
    g_mark.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.92];
    g_mark.layer.cornerRadius = 7; g_mark.layer.masksToBounds = YES;
    g_mark.layer.borderColor = GSC(48).CGColor; g_mark.layer.borderWidth = 1;
    g_markGrad = [CAGradientLayer layer]; g_markGrad.frame = CGRectMake(0, 0, 150, 2);
    g_markGrad.startPoint = CGPointMake(0, 0.5); g_markGrad.endPoint = CGPointMake(1, 0.5);
    g_markGrad.colors = @[(id)GSC(45).CGColor, (id)GSC(245).CGColor, (id)GSC(45).CGColor]; [g_mark.layer addSublayer:g_markGrad];
    g_markLbl = [[UILabel alloc] initWithFrame:CGRectMake(11, 0, 130, 24)]; g_markLbl.userInteractionEnabled = NO; [g_mark addSubview:g_markLbl];
    markUpdate(0);
    [g_mark addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:g_h action:@selector(tap:)]];   // тап по ватермарке открывает меню
    [g_mark addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:g_h action:@selector(fabPan:)]];
    CADisplayLink *ml = [CADisplayLink displayLinkWithTarget:g_h selector:@selector(markTick:)]; [ml addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [w addSubview:g_panel]; [w addSubview:g_mark];
    selectTab(0);
}


// ---------------- диагностика ----------------
static UILabel *g_status;
static NSMutableSet<NSString *> *g_skip;
static int g_okN, g_totN;
static NSMutableString *g_fails;
static NSString *docPath(NSString *n) { return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:n]; }
static void writeState(NSString *t) { [t writeToFile:docPath(@"cm_state.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
static void showStatus(NSString *t) { if (g_status) g_status.text = t; NSLog(@"[CM] %@", t); }
static void report() { showStatus([NSString stringWithFormat:@"patched %d/%d %@", g_okN, g_totN, g_fails.length ? [@"FAIL: " stringByAppendingString:g_fails] : @"ok"]); }
static void fail(const char *tag, NSString *why) { [g_fails appendFormat:@"%s(%@) ", tag, why]; NSLog(@"[CM] FAIL %s: %@", tag, why); }

// подмена methodPointer у MethodInfo (Unity вызывает Update/Start/... через runtime_invoke)
static bool patchMI(const char *tag, void *mi, uintptr_t rva, void *rep) {
    if ([g_skip containsObject:[NSString stringWithUTF8String:tag]]) { NSLog(@"[CM] skip %s", tag); return false; }
    g_totN++;
    if (!mi) { fail(tag, @"no method"); return false; }
    void *cur = *(void **)mi;
    if (rva ? ((uintptr_t)cur != B + rva) : (!cur || (uintptr_t)cur < B || (uintptr_t)cur - B > 0x9000000)) { fail(tag, @"ptr mismatch"); return false; }
    if (origOf(mi)) { g_totN--; return true; }
    writeState([NSString stringWithFormat:@"crash-at:%s", tag]);
    regOrig(mi, cur);
    *(void **)mi = rep;
    g_okN++;
    writeState([NSString stringWithFormat:@"ok:%d/%d last=%s", g_okN, g_totN, tag]);
    return true;
}
// подмена записи в vtable класса (виртуальные и интерфейсные вызовы)
static bool patchVT(const char *tag, void *klass, void *mi, uintptr_t rva, void *rep) {
    if ([g_skip containsObject:[NSString stringWithUTF8String:tag]]) { NSLog(@"[CM] skip %s", tag); return false; }
    g_totN++;
    if (!klass || !mi) { fail(tag, @"no class/method"); return false; }
    uintptr_t want = B + rva, base = (uintptr_t)klass; int n = 0;
    writeState([NSString stringWithFormat:@"crash-at:%s", tag]);
    for (uintptr_t off = 0x100; off < 0x1000; off += 8) {
        uintptr_t *p = (uintptr_t *)(base + off);
        if (p[0] == (uintptr_t)mi && p[-1] == want) {
            if (!origOf(mi)) regOrig(mi, (void *)want);
            p[-1] = (uintptr_t)rep; n++;
        }
    }
    if (!n) { fail(tag, @"vtable entry not found"); return false; }
    g_okN++;
    writeState([NSString stringWithFormat:@"ok:%d/%d last=%s x%d", g_okN, g_totN, tag, n]);
    return true;
}

// ---------------- il2cpp API ----------------
static void *(*il_domain_get)(void);
static void **(*il_domain_get_assemblies)(void *, size_t *);
static void *(*il_assembly_get_image)(void *);
static const char *(*il_image_get_name)(void *);
static uint32_t (*il_image_get_class_count)(void *);
static void *(*il_image_get_class)(void *, uint32_t);
static void *(*il_class_from_name)(void *, const char *, const char *);
static void *(*il_class_get_method)(void *, const char *, int);
static void *(*il_class_get_parent)(void *);

static void *findImage(const char *sub) {
    size_t n = 0; void **as = il_domain_get_assemblies(il_domain_get(), &n);
    for (size_t i = 0; i < n; i++) {
        void *img = il_assembly_get_image(as[i]); const char *nm = img ? il_image_get_name(img) : NULL;
        if (nm && strstr(nm, sub)) return img;
    }
    return NULL;
}

static void *findClassAny(const char *cls) {
    size_t n = 0; void **as = il_domain_get_assemblies(il_domain_get(), &n);
    const char *nss[] = {"Photon.Pun", "", "Photon.Realtime"};
    for (size_t i = 0; i < n; i++) {
        void *img = il_assembly_get_image(as[i]); if (!img) continue;
        for (const char *ns : nss) { void *k = il_class_from_name(img, ns, cls); if (k) return k; }
    }
    return NULL;
}

static void installPatches() {
    void *img = findImage("Assembly-CSharp");
    if (!img) { fail("image", @"Assembly-CSharp not found"); report(); return; }
    void *cm = il_class_from_name(img, "", "CharacterMotor");
    void *dr = il_class_from_name(img, "", "DamageReciver2");
    void *bb = il_class_from_name(img, "", "BaseBulletScript");
    if (!cm || !dr || !bb) { fail("class", @"class not found"); report(); return; }

    patchMI("CM.Start",   il_class_get_method(cm, "Start", 0),     RVA_CM_Start,     (void *)h_Start);      report();
    patchMI("CM.Destroy", il_class_get_method(cm, "OnDestroy", 0), RVA_CM_OnDestroy, (void *)h_Destroy);    report();
    patchMI("CM.Update",  il_class_get_method(cm, "Update", 0),    RVA_CM_Update,    (void *)h_Update);     report();
    g_hasLate = patchMI("CM.Late", il_class_get_method(cm, "LateUpdate", 0), 0, (void *)h_Late); report();
    patchVT("DR.Damage",  dr, il_class_get_method(dr, "Damage", 2), RVA_DR_Damage,   (void *)h_Damage);     report();
    patchVT("CM.Serialize", cm, il_class_get_method(cm, "OnPhotonSerializeView", 2), RVA_CM_Serialize, (void *)h_Ser); report();
    { void *ps = findClassAny("PhotonStream"); patchMI("PS.SendNext", ps ? il_class_get_method(ps, "SendNext", 1) : NULL, RVA_PS_SendNext, (void *)h_SendNext); report(); }

    patchMI("BUL.Update", il_class_get_method(bb, "Update", 0), 0x3DC0188, (void *)h_BulUpdate);
    uint32_t cnt = il_image_get_class_count(img); int sub = 0;
    for (uint32_t i = 0; i < cnt; i++) {
        void *k = il_image_get_class(img, i); void *p = k; bool isB = false;
        for (int d = 0; d < 12 && p; d++) { p = il_class_get_parent(p); if (p == bb) { isB = true; break; } }
        if (!isB) continue;
        void *mi = il_class_get_method(k, "Update", 0);
        if (mi && !origOf(mi)) { char tag[32]; snprintf(tag, sizeof tag, "BUL.sub%d", sub++); patchMI(tag, mi, 0, (void *)h_BulUpdate); }
    }
    report();
}

// ---------------- managed-обёртки (методы Unity берём из метаданных игры) ----------------
static void *coreImg, *camKlass;
static void *(*il_array_new)(void *, uintptr_t);
struct MM { void *fn, *mi; };
static MM m_gtr, m_gpos, m_grot, m_srot, m_look, m_w2s, m_main, m_sw, m_sh, m_fog, m_fogMode, m_fogDens, m_fogCol, m_sky, m_clear, m_bg, m_allCnt, m_getAll, m_enabled, m_targetTex, m_childCnt, m_getChild, m_parent, m_name, m_glrot, m_slrot, m_setAsp, m_resetAsp;
static bool mgd(const char *ns, const char *cls, const char *meth, int argc, MM *out) {
    if (!coreImg) return false;
    void *k = il_class_from_name(coreImg, ns, cls); if (!k) return false;
    void *x = il_class_get_method(k, meth, argc); if (!x) return false;
    out->mi = x; out->fn = *(void **)x; return out->fn != NULL;
}
static void *w_gtr(void *c) { return ((void *(*)(void *, void *))m_gtr.fn)(c, m_gtr.mi); }
static void w_gpos(void *t, Vec3 *o) { *o = ((Vec3 (*)(void *, void *))m_gpos.fn)(t, m_gpos.mi); }
static void w_grot(void *t, Quat *o) { *o = ((Quat (*)(void *, void *))m_grot.fn)(t, m_grot.mi); }
static void w_srot(void *t, Quat *q) { ((void (*)(void *, Quat, void *))m_srot.fn)(t, *q, m_srot.mi); }
static void w_look(Vec3 *f, Vec3 *u, Quat *o) { *o = ((Quat (*)(Vec3, Vec3, void *))m_look.fn)(*f, *u, m_look.mi); }
static void w_w2s(void *cam, Vec3 *p, int eye, Vec3 *o) { *o = ((Vec3 (*)(void *, Vec3, void *))m_w2s.fn)(cam, *p, m_w2s.mi); }
static void *w_main(void) { return ((void *(*)(void *))m_main.fn)(m_main.mi); }
static int w_sw(void) { return ((int (*)(void *))m_sw.fn)(m_sw.mi); }
static int w_sh(void) { return ((int (*)(void *))m_sh.fn)(m_sh.mi); }
static void w_fog(bool b) { ((void (*)(bool, void *))m_fog.fn)(b, m_fog.mi); }
static void w_fogMode(int m) { ((void (*)(int, void *))m_fogMode.fn)(m, m_fogMode.mi); }
static void w_fogDens(float d) { ((void (*)(float, void *))m_fogDens.fn)(d, m_fogDens.mi); }
static void w_fogCol(Col *c) { ((void (*)(Col, void *))m_fogCol.fn)(*c, m_fogCol.mi); }
static void w_sky(void *m) { ((void (*)(void *, void *))m_sky.fn)(m, m_sky.mi); }
static void w_clear(void *cam, int f) { ((void (*)(void *, int, void *))m_clear.fn)(cam, f, m_clear.mi); }
static void w_setAsp(void *cam, float a) { ((void (*)(void *, float, void *))m_setAsp.fn)(cam, a, m_setAsp.mi); }
static void w_resetAsp(void *cam) { ((void (*)(void *, void *))m_resetAsp.fn)(cam, m_resetAsp.mi); }
static void w_bg(void *cam, Col *c) { ((void (*)(void *, Col, void *))m_bg.fn)(cam, *c, m_bg.mi); }

static int w_childCnt(void *t) { return ((int (*)(void *, void *))m_childCnt.fn)(t, m_childCnt.mi); }
static void *w_getChild(void *t, int i) { return ((void *(*)(void *, int, void *))m_getChild.fn)(t, i, m_getChild.mi); }
static void *w_parent(void *t) { return ((void *(*)(void *, void *))m_parent.fn)(t, m_parent.mi); }
static Quat w_glr(void *t) { return ((Quat (*)(void *, void *))m_glrot.fn)(t, m_glrot.mi); }
static void w_slr(void *t, Quat q) { ((void (*)(void *, Quat, void *))m_slrot.fn)(t, q, m_slrot.mi); }
static NSString *objName(void *o) { return (m_name.fn && o) ? il2cppStr(((void *(*)(void *, void *))m_name.fn)(o, m_name.mi)) : @"?"; }

// ---------- хелперы иерархии ----------
static bool ssApiOK() { return m_childCnt.fn && m_getChild.fn && m_glrot.fn && m_slrot.fn && m_parent.fn && Comp_get_tr; }
static bool ssHasCam(void *c, void *camTr) {   // камера лежит внутри этого трансформа?
    void *t = camTr; for (int d = 0; d < 16 && t; d++) { if (t == c) return true; t = w_parent(t); } return false;
}
static bool g_ssActive; static void *g_ssRoot; static void *g_ssKid[16]; static Quat g_ssBase[16]; static int g_ssN;
static double g_ssT; static float g_ownSpin;
static void ssRestore() {
    for (int i = 0; i < g_ssN; i++) if (g_ssKid[i]) w_slr(g_ssKid[i], g_ssBase[i]);
    g_ssActive = false; g_ssN = 0; g_ssRoot = NULL;
}
// показываем на своей модели тот же yaw/pitch, что уходит по сети (камера не крутится)
static void applyOwnAA(void *root) {
    if (!ssApiOK()) return;
    if (!(C.aa && C.ownAA)) { if (g_ssActive) ssRestore(); g_ssT = 0; return; }
    void *rt = Comp_get_tr(root); if (!rt) return;
    double now = CACurrentMediaTime(); float dt = g_ssT > 0 ? (float)(now - g_ssT) : 0; g_ssT = now; if (dt > 0.1f) dt = 0.1f;
    float yaw;
    if (C.aaMode == 1) { g_ownSpin = fmodf(g_ownSpin + C.aaSpin * g_serRate * dt, 360.f); yaw = C.aaBase + g_ownSpin; }   // спин плавно, как у других
    else yaw = g_aaLastYaw;
    int n = w_childCnt(rt); if (n > 16) n = 16; if (n <= 0) return;
    if (g_ssRoot != rt || g_ssN != n) {   // (пере)захват базовых поворотов
        void *nk[16]; Quat nb[16];
        for (int i = 0; i < n; i++) {
            void *c = w_getChild(rt, i); nk[i] = c; nb[i] = c ? w_glr(c) : (Quat){0, 0, 0, 1};
            if (g_ssRoot == rt) for (int j = 0; j < g_ssN; j++) if (g_ssKid[j] == c) nb[i] = g_ssBase[j];
        }
        memcpy(g_ssKid, nk, sizeof(void *) * n); memcpy(g_ssBase, nb, sizeof(Quat) * n); g_ssN = n; g_ssRoot = rt;
    }
    void *cam = pickCamera(); void *camTr = cam ? Comp_get_tr(cam) : NULL;
    float ya = yaw * (float)M_PI / 180.f, pa = C.aaPitch * (float)M_PI / 180.f;
    Quat qy = {0, sinf(ya / 2), 0, cosf(ya / 2)}, qx = {sinf(pa / 2), 0, 0, cosf(pa / 2)};
    for (int i = 0; i < n; i++) {
        void *c = g_ssKid[i]; if (!c) continue;
        if (camTr && ssHasCam(c, camTr)) continue;   // ветку с камерой не трогаем
        w_slr(c, qmul(qy, qmul(g_ssBase[i], qx)));
    }
    g_ssActive = true;
}
static void dumpHierarchy() {
    [g_snText setString:@""];
    if (!g_local || !ssApiOK()) { [g_snText appendString:@"no local player or Transform API missing"]; return; }
    void *rt = Comp_get_tr(g_local); void *cam = pickCamera(); void *camTr = cam ? Comp_get_tr(cam) : NULL;
    int n = w_childCnt(rt);
    [g_snText appendFormat:@"root=%@ kids=%d cam=%d camInRoot=%d\n", objName(rt), n, camTr != NULL, camTr && ssHasCam(rt, camTr)];
    for (int i = 0; i < n && i < 16; i++) {
        void *c = w_getChild(rt, i);
        [g_snText appendFormat:@"%d:%@ cam=%d  |  ", i, objName(c), camTr && c && ssHasCam(c, camTr)];
    }
}

static void *pickCamera() {
    static void *cached; static double cachedT;
    void *c = Cam_main ? Cam_main() : NULL; if (c) return c;
    double now = CACurrentMediaTime();
    if (cached && now - cachedT < 0.5) return cached;
    cachedT = now; cached = NULL;
    if (!m_allCnt.fn || !m_getAll.fn || !il_array_new || !camKlass) return NULL;
    int n = ((int (*)(void *))m_allCnt.fn)(m_allCnt.mi); if (n <= 0 || n > 16) return NULL;
    void *arr = il_array_new(camKlass, n); if (!arr) return NULL;
    ((int (*)(void *, void *))m_getAll.fn)(arr, m_getAll.mi);
    for (int i = 0; i < n; i++) {
        void *cam = ((void **)((uintptr_t)arr + 0x20))[i]; if (!cam) continue;
        bool en = m_enabled.fn ? ((bool (*)(void *, void *))m_enabled.fn)(cam, m_enabled.mi) : true;
        void *tt = m_targetTex.fn ? ((void *(*)(void *, void *))m_targetTex.fn)(cam, m_targetTex.mi) : NULL;
        if (en && !tt) { cached = cam; break; }
    }
    return cached;
}

// ---------------- инициализация ----------------
static void setup() {
    B = getBase("UnityFramework");
    void *h = dlopen(NULL, RTLD_NOW);
#define SYM(v, n) v = (decltype(v))dlsym(h, n)
    SYM(resolve_icall, "il2cpp_resolve_icall");
    SYM(il_domain_get, "il2cpp_domain_get"); SYM(il_domain_get_assemblies, "il2cpp_domain_get_assemblies");
    SYM(il_assembly_get_image, "il2cpp_assembly_get_image"); SYM(il_image_get_name, "il2cpp_image_get_name");
    SYM(il_image_get_class_count, "il2cpp_image_get_class_count"); SYM(il_image_get_class, "il2cpp_image_get_class");
    SYM(il_class_from_name, "il2cpp_class_from_name"); SYM(il_class_get_method, "il2cpp_class_get_method_from_name");
    SYM(il_class_get_parent, "il2cpp_class_get_parent");
    SYM(il2cpp_object_get_class, "il2cpp_object_get_class"); SYM(il2cpp_class_get_name, "il2cpp_class_get_name");
    if (!B || !resolve_icall || !il_domain_get) {
        NSLog(@"[CM] base/il2cpp api not found, retry");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ setup(); });
        return;
    }
    g_players = [NSMutableSet new]; g_fails = [NSMutableString new]; g_snText = [NSMutableString new]; g_aliveMap = [NSMutableDictionary new]; initSounds();
    coreImg = findImage("UnityEngine.CoreModule");
    SYM(il_array_new, "il2cpp_array_new");
    camKlass = coreImg ? il_class_from_name(coreImg, "UnityEngine", "Camera") : NULL;
    NSMutableString *api = [NSMutableString stringWithFormat:@"core:%d ", coreImg != NULL];
#define API(var, wrapper, mm, ns, cls, meth, argc, icname, tag) \
    do { if (mgd(ns, cls, meth, argc, &mm)) { var = (decltype(var))wrapper; [api appendString:@tag ":M "]; } \
         else { ICALL(var, icname); [api appendString:var ? @tag ":i " : @tag ":X "]; } } while (0)
    API(Cam_main,    w_main,   m_main,    "UnityEngine", "Camera",         "get_main", 0, "UnityEngine.Camera::get_main()", "main");
    API(Comp_get_tr, w_gtr,    m_gtr,     "UnityEngine", "Component",      "get_transform", 0, "UnityEngine.Component::get_transform()", "tr");
    API(Tr_get_pos,  w_gpos,   m_gpos,    "UnityEngine", "Transform",      "get_position", 0, "UnityEngine.Transform::get_position_Injected(UnityEngine.Vector3&)", "pos");
    API(Tr_get_rot,  w_grot,   m_grot,    "UnityEngine", "Transform",      "get_rotation", 0, "UnityEngine.Transform::get_rotation_Injected(UnityEngine.Quaternion&)", "rot");
    API(Tr_set_rot,  w_srot,   m_srot,    "UnityEngine", "Transform",      "set_rotation", 1, "UnityEngine.Transform::set_rotation_Injected(UnityEngine.Quaternion&)", "srot");
    API(Quat_Look,   w_look,   m_look,    "UnityEngine", "Quaternion",     "LookRotation", 2, "UnityEngine.Quaternion::LookRotation_Injected(UnityEngine.Vector3&,UnityEngine.Vector3&,UnityEngine.Quaternion&)", "look");
    API(Cam_w2s,     w_w2s,    m_w2s,     "UnityEngine", "Camera",         "WorldToScreenPoint", 1, "UnityEngine.Camera::WorldToScreenPoint_Injected(UnityEngine.Vector3&,UnityEngine.Camera/MonoOrStereoscopicEye,UnityEngine.Vector3&)", "w2s");
    API(Scr_w,       w_sw,     m_sw,      "UnityEngine", "Screen",         "get_width", 0, "UnityEngine.Screen::get_width()", "sw");
    API(Scr_h,       w_sh,     m_sh,      "UnityEngine", "Screen",         "get_height", 0, "UnityEngine.Screen::get_height()", "sh");
    API(RS_fog,      w_fog,    m_fog,     "UnityEngine", "RenderSettings", "set_fog", 1, "UnityEngine.RenderSettings::set_fog(System.Boolean)", "fog");
    API(RS_fogMode,  w_fogMode,m_fogMode, "UnityEngine", "RenderSettings", "set_fogMode", 1, "UnityEngine.RenderSettings::set_fogMode(UnityEngine.FogMode)", "fmode");
    API(RS_fogDens,  w_fogDens,m_fogDens, "UnityEngine", "RenderSettings", "set_fogDensity", 1, "UnityEngine.RenderSettings::set_fogDensity(System.Single)", "fdens");
    API(RS_fogCol,   w_fogCol, m_fogCol,  "UnityEngine", "RenderSettings", "set_fogColor", 1, "UnityEngine.RenderSettings::set_fogColor_Injected(UnityEngine.Color&)", "fcol");
    API(RS_skybox,   w_sky,    m_sky,     "UnityEngine", "RenderSettings", "set_skybox", 1, "UnityEngine.RenderSettings::set_skybox(UnityEngine.Material)", "sky");
    API(Cam_clear,   w_clear,  m_clear,   "UnityEngine", "Camera",         "set_clearFlags", 1, "UnityEngine.Camera::set_clearFlags(UnityEngine.CameraClearFlags)", "clr");
    API(Cam_bg,      w_bg,     m_bg,      "UnityEngine", "Camera",         "set_backgroundColor", 1, "UnityEngine.Camera::set_backgroundColor_Injected(UnityEngine.Color&)", "bg");
    API(Cam_setAsp,  w_setAsp, m_setAsp,  "UnityEngine", "Camera",         "set_aspect", 1, "UnityEngine.Camera::set_aspect(System.Single)", "asp");
    API(Cam_resetAsp,w_resetAsp,m_resetAsp,"UnityEngine","Camera",         "ResetAspect", 0, "UnityEngine.Camera::ResetAspect()", "rasp");
    mgd("UnityEngine", "Camera", "get_allCamerasCount", 0, &m_allCnt);
    mgd("UnityEngine", "Camera", "GetAllCameras", 1, &m_getAll);
    mgd("UnityEngine", "Behaviour", "get_enabled", 0, &m_enabled);
    mgd("UnityEngine", "Camera", "get_targetTexture", 0, &m_targetTex);
    mgd("UnityEngine", "Transform", "get_childCount", 0, &m_childCnt);
    mgd("UnityEngine", "Transform", "GetChild", 1, &m_getChild);
    mgd("UnityEngine", "Transform", "get_parent", 0, &m_parent);
    mgd("UnityEngine", "Object", "get_name", 0, &m_name);
    mgd("UnityEngine", "Transform", "get_localRotation", 0, &m_glrot);
    mgd("UnityEngine", "Transform", "set_localRotation", 1, &m_slrot);
    NSLog(@"[CM] api %@", api);

    NSString *prevBc = [[NSString stringWithContentsOfFile:docPath(@"cm_bc.txt") encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    g_bcFd = open([docPath(@"cm_bc.txt") fileSystemRepresentation], O_RDWR | O_CREAT, 0644);
    NSString *prev = [NSString stringWithContentsOfFile:docPath(@"cm_state.txt") encoding:NSUTF8StringEncoding error:nil];
    g_skip = [NSMutableSet set];
    for (NSString *l in [[NSString stringWithContentsOfFile:docPath(@"cm_skip.txt") encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"])
        if (l.length) [g_skip addObject:l];
    if ([prev hasPrefix:@"crash-at:"]) {
        [g_skip addObject:[prev substringFromIndex:9]];
        [[g_skip.allObjects componentsJoinedByString:@"\n"] writeToFile:docPath(@"cm_skip.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    buildUI();
    UIWindow *w = keyWin();
    g_status = [[UILabel alloc] initWithFrame:CGRectMake(60, w.bounds.size.height - 48, 330, 16)];
    g_status.textColor = UIColor.yellowColor; g_status.font = [UIFont boldSystemFontOfSize:11]; g_status.userInteractionEnabled = NO;
    if (prev.length) showStatus([NSString stringWithFormat:@"prev: %@ | bc: %@ | skip: %@", prev, prevBc, [g_skip.allObjects componentsJoinedByString:@","]]);
    UILabel *dbg = [[UILabel alloc] initWithFrame:CGRectMake(60, w.bounds.size.height - 32, 420, 30)];
    dbg.textColor = UIColor.cyanColor; dbg.font = [UIFont boldSystemFontOfSize:10]; dbg.numberOfLines = 3; dbg.userInteractionEnabled = NO;
    dbg.text = api;
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        NSUInteger np; @synchronized (g_players) { np = g_players.count; }
        if (g_snLabel) g_snLabel.text = g_snText.length ? g_snText : @"press capture and wait 1-2 sec";
        dbg.text = [NSString stringWithFormat:@"%@\ncam=%d local=%d players=%lu target=%d", api, pickCamera() != NULL, g_local != NULL, (unsigned long)np, g_hasTarget];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ installPatches(); });
}

__attribute__((constructor)) static void init() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ setup(); });
}
