// menu.mm — Vasyaware ImGui Menu (CAMetalLayer)
#import "imgui.h"
#import "imgui_impl_metal.h"
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>

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
// ФЛАГИ
// =================================================================

BOOL menuVisible = YES;
BOOL imguiInitialized = NO;

extern id<MTLDevice> g_device;
extern id<MTLCommandQueue> g_commandQueue;

BOOL silentAimEnabled = NO;
BOOL kickBypassEnabled = NO;
BOOL hitMarkerEnabled = NO;
BOOL hitSoundsEnabled = NO;
BOOL hitMarkerActive = NO;
float hitMarkerTimer = 0.0f;

BOOL bhopEnabled = NO;
BOOL speedHackEnabled = NO;
float speedMultiplier = 5.0f;

BOOL espEnabled = NO;
BOOL fogEnabled = NO;
float fogDensity = 0.05f;

BOOL saveConfigOnExit = YES;

// =================================================================
// ЖЕСТ
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
    if (!window) return;

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
// СТИЛЬ
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
    if (imguiInitialized) return;
    if (!g_device) {
        WriteLog(@"Cannot init ImGui - no Metal device!");
        return;
    }
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::GetIO().ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    ApplyVasyawareStyle();
    ImGui_ImplMetal_Init(g_device);
    imguiInitialized = YES;
    WriteLog(@"ImGui initialized!");
}

// =================================================================
// ОТРИСОВКА
// =================================================================

void RenderMenu(id<MTLCommandBuffer> commandBuffer, id<MTLRenderCommandEncoder> encoder) {
    if (!menuVisible || !encoder || !commandBuffer) return;

    static BOOL initialized = NO;
    if (!initialized) {
        SetupImGui();
        initialized = YES;
    }
    if (!imguiInitialized) return;

    MTLRenderPassDescriptor* passDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    passDescriptor.colorAttachments[0].loadAction = MTLLoadActionLoad;
    passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

    ImGui_ImplMetal_NewFrame(passDescriptor);
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
        if (ImGui::BeginTabItem("Visuals")) {
            ImGui::TextColored(ImVec4(1.0f, 1.0f, 0.4f, 1.0f), "VISUALS");
            ImGui::Separator();
            ImGui::Checkbox("ESP", &espEnabled);
            ImGui::Checkbox("Fog (Only Me)", &fogEnabled);
            if (fogEnabled) {
                ImGui::SliderFloat("Fog Density", &fogDensity, 0.01f, 1.0f, "%.2f");
            }
            ImGui::EndTabItem();
        }
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

    ImGui::Render();
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), commandBuffer, encoder);
}
