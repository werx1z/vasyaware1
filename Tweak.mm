// ChickenMenu - HvH для закрытого лобби. Все офсеты из dump.cs ТВОЕЙ версии игры.
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <math.h>
#include <string.h>
#if __has_include(<dobby.h>)
#include <dobby.h>
#define HOOKRAW(a, r, o) DobbyHook((void *)(a), (dobby_dummy_func_t)(r), (dobby_dummy_func_t *)(o))
#else
#include <substrate.h>
#define HOOKRAW(a, r, o) (MSHookFunction((void *)(a), (void *)(r), (void **)(o)), 0)
#endif

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
static int YAW_IDX = -1;     // индекс yaw в SendNext. -1 = только лог. Определи по логу [AA]

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

// ---------------- хуки ----------------
static void (*o_Start)(void *, void *);
static void h_Start(void *self, void *mi) {
    o_Start(self, mi);
    @synchronized (g_players) { [g_players addObject:@((uintptr_t)self)]; }
    if (isMine(self)) g_local = self;
}
static void (*o_Destroy)(void *, void *);
static void h_Destroy(void *self, void *mi) {
    @synchronized (g_players) { [g_players removeObject:@((uintptr_t)self)]; }
    if (g_local == self) g_local = NULL;
    o_Destroy(self, mi);
}

static void applyVisuals() {
    if (C.fog && RS_fog) { Col k = {0, 0, 0, 1}; RS_fog(true); RS_fogCol(&k); RS_fogMode(2); RS_fogDens(0.1f); }
    if (C.sky && Cam_main) {
        if (RS_skybox) RS_skybox(NULL);
        void *cam = Cam_main(); Col k = {0, 0, 0, 1};
        if (cam) { Cam_clear(cam, 2); Cam_bg(cam, &k); }
    }
}

static float g_baseSpeed;
static void (*o_Update)(void *, void *);
static void h_Update(void *self, void *mi) {
    o_Update(self, mi);
    if (!g_local && isMine(self)) g_local = self;
    if (self != g_local) return;
    updateTarget(); applyVisuals();
    if (C.bhop) {
        float *sp = (float *)((uintptr_t)self + OFF_CM_Speed);
        if (g_baseSpeed == 0) g_baseSpeed = *sp;
        *sp = g_baseSpeed * C.bhopMul;
        if (FN(RVA_CM_IsGrounded, bool, void *, void *)(self, NULL)) FN(RVA_CM_Jump, void, void *, void *)(self, NULL);
    } else if (g_baseSpeed != 0) { *(float *)((uintptr_t)self + OFF_CM_Speed) = g_baseSpeed; }
}

static void prepareShot(void *motor) {
    void *pwm = *(void **)((uintptr_t)motor + OFF_CM_PWM); if (!pwm) return;
    void *w = *(void **)((uintptr_t)pwm + OFF_PWM_Weapon); if (!w) return;
    if (C.nospread) {
        void *gi = *(void **)((uintptr_t)w + OFF_W_GunInfo);
        if (gi) { Vec3 *e = (Vec3 *)((uintptr_t)gi + OFF_GI_ErrDelta); e->x = e->y = e->z = 0; }
    }
    if (C.silent && g_hasTarget) *(Vec3 *)((uintptr_t)pwm + OFF_PWM_Target) = g_aim;
}
static void (*o_Push)(void *, void *);
static void h_Push(void *self, void *mi) {
    if (self != g_local) { o_Push(self, mi); return; }
    prepareShot(self); o_Push(self, mi);
    if (C.dtap) {
        void *pwm = *(void **)((uintptr_t)self + OFF_CM_PWM);
        void *w = pwm ? *(void **)((uintptr_t)pwm + OFF_PWM_Weapon) : NULL;
        if (w && *(int *)((uintptr_t)w + OFF_W_Ammo) > 0) { prepareShot(self); o_Push(self, mi); }
    }
}

// silent aim на самой пуле
static int g_bulLog;
static void (*o_UpdPos)(void *, void *);
static void h_UpdPos(void *self, void *mi) {
    if (g_local) {
        bool orig = *(bool *)((uintptr_t)self + OFF_BUL_Orig);
        int owner = *(int *)((uintptr_t)self + OFF_BUL_Owner);
        float life = *(float *)((uintptr_t)self + OFF_BUL_Life);
        if (orig && life < 0.05f && owner == viewID(g_local)) {
            Vec3 *dir = (Vec3 *)((uintptr_t)self + OFF_BUL_Dir);
            if (g_bulLog < 10) { g_bulLog++; NSLog(@"[BUL] owner=%d dir=%f %f %f", owner, dir->x, dir->y, dir->z); }
            void *tr = *(void **)((uintptr_t)self + OFF_BUL_Tr);
            if (C.silent && g_hasTarget && tr && Tr_get_pos) {
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
    o_UpdPos(self, mi);
}

// хитмаркер / звуки
static int g_dmgLog;
static void (*o_Damage)(void *, float, int, void *);
static void h_Damage(void *self, float dmg, int from, void *mi) {
    o_Damage(self, dmg, from, mi);
    if (g_dmgLog < 15) { g_dmgLog++; NSLog(@"[HIT] dmg=%f from=%d local=%d", dmg, from, g_local ? viewID(g_local) : -1); }
    if (g_local && from == viewID(g_local)) {
        g_hitTime = CACurrentMediaTime();
        if (C.hitsnd) AudioServicesPlaySystemSound(1057);
    }
}
static void (*o_Kill)(void *, void *);
static void h_Kill(void *self, void *mi) {
    o_Kill(self, mi);
    if (self == g_local && C.killsnd) AudioServicesPlaySystemSound(1025);
}

// anti-aim: логируем порядок данных, подменяем yaw по индексу
static bool g_inSer; static int g_idx;
static void (*o_Ser)(void *, void *, void *, void *);
static void h_Ser(void *self, void *stream, void *info, void *mi) {
    g_inSer = self == g_local && *(bool *)((uintptr_t)stream + OFF_PS_Writing); g_idx = 0;
    o_Ser(self, stream, info, mi); g_inSer = false;
}
static int g_aaTick, g_aaLog;
static void (*o_Send)(void *, void *, void *);
static void h_Send(void *stream, void *obj, void *mi) {
    if (g_inSer && obj) {
        const char *t = il2cpp_class_get_name(il2cpp_object_get_class(obj));
        bool isF = !strcmp(t, "Single");
        if (g_aaLog < 60) { g_aaLog++; NSLog(@"[AA] #%d %s %f", g_idx, t, isF ? *(float *)((uintptr_t)obj + 0x10) : 0.f); }
        if (C.aa && isF && g_idx == YAW_IDX) { g_aaTick++; *(float *)((uintptr_t)obj + 0x10) += (g_aaTick & 1) ? C.aaOff : -C.aaOff; }
        g_idx++;
    }
    o_Send(stream, obj, mi);
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


// ---------------- диагностика хуков ----------------
static UILabel *g_status;
static int g_hookOK, g_hookTot;
static NSString *statePath() {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"cm_state.txt"];
}
static void writeState(NSString *t) { [t writeToFile:statePath() atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
static void showStatus(NSString *t) { if (g_status) g_status.text = t; NSLog(@"[CM] %@", t); }
static void doHook(const char *name, uintptr_t addr, void *rep, void **orig) {
    g_hookTot++;
    writeState([NSString stringWithFormat:@"crash-at:%s", name]);   // если игра упадёт на этом хуке, узнаем при следующем запуске
    int r = HOOKRAW(addr, rep, orig);
    bool ok = (r == 0 && *orig != NULL);
    if (ok) g_hookOK++;
    writeState([NSString stringWithFormat:@"ok:%d/%d last=%s r=%d", g_hookOK, g_hookTot, name, r]);
    showStatus([NSString stringWithFormat:@"hooks %d/%d (%s %@)", g_hookOK, g_hookTot, name, ok ? @"ok" : @"FAIL"]);
}
#define HOOK(rva, rep, orig) doHook(#rep, B + (rva), (void *)(rep), (void **)(orig))

// ---------------- инициализация ----------------
static void setup() {
    B = getBase("UnityFramework");
    void *h = dlopen(NULL, RTLD_NOW);
    resolve_icall = (decltype(resolve_icall))dlsym(h, "il2cpp_resolve_icall");
    il2cpp_object_get_class = (decltype(il2cpp_object_get_class))dlsym(h, "il2cpp_object_get_class");
    il2cpp_class_get_name = (decltype(il2cpp_class_get_name))dlsym(h, "il2cpp_class_get_name");
    if (!B || !resolve_icall) { NSLog(@"[CM] base/icall not found, retry"); dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ setup(); }); return; }
    g_players = [NSMutableSet new];
    // Имена icall зависят от версии Unity: при nullptr смотри лог [CM] icall и поправь строку.
    ICALL(Cam_main,   "UnityEngine.Camera::get_main()");
    ICALL(Comp_get_tr,"UnityEngine.Component::get_transform()");
    ICALL(Tr_get_pos, "UnityEngine.Transform::get_position_Injected(UnityEngine.Vector3&)");
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
    NSLog(@"[CM] icall main=%p tr=%p pos=%p w2s=%p fog=%p sky=%p clear=%p look=%p", Cam_main, Comp_get_tr, Tr_get_pos, Cam_w2s, RS_fog, RS_skybox, Cam_clear, Quat_Look);

    NSString *prev = [NSString stringWithContentsOfFile:statePath() encoding:NSUTF8StringEncoding error:nil];
    buildUI();
    UIWindow *w = keyWin();
    g_status = [[UILabel alloc] initWithFrame:CGRectMake(60, 22, 320, 30)];
    g_status.textColor = UIColor.yellowColor; g_status.font = [UIFont boldSystemFontOfSize:11]; g_status.userInteractionEnabled = NO;
    [w addSubview:g_status];
    if (prev.length) showStatus([@"prev run: " stringByAppendingString:prev]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    HOOK(RVA_CM_Start,     h_Start,   &o_Start);
    HOOK(RVA_CM_OnDestroy, h_Destroy, &o_Destroy);
    HOOK(RVA_CM_Update, h_Update, &o_Update);
    HOOK(RVA_CM_PushBullet, h_Push, &o_Push);
    HOOK(RVA_BB_UpdatePos, h_UpdPos, &o_UpdPos);
    HOOK(RVA_DR_Damage, h_Damage, &o_Damage);
    HOOK(RVA_CM_MakeKill, h_Kill, &o_Kill);
    HOOK(RVA_CM_Serialize, h_Ser, &o_Ser);
    HOOK(RVA_PS_SendNext, h_Send, &o_Send);
    NSLog(@"[CM] ready, base=%p", (void *)B);
    });
}

__attribute__((constructor)) static void init() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ setup(); });
}
