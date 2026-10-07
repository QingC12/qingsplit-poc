//
// QingSplitPOC.m  —  First Floating Window POC v0.1
//
// 目标（唯一问题）：
//   QingSplit 能不能把一个真实 App Scene 作为第一个浮动窗口稳定显示在
//   自己的 UIWindow 中，同时 SpringBoard 不崩溃？
//
// 最小闭环（第一版 ONLY）：
//   目标 App FBScene
//     → FBSceneLayer / CA Context
//     → QingSplit 自有 UIWindow (LEVEL=999.0)
//     → 浮动显示目标 App
//     → _setActivePrioritizedPresenter:（最小写，失败不阻断）
//     → 控制前后顺序
//
// 明确不包含（第一版禁止）：
//   拖动 / 缩放 / 多窗口 / 手势系统 / 设置界面 / Keyboard Settings
//   License / Activation / Stheno 授权机制 / SBAppLayout
//
// 安全设计（沿用 SH2 + POC-24b 已验证路线）：
//   - 注入 SpringBoard（ellekit, Filter=com.apple.springboard）
//   - 延迟 5s 启动，等待 SB 稳定
//   - 崩溃闸门：/var/mobile/qsp_poc_state 连续启动计数，上次无 POC_OK
//     且 ≥3 次 → SAFE_MODE（只打日志，不创建任何窗口/写操作）
//   - 所有动作独立 @try/@catch + DBG 检查点
//   - 日志：/var/mobile/QingSplitPOC.log（SpringBoard 沙箱外唯一可写路径）
//   - 回滚：dpkg -r com.qingsplit.poc 即完全卸载（闸门兜底）
//
// 构建：GitHub Actions macos-latest + xcrun clang arm64e + ldid + rootless deb
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/stat.h>

// ----------------------------------------------------------------------------
// 日志
// ----------------------------------------------------------------------------
static FILE *g_log = NULL;

static void poc_log(NSString *fmt, ...) {
    if (!g_log) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"%@|[POC] %@\n",
                      [df stringFromDate:[NSDate date]], msg];
    fputs(line.UTF8String, g_log);
    fflush(g_log);
}

static void poc_open_log(void) {
    NSString *path = @"/var/mobile/QingSplitPOC.log";
    g_log = fopen(path.UTF8String, "a");
    if (!g_log) g_log = stderr;
}

// ----------------------------------------------------------------------------
// 小工具
// ----------------------------------------------------------------------------
static NSString *poc_cls(id obj) {
    if (!obj) return @"nil";
    return NSStringFromClass([obj class]);
}

static id poc_tryKVC(id obj, NSArray<NSString *> *keys) {
    if (!obj) return nil;
    for (NSString *k in keys) {
        @try {
            id v = [obj valueForKey:k];
            if (v && ![v isKindOfClass:[NSNull class]]) return v;
        } @catch (NSException *e) { }
    }
    return nil;
}

static NSString *poc_str(id v) {
    if (!v) return @"nil";
    return [NSString stringWithFormat:@"%@", v];
}

// 运行时调用私有 init: _UIContextLayerHostView initWithSceneLayer:
static id poc_msgSend_initWithSceneLayer(Class cls, id layer) {
    if (!cls || !layer) return nil;
    SEL sel = sel_registerName("initWithSceneLayer:");
    if (![cls instancesRespondToSelector:sel]) return nil;
    id (*fn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
    return fn([[cls alloc] init], sel, layer);
}

// 运行时调用: _UIScenePresenterOwner _setActivePrioritizedPresenter:(presenter)
static BOOL poc_msgSend_setActivePrioritizedPresenter(id owner, id presenter) {
    if (!owner || !presenter) return NO;
    SEL sel = sel_registerName("_setActivePrioritizedPresenter:");
    if (![owner respondsToSelector:sel]) return NO;
    void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    @try { fn(owner, sel, presenter); return YES; }
    @catch (NSException *e) { return NO; }
}

// ----------------------------------------------------------------------------
// 窗口：QSFloatingWindow : UIWindow（对齐 Stheno.SthenoWindow LEVEL=999.0）
// ----------------------------------------------------------------------------
@interface QSFloatingWindow : UIWindow
@end
@implementation QSFloatingWindow
@end

// ----------------------------------------------------------------------------
// 崩溃闸门
// ----------------------------------------------------------------------------
// 返回 YES 表示进入安全模式（本启动不做任何窗口/写操作）
static BOOL poc_safety_gate(void) {
    NSString *path = @"/var/mobile/qsp_poc_state";
    NSInteger boot = 0, ok = 0;
    NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (old) {
        NSArray *parts = [old componentsSeparatedByString:@" "];
        if (parts.count >= 2) {
            boot = [parts[0] integerValue];
            ok   = [parts[1] integerValue];
        }
    }
    boot += 1;
    if (ok == 0 && boot >= 3) {
        poc_log(@"SAFE_MODE boot=%ld (no POC_OK in previous boots) — skip all window ops this launch", (long)boot);
        NSString *s = [NSString stringWithFormat:@"%ld 0", (long)boot];
        [s writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return YES;
    }
    NSString *s = [NSString stringWithFormat:@"%ld 0", (long)boot];
    [s writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    return NO;
}

static void poc_mark_ok(void) {
    NSString *path = @"/var/mobile/qsp_poc_state";
    NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    NSInteger boot = 0;
    if (old) boot = [[old componentsSeparatedByString:@" "] firstObject].integerValue;
    if (boot < 1) boot = 1;
    NSString *s = [NSString stringWithFormat:@"%ld 1", (long)boot];
    [s writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

// ----------------------------------------------------------------------------
// FBScene 枚举（探针已验证路径）
// ----------------------------------------------------------------------------
static id poc_scene_manager(void) {
    Class cls = NSClassFromString(@"FBSceneManager");
    if (!cls) return nil;
    id (*fn)(Class, SEL) = (id (*)(Class, SEL))objc_msgSend;
    return fn(cls, sel_registerName("sharedInstance"));
}

static NSArray *poc_all_scenes(void) {
    NSMutableArray *outArr = [NSMutableArray array];
    @try {
        id mgr = poc_scene_manager();
        if (!mgr) return outArr;
        id ws = [mgr valueForKey:@"workspace"];
        id all = [ws valueForKey:@"allScenes"];
        if ([all isKindOfClass:[NSArray class]]) [outArr addObjectsFromArray:all];
        // 兜底：enumerateScenesWithBlock:
        if (!outArr.count) {
            SEL sel = sel_registerName("enumerateScenesWithBlock:");
            if ([ws respondsToSelector:sel]) {
                void (*fn)(id, SEL, void (^)(id)) = (void (*)(id, SEL, void (^)(id)))objc_msgSend;
                fn(ws, sel, ^(id scene) { [outArr addObject:scene]; });
            }
        }
    } @catch (NSException *e) {
        poc_log(@"SCENES_EXC %@", e.name);
    }
    return outArr;
}

static NSString *poc_scene_id(id scene) {
    id v = [scene valueForKey:@"identifier"];
    return v ? [NSString stringWithFormat:@"%@", v] : @"nil";
}

static BOOL poc_is_target_scene(NSString *sid, NSString *wanted) {
    if ([sid isEqualToString:@"nil"]) return NO;
    if ([sid hasPrefix:@"com.apple."]) return NO;
    if ([sid hasPrefix:@"springboard"] || [sid hasPrefix:@"SystemAperture"]) return NO;
    if ([sid containsString:@"Stheno"] || [sid containsString:@"QingSplit"]) return NO;
    if (wanted.length && ![sid hasPrefix:wanted]) return NO;
    return YES;
}

static NSDictionary *poc_pick_target(NSString *wanted) {
    // 返回 @{scene, sid, pid, layer, ctx}
    NSArray *scenes = poc_all_scenes();
    id fallback = nil; NSString *fallbackSid = nil;
    for (id sc in scenes) {
        NSString *sid = poc_scene_id(sc);
        if (!poc_is_target_scene(sid, nil)) continue;
        if (!fallback) { fallback = sc; fallbackSid = sid; }
        if (wanted.length && [sid hasPrefix:wanted]) {
            fallback = sc; fallbackSid = sid;
            break;
        }
    }
    if (!fallback) return nil;
    id layer = nil;
    @try {
        id lm = [fallback valueForKey:@"layerManager"];
        NSArray *layers = [lm valueForKey:@"layers"];
        if ([layers isKindOfClass:[NSArray class]] && layers.count) layer = layers.firstObject;
    } @catch (NSException *e) { }
    NSInteger ctx = 0;
    if (layer) ctx = [poc_tryKVC(layer, @[@"_contextID", @"contextID"]) integerValue];
    id proc = nil; NSInteger pid = 0;
    @try {
        proc = [fallback valueForKey:@"clientProcess"];
        pid = [proc valueForKey:@"pid"] ? [[proc valueForKey:@"pid"] integerValue] : 0;
    } @catch (NSException *e) { }
    return @{ @"scene": fallback, @"sid": fallbackSid,
              @"layer": layer ?: (id)[NSNull null], @"ctx": @(ctx),
              @"pid": @(pid) };
}

// ----------------------------------------------------------------------------
// 渲染路径阶梯（Phase 0 核心）：三条路径，全部 @try，失败顺延
//   路径1: _UIContextLayerHostView initWithSceneLayer:
//   路径2: _UISceneLayerHostContainerView + KVC _scene
//   路径3: CALayer _setContentsContextID: (纯 CA context attach)
// ----------------------------------------------------------------------------
static UIView *poc_make_host_view(id sceneLayer, NSInteger ctx, int *outPath) {
    // 路径 1
    Class cls1 = NSClassFromString(@"_UIContextLayerHostView");
    if (cls1) {
        @try {
            UIView *v = poc_msgSend_initWithSceneLayer(cls1, sceneLayer);
            if (v) { *outPath = 1; return v; }
        } @catch (NSException *e) { poc_log(@"PATH1_EXC %@", e.name); }
    } else {
        poc_log(@"PATH1_MISSING _UIContextLayerHostView class not found");
    }

    // 路径 2
    Class cls2 = NSClassFromString(@"_UISceneLayerHostContainerView");
    if (cls2) {
        @try {
            UIView *v = [[cls2 alloc] initWithFrame:CGRectMake(0, 0, 320, 480)];
            if (v && [v respondsToSelector:@selector(setValue:forKey:)]) {
                [v setValue:sceneLayer forKey:@"scene"];
                [v setValue:sceneLayer forKey:@"_scene"];
                *outPath = 2;
                return v;
            }
        } @catch (NSException *e) { poc_log(@"PATH2_EXC %@", e.name); }
    } else {
        poc_log(@"PATH2_MISSING _UISceneLayerHostContainerView class not found");
    }

    // 路径 3
    if (ctx > 0) {
        @try {
            SEL sel = sel_registerName("_setContentsContextID:");
            CALayer *ly = [CALayer layer];
            ly.frame = CGRectMake(0, 0, 320, 480);
            if ([ly respondsToSelector:sel]) {
                void (*fn)(id, SEL, unsigned int) = (void (*)(id, SEL, unsigned int))objc_msgSend;
                fn(ly, sel, (unsigned int)ctx);
                UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 480)];
                [v.layer addSublayer:ly];
                *outPath = 3;
                return v;
            }
        } @catch (NSException *e) { poc_log(@"PATH3_EXC %@", e.name); }
    }
    return nil;
}

// ----------------------------------------------------------------------------
// Z-order（最小写）：遍历窗口容器链找目标 scene 的 presenter → _setActivePrioritizedPresenter:
// 探针已验证链: 容器(_UISceneLayerHostContainerView) → _dataSource(_UIScenePresentationView)
//              → presenter → owner → _scenePresentationManager
// ----------------------------------------------------------------------------
static void poc_zorder_raise(NSString *targetSid, id targetScene) {
    NSInteger raised = 0;
    @try {
        for (UIWindow *w in [[UIApplication sharedApplication] windows]) {
            NSMutableArray *found = [NSMutableArray array];
            __block void (^walk)(UIView *, int);
            void (^walkBlock)(UIView *, int) = ^(UIView *v, int depth) {
                if (!v || depth > 8) return;
                if ([poc_cls(v) isEqualToString:@"_UISceneLayerHostContainerView"]) [found addObject:v];
                for (UIView *c in v.subviews) walk(c, depth + 1);
            };
            walk = walkBlock;
            walk(w, 0);
            for (UIView *container in found) {
                    @try {
                        id scene = poc_tryKVC(container, @[@"_scene", @"scene"]);
                        if (!scene) continue;
                        NSString *sid = poc_scene_id(scene);
                        if (![sid isEqualToString:targetSid]) continue;
                        id presenter = poc_tryKVC(container, @[@"presenter", @"_presenter"]);
                        if (!presenter) {
                            id ds = poc_tryKVC(container, @[@"_dataSource", @"dataSource"]);
                            presenter = poc_tryKVC(ds, @[@"presenter", @"_presenter"]);
                        }
                        id owner = poc_tryKVC(presenter, @[@"_owner", @"owner"]);
                        if (owner && poc_msgSend_setActivePrioritizedPresenter(owner, presenter)) {
                            raised++;
                            poc_log(@"ZORDER_RAISE_OK sid=%@ presenter=%@ owner=%@",
                                    sid, poc_cls(presenter), poc_cls(owner));
                        } else {
                            poc_log(@"ZORDER_RAISE_SKIP sid=%@ (owner=%@ presenter=%@)",
                                    sid, poc_cls(owner), poc_cls(presenter));
                        }
                    } @catch (NSException *e) { }
                }
            }
        }
    } @catch (NSException *e) { }
    if (!raised) poc_log(@"ZORDER_NONE target=%@ (no presenter in container chain)", targetSid);
}
// ----------------------------------------------------------------------------
// 主流程
// ----------------------------------------------------------------------------
@interface POCController : UIViewController
@end
@implementation POCController
@end

static UIWindow *g_win = nil;
static UIView *g_hostView = nil;

static void poc_try_float(void) {
    if (g_win) return; // 只允许一个浮窗（第一版）

    // 1. 确定目标
    NSString *wanted = [NSString stringWithContentsOfFile:@"/tmp/qsp_target"
                                                encoding:NSUTF8StringEncoding error:NULL];
    wanted = [wanted stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSDictionary *target = poc_pick_target(wanted);
    if (!target) {
        poc_log(@"TARGET_NONE wanted=%@ — waiting for app scene", wanted ?: @"(auto)");
        return;
    }
    NSString *sid = target[@"sid"];
    id scene = target[@"scene"];
    id layer = [target[@"layer"] isKindOfClass:[NSNull class]] ? nil : target[@"layer"];
    NSInteger ctx = [target[@"ctx"] integerValue];
    NSInteger pid = [target[@"pid"] integerValue];
    poc_log(@"TARGET sid=%@ pid=%ld layer=%@ ctx=%ld",
            sid, (long)pid, poc_cls(layer), (long)ctx);

    // 2. 渲染 host view（Phase 0 核心风险点）
    int path = 0;
    UIView *hv = layer ? poc_make_host_view(layer, ctx, &path) : nil;
    if (!hv) {
        poc_log(@"RENDER_FAIL all paths failed — POC ABORT (no write ops performed)");
        return;
    }
    poc_log(@"RENDER_PATH=%d ctx=%ld", path, (long)ctx);

    // 3. 创建浮窗窗口（写操作 #1：窗口创建/显示，对齐 Stheno LEVEL=999.0）
    @try {
        g_win = [[QSFloatingWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
        g_win.windowLevel = 999.0;
        g_win.hidden = NO;
        g_win.userInteractionEnabled = YES;
        g_win.rootViewController = [[POCController alloc] init];
        // 3.1 host view 放窗口中央（固定 320×480，第一版无手势）
        hv.frame = CGRectMake((g_win.bounds.size.width - 320) / 2.0,
                              (g_win.bounds.size.height - 480) / 2.0,
                              320, 480);
        [g_win addSubview:hv];
        g_hostView = hv;
        poc_log(@"WINDOW_OK class=%@ level=%.1f frame=%@ host=%@",
                poc_cls(g_win), g_win.windowLevel,
                NSStringFromCGRect(g_win.frame), poc_cls(hv));
    } @catch (NSException *e) {
        poc_log(@"WINDOW_EXC %@ — abort", e.name);
        return;
    }

    // 4. Z-order（写操作 #2，最小：仅目标 scene 的 presenter，失败不阻断）
    poc_zorder_raise(sid, scene);

    // 5. 标记 OK（崩溃闸门复位）
    poc_mark_ok();
    poc_log(@"POC_OK sid=%@ path=%d — floating window established", sid, path);
}

// 注入入口：延迟 5s 启动，之后每 3s 尝试一次（等待目标 App scene 出现）
@interface POCBootstrap : NSObject
@end
@implementation POCBootstrap
+ (void)load {
    poc_open_log();
    poc_log(@"=== QingSplitPOC v0.1 LOADED pid=%d ===", (int)getpid());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (poc_safety_gate()) return;
        poc_log(@"BOOTSTRAP_START");
        NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(NSTimer *tm) {
            poc_try_float();
            if (g_win) [tm invalidate];
        }];
        // 兜底：60s 后若仍无目标则停表并记录（不崩溃）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 65 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (!g_win) { [t invalidate]; poc_log(@"TIMEOUT no target scene in 60s — idle"); }
        });
    });
}
@end
