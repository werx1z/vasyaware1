// ChickenMenu - HvH для закрытого лобби. Все офсеты из dump.cs ТВОЕЙ версии игры.
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <math.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>

struct Vec3 { float x, y, z; };
struct Quat { float x, y, z, w; };
struct Col  { float r, g, b, a; };

// ---------------- настройки ----------------
static struct {
    bool fog = true, sky = true, hitm = true, hitsnd = true, killsnd = true, esp = true;
    bool silent = true, nospread = true, dtap = true, bhop = true, aa = false;
    float bhopMul = 1.25f;   // множитель SpeedValue
    float aaOff   = 90.f;    // jitter +-
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
static double g_hitTime;

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
static void h_Start(void *self, void *mi) {
    fn_v_t o = (fn_v_t)origOf(mi); if (o) o(self, mi);
    @synchronized (g_players) { [g_players addObject:@((uintptr_t)self)]; }
    if (isMine(self)) g_local = self;
}
static void h_Destroy(void *self, void *mi) {
    @synchronized (g_players) { [g_players removeObject:@((uintptr_t)self)]; }
    if (g_local == self) g_local = NULL;
    fn_v_t o = (fn_v_t)origOf(mi); if (o) o(self, mi);
}

static void applyVisuals() {
    if (C.fog && RS_fog && RS_fogCol && RS_fogMode && RS_fogDens) { Col k = {0, 0, 0, 1}; RS_fog(true); RS_fogCol(&k); RS_fogMode(2); RS_fogDens(0.1f); }
    if (C.sky && Cam_main && Cam_clear && Cam_bg) {
        if (RS_skybox) RS_skybox(NULL);
        void *cam = Cam_main(); Col k = {0, 0, 0, 1};
        if (cam) { Cam_clear(cam, 2); Cam_bg(cam, &k); }
    }
}

static float g_baseSpeed, g_lastShoot; static int g_lastFrags = -1; static double g_dtT; static int g_dtLog;
static void h_Update(void *self, void *mi) {
    fn_v_t o = (fn_v_t)origOf(mi); if (o) o(self, mi);
    if (!g_local && isMine(self)) g_local = self;
    if (self != g_local) return;
    updateTarget(); applyVisuals();

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
    if (g_lastFrags >= 0 && fc > g_lastFrags && C.killsnd) AudioServicesPlaySystemSound(1025);
    g_lastFrags = fc;

    // bhop
    if (C.bhop) {
        float *sp = (float *)((uintptr_t)self + OFF_CM_Speed);
        if (g_baseSpeed == 0) g_baseSpeed = *sp;
        *sp = g_baseSpeed * C.bhopMul;
        if (FN(RVA_CM_IsGrounded, bool, void *, void *)(self, NULL)) FN(RVA_CM_Jump, void, void *, void *)(self, NULL);
    } else if (g_baseSpeed != 0) { *(float *)((uintptr_t)self + OFF_CM_Speed) = g_baseSpeed; }
}

// silent aim на самой пуле (Update у BaseBulletScript и подклассов)
static int g_bulLog;
static void h_BulUpdate(void *self, void *mi) {
    if (g_local && C.silent && g_hasTarget) {
        bool orig = *(bool *)((uintptr_t)self + OFF_BUL_Orig);
        int owner = *(int *)((uintptr_t)self + OFF_BUL_Owner);
        float life = *(float *)((uintptr_t)self + OFF_BUL_Life);
        if (orig && life < 0.05f && owner == viewID(g_local)) {
            Vec3 *dir = (Vec3 *)((uintptr_t)self + OFF_BUL_Dir);
            if (g_bulLog < 10) { g_bulLog++; NSLog(@"[BUL] owner=%d dir=%f %f %f", owner, dir->x, dir->y, dir->z); }
            void *tr = *(void **)((uintptr_t)self + OFF_BUL_Tr);
            if (tr && Tr_get_pos) {
                Vec3 p; Tr_get_pos(tr, &p);
                Vec3 d = {g_aim.x - p.x, g_aim.y - p.y, g_aim.z - p.z};
                float l = sqrtf(d.x*d.x + d.y*d.y + d.z*d.z);
                if (l > 0.001f) {
                    d.x /= l; d.y /= l; d.z /= l; *dir = d;
                    if (Quat_Look && Tr_set_rot) { Vec3 up = {0, 1, 0}; Quat q; Quat_Look(&d, &up, &q); Tr_set_rot(tr, &q); }
                }
            }
        }
    }
    fn_v_t o = (fn_v_t)origOf(mi); if (o) o(self, mi);
}

// хитмаркер / хитсаунд (DamageReciver2.Damage, vtable)
static int g_dmgLog;
static void h_Damage(void *self, float dmg, int from, void *mi) {
    fn_dmg_t o = (fn_dmg_t)origOf(mi); if (o) o(self, dmg, from, mi);
    if (g_dmgLog < 15) { g_dmgLog++; NSLog(@"[HIT] dmg=%f from=%d local=%d", dmg, from, g_local ? viewID(g_local) : -1); }
    if (g_local && from == viewID(g_local)) {
        g_hitTime = CACurrentMediaTime();
        if (C.hitsnd) AudioServicesPlaySystemSound(1057);
    }
}

// anti-aim: на время сериализации поворачиваем трансформ, потом возвращаем
static int g_aaTick;
static void h_Ser(void *self, void *stream, void *info, void *mi) {
    fn_ser_t o = (fn_ser_t)origOf(mi);
    void *tr = NULL; Quat saved = {0, 0, 0, 1};
    if (C.aa && self == g_local && stream && *(bool *)((uintptr_t)stream + OFF_PS_Writing) && Comp_get_tr && Tr_get_rot && Tr_set_rot) {
        tr = Comp_get_tr(self);
        if (tr) {
            Tr_get_rot(tr, &saved); g_aaTick++;
            float a = ((g_aaTick & 1) ? C.aaOff : -C.aaOff) * (float)M_PI / 180.f;
            Quat qy = {0, sinf(a / 2), 0, cosf(a / 2)}; Quat q = qmul(qy, saved);
            Tr_set_rot(tr, &q);
        }
    }
    if (o) o(self, stream, info, mi);
    if (tr) Tr_set_rot(tr, &saved);
}

// ---------------- ESP ----------------
@interface ESPView : UIView @end
@implementation ESPView
- (void)drawRect:(CGRect)r {
    CGContextRef c = UIGraphicsGetCurrentContext(); CGSize S = self.bounds.size;
    if (C.hitm && CACurrentMediaTime() - g_hitTime < 0.25) {
        CGFloat cx = S.width / 2, cy = S.height / 2, a = 8, b = 20;
        CGContextSetStrokeColorWithColor(c, UIColor.whiteColor.CGColor); CGContextSetLineWidth(c, 2);
        for (int sx = -1; sx <= 1; sx += 2) for (int sy = -1; sy <= 1; sy += 2) {
            CGContextMoveToPoint(c, cx + sx * a, cy + sy * a); CGContextAddLineToPoint(c, cx + sx * b, cy + sy * b);
        }
        CGContextStrokePath(c);
    }
    if (!C.esp || !g_local || !Cam_main || !Cam_w2s) return;
    void *cam = Cam_main(); if (!cam) return;
    float sw = Scr_w(), sh = Scr_h(); if (sw < 1 || sh < 1) return;
    NSArray *all; @synchronized (g_players) { all = g_players.allObjects; }
    for (NSNumber *n in all) {
        void *p = (void *)n.unsignedLongValue; if (p == g_local || !alive(p)) continue;
        Vec3 f = posOf(p), h = f; h.y += C.headH * scaleOf(p) * 1.15f;
        Vec3 sf, shd; Cam_w2s(cam, &f, 2, &sf); Cam_w2s(cam, &h, 2, &shd);
        if (sf.z <= 0 || shd.z <= 0) continue;
        CGFloat fx = sf.x / sw * S.width,  fy = (1 - sf.y / sh) * S.height;
        CGFloat hx = shd.x / sw * S.width, hy = (1 - shd.y / sh) * S.height;
        CGFloat bh = fabs(fy - hy), bw = bh * 0.6, x = (fx + hx) / 2 - bw / 2, y = MIN(fy, hy);
        float hp = getHP(p); UIColor *col = hp > 50 ? UIColor.greenColor : (hp > 25 ? UIColor.yellowColor : UIColor.redColor);
        CGContextSetStrokeColorWithColor(c, col.CGColor); CGContextSetLineWidth(c, 1.5);
        CGContextStrokeRect(c, CGRectMake(x, y, bw, bh));
        NSString *t = [NSString stringWithFormat:@"%@  %d", nickOf(p), (int)hp];
        [t drawAtPoint:CGPointMake(x, y - 13) withAttributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:10], NSForegroundColorAttributeName: UIColor.whiteColor}];
    }
}
@end

// ---------------- меню ----------------
struct Item { const char *name; bool *p; };
static Item items[] = {
    {"Silent Aim 360", &C.silent}, {"Double Tap", &C.dtap}, {"No Spread", &C.nospread},
    {"Bhop", &C.bhop}, {"Anti-Aim jitter", &C.aa}, {"ESP", &C.esp},
    {"Black fog", &C.fog}, {"Black sky", &C.sky}, {"Hitmarker", &C.hitm},
    {"Hitsound", &C.hitsnd}, {"Killsound", &C.killsnd},
};
@interface MenuH : NSObject
- (void)tg:(UISwitch *)s; - (void)tap:(UIButton *)b;
@end
static UIView *g_panel;
@implementation MenuH
- (void)tg:(UISwitch *)s { *items[s.tag].p = s.on; }
- (void)tap:(UIButton *)b { g_panel.hidden = !g_panel.hidden; }
@end
static MenuH *g_h;
static ESPView *g_esp;

static UIWindow *keyWin() {
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
        if ([sc isKindOfClass:UIWindowScene.class])
            for (UIWindow *w in ((UIWindowScene *)sc).windows) if (w.isKeyWindow) return w;
    return UIApplication.sharedApplication.windows.firstObject;
}
static void buildUI() {
    UIWindow *w = keyWin(); if (!w) return; g_h = [MenuH new];
    g_esp = [[ESPView alloc] initWithFrame:w.bounds]; g_esp.userInteractionEnabled = NO;
    g_esp.backgroundColor = UIColor.clearColor; g_esp.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [w addSubview:g_esp];
    CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:g_esp selector:@selector(setNeedsDisplay)]; [dl addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    int n = sizeof(items) / sizeof(items[0]);
    g_panel = [[UIView alloc] initWithFrame:CGRectMake(10, 60, 210, 12 + n * 34)];
    g_panel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75]; g_panel.layer.cornerRadius = 10; g_panel.hidden = YES;
    for (int i = 0; i < n; i++) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(10, 8 + i * 34, 120, 30)];
        l.text = [NSString stringWithUTF8String:items[i].name]; l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:13];
        UISwitch *s = [[UISwitch alloc] initWithFrame:CGRectMake(145, 8 + i * 34, 51, 31)];
        s.transform = CGAffineTransformMakeScale(0.75, 0.75); s.on = *items[i].p; s.tag = i;
        [s addTarget:g_h action:@selector(tg:) forControlEvents:UIControlEventValueChanged];
        [g_panel addSubview:l]; [g_panel addSubview:s];
    }
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem]; b.frame = CGRectMake(10, 15, 40, 40);
    [b setTitle:@"M" forState:UIControlStateNormal]; b.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    b.layer.cornerRadius = 20; [b addTarget:g_h action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
    [w addSubview:g_panel]; [w addSubview:b];
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

static void *findImage() {
    size_t n = 0; void **as = il_domain_get_assemblies(il_domain_get(), &n);
    for (size_t i = 0; i < n; i++) {
        void *img = il_assembly_get_image(as[i]); const char *nm = img ? il_image_get_name(img) : NULL;
        if (nm && strstr(nm, "Assembly-CSharp")) return img;
    }
    return NULL;
}

static void installPatches() {
    void *img = findImage();
    if (!img) { fail("image", @"Assembly-CSharp not found"); report(); return; }
    void *cm = il_class_from_name(img, "", "CharacterMotor");
    void *dr = il_class_from_name(img, "", "DamageReciver2");
    void *bb = il_class_from_name(img, "", "BaseBulletScript");
    if (!cm || !dr || !bb) { fail("class", @"class not found"); report(); return; }

    patchMI("CM.Start",   il_class_get_method(cm, "Start", 0),     RVA_CM_Start,     (void *)h_Start);      report();
    patchMI("CM.Destroy", il_class_get_method(cm, "OnDestroy", 0), RVA_CM_OnDestroy, (void *)h_Destroy);    report();
    patchMI("CM.Update",  il_class_get_method(cm, "Update", 0),    RVA_CM_Update,    (void *)h_Update);     report();
    patchVT("DR.Damage",  dr, il_class_get_method(dr, "Damage", 2), RVA_DR_Damage,   (void *)h_Damage);     report();
    patchVT("CM.Serialize", cm, il_class_get_method(cm, "OnPhotonSerializeView", 2), RVA_CM_Serialize, (void *)h_Ser); report();

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
    if (!B || !resolve_icall || !il_domain_get) {
        NSLog(@"[CM] base/il2cpp api not found, retry");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ setup(); });
        return;
    }
    g_players = [NSMutableSet new]; g_fails = [NSMutableString new];
    ICALL(Cam_main,   "UnityEngine.Camera::get_main()");
    ICALL(Comp_get_tr,"UnityEngine.Component::get_transform()");
    ICALL(Tr_get_pos, "UnityEngine.Transform::get_position_Injected(UnityEngine.Vector3&)");
    ICALL(Tr_get_rot, "UnityEngine.Transform::get_rotation_Injected(UnityEngine.Quaternion&)");
    ICALL(Tr_set_rot, "UnityEngine.Transform::set_rotation_Injected(UnityEngine.Quaternion&)");
    ICALL(Quat_Look,  "UnityEngine.Quaternion::LookRotation_Injected(UnityEngine.Vector3&,UnityEngine.Vector3&,UnityEngine.Quaternion&)");
    ICALL(Cam_w2s,    "UnityEngine.Camera::WorldToScreenPoint_Injected(UnityEngine.Vector3&,UnityEngine.Camera/MonoOrStereoscopicEye,UnityEngine.Vector3&)");
    ICALL(Scr_w,      "UnityEngine.Screen::get_width()");
    ICALL(Scr_h,      "UnityEngine.Screen::get_height()");
    ICALL(RS_fog,     "UnityEngine.RenderSettings::set_fog(System.Boolean)");
    ICALL(RS_fogMode, "UnityEngine.RenderSettings::set_fogMode(UnityEngine.FogMode)");
    ICALL(RS_fogDens, "UnityEngine.RenderSettings::set_fogDensity(System.Single)");
    ICALL(RS_fogCol,  "UnityEngine.RenderSettings::set_fogColor_Injected(UnityEngine.Color&)");
    ICALL(RS_skybox,  "UnityEngine.RenderSettings::set_skybox(UnityEngine.Material)");
    ICALL(Cam_clear,  "UnityEngine.Camera::set_clearFlags(UnityEngine.CameraClearFlags)");
    ICALL(Cam_bg,     "UnityEngine.Camera::set_backgroundColor_Injected(UnityEngine.Color&)");
    NSLog(@"[CM] icall main=%p tr=%p pos=%p rot=%p w2s=%p fog=%p sky=%p clear=%p look=%p", Cam_main, Comp_get_tr, Tr_get_pos, Tr_get_rot, Cam_w2s, RS_fog, RS_skybox, Cam_clear, Quat_Look);

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
    g_status = [[UILabel alloc] initWithFrame:CGRectMake(60, 22, 330, 30)];
    g_status.textColor = UIColor.yellowColor; g_status.font = [UIFont boldSystemFontOfSize:11]; g_status.userInteractionEnabled = NO;
    [w addSubview:g_status];
    if (prev.length) showStatus([NSString stringWithFormat:@"prev: %@ | skip: %@", prev, [g_skip.allObjects componentsJoinedByString:@","]]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ installPatches(); });
}

__attribute__((constructor)) static void init() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ setup(); });
}
