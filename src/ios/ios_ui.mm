// SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <sys/types.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>

#include "input_common/drivers/virtual_gamepad.h"
#include "ios/ios_ui.h"

extern "C" int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);

namespace {

constexpr unsigned int CS_OPS_STATUS = 0;
constexpr uint32_t CS_DEBUGGED = 0x10000000;

std::optional<std::string> g_selected_game;
UIWindow* g_launcher_window = nil;
UINavigationController* g_launcher_nav = nil;
InputCommon::VirtualGamepad* g_gamepad = nullptr;
std::function<void()> g_on_quit;

using Button = InputCommon::VirtualGamepad::VirtualButton;

NSString* DocumentsPath() {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)
        .firstObject;
}

NSArray<NSString*>* GameExtensions() {
    return @[ @"nsp", @"xci", @"nsz", @"xcz", @"nca", @"nro", @"nso", @"nup", @"kip" ];
}

void CreateFolders() {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* docs = DocumentsPath();
    for (NSString* sub in @[ @"games", @"keys", @"nand/system/Contents/registered" ]) {
        [fm createDirectoryAtPath:[docs stringByAppendingPathComponent:sub]
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:nil];
    }
    NSString* readme = [docs stringByAppendingPathComponent:@"README.txt"];
    if (![fm fileExistsAtPath:readme]) {
        NSString* text =
            @"Lichii for iOS\n\n"
             "keys/      put prod.keys and title.keys here\n"
             "games/     put your games here (.nsp .xci .nsz .xcz .nup .nro)\n"
             "nand/system/Contents/registered/\n"
             "           unzip your firmware and put all of its .nca files here\n"
             "log/       eden_log.txt, for bug reports\n\n"
             "JIT: open StikDebug and launch Lichii from it (or attach to it) before playing.\n";
        [text writeToFile:readme atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

UIWindowScene* ActiveScene() {
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            return (UIWindowScene*)scene;
        }
    }
    return nil;
}

UIViewController* TopController(UIViewController* root) {
    while (root.presentedViewController != nil) {
        root = root.presentedViewController;
    }
    return root;
}

void SelectGame(NSString* path) {
    g_selected_game = std::string(path.fileSystemRepresentation);
}

} // namespace

// ---------------------------------------------------------------------------------------------
// Game list

@interface LCLauncherController : UITableViewController <UIDocumentPickerDelegate>
@property(nonatomic, strong) NSArray<NSString*>* games;
@end

@implementation LCLauncherController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Lichii";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(openFile)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self
                                                      action:@selector(reload)];
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    NSMutableArray<NSString*>* found = [NSMutableArray array];
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* docs = DocumentsPath();
    for (NSString* dir in @[ [docs stringByAppendingPathComponent:@"games"], docs ]) {
        for (NSString* name in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if ([GameExtensions() containsObject:name.pathExtension.lowercaseString]) {
                [found addObject:[dir stringByAppendingPathComponent:name]];
            }
        }
    }
    [found sortUsingComparator:^NSComparisonResult(NSString* a, NSString* b) {
      return [a.lastPathComponent localizedCaseInsensitiveCompare:b.lastPathComponent];
    }];
    self.games = found;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
    return 2;
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"Status" : @"Games";
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"Files app → On My iPhone → Lichii: put prod.keys and title.keys in keys/, "
               @"games in games/, and your firmware's .nca files in "
               @"nand/system/Contents/registered/. See README.txt there.";
    }
    return self.games.count == 0 ? @"No games found. Add some to the games folder or tap +." : nil;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 2 : (NSInteger)self.games.count;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)ip {
    UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                   reuseIdentifier:nil];
    if (ip.section == 0 && ip.row == 0) {
        const bool jit = IosUI::IsJitEnabled();
        cell.textLabel.text = jit ? @"JIT enabled" : @"JIT not enabled";
        cell.detailTextLabel.text =
            jit ? @"Ready to play."
                : @"Launch Lichii from StikDebug, then tap here to check again.";
        cell.imageView.image =
            [UIImage systemImageNamed:jit ? @"checkmark.circle.fill" : @"xmark.octagon.fill"];
        cell.imageView.tintColor = jit ? UIColor.systemGreenColor : UIColor.systemRedColor;
    } else if (ip.section == 0) {
        NSString* keys = [DocumentsPath() stringByAppendingPathComponent:@"keys/prod.keys"];
        const bool has_keys = [NSFileManager.defaultManager fileExistsAtPath:keys];
        cell.textLabel.text = has_keys ? @"Keys found" : @"prod.keys missing";
        cell.detailTextLabel.text =
            has_keys ? @"keys/prod.keys" : @"Copy prod.keys and title.keys into the keys folder.";
        cell.imageView.image =
            [UIImage systemImageNamed:has_keys ? @"key.fill" : @"exclamationmark.triangle.fill"];
        cell.imageView.tintColor = has_keys ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
    } else {
        NSString* path = self.games[(NSUInteger)ip.row];
        cell.textLabel.text = path.lastPathComponent.stringByDeletingPathExtension;
        NSDictionary* attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        cell.detailTextLabel.text = [NSString
            stringWithFormat:@"%@ · %@", path.pathExtension.uppercaseString,
                             [NSByteCountFormatter
                                 stringFromByteCount:(long long)attrs.fileSize
                                          countStyle:NSByteCountFormatterCountStyleFile]];
        cell.imageView.image = [UIImage systemImageNamed:@"gamecontroller.fill"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) {
        [self reload];
        return;
    }
    [self launch:self.games[(NSUInteger)ip.row]];
}

- (void)launch:(NSString*)path {
    if (IosUI::IsJitEnabled()) {
        SelectGame(path);
        return;
    }
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:@"JIT is not enabled"
                         message:@"Without JIT, iOS stops Lichii as soon as the game starts. "
                                 @"Launch Lichii from StikDebug first."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Start anyway"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction*) {
                                              SelectGame(path);
                                            }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openFile {
    UIDocumentPickerViewController* picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeItem ]
                                                                    asCopy:NO];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller
    didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    NSURL* url = urls.firstObject;
    if (url == nil) {
        return;
    }
    // Access stays open for the life of the process; the game file is read while it runs.
    [url startAccessingSecurityScopedResource];
    [self launch:url.path];
}

@end

// ---------------------------------------------------------------------------------------------
// On-screen controls

@interface LCButtonView : UIView
@property(nonatomic) Button button;
@property(nonatomic, strong) UILabel* label;
@end

@implementation LCButtonView

- (instancetype)initWithButton:(Button)button title:(NSString*)title {
    if ((self = [super initWithFrame:CGRectZero])) {
        _button = button;
        self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
        self.layer.borderWidth = 1.5;
        self.multipleTouchEnabled = YES;
        _label = [[UILabel alloc] init];
        _label.text = title;
        _label.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.font = [UIFont boldSystemFontOfSize:16];
        _label.adjustsFontSizeToFitWidth = YES;
        [self addSubview:_label];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.label.frame = self.bounds;
    self.layer.cornerRadius = std::min(self.bounds.size.width, self.bounds.size.height) / 2;
}

- (void)setPressed:(bool)pressed {
    self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:pressed ? 0.5 : 0.18];
    if (g_gamepad != nullptr) {
        g_gamepad->SetButtonState(0, self.button, pressed);
    }
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self setPressed:true];
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self setPressed:false];
}
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self setPressed:false];
}

@end

@interface LCStickView : UIView
@property(nonatomic) InputCommon::VirtualGamepad::VirtualStick stick;
@property(nonatomic, strong) UIView* knob;
@end

@implementation LCStickView

- (instancetype)initWithStick:(InputCommon::VirtualGamepad::VirtualStick)stick {
    if ((self = [super initWithFrame:CGRectZero])) {
        _stick = stick;
        self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.45].CGColor;
        self.layer.borderWidth = 1.5;
        _knob = [[UIView alloc] init];
        _knob.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.45];
        _knob.userInteractionEnabled = NO;
        [self addSubview:_knob];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = self.bounds.size.width / 2;
    const CGFloat k = self.bounds.size.width * 0.45;
    self.knob.bounds = CGRectMake(0, 0, k, k);
    self.knob.layer.cornerRadius = k / 2;
    [self moveKnobX:0 y:0];
}

- (void)moveKnobX:(CGFloat)x y:(CGFloat)y {
    const CGFloat r = self.bounds.size.width / 2;
    self.knob.center = CGPointMake(r + x * r, r + y * r);
    if (g_gamepad != nullptr) {
        // The core takes up as positive, UIKit has y growing downwards.
        g_gamepad->SetStickPosition(0, self.stick, float(x), float(-y));
    }
}

- (void)track:(UITouch*)touch {
    const CGPoint p = [touch locationInView:self];
    const CGFloat r = self.bounds.size.width / 2;
    CGFloat x = (p.x - r) / r;
    CGFloat y = (p.y - r) / r;
    const CGFloat len = std::hypot(x, y);
    if (len > 1.0) {
        x /= len;
        y /= len;
    }
    [self moveKnobX:x y:y];
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self track:touches.anyObject];
}
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self track:touches.anyObject];
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self moveKnobX:0 y:0];
}
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self moveKnobX:0 y:0];
}

@end

@interface LCOverlayView : UIView
@property(nonatomic, strong) NSMutableDictionary<NSNumber*, LCButtonView*>* buttons;
@property(nonatomic, strong) LCStickView* leftStick;
@property(nonatomic, strong) LCStickView* rightStick;
@property(nonatomic, strong) UIButton* menuButton;
@property(nonatomic) BOOL controlsVisible;
@end

LCOverlayView* g_overlay = nil;

@implementation LCOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.multipleTouchEnabled = YES;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _controlsVisible = YES;
        _buttons = [NSMutableDictionary dictionary];
        const std::pair<Button, NSString*> defs[] = {
            {Button::ButtonA, @"A"},      {Button::ButtonB, @"B"},
            {Button::ButtonX, @"X"},      {Button::ButtonY, @"Y"},
            {Button::ButtonUp, @"▲"},     {Button::ButtonDown, @"▼"},
            {Button::ButtonLeft, @"◀"},   {Button::ButtonRight, @"▶"},
            {Button::TriggerL, @"L"},     {Button::TriggerZL, @"ZL"},
            {Button::TriggerR, @"R"},     {Button::TriggerZR, @"ZR"},
            {Button::ButtonMinus, @"−"},  {Button::ButtonPlus, @"+"},
            {Button::StickL, @"LS"},      {Button::StickR, @"RS"},
        };
        for (const auto& [button, title] : defs) {
            LCButtonView* view = [[LCButtonView alloc] initWithButton:button title:title];
            _buttons[@(static_cast<int>(button))] = view;
            [self addSubview:view];
        }
        _leftStick = [[LCStickView alloc]
            initWithStick:InputCommon::VirtualGamepad::VirtualStick::Left];
        _rightStick = [[LCStickView alloc]
            initWithStick:InputCommon::VirtualGamepad::VirtualStick::Right];
        [self addSubview:_leftStick];
        [self addSubview:_rightStick];

        _menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_menuButton setImage:[UIImage systemImageNamed:@"line.3.horizontal.circle"]
                     forState:UIControlStateNormal];
        _menuButton.tintColor = [UIColor colorWithWhite:1.0 alpha:0.7];
        [_menuButton addTarget:self
                        action:@selector(showMenu)
              forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_menuButton];
    }
    return self;
}

- (LCButtonView*)button:(Button)b {
    return self.buttons[@(static_cast<int>(b))];
}

- (void)place:(UIView*)view x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h {
    view.frame = CGRectMake(x - w / 2, y - h / 2, w, h);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    const CGSize size = self.bounds.size;
    const UIEdgeInsets safe = self.safeAreaInsets;
    const CGFloat W = size.width, H = size.height;
    const CGFloat s = std::min(W, H) * 0.13; // one face button
    const CGFloat left = safe.left + 8, right = W - safe.right - 8;
    const CGFloat top = std::max<CGFloat>(safe.top, 8) + 4, bottom = H - safe.bottom - 8;

    // Face buttons, right side.
    const CGFloat rx = right - 1.6 * s, ry = bottom - 3.0 * s;
    [self place:[self button:Button::ButtonA] x:rx + s y:ry w:s h:s];
    [self place:[self button:Button::ButtonB] x:rx y:ry + s w:s h:s];
    [self place:[self button:Button::ButtonX] x:rx y:ry - s w:s h:s];
    [self place:[self button:Button::ButtonY] x:rx - s y:ry w:s h:s];

    // Sticks: left stick top-left of the d-pad, right stick bottom-left of the face buttons.
    [self place:self.leftStick x:left + 1.6 * s y:bottom - 3.0 * s w:2.4 * s h:2.4 * s];
    [self place:self.rightStick x:right - 4.4 * s y:bottom - 1.0 * s w:1.9 * s h:1.9 * s];

    // D-pad, left side below and right of the left stick.
    const CGFloat dx = left + 4.4 * s, dy = bottom - 1.15 * s, d = 0.78 * s;
    [self place:[self button:Button::ButtonUp] x:dx y:dy - d w:d h:d];
    [self place:[self button:Button::ButtonDown] x:dx y:dy + d w:d h:d];
    [self place:[self button:Button::ButtonLeft] x:dx - d y:dy w:d h:d];
    [self place:[self button:Button::ButtonRight] x:dx + d y:dy w:d h:d];

    // Shoulders.
    const CGFloat sw = 1.7 * s, sh = 0.75 * s;
    [self place:[self button:Button::TriggerZL] x:left + sw / 2 y:top + sh / 2 w:sw h:sh];
    [self place:[self button:Button::TriggerL] x:left + sw / 2 y:top + 1.6 * sh w:sw h:sh];
    [self place:[self button:Button::TriggerZR] x:right - sw / 2 y:top + sh / 2 w:sw h:sh];
    [self place:[self button:Button::TriggerR] x:right - sw / 2 y:top + 1.6 * sh w:sw h:sh];

    // Stick clicks next to the shoulders, minus/plus and the menu in the middle.
    const CGFloat small = 0.7 * s;
    [self place:[self button:Button::StickL] x:left + sw + small y:top + small / 2 w:small h:small];
    [self place:[self button:Button::StickR] x:right - sw - small y:top + small / 2 w:small h:small];
    [self place:[self button:Button::ButtonMinus] x:W / 2 - 1.3 * s y:top + small / 2 w:small h:small];
    [self place:[self button:Button::ButtonPlus] x:W / 2 + 1.3 * s y:top + small / 2 w:small h:small];
    [self place:self.menuButton x:W / 2 y:top + small / 2 w:small h:small];
}

// Touches that miss every control go through to the game's touchscreen.
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    UIView* hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}

- (void)setControlsVisible:(BOOL)visible {
    _controlsVisible = visible;
    for (UIView* view in self.subviews) {
        if (view != self.menuButton) {
            view.hidden = !visible;
        }
    }
    if (!visible && g_gamepad != nullptr) {
        g_gamepad->ResetControllers();
    }
}

- (void)showMenu {
    UIAlertController* sheet =
        [UIAlertController alertControllerWithTitle:@"Lichii"
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction
                         actionWithTitle:self.controlsVisible ? @"Hide on-screen controls"
                                                              : @"Show on-screen controls"
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction*) {
                                   self.controlsVisible = !self.controlsVisible;
                                 }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Quit Lichii"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction*) {
                                              if (g_on_quit) {
                                                  g_on_quit();
                                              }
                                            }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = self.menuButton;
    sheet.popoverPresentationController.sourceRect = self.menuButton.bounds;
    UIViewController* root = self.window.rootViewController;
    if (root != nil) {
        [TopController(root) presentViewController:sheet animated:YES completion:nil];
    }
}

@end

// ---------------------------------------------------------------------------------------------

namespace IosUI {

bool IsJitEnabled() {
    uint32_t flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
        return false;
    }
    return (flags & CS_DEBUGGED) != 0;
}

void ShowLauncher() {
    CreateFolders();
    if (g_launcher_window == nil) {
        UIWindowScene* scene = ActiveScene();
        g_launcher_window = scene != nil ? [[UIWindow alloc] initWithWindowScene:scene]
                                         : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        g_launcher_window.windowLevel = UIWindowLevelNormal + 1;
        LCLauncherController* list =
            [[LCLauncherController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        g_launcher_nav = [[UINavigationController alloc] initWithRootViewController:list];
        g_launcher_nav.navigationBar.prefersLargeTitles = YES;
        g_launcher_window.rootViewController = g_launcher_nav;
    }
    g_launcher_window.hidden = NO;
    [g_launcher_window makeKeyAndVisible];
}

void HideLauncher() {
    g_launcher_window.hidden = YES;
}

std::optional<std::string> TakeSelectedGame() {
    auto game = std::move(g_selected_game);
    g_selected_game.reset();
    return game;
}

void ShowMessage(const std::string& title, const std::string& message) {
    UIAlertController* alert =
        [UIAlertController alertControllerWithTitle:@(title.c_str())
                                            message:@(message.c_str())
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    UIViewController* root = nil;
    if (g_launcher_window != nil && !g_launcher_window.hidden) {
        root = g_launcher_nav;
    } else if (g_overlay.window != nil) {
        root = g_overlay.window.rootViewController;
    }
    if (root != nil) {
        [TopController(root) presentViewController:alert animated:YES completion:nil];
    }
}

void AttachOverlay(void* uikit_window, InputCommon::VirtualGamepad* gamepad,
                   std::function<void()> on_quit) {
    g_gamepad = gamepad;
    g_on_quit = std::move(on_quit);
    UIWindow* window = (__bridge UIWindow*)uikit_window;
    UIView* host = window.rootViewController.view ?: window;
    g_overlay = [[LCOverlayView alloc] initWithFrame:host.bounds];
    [host addSubview:g_overlay];
    [host bringSubviewToFront:g_overlay];
}

void SetOverlayVisible(bool visible) {
    g_overlay.controlsVisible = visible;
}

} // namespace IosUI
