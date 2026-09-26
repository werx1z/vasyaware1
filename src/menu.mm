// menu.mm — Vasyaware ImGui Menu + Logs
#import "imgui.h"
#import "imgui_impl_opengl3.h"
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <UIKit/UIKit.h>

// =================================================================
// ЛОГИ В ФАЙЛ
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
// ГЛОБАЛЬНЫЕ ФЛАГИ
// =================================================================

BOOL menuVisible = YES;
BOOL imguiInitialized = NO;

// Combat
BOOL silentAimEnabled = NO;
BOOL kickBypassEnabled = NO;
BOOL hitMarkerEnabled = NO;
BOOL hitSoundsEnabled = NO;
BOOL hitMarkerActive = NO;
float hitMarkerTimer = 0.0f;

// Movement
BOOL bhopEnabled = NO;
BOOL speedHackEnabled = NO;
float speedMultiplier = 5.0f;

// Visuals
BOOL espEnabled = NO;
BOOL fogEnabled = NO;
float fogDensity = 0.05f;

// Config
BOOL saveConfigOnExit = YES;

// =================================================================
// ЖЕСТ (3 ПАЛЬЦА, 2 ТАПА)
// =================================================================

static UITapGestureRecognizer* menuGesture = nil;

@interface VasyawareGestureHandler : NSObject
+ (instancetype)shared;
- (void)handleGesture:(UITapGestureRecognizer*)recognizer;
@end

@implementation VasyawareGestureHandler
+ (instancetype)shared {
    static VasyawareGestureHandler* instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VasyawareGestureHandler alloc] init];
    });
    return instance;
}
- (void)handleGesture:(UITapGestureRecognizer*)recognizer {
    if (recognizer.state == UIGestureRecognizerStateEnded) {
        menuVisible = !menuVisible;
        WriteLog([NSString stringWithFormat:@"Menu: %@", menuVisible ? @"ON" : @"OFF"]);
    }
}
@end

void SetupMenuGesture() {
    UIWindow* window = [UIApplication sharedApplication].keyWindow;
    if (!window) window = [[UIApplication sharedApplication].windows firstObject];
    if (!window) {
        WriteLog(@"No window for gesture!");
        return;
    }

    if (menuGesture) {
        [window removeGestureRecognizer:menuGesture];
        menuGesture = nil;
    }

    menuGesture = [[UITapGestureRecognizer alloc] initWithTarget:[VasyawareGestureHandler shared]
                                                          action:@selector(handleGesture:)];
    menuGesture.numberOfTapsRequired = 2;
    menuGesture.numberOfTouchesRequired = 3;
    menuGesture.cancelsTouchesInView = NO;
    [window addGestureRecognizer:menuGesture];

    WriteLog(@"Gesture installed: 3 fingers, 2 taps");
}

// =================================================================
// СТИЛЬ VASYWARE
// =================================================================

void ApplyVasyawareStyle() {
    ImGuiStyle& style = ImGui::GetStyle();
    style.WindowRounding    = 12.0f;
    style.FrameRounding     = 8.0f;
    style.GrabRounding      = 8.0f;
    style.TabRounding       = 8.0f;
    style.WindowPadding     = ImVec2(12, 12);
    style.FramePadding      = ImVec2(8, 5);
    style.ItemSpacing       = ImVec2(10, 8);

    ImVec4* c = style.Colors;
    c[ImGuiCol_WindowBg]      = ImVec4(0.05f, 0.05f, 0.08f, 0.96f);
    c[ImGuiCol_TitleBgActive] = ImVec4(0.12f, 0.18f, 0.30f, 1.00f);
    c[ImGuiCol_CheckMark]     = ImVec4(0.30f, 0.85f, 0.45f, 1.00f);
    c[ImGuiCol_SliderGrab]    = ImVec4(0.30f, 0.70f, 1.00f, 1.00f);
    c[ImGuiCol_Button]        = ImVec4(0.15f, 0.25f, 0.45f, 1.00f);
    c[ImGuiCol_ButtonHovered] = ImVec4(0.25f, 0.45f, 0.75f, 1.00f);
    c[ImGuiCol_Tab]           = ImVec4(0.10f, 0.12f, 0.20f, 1.00f);
    c[ImGuiCol_TabHovered]    = ImVec4(0.25f, 0.45f, 0.75f, 1.00f);
    c[ImGuiCol_TabActive]     = ImVec4(0.18f, 0.30f, 0.55f, 1.00f);
}

// =================================================================
// ИНИЦИАЛИЗАЦИЯ
// =================================================================

void SetupImGui() {
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::GetIO().ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    ApplyVasyawareStyle();
    ImGui_ImplOpenGL3_Init("#version 100");
    imguiInitialized = YES;
    WriteLog(@"ImGui initialized");
}

// =================================================================
// ОТРИСОВКА МЕНЮ
// =================================================================

void RenderMenu() {
    if (!menuVisible || !imguiInitialized) return;

    ImGui_ImplOpenGL3_NewFrame();
    ImGui::NewFrame();

    CGSize screen = [UIScreen mainScreen].bounds.size;
    ImGui::SetNextWindowSize(ImVec2(450, 550), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos(ImVec2(screen.width/2 - 225, screen.height/2 - 275), ImGuiCond_FirstUseEver);

    ImGui::Begin("Vasyaware | Chicken Gun", &menuVisible, ImGuiWindowFlags_NoCollapse);

    ImGui::TextColored(ImVec4(0.30f, 0.85f, 0.45f, 1.0f), "V A S Y A W A R E");
    ImGui::SameLine();
    ImGui::TextColored(ImVec4(0.50f, 0.50f, 0.55f, 1.0f), "v1.0");
    ImGui::Separator();
    ImGui::Spacing();

    if (ImGui::BeginTabBar("VasyawareTabs")) {
        // COMBAT
        if (ImGui::BeginTabItem("Combat")) {
            ImGui::TextColored(ImVec4(1.0f, 0.4f, 0.4f, 1.0f), "AIMBOT");
            ImGui::Separator();
            ImGui::Checkbox("Silent Aim", &silentAimEnabled);
            ImGui::Spacing();
            ImGui::TextColored(ImVec4(1.0f, 0.7f, 0.3f, 1.0f), "MISC");
            ImGui::Separator();
            ImGui::Checkbox("Kick Bypass", &kickBypassEnabled);
            ImGui::Spacing();
            ImGui::TextColored(ImVec4(0.4f, 1.0f, 0.4f, 1.0f), "HIT EFFECTS");
            ImGui::Separator();
            ImGui::Checkbox("Hit Marker", &hitMarkerEnabled);
            ImGui::Checkbox("Hit Sounds", &hitSoundsEnabled);
            ImGui::EndTabItem();
        }

        // MOVEMENT
        if (ImGui::BeginTabItem("Movement")) {
            ImGui::TextColored(ImVec4(0.4f, 0.8f, 1.0f, 1.0f), "MOVEMENT");
            ImGui::Separator();
            ImGui::Checkbox("Bhop", &bhopEnabled);
            ImGui::Checkbox("Speed Hack", &speedHackEnabled);
            if (speedHackEnabled) {
                ImGui::SliderFloat("Speed Multiplier", &speedMultiplier, 1.0f, 20.0f, "%.1fx");
            }
            ImGui::EndTabItem();
        }

        // VISUALS
        if (ImGui::BeginTabItem("Visuals")) {
            ImGui::TextColored(ImVec4(1.0f, 1y.0f, 0.4fld, 1.0f), ".hVISUALS");
            ImGui::Separator>
();
            ImGui::Checkbox("ESP", &esp#importEnabled);
            ImGui::Checkbox("Fog (Only Me)", &fogEnabled);
            if (fogEnabled) {
                ImGui::SliderFloat("Fog Density", &fogDensity, 0.01f, 1.0f, "%.2f");
            }
            ImGui::EndTabItem();
        }

        // CONFIG
        if (ImGui::BeginTabItem("Config")) {
            ImGui::TextColored(ImVec4(0.8f, 0.8f, 0.8f, 1.0f), "SETTINGS");
            ImGui::Separator();
            ImGui::Checkbox("Save Config on Exit", &saveConfigOnExit);
            ImGui::Spacing();
            if (ImGui::Button("Reset All", ImVec2(140, 35))) {
                silentAimEnabled = kickBypassEnabled = NO;
                hitMarkerEnabled = hitSoundsEnabled = NO;
                bhopEnabled = speedHackEnabled = NO;
                fogEnabled = espEnabled = NO;
                speedMultiplier = 5.0f;
                fogDensity = 0.05f;
            }
            ImGui::SameLine();
            if (ImGui::Button("Unload Cheat", ImVec2(140, 35))) {
                menuVisible = NO;
            }
            ImGui::Separator();
            ImGui::TextColored(ImVec4(0.30f, 0.85f, 0.45f, 1.0f), "Vasyaware v1.0");
            ImGui::Text("Built: %s", __DATE__);
            ImGui::EndTabItem();
        }

        ImGui::EndTabBar();
    }

    ImGui::End();

    // Hit Marker
    if (hitMarkerActive && hitMarkerTimer > 0) {
        ImDrawList* drawList = ImGui::GetForegroundDrawList();
        ImVec2 center = ImVec2(screen.width / 2, screen.height / 2);
        float size = 15.0f;
        ImU32 color = IM_COL32(255, 50, 50, 255);

        drawList->AddLine(ImVec2(center.x - size, center.y - size), ImVec2(center.x - size/3, center.y - size/3), color, 2.5f);
        drawList->AddLine(ImVec2(center.x + size/3, center.y - size/3), ImVec2(center.x + size, center.y - size), color, 2.5f);
        drawList->AddLine(ImVec2(center.x - size, center.y + size), ImVec2(center.x - size/3, center.y + size/3), color, 2.5f);
        drawList->AddLine(ImVec2(center.x + size/3, center.y + size/3), ImVec2(center.x + size, center.y + size), color, 2.5f);
    }

    ImGui::Render();
    ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
}
