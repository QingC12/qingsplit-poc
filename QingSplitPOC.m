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
#import <unistd.h>
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
    return fn([cls alloc], sel, layer);
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

// v0.3.18: 目标 scene 是否仍存在（用于关闭后复位 —— app 退出则 scene 从 workspace 消失）
static BOOL poc_scene_alive(NSString *sid) {
    if (!sid) return NO;
    for (id sc in poc_all_scenes()) {
        NSString *s = poc_scene_id(sc);
        if (s && [s isEqualToString:sid]) return YES;
    }
    return NO;
}

// v0.3.4: 读取 FBSceneLayer 的原始尺寸（native）—— 多 key + selector 直调 + 屏幕兜底
// v0.3.3 实锤：KVC valueForKey:@"frame" 返回 CGRectZero（key/时机问题），native 拿不到 → contain 失效
static CGSize poc_layer_native_size(id layer) {
    if (!layer) return CGSizeZero;
    NSArray *cRectKeys = @[@"frame", @"bounds", @"_frame", @"layerFrame"];
    for (NSString *k in cRectKeys) {
        @try {
            id v = [layer valueForKey:k];
            if ([v respondsToSelector:@selector(CGRectValue)]) {
                CGRect r = [v CGRectValue];
                if (r.size.width > 0 && r.size.height > 0) return r.size;
            }
        } @catch (NSException *e) { }
    }
    NSArray *cSizeKeys = @[@"size", @"contentSize", @"_size", @"contentBoundsSize"];
    for (NSString *k in cSizeKeys) {
        @try {
            id v = [layer valueForKey:k];
            if ([v respondsToSelector:@selector(CGSizeValue)]) {
                CGSize s = [v CGSizeValue];
                if (s.width > 0 && s.height > 0) return s;
            }
        } @catch (NSException *e) { }
    }
    @try {
        if ([layer respondsToSelector:@selector(frame)]) {
            CGRect (*fn)(id, SEL) = (CGRect (*)(id, SEL))objc_msgSend;
            CGRect r = fn(layer, @selector(frame));
            if (r.size.width > 0 && r.size.height > 0) return r.size;
        }
    } @catch (NSException *e) { }
    return CGSizeZero;
}

static BOOL poc_is_target_scene(NSString *sid, NSString *wanted) {
    if ([sid isEqualToString:@"nil"]) return NO;
    // v0.1.1: FBScene identifier 格式为 "sceneID:<bundle-id>-default"（app scene 判据）
    // 系统 scene（springboard/SystemAperture/SuperHighLevelSystemAperture/UUID）无 sceneID: 前缀
    if (![sid hasPrefix:@"sceneID:"]) return NO;
    if ([sid containsString:@"com.apple."]) return NO;
    if ([sid containsString:@"Stheno"] || [sid containsString:@"QingSplit"]) return NO;
    if (wanted.length && ![sid hasPrefix:wanted]) return NO;
    return YES;
}

static NSDictionary *poc_pick_target(NSString *wanted) {
    // 返回 @{scene, sid, pid, layer, ctx}
    // v0.4.0: 支持逗号分隔多目标（设置 targets）；任一命中即可
    NSMutableArray *wantedList = nil;
    if (wanted.length) {
        wantedList = [NSMutableArray array];
        for (NSString *w in [wanted componentsSeparatedByString:@","]) {
            NSString *t = [w stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (t.length) [wantedList addObject:t];
        }
    }
    NSArray *scenes = poc_all_scenes();
    id fallback = nil; NSString *fallbackSid = nil;
    for (id sc in scenes) {
        NSString *sid = poc_scene_id(sc);
        if (!poc_is_target_scene(sid, nil)) continue;
        if (!fallback) { fallback = sc; fallbackSid = sid; }
        if (wantedList.count) {
            for (NSString *w in wantedList) {
                if ([sid hasPrefix:w]) {
                    fallback = sc; fallbackSid = sid;
                    break;
                }
            }
            if ([fallbackSid isEqualToString:sid]) break;
        }
    }
    if (!fallback) return nil;
    // layer 提取（轨道 A，对齐探针已验证路径 v0.1.6 P3 段）：
    //   layerManager → layers（多 key 兜底，layers 可能是 NSSet/NSOrderedSet）
    id layer = nil; NSInteger layerCount = 0; NSString *lmCls = @"nil"; NSString *layersKind = @"nil";
    NSArray *allLayers = nil;
    @try {
        id lm = poc_tryKVC(fallback, @[@"layerManager", @"_layerManager"]);
        lmCls = poc_cls(lm);
        id layers = poc_tryKVC(lm, @[@"layers", @"_layers", @"sceneLayers"]);
        layersKind = layers ? NSStringFromClass([layers class]) : @"nil";
        // v0.1.3: layers 实际是 __NSFrozenOrderedSetM (NSOrderedSet)，不是 NSArray/NSSet！
        // 必须同时支持 NSArray / NSSet / NSOrderedSet
        if ([layers isKindOfClass:[NSArray class]]) {
            allLayers = layers;
        } else if ([layers isKindOfClass:[NSSet class]]) {
            allLayers = [layers allObjects];
        } else if ([layers isKindOfClass:[NSOrderedSet class]]) {
            allLayers = [layers array];
        } else if ([layers respondsToSelector:@selector(allObjects)]) {
            allLayers = [layers allObjects];
        }
        layerCount = allLayers.count;
        // v0.1.4: 优先 type==0（主内容层），逐个打日志供诊断
        for (id l in allLayers) {
            NSString *t = poc_str(poc_tryKVC(l, @[@"_type", @"type"]));
            NSInteger c = [poc_tryKVC(l, @[@"_contextID", @"contextID"]) integerValue];
            // v0.3.3: 记录 scene layer 原始 frame（native 尺寸，host 内容按此渲染）
            // v0.3.4: 多 key + selector 直调 + 屏幕兜底
            CGRect lf = CGRectZero;
            @try {
                id fv = [l valueForKey:@"frame"];
                if (fv && [fv respondsToSelector:@selector(CGRectValue)]) lf = [fv CGRectValue];
            } @catch (NSException *e) { }
            CGSize native = poc_layer_native_size(l);
            NSString *nsrc = @"layer";
            if (native.width <= 0) { native = [[UIScreen mainScreen] bounds].size; nsrc = @"screen"; }
            poc_log(@"LAYER_SCAN type=%@ ctx=%ld cls=%@ frame=%@ native=%@ src=%@", t, (long)c, poc_cls(l),
                    NSStringFromCGRect(lf), NSStringFromCGSize(native), nsrc);
            if (!layer && [t isEqualToString:@"0"]) layer = l;
        }
        if (!layer && allLayers.count) layer = allLayers.firstObject;
    } @catch (NSException *e) { }
    NSInteger ctx = 0;
    if (layer) ctx = [poc_tryKVC(layer, @[@"_contextID", @"contextID"]) integerValue];
    id proc = nil; NSInteger pid = 0;
    @try {
        proc = [fallback valueForKey:@"clientProcess"];
        pid = [proc valueForKey:@"pid"] ? [[proc valueForKey:@"pid"] integerValue] : 0;
    } @catch (NSException *e) { }
    return @{ @"scene": fallback, @"sid": fallbackSid, @"layerCount": @(layerCount),
              @"layer": layer ?: (id)[NSNull null], @"ctx": @(ctx),
              @"lmCls": lmCls, @"layersKind": layersKind,
              @"pid": @(pid) };
}

// ----------------------------------------------------------------------------
// 轨道 B：从系统宿主容器反向取 contextID
// 前台 App 的 layer 被 SBRootSceneWindow 内的 _UISceneLayerHostContainerView 消费，
// 其 CA contextID 就是该 App 内容的渲染 context → 直接路径 3 直连
// 返回容器类名或 nil
// ----------------------------------------------------------------------------
static NSInteger poc_find_container_ctx(NSString *targetSid, NSString **outContainerCls, NSInteger *outLayerCtx) {
    NSInteger winCtx = 0;
    if (outContainerCls) *outContainerCls = @"nil";
    if (outLayerCtx) *outLayerCtx = 0;
    @try {
        // 窗口双源收集（对齐探针）：UIApplication.windows + connectedScenes.windows
        NSMutableSet *winSet = [NSMutableSet set];
        for (UIWindow *w in [[UIApplication sharedApplication] windows]) {
            [winSet addObject:[NSValue valueWithNonretainedObject:w]];
        }
        for (UIScene *sc in [[UIApplication sharedApplication] connectedScenes]) {
            NSArray *ws = poc_tryKVC(sc, @[@"windows"]);
            for (UIWindow *w in ws) {
                if (w) [winSet addObject:[NSValue valueWithNonretainedObject:w]];
            }
        }
        for (NSValue *vv in winSet) {
            UIWindow *w = [vv nonretainedObjectValue];
            if (!w) continue;
            NSMutableArray *containers = [NSMutableArray array];
            __block void (^walk)(UIView *, int);
            void (^walkBlock)(UIView *, int) = ^(UIView *v, int depth) {
                if (!v || depth > 10) return;
                if ([poc_cls(v) isEqualToString:@"_UISceneLayerHostContainerView"]) [containers addObject:v];
                for (UIView *c in v.subviews) walk(c, depth + 1);
            };
            walk = walkBlock;
            walk(w, 0);
            for (UIView *container in containers) {
                @try {
                    id cscene = poc_tryKVC(container, @[@"_scene", @"scene"]);
                    if (!cscene) continue;
                    NSString *csid = poc_scene_id(cscene);
                    if (![csid isEqualToString:targetSid]) continue;
                    // 容器视图自身的 CA context（系统用它渲染该 app 内容）
                    id ctxVal = poc_tryKVC(container.layer, @[@"contextId", @"_contextId", @"contextID", @"_contextID"]);
                    NSInteger cctx = [ctxVal integerValue];
                    // 容器可能持有 presentationContext，内含 sceneLayer 引用
                    id pctx = poc_tryKVC(container, @[@"_presentationContext", @"presentationContext"]);
                    id slayer = poc_tryKVC(pctx, @[@"sceneLayer", @"_sceneLayer", @"layer"]);
                    NSInteger lctx = slayer ? [poc_tryKVC(slayer, @[@"_contextID", @"contextID"]) integerValue] : 0;
                    poc_log(@"TRACKB_MATCH sid=%@ container=%@ winCtx=%ld layerCtx=%ld slayer=%@",
                            csid, poc_cls(container), (long)cctx, (long)lctx, poc_cls(slayer));
                    if (outContainerCls) *outContainerCls = poc_cls(container);
                    if (outLayerCtx) *outLayerCtx = lctx;
                    if (cctx > 0) winCtx = cctx;
                } @catch (NSException *e) { }
            }
        }
    } @catch (NSException *e) { }
    return winCtx;
}

// 仅凭 contextID 渲染（路径 3：CALayer _setContentsContextID:）
static UIView *poc_host_view_from_ctx(NSInteger ctx) {
    if (ctx <= 0) return nil;
    @try {
        SEL sel = sel_registerName("_setContentsContextID:");
        CALayer *ly = [CALayer layer];
        ly.frame = CGRectMake(0, 0, 320, 480);
        if (![ly respondsToSelector:sel]) return nil;
        void (*fn)(id, SEL, unsigned int) = (void (*)(id, SEL, unsigned int))objc_msgSend;
        fn(ly, sel, (unsigned int)ctx);
        UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 480)];
        [v.layer addSublayer:ly];
        return v;
    } @catch (NSException *e) {
        poc_log(@"CTX_HOST_EXC %@", e.name);
        return nil;
    }
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
    } @catch (NSException *e) { }
    if (!raised) poc_log(@"ZORDER_NONE target=%@ (no presenter in container chain)", targetSid);
}
// ----------------------------------------------------------------------------
// 主流程
// ----------------------------------------------------------------------------
// v0.1.7: 触摸穿透 —— 浮窗背景区域返回 nil（穿透到下层窗口），
// 只让 host view 区域响应。否则全屏窗口会拦截整个屏幕的触摸。
@interface POCView : UIView
@end
@implementation POCView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *h = [super hitTest:point withEvent:event];
    if (!h || h == self) return nil;
    return h;
}
@end

@interface POCController : UIViewController
@end
@implementation POCController
- (void)loadView {
    self.view = [[POCView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
}
@end

// v0.3.0: 浮窗容器 —— 边框拖动/缩放手势，内容区触摸仍路由给被 host 的 app
//   - Pan: 拖动容器（窗口内移动）
//   - Pinch: 缩放容器（含内容）
//   - 手势仅在"边框区域"激活（起点在 contentView 外），不抢 app 内容交互
static UIView *g_container = nil;   // QSFloatContainer 实例（static 简化）
static void poc_save_float_state(CGRect f);   // v0.3.12 前向声明（定义在下方全局区，供 QSFloatContainer 手势 ended 调用）
static void poc_close_float(void);            // v0.3.16 前向声明（关闭浮窗：只移除窗口，不动 Scene）
static BOOL poc_setting_bool(NSString *key, BOOL def);   // v0.4.0 前向声明（设置读取，定义在下方全局区）

@interface QSFloatContainer : UIView
@property (nonatomic, strong) UIView *contentView;
// v0.3.3: hosted scene layer 的原始尺寸（native）——_UIContextLayerHostView 内容按此渲染，不随 frame 拉伸
@property (nonatomic, assign) CGSize nativeContentSize;
@end
@implementation QSFloatContainer {
    UIPanGestureRecognizer *_pan;
    UIPinchGestureRecognizer *_pinch;
    UIPanGestureRecognizer *_scalePan;   // v0.3.8: 左下/右下角单指滑动缩放
    UILongPressGestureRecognizer *_longPress;   // v0.4.9: Stheno LongPressGesture —— 长按整窗拖动
    UIView *_contentView;   // v0.3.1: 手动 ivar（自定义 setter）
    BOOL _halfSnapped;      // v0.4.9: 当前处于半屏吸附态（拖离时还原浮动尺寸）
    CGRect _preSnapFrame;   // v0.4.9: 吸附前的 frame（尺寸还原依据）
    BOOL _lpActive;         // v0.4.9: 长按拖动进行中
    CGPoint _lpOrigin, _lpStart;
    UIView *_knobL, *_knobR;   // v0.4.10: 角落把手引用（吸附改宽后强制重定位，防跑出窗口）
    UIButton *_closeBtn;       // v0.4.10: 关闭按钮引用
    UITapGestureRecognizer *_doubleTap;   // v0.4.13: 双击顶部条重置窗口尺寸（细长条无法操作时恢复）
    UIView *_gripTop, *_gripBottom, *_gripLeft, *_gripRight;   // v0.4.14: 手势可视指示
    UILabel *_resetBadge;      // v0.4.14: 顶部双击重置图标（↻）
}
// v0.3.1 修复：contentView 赋值即自动 addSubview（v0.3.0 漏了 → host 不在视图树 → 内容不显示 + hostAlive=0）
- (void)setContentView:(UIView *)cv {
    if (_contentView != cv) {
        [_contentView removeFromSuperview];
        _contentView = cv;
        if (cv) {
            // v0.4.16: 内容视图同步圆角裁剪（悬浮窗四角圆润，内容不再盖成方形）
            cv.layer.cornerRadius = 20;
            cv.layer.masksToBounds = YES;
            [self addSubview:cv];
        }
        [self setNeedsLayout];
    }
}
- (UIView *)contentView { return _contentView; }
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // v0.3.11: 去除手势区灰色背景（用户要求）——容器背景透明，只留白色边框线 + 角落把手
        self.backgroundColor = [UIColor clearColor];
        self.layer.cornerRadius = 20;   // v0.4.16: 圆角化四角（内容视图同步裁剪）
        self.layer.borderWidth = 0;   // v0.4.15: 去白框 —— 手势指引（横条/竖条/图标）已足够
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
        self.clipsToBounds = YES;
        _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
        _pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(onPinch:)];
        _scalePan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onScalePan:)];
        // v0.4.9: Stheno LongPressGesture(minimumDuration:maximumDistance:) 对应 —— v0.4.11: 0.3s / 30pt
        _longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
        _longPress.minimumPressDuration = 0.3;
        _longPress.allowableMovement = 30;
        // v0.4.13: 双击顶部条重置窗口（内容区触摸被 host 接管，长按不生效 —— 重置放触摸正常的顶部条）
        _doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDoubleTap:)];
        _doubleTap.numberOfTapsRequired = 2;
        _pan.delegate = self;
        _pinch.delegate = self;
        _scalePan.delegate = self;
        _longPress.delegate = self;
        _doubleTap.delegate = self;
        [self addGestureRecognizer:_pan];
        [self addGestureRecognizer:_pinch];
        [self addGestureRecognizer:_scalePan];
        [self addGestureRecognizer:_longPress];
        [self addGestureRecognizer:_doubleTap];
        // v0.3.8: 左下/右下角缩放把手（纯视觉指示，不拦截触摸）；v0.3.15: 缩小到 20×20 跟随角落区
        [self addCornerKnob:CGRectMake(12, self.bounds.size.height - 32, 20, 20)];
        [self addCornerKnob:CGRectMake(self.bounds.size.width - 32, self.bounds.size.height - 32, 20, 20)];
        // v0.3.16: 右上角关闭按钮（明确关闭机制，仅移除浮窗不动 Scene）
        [self addCloseButton];
        // v0.4.14: 全部手势可视指示（拖动/重置），风格与把手/关闭一致（白色半透明圆角，不拦截触摸）
        [self addGestureIndicators];
    }
    return self;
}
// v0.4.14: 手势可视指示 —— 顶部=拖动横条+↻重置图标，底部=拖动横条，左右边缘=竖条
- (void)addGestureIndicators {
    UIColor *c = [UIColor colorWithWhite:1.0 alpha:0.65];
    CGFloat radius = 2.5;
    // 顶部条：拖动横条（居中）+ 重置图标（右侧避开关闭按钮）
    _gripTop = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 32, 5)];
    _gripTop.backgroundColor = c;
    _gripTop.layer.cornerRadius = radius;
    _gripTop.userInteractionEnabled = NO;
    [self addSubview:_gripTop];
    _resetBadge = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 24, 24)];
    _resetBadge.text = @"↻";
    _resetBadge.textColor = c;
    _resetBadge.font = [UIFont boldSystemFontOfSize:14];
    _resetBadge.textAlignment = NSTextAlignmentCenter;
    _resetBadge.userInteractionEnabled = NO;
    [self addSubview:_resetBadge];
    // 底部条：拖动横条（居中，稍粗）
    _gripBottom = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 56, 6)];
    _gripBottom.backgroundColor = c;
    _gripBottom.layer.cornerRadius = 3;
    _gripBottom.userInteractionEnabled = NO;
    [self addSubview:_gripBottom];
    // 左右边缘：竖条（垂直居中）
    _gripLeft = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 5, 36)];
    _gripLeft.backgroundColor = c;
    _gripLeft.layer.cornerRadius = radius;
    _gripLeft.userInteractionEnabled = NO;
    [self addSubview:_gripLeft];
    _gripRight = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 5, 36)];
    _gripRight.backgroundColor = c;
    _gripRight.layer.cornerRadius = radius;
    _gripRight.userInteractionEnabled = NO;
    [self addSubview:_gripRight];
    [self setNeedsLayout];
}
// v0.3.16: 关闭按钮 —— 右上角 44×44 热区 + 白圆 × 视觉。点击 → 只移除浮窗（不杀 Scene）
- (void)addCloseButton {
    // v0.4.0: 关闭按钮开关（设置）
    if (!poc_setting_bool(@"closeBtn", YES)) return;
    CGFloat s = 44;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(self.bounds.size.width - s, 0, s, s);
    b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake((s - 24) / 2.0, (s - 24) / 2.0, 24, 24)];
    dot.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    dot.layer.cornerRadius = 12;
    dot.userInteractionEnabled = NO;
    UILabel *xl = [[UILabel alloc] initWithFrame:dot.bounds];
    xl.text = @"×";
    xl.textColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    xl.font = [UIFont boldSystemFontOfSize:17];
    xl.textAlignment = NSTextAlignmentCenter;
    xl.userInteractionEnabled = NO;
    [dot addSubview:xl];
    [b addSubview:dot];
    [b addTarget:self action:@selector(onCloseTap:) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b];
    _closeBtn = b;   // v0.4.10
}
- (void)onCloseTap:(id)sender {
    poc_log(@"CLOSE_TAP");
    poc_close_float();
}
- (void)addCornerKnob:(CGRect)f {
    UIView *k = [[UIView alloc] initWithFrame:f];
    k.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    k.layer.cornerRadius = 12;
    k.userInteractionEnabled = NO;
    k.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin;
    [self addSubview:k];
    // v0.4.10: 按初始 x 归属左/右把手，供 layoutSubviews 强制重定位
    if (f.origin.x < self.bounds.size.width / 2.0) _knobL = k; else _knobR = k;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    // v0.4.10: 吸附改宽后把手/关闭按钮必须跟随新 bounds（autoresizing 对 x=w-32 这类绝对位不可靠）
    CGRect b = self.bounds;
    if (_knobL) _knobL.frame = CGRectMake(12, b.size.height - 32, 20, 20);
    if (_knobR) _knobR.frame = CGRectMake(b.size.width - 32, b.size.height - 32, 20, 20);
    if (_closeBtn) _closeBtn.frame = CGRectMake(b.size.width - 44, 0, 44, 44);
    // v0.4.14: 手势指示跟随 bounds
    if (_gripTop) _gripTop.frame = CGRectMake((b.size.width - 32) / 2.0, 19, 32, 5);
    if (_resetBadge) _resetBadge.frame = CGRectMake(b.size.width - 66, 2, 24, 24);
    if (_gripBottom) _gripBottom.frame = CGRectMake((b.size.width - 56) / 2.0, b.size.height - 40, 56, 6);
    if (_gripLeft) _gripLeft.frame = CGRectMake(5, (b.size.height - 36) / 2.0, 5, 36);
    if (_gripRight) _gripRight.frame = CGRectMake(b.size.width - 10, (b.size.height - 36) / 2.0, 5, 36);
    UIView *cv = self.contentView;
    if (!cv) return;
    // 内容区内边距 24（边框拖动区，v0.3.6 加宽 —— 用户实测 14px 不易操作）
    CGRect inner = CGRectInset(self.bounds, 24, 24);
    CGSize native = self.nativeContentSize;
    if (native.width > 0 && native.height > 0) {
        // v0.4.12: contain → fill —— 内容填满窗口（MAX 缩放 + 裁剪），消除细长窗上下/左右大留白
        // 列表类 App（酷安/Filza 单列布局）中间列正好全显示；clipsToBounds 负责裁剪
        CGFloat sx = inner.size.width / native.width;
        CGFloat sy = inner.size.height / native.height;
        CGFloat s = MAX(sx, sy);
        if (s > 0) {
            cv.bounds = CGRectMake(0, 0, native.width, native.height);
            cv.center = CGPointMake(CGRectGetMidX(inner), CGRectGetMidY(inner));
            cv.transform = CGAffineTransformMakeScale(s, s);
        }
        poc_log(@"CONTENT_FILL %@ s=%.3f", (sx > sy) ? @"w-fit" : @"h-fit", s);
    } else {
        cv.frame = inner;
        cv.transform = CGAffineTransformIdentity;
    }
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *h = [super hitTest:point withEvent:event];
    if (h == self) return self;   // 边框 → 容器（手势）
    return h;                     // 内容 → app
}
// v0.3.1: Pan 限边框起点；Pinch 始终允许（双指中点常落内容区，原判定会误拒）
// v0.3.3: 判定直接用 inset 内容区（transform 下 contentView.frame 不再等于 inset 区域）
// v0.3.6: inset 与 layoutSubviews 同步 24px
// v0.3.8: 角落 60×60 → scalePan（左下/右下缩放）；其余边框 → pan（拖动）
// v0.3.12: 手势精简（用户要求）——只保留：
//   - 角落缩放（60×60 左下/右下）
//   - 底部移动（底部 40px 横条拖动，排除角落）
//   双指 Pinch 禁用
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gr {
    CGPoint p = [gr locationInView:self];
    if (gr == _scalePan) {
        // v0.3.15: 角落缩放区 60×60 → 44×44（用户实测角落过于灵敏，缩小）
        CGRect bl = CGRectMake(0, self.bounds.size.height - 44, 44, 44);
        CGRect br = CGRectMake(self.bounds.size.width - 44, self.bounds.size.height - 44, 44, 44);
        if (!CGRectContainsPoint(bl, p) && !CGRectContainsPoint(br, p)) return NO;
        return YES;
    }
    if (gr == _pan) {
        // v0.4.11: 手势贴近悬浮窗 —— 热区从"仅底部条"扩展为：顶部 44 + 底部 72 + 左右边缘 16 全高
        CGRect b = self.bounds;
        CGRect topBar = CGRectMake(0, 0, b.size.width, 44);
        CGRect bottomBar = CGRectMake(0, b.size.height - 72, b.size.width, 72);
        CGRect leftEdge = CGRectMake(0, 0, 16, b.size.height);
        CGRect rightEdge = CGRectMake(b.size.width - 16, 0, 16, b.size.height);
        BOOL inZone = CGRectContainsPoint(topBar, p) || CGRectContainsPoint(bottomBar, p)
                   || CGRectContainsPoint(leftEdge, p) || CGRectContainsPoint(rightEdge, p);
        if (!inZone) return NO;
        // 角落区归 scalePan（避免竞争）—— 同步 44×44
        CGRect bl = CGRectMake(0, b.size.height - 44, 44, 44);
        CGRect br = CGRectMake(b.size.width - 44, b.size.height - 44, 44, 44);
        if (CGRectContainsPoint(bl, p) || CGRectContainsPoint(br, p)) return NO;
        // v0.4.11: 右上角关闭按钮区归按钮（排除 pan 抢占点击）
        CGRect closeZone = CGRectMake(b.size.width - 44, 0, 44, 44);
        if (CGRectContainsPoint(closeZone, p)) return NO;
        return YES;
    }
    if (gr == _pinch) return NO;   // v0.3.12: 双指缩放已去除（只保留角落缩放）
    if (gr == _doubleTap) {
        // v0.4.13: 双击仅限顶部 44px 条（触摸正常区，内容区被 host 接管收不到）
        CGRect b = self.bounds;
        CGRect topBar = CGRectMake(0, 0, b.size.width, 44);
        if (!CGRectContainsPoint(topBar, p)) return NO;
        CGRect closeZone = CGRectMake(b.size.width - 44, 0, 44, 44);
        if (CGRectContainsPoint(closeZone, p)) return NO;
        return YES;
    }
    if (gr == _longPress) {
        // v0.4.9: 长按整窗（内容区也可）—— 排除底部条/边缘（pan 更直接）与角落（scalePan）与关闭按钮
        CGRect b = self.bounds;
        CGRect bottomBar = CGRectMake(0, b.size.height - 72, b.size.width, 72);
        CGRect leftEdge = CGRectMake(0, 0, 16, b.size.height);
        CGRect rightEdge = CGRectMake(b.size.width - 16, 0, 16, b.size.height);
        if (CGRectContainsPoint(bottomBar, p) || CGRectContainsPoint(leftEdge, p)
         || CGRectContainsPoint(rightEdge, p)) return NO;
        CGRect bl = CGRectMake(0, b.size.height - 44, 44, 44);
        CGRect br = CGRectMake(b.size.width - 44, b.size.height - 44, 44, 44);
        if (CGRectContainsPoint(bl, p) || CGRectContainsPoint(br, p)) return NO;
        CGRect closeZone = CGRectMake(b.size.width - 44, 0, 44, 44);
        if (CGRectContainsPoint(closeZone, p)) return NO;
        return YES;
    }
    return YES;
}
// v0.4.9: 长按拖动不与其他容器手势同时（内容区 App 手势除外——UIKit 默认由长按识别后接管）
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}
- (void)onLongPress:(UILongPressGestureRecognizer *)g {    if (g.state == UIGestureRecognizerStateBegan) {
        _lpActive = YES;
        _lpOrigin = self.center;
        _lpStart = [g locationInView:self.superview];
        // v0.4.11: 日志确认长按触发（真机排查）
        poc_log(@"LP_BEGIN at=%@", NSStringFromCGPoint(_lpStart));
        // 轻触觉反馈提示进入拖动模式（Stheno 手感）
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [fb impactOccurred];
    } else if (g.state == UIGestureRecognizerStateChanged && _lpActive) {
        CGPoint cur = [g locationInView:self.superview];
        CGFloat dx = cur.x - _lpStart.x, dy = cur.y - _lpStart.y;
        CGRect f = self.frame;
        CGFloat minCx = 60 - f.size.width / 2.0, maxCx = 430 - 60 + f.size.width / 2.0;
        CGFloat minCy = 60 - f.size.height / 2.0, maxCy = 932 - 60 + f.size.height / 2.0;
        self.center = CGPointMake(MAX(minCx, MIN(_lpOrigin.x + dx, maxCx)),
                                  MAX(minCy, MIN(_lpOrigin.y + dy, maxCy)));
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        _lpActive = NO;
        // 边缘吸附（25px 阈值）+ 弹簧动画（与 pan ended 一致，无惯性）
        CGRect f = self.frame;
        CGFloat nx = f.origin.x, ny = f.origin.y;
        BOOL snapped = NO;
        CGFloat snapW = f.size.width;
        if (poc_setting_bool(@"halfSnap", YES) && f.size.width >= 258.0) {
            if (nx < 25) { nx = 0; snapped = YES; snapW = 215; }
            else if ((430 - (nx + f.size.width)) < 25) { nx = 215; snapped = YES; snapW = 215; }
        }
        if (!snapped && poc_setting_bool(@"edgeSnap", YES)) {
            if (nx < 25) nx = 0;
            else if ((430 - (nx + f.size.width)) < 25) nx = 430 - f.size.width;
            if (ny < 25) ny = 0;
            else if ((932 - (ny + f.size.height)) < 25) ny = 932 - f.size.height;
        }
        // v0.4.14: 半屏吸附高度按内容比例归一 + 垂直居中（防细长条 + fill 裁切只显示局部）
        CGFloat snapH = f.size.height;
        if (snapped) {
            CGFloat nw = self.nativeContentSize.width, nh = self.nativeContentSize.height;
            if (nw > 0 && nh > 0) {
                snapH = 215.0 * (nh / nw);
                if (snapH > 932) snapH = 932;
                if (snapH < 240) snapH = 240;
            }
            ny = (932.0 - snapH) / 2.0;
        }
        CGRect sf = CGRectMake(nx, ny, snapW, snapH);
        if (snapped) {
            _preSnapFrame = f;   // v0.4.9: 记录吸附前尺寸（拖离还原）
            _halfSnapped = YES;
            poc_log(@"LP_SNAP %@", NSStringFromCGRect(sf));
        }
        if (fabs(nx - f.origin.x) > 0.5 || fabs(ny - f.origin.y) > 0.5) {
            UISpringTimingParameters *tp = [[UISpringTimingParameters alloc] initWithDampingRatio:0.82
                                                                                  initialVelocity:CGVectorMake(0, 0)];
            UIViewPropertyAnimator *anim = [[UIViewPropertyAnimator alloc] initWithDuration:0.32 timingParameters:tp];
            [anim addAnimations:^{ self.frame = sf; }];
            [anim startAnimation];
            poc_save_float_state(sf);
        } else {
            poc_save_float_state(f);
        }
    }
}
// v0.4.13: 双击顶部条重置窗口 —— 细长条/畸形尺寸无法操作时，恢复默认尺寸（340×内容比例，居中）
- (void)onDoubleTap:(UITapGestureRecognizer *)g {
    poc_log(@"RESET_TAP");
    CGSize native = self.nativeContentSize;
    CGFloat defW = 340, defH = 500;
    if (native.width > 0 && native.height > 0) {
        defH = defW * (native.height / native.width);
        if (defH > 860) { defH = 860; defW = defH * (native.width / native.height); }
    }
    CGRect b = self.superview ? self.superview.bounds : CGRectMake(0, 0, 430, 932);
    CGRect rf = CGRectMake((b.size.width - defW) / 2.0, (b.size.height - defH) / 2.0, defW, defH);
    _halfSnapped = NO;   // 重置脱离半屏态
    poc_log(@"RESET_TAP to=%@", NSStringFromCGRect(rf));
    UISpringTimingParameters *tp = [[UISpringTimingParameters alloc] initWithDampingRatio:0.82
                                                                          initialVelocity:CGVectorMake(0, 0)];
    UIViewPropertyAnimator *anim = [[UIViewPropertyAnimator alloc] initWithDuration:0.32 timingParameters:tp];
    [anim addAnimations:^{ self.frame = rf; }];
    [anim startAnimation];
    poc_save_float_state(rf);
}
- (void)onPan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateChanged) {
        // v0.4.9: 半屏吸附后拖离 → 还原吸附前浮动尺寸（Stheno medusaFrameLast/finalFrame 精神）
        if (_halfSnapped && self.bounds.size.width <= 215.5) {
            _halfSnapped = NO;
            CGRect pf = _preSnapFrame;
            if (pf.size.width > 0 && pf.size.height > 0) {
                CGPoint c = self.center;
                self.bounds = CGRectMake(0, 0, pf.size.width, pf.size.height);
                self.center = c;   // 中心保持手指位置，宽高还原
                poc_log(@"HALF_UNSNAP restore=%.0fx%.0f", pf.size.width, pf.size.height);
            }
        }
        CGPoint t = [g translationInView:self.superview];
        CGPoint c = CGPointMake(self.center.x + t.x, self.center.y + t.y);
        // v0.3.16: 拖动约束 —— 浮窗至少保留 60px 在屏幕内（左右/上下都不能完全拖出）
        CGRect f = self.frame;
        CGFloat minCx = 60 - f.size.width / 2.0;        // 左边至少 60 在屏内
        CGFloat maxCx = 430 - 60 + f.size.width / 2.0;  // 右边至少 60 在屏内
        CGFloat minCy = 60 - f.size.height / 2.0;       // 顶部至少 60 在屏内
        CGFloat maxCy = 932 - 60 + f.size.height / 2.0; // 底部至少 60 在屏内
        c.x = MAX(minCx, MIN(c.x, maxCx));
        c.y = MAX(minCy, MIN(c.y, maxCy));
        self.center = c;
        [g setTranslation:CGPointZero inView:self.superview];
    } else if (g.state == UIGestureRecognizerStateEnded) {
        // v0.4.8: 修复 v0.4.7 半屏吸附 bug（snapped 后窗口宽未改 215 → 右吸半个出屏）
        // + 吸附阈值 40→25px（不过敏） + 惯性系数 0.18→0.12（减少"过半即吸"错觉）
        CGRect f = self.frame;
        CGFloat nx = f.origin.x, ny = f.origin.y;
        BOOL flung = NO;
        CGPoint vel = [g velocityInView:self.superview];
        CGFloat speed = (CGFloat)hypot(vel.x, vel.y);
        if (speed > 500.0) {
            flung = YES;
            nx = nx + vel.x * 0.12;
            ny = ny + vel.y * 0.12;
            // clamp：至少 60px 留在屏内（v0.3.16 拖动约束）
            CGFloat minX = -f.size.width + 60.0, maxX = 430.0 - 60.0;
            CGFloat minY = -f.size.height + 60.0, maxY = 932.0 - 60.0;
            nx = MAX(minX, MIN(nx, maxX));
            ny = MAX(minY, MIN(ny, maxY));
        }
        // 半屏吸附（基于惯性后的位置）：宽 ≥ 60% 屏宽（258）贴左/右缘 → 215 半屏
        BOOL snapped = NO;
        CGFloat snapW = f.size.width;
        if (poc_setting_bool(@"halfSnap", YES) && f.size.width >= 258.0) {
            if (nx < 25) { nx = 0; snapped = YES; snapW = 215; }
            else if ((430 - (nx + f.size.width)) < 25) { nx = 215; snapped = YES; snapW = 215; }
        }
        // 边缘吸附（v0.3.16）—— v0.4.0 加开关
        if (!snapped && poc_setting_bool(@"edgeSnap", YES)) {
            if (nx < 25) nx = 0;
            else if ((430 - (nx + f.size.width)) < 25) nx = 430 - f.size.width;
            if (ny < 25) ny = 0;
            else if ((932 - (ny + f.size.height)) < 25) ny = 932 - f.size.height;
        }
        // v0.4.14: 半屏吸附高度按内容比例归一 + 垂直居中（防细长条 + fill 裁切只显示局部）
        CGFloat snapH = f.size.height;
        if (snapped) {
            CGFloat nw = self.nativeContentSize.width, nh = self.nativeContentSize.height;
            if (nw > 0 && nh > 0) {
                snapH = 215.0 * (nh / nw);
                if (snapH > 932) snapH = 932;
                if (snapH < 240) snapH = 240;
            }
            ny = (932.0 - snapH) / 2.0;
        }
        CGRect sf = CGRectMake(nx, ny, snapW, snapH);
        BOOL moved = (fabs(nx - f.origin.x) > 0.5 || fabs(ny - f.origin.y) > 0.5);
        if (snapped) {
            // v0.4.9: 记录吸附前尺寸（拖离时还原）
            _preSnapFrame = f;
            _halfSnapped = YES;
            poc_log(@"HALF_SNAP %@", NSStringFromCGRect(sf));
        }
        else if (moved) poc_log(@"MOVE_END %@ vel=%@ flung=%d", NSStringFromCGRect(sf), NSStringFromCGPoint(vel), flung);
        if (moved) {
            // v0.4.7: 弹簧动画（SwiftUI spring 对应）—— dampingRatio 0.82 回弹柔顺
            UISpringTimingParameters *tp = [[UISpringTimingParameters alloc] initWithDampingRatio:0.82
                                                                                  initialVelocity:CGVectorMake(0, 0)];
            UIViewPropertyAnimator *anim = [[UIViewPropertyAnimator alloc] initWithDuration:0.32 timingParameters:tp];
            [anim addAnimations:^{ self.frame = sf; }];
            [anim startAnimation];
            poc_save_float_state(sf);   // 保存惯性/吸附后的目标位置
        } else {
            poc_save_float_state(self.frame);   // v0.3.12: 位置记忆
        }
    }
}
// v0.3.8: 角落滑动缩放 —— v0.3.9 方向改为用户要求：
//   朝对角（左下→右上 / 右下→左上）= 缩小；朝外直线（远离角落）= 放大
//   用 translation 在"内方向"上的投影做指数映射，保持宽高比
- (void)onScalePan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:self];
        CGPoint start = [g locationInView:self];
        // 确定起始角：左下 (1,-1) 内方向，右下 (-1,-1) 内方向
        CGFloat dx = 1.0, dy = -1.0;
        if (start.x > self.bounds.size.width / 2.0) { dx = -1.0; dy = -1.0; }
        CGFloat dot = t.x * dx + t.y * dy;   // >0 朝对角（内）= 缩小；<0 朝外 = 放大
        CGFloat factor = exp(-dot / 400.0);
        CGFloat ratio = self.bounds.size.height / self.bounds.size.width;
        CGFloat newW = self.bounds.size.width * factor;
        if (newW < 180) newW = 180;
        if (newW > 430) newW = 430;
        CGFloat maxWByH = 932.0 / ratio;
        if (newW > maxWByH) newW = maxWByH;
        CGFloat newH = newW * ratio;
        self.bounds = CGRectMake(0, 0, newW, newH);
        [g setTranslation:CGPointZero inView:self];
    } else if (g.state == UIGestureRecognizerStateEnded) {
        _halfSnapped = NO;   // v0.4.9: 角落缩放脱离半屏态（用户主动改尺寸）
        poc_save_float_state(self.frame);   // v0.3.12: 尺寸记忆
    }
}
- (void)onPinch:(UIPinchGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateChanged) {
        // v0.3.2: 保持宽高比缩放 —— 先统一 scale，再按比例 clamp（原版 W/H 独立 clamp 会破坏比例 → 内容变形）
        CGFloat ratio = self.bounds.size.height / self.bounds.size.width;   // H/W
        CGFloat s = g.scale;
        CGFloat newW = self.bounds.size.width * s;
        // 比例约束：宽 180~430（屏幕宽），高不超过 932（屏幕高），全程保持 ratio
        if (newW < 180) newW = 180;
        if (newW > 430) newW = 430;
        CGFloat maxWByH = 932.0 / ratio;
        if (newW > maxWByH) newW = maxWByH;
        CGFloat newH = newW * ratio;
        self.bounds = CGRectMake(0, 0, newW, newH);
        g.scale = 1.0;
    }
}
@end

static UIWindow *g_win = nil;
static UIView *g_hostView = nil;
static UIView *g_diag = nil;   // v0.1.7: 红色诊断视图（独立子视图，20s 后移除）
static NSString *g_lastSid = nil;  // v0.1.8: 保持模式 —— 目标 scene id
static NSInteger g_lastCtx = 0;    // v0.1.8: 保持模式 —— 当前 host 的 contextID
static BOOL g_apiProbed = NO;      // v0.2.0: scene 激活 API 只探测一次
static BOOL g_floatClosed = NO;   // v0.3.18: 用户点击关闭后保持关闭（防止 1s tick 自动重建）；目标 scene 消失后复位
static UIView *g_sbContainer = nil;  // v0.3.12: 主屏回退 —— 目标 app 的 SB 呈现容器（隐藏后露出桌面）
// v0.4.15: 手动触发 —— 屏幕右侧滑动弹出应用选择器，点选要悬浮的应用（替代自动触发）
static UIWindow *g_triggerWin = nil;
static UIView *g_pickerPanel = nil;      // v0.4.16: 应用选择器面板（右侧滑入）
static NSArray *g_pickerRows = nil;      // v0.4.19: 选择器行视图（跟手高亮）
static CGFloat g_pickerRowH = 50;       // v0.4.22: 自适应行高（铺满触发条 150pt）
static NSString *g_manualSid = nil;      // v0.4.16: 手动选中的目标 scene id（前缀匹配）
static BOOL g_triggerArmed = NO;

// v0.3.12: 浮窗状态记忆（位置/尺寸持久化）
// v0.3.13 修复：真机 STATE_SAVE_FAIL（writeToFile 返回 NO）——多候选路径逐个尝试
// （rootless fake root 下 /var/jb/var/mobile 可能不可写），日志记录成功路径；读时同样多路径回退
static NSArray *poc_state_paths(void) {
    return @[
        @"/var/jb/var/mobile/Library/Preferences/com.qingsplit.poc.plist",
        @"/var/mobile/Library/Preferences/com.qingsplit.poc.plist",
        @"/var/mobile/Documents/com.qingsplit.poc.plist",
        @"/tmp/qsp_state.plist",
    ];
}
// v0.4.0: 正式插件化 —— 设置读取（与浮窗状态同 plist；PreferenceLoader 写入）
static NSDictionary *poc_settings(void) {
    for (NSString *p in poc_state_paths()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d) return d;
    }
    return nil;
}
static BOOL poc_setting_bool(NSString *key, BOOL def) {
    id v = poc_settings()[key];
    return v ? [v boolValue] : def;
}
static NSString *poc_setting_str(NSString *key, NSString *def) {
    id v = poc_settings()[key];
    return v ? [NSString stringWithFormat:@"%@", v] : def;
}
static void poc_save_float_state(CGRect f) {
    @try {
        NSDictionary *d = @{@"ox": @(f.origin.x), @"oy": @(f.origin.y),
                            @"w": @(f.size.width), @"h": @(f.size.height)};
        BOOL saved = NO;
        for (NSString *p in poc_state_paths()) {
            if ([d writeToFile:p atomically:YES]) {
                saved = YES;
                poc_log(@"STATE_SAVE %@ %@", NSStringFromCGRect(f), p);
                break;
            }
        }
        if (!saved) {
            NSString *dir = @"/var/jb/var/mobile/Library/Preferences";
            BOOL dirExists = [[NSFileManager defaultManager] fileExistsAtPath:dir];
            BOOL dirWritable = [[NSFileManager defaultManager] isWritableFileAtPath:dir];
            BOOL tmpWritable = [[NSFileManager defaultManager] isWritableFileAtPath:@"/tmp"];
            poc_log(@"STATE_SAVE_FAIL all paths %@ dir=%@ writable=%d tmp=%d",
                    NSStringFromCGRect(f), dirExists ? @"yes" : @"no", dirWritable, tmpWritable);
        }
    } @catch (NSException *e) {
        poc_log(@"STATE_SAVE_EXC %@", e.name);
    }
}
static CGRect poc_load_float_state(void) {
    CGRect d = CGRectMake((430.0 - 340.0) / 2.0, (932.0 - 500.0) / 2.0, 340, 500);
    @try {
        for (NSString *p in poc_state_paths()) {
            NSDictionary *d2 = [NSDictionary dictionaryWithContentsOfFile:p];
            if (!d2) continue;
            CGFloat ox = [d2[@"ox"] doubleValue], oy = [d2[@"oy"] doubleValue];
            CGFloat w = [d2[@"w"] doubleValue], h = [d2[@"h"] doubleValue];
            // v0.4.14: 校验 —— 细长条记忆（宽<240 或 高宽比>3.2）丢弃，用默认（防吸附变长条+内容局部）
            BOOL sane = (w >= 240 && w <= 430 && h >= 240 && h <= 932 && (h / w) <= 3.2);
            if (sane) {
                ox = MAX(0, MIN(ox, 430.0 - w));
                oy = MAX(0, MIN(oy, 932.0 - h));
                d = CGRectMake(ox, oy, w, h);
                poc_log(@"STATE_LOAD %@ %@", NSStringFromCGRect(d), p);
                break;
            }
        }
    } @catch (NSException *e) {
        poc_log(@"STATE_LOAD_EXC %@", e.name);
    }
    return d;
}

// v0.3.12: 主屏回退 —— 在 SB 视图树中找目标 scene 的呈现容器（_UISceneLayerHostContainerView）
// 链（探针 v0.1.2/0.1.3 已验证）：容器 → _dataSource(_UIScenePresentationView) → presenter → owner → scene
// 也尝试容器直持 _scene（探针注释：容器持有 _scene + _presentationContext + _dataSource）
// v0.3.13 增强：真机 SCREEN_HIDE_NOTFOUND —— 诊断窗口/容器数量 + 打印每个容器可解析的 sceneID
// + 兜底隐藏 _UIScenePresentationView（presenter 呈现视图，容器父级）
static UIView *poc_search_sb_container(UIView *v, NSString *sid, int depth, BOOL *matched) {
    if (!v || depth > 20) return nil;
    if ([poc_cls(v) isEqualToString:@"_UISceneLayerHostContainerView"] ||
        [poc_cls(v) isEqualToString:@"_UIScenePresentationView"]) {
        @try {
            NSString *scid = nil;
            id scene = poc_tryKVC(v, @[@"_scene", @"scene"]);
            if (scene) scid = poc_scene_id(scene);
            if (!scid) {
                id ds = poc_tryKVC(v, @[@"_dataSource", @"dataSource"]);
                id presenter = ds ? poc_tryKVC(ds, @[@"presenter", @"_presenter"]) : nil;
                id owner = presenter ? poc_tryKVC(presenter, @[@"owner", @"_owner", @"presenterOwner", @"_presenterOwner"]) : nil;
                id sc2 = owner ? poc_tryKVC(owner, @[@"scene"]) : nil;
                if (sc2) scid = poc_scene_id(sc2);
            }
            if (!scid) {
                // 兜底：presenter → scene 直连
                id pres = poc_tryKVC(v, @[@"presenter", @"_presenter"]);
                if (pres) {
                    id sc3 = poc_tryKVC(pres, @[@"scene"]);
                    if (sc3) scid = poc_scene_id(sc3);
                }
            }
            if (scid) {
                // v0.3.13 诊断：记录该容器归属的 scene（同场景只记一次）
                static NSMutableSet *g_seen = nil;
                if (!g_seen) g_seen = [NSMutableSet set];
                if (![g_seen containsObject:scid]) {
                    [g_seen addObject:scid];
                    poc_log(@"SB_CONTAINER cls=%@ scene=%@", poc_cls(v), scid);
                }
                if (scid && sid && [scid isEqualToString:sid]) { *matched = YES; return v; }
            }
        } @catch (NSException *e) { }
    }
    for (UIView *sub in v.subviews) {
        UIView *r = poc_search_sb_container(sub, sid, depth + 1, matched);
        if (r) return r;
    }
    return nil;
}
static UIView *poc_find_sb_container(NSString *sid) {
    NSArray *ws = [[UIApplication sharedApplication] windows];
    poc_log(@"SB_WINDOW_COUNT %lu", (unsigned long)ws.count);
    BOOL matched = NO;
    for (UIWindow *w in ws) {
        UIView *r = poc_search_sb_container(w, sid, 0, &matched);
        if (r) return r;
    }
    return nil;
}
// 隐藏目标 app 的全屏呈现（主屏不显示 → 露出桌面）。WRITE RISK = MEDIUM：
//   - 只改 SB 视图树的 hidden 状态（可恢复），不碰 scene 状态机
//   - app 退出(lc==0)时 KEEP 自动恢复显示；SB 重启自然复原
//   - 最坏风险：SB 布局/动画异常 → respring（闸门兜底，可 dpkg -r 回滚）
static void poc_screen_hide(NSString *sid) {
    if (!sid || g_sbContainer) return;
    @try {
        g_sbContainer = poc_find_sb_container(sid);
        if (g_sbContainer) {
            [g_sbContainer setHidden:YES];
            poc_log(@"SCREEN_HIDE_OK cls=%@", poc_cls(g_sbContainer));
        } else {
            poc_log(@"SCREEN_HIDE_NOTFOUND");
        }
    } @catch (NSException *e) {
        g_sbContainer = nil;
        poc_log(@"SCREEN_HIDE_EXC %@", e.name);
    }
}
static void poc_screen_restore(void) {
    if (!g_sbContainer) return;
    @try {
        [g_sbContainer setHidden:NO];
        poc_log(@"SCREEN_SHOW_RESTORE");
    } @catch (NSException *e) {
        poc_log(@"SCREEN_SHOW_EXC %@", e.name);
    }
    g_sbContainer = nil;
}

// v0.3.16: 关闭浮窗 —— 只移除浮窗 UI（窗口/容器/host/红诊断），不释放/杀死目标 App Scene
// WRITE RISK = LOW
//   - 只改自己创建的 UIWindow/视图的 hidden/引用；不动 SB 状态、不动 FBScene、不动 layerManager
//   - g_win 置 nil 后 poc_try_float 下一 tick 重新建窗 → "关闭后重新打开仍能 HOST_REFRESH"
//   - 主屏回退恢复（露出桌面）；scene 的 layer 保持系统管理，原 app 仍在
static void poc_close_float(void) {
    @try {
        poc_screen_restore();          // 1. 恢复主屏显示（若有隐藏）
        if (g_win) {
            // v0.4.0+: 关闭动画 —— v0.4.7 借鉴 Stheno AnyTransition（asymmetric 移除侧）：
            // 0.15s 淡出 + scale 1.0→0.96，完成后移除（先解除引用防重复点击二次动画）
            UIWindow *w = g_win;
            g_win = nil;
            [UIView animateWithDuration:0.15 delay:0 options:UIViewAnimationOptionCurveEaseIn
                             animations:^{
                w.alpha = 0.0;
                w.transform = CGAffineTransformMakeScale(0.96, 0.96);
            }
                             completion:^(BOOL done) {
                w.rootViewController = nil;
                w.hidden = YES;
            }];
        }
        g_container = nil;
        g_hostView = nil;
        g_diag = nil;
        g_floatClosed = YES;           // v0.3.18: 保持关闭 —— 不自动重建；目标 scene 消失后才复位
        // v0.3.18: g_lastSid 保留（用于判断目标 scene 何时消失）；g_lastCtx 归零
        g_lastCtx = 0;
        // v0.4.15: 浮窗关闭 → "浮"按钮重现（手动触发入口）
        if (g_triggerWin) g_triggerWin.hidden = NO;
        poc_log(@"FLOAT_CLOSED — scene untouched, window removed, stay closed until target app exits");
    } @catch (NSException *e) {
        poc_log(@"FLOAT_CLOSE_EXC %@", e.name);
    }
}

// v0.2.1: B 方案最小写 —— 空窗期调用 activateWithTransitionContext: 拉回 scene
// WRITE RISK = MEDIUM
//   - 可能把目标 app 短暂拉回主屏（行为错误，用户切走即恢复，可观察）
//   - context 未配置可能触发 SB 状态机异常 → respring（闸门兜底，可回滚）
//   - 不碰数据/越狱
// 保护：节流 6s 一次 + @try + 闸门
static void poc_scene_keepalive(id scene, NSInteger lastCtx) {
    if (!scene) return;
    static double lastCall = 0;
    double now = CACurrentMediaTime();
    if (now - lastCall < 6.0) return;  // 节流
    lastCall = now;
    @try {
        SEL sel = sel_registerName("activateWithTransitionContext:");
        if (![scene respondsToSelector:sel]) {
            poc_log(@"KEEPALIVE_API_MISSING");
            return;
        }
        id ctx = nil;
        Class c = NSClassFromString(@"FBSSceneTransitionContext");
        if (c) ctx = [[c alloc] init];
        poc_log(@"KEEPALIVE_CALL lastCtx=%ld ctxCls=%@", (long)lastCtx, ctx ? NSStringFromClass(c) : @"nil");
        void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
        fn(scene, sel, ctx);
        poc_log(@"KEEPALIVE_CALLED");
    } @catch (NSException *e) {
        poc_log(@"KEEPALIVE_EXC %@", e.name);
    }
}
static void poc_probe_scene_apis(id scene) {
    if (!scene || g_apiProbed) return;
    g_apiProbed = YES;
    NSArray *selNames = @[
        @"activate", @"activateWithTransitionContext:", @"activateWithCompletion:",
        @"deactivate", @"deactivateWithTransitionContext:",
        @"_applyUpdateToSettings:", @"_updateToSettings:",
        @"_activateScene:", @"activateScene:"
    ];
    for (NSString *n in selNames) {
        if ([scene respondsToSelector:NSSelectorFromString(n)]) {
            poc_log(@"SCENE_API_FOUND %@", n);
        }
    }
    // presenter 侧：scene 是否回指 presentation manager
    id pm = poc_tryKVC(scene, @[@"_presentationManager", @"presentationManager", @"presenterManager"]);
    if (pm) poc_log(@"SCENE_PM cls=%@", poc_cls(pm));
    else poc_log(@"SCENE_PM nil");
    // scene 的 observer/生命周期委托面
    id ob = poc_tryKVC(scene, @[@"_observer", @"observer"]);
    if (ob) poc_log(@"SCENE_OBSERVER cls=%@", poc_cls(ob));
}

// v0.1.8: 保持模式 —— 切换应用后 scene layer 可能被系统重建（contextID 漂移），
// 每 3s 检测：窗口存活 / host 存活 / contextID 变化 → 自动重建 host view
static void poc_keep_float(void) {
    @try {
        BOOL winAlive = NO;
        for (UIWindow *w in [[UIApplication sharedApplication] windows]) {
            if (w == g_win) { winAlive = YES; break; }
        }
        BOOL hostAlive = (g_hostView.superview != nil);
        // 重读目标 scene 当前 layer contextID
        id newLayer = nil;
        NSInteger newCtx = 0;
        id targetScene = nil;   // v0.2.0: 循环外保存目标 scene
        for (id sc in poc_all_scenes()) {
            NSString *sid = poc_scene_id(sc);
            if (!g_lastSid || ![sid isEqualToString:g_lastSid]) continue;
            targetScene = sc;
            id lm = poc_tryKVC(sc, @[@"layerManager", @"_layerManager"]);
            id layers = poc_tryKVC(lm, @[@"layers", @"_layers", @"sceneLayers"]);
            NSArray *arr = nil;
            if ([layers isKindOfClass:[NSArray class]]) arr = layers;
            else if ([layers isKindOfClass:[NSSet class]]) arr = [layers allObjects];
            else if ([layers isKindOfClass:[NSOrderedSet class]]) arr = [layers array];
            else if ([layers respondsToSelector:@selector(allObjects)]) arr = [layers allObjects];
            // v0.3.7: 收集所有 type=0 layer（页面切换时新增 layer 才是当前显示层）
            NSMutableArray *type0s = [NSMutableArray array];
            for (id l in arr) {
                NSString *t = poc_str(poc_tryKVC(l, @[@"_type", @"type"]));
                NSInteger c = [poc_tryKVC(l, @[@"_contextID", @"contextID"]) integerValue];
                if ([t isEqualToString:@"0"]) [type0s addObject:@{@"layer": l, @"ctx": @(c)}];
            }
            // v0.3.7: lc 变化 = 页面切换事件 → 优先切到"新 layer"（ctx != 当前 host ctx）
            // 酷安实锤：二级页面 lc 1→2，新页面内容在新 layer，旧 layer context 白屏
            // v0.3.9 修正：酷安新增 layer 是 type=1（不是 type=0！），切换不限于 type=0 —— 所有 layer 都算
            NSMutableArray *allLayersInfo = [NSMutableArray array];
            for (id l in arr) {
                NSString *t = poc_str(poc_tryKVC(l, @[@"_type", @"type"]));
                NSInteger c = [poc_tryKVC(l, @[@"_contextID", @"contextID"]) integerValue];
                [allLayersInfo addObject:@{@"layer": l, @"ctx": @(c), @"type": t}];
                if ([t isEqualToString:@"0"]) [type0s addObject:@{@"layer": l, @"ctx": @(c)}];
            }
            static NSInteger g_lastLc = -1;
            if (g_lastLc >= 0 && (NSInteger)arr.count != g_lastLc && allLayersInfo.count) {
                NSInteger switchCtx = 0; id switchLayer = nil;
                for (NSDictionary *d in allLayersInfo) {
                    NSInteger c = [d[@"ctx"] integerValue];
                    if (c != g_lastCtx) { switchLayer = d[@"layer"]; switchCtx = c; break; }
                }
                if (switchLayer) {
                    newLayer = switchLayer; newCtx = switchCtx;
                    poc_log(@"LAYER_SWITCH lc=%ld→%ld ctx=%ld→%ld", (long)g_lastLc, (long)arr.count, (long)g_lastCtx, (long)newCtx);
                } else {
                    poc_log(@"LAYER_SWITCH_NONE lc=%ld→%ld (all layers share ctx=%ld)", (long)g_lastLc, (long)arr.count, (long)g_lastCtx);
                }
            }
            g_lastLc = arr.count;
            // v0.3.10 修复：非切换路径优先保持当前 host 的 ctx（防止 lc 不变时又切回第一个 layer → 来回抖动/白屏闪烁）
            // v0.3.9 实锤：切换后 lc 仍=2，下次 KEEP 取 arr.firstObject（旧层）→ HOST_REFRESH 切回 → 抖动
            if (!newLayer) {
                for (NSDictionary *d in allLayersInfo) {
                    if ([d[@"ctx"] integerValue] == g_lastCtx) { newLayer = d[@"layer"]; newCtx = g_lastCtx; break; }
                }
            }
            if (!newLayer && type0s.count) { newLayer = type0s[0][@"layer"]; newCtx = [type0s[0][@"ctx"] integerValue]; }
            if (!newLayer && arr.count) { newLayer = arr.firstObject; newCtx = [poc_tryKVC(newLayer, @[@"_contextID", @"contextID"]) integerValue]; }
            break;
        }
        // v0.2.0: 记录 activationState 序列（切走后降到几是关键证据）
        // v0.2.1: KVC 拿不到（key 名不对），改用 objc_msgSend 直调方法
        NSString *actStr = @"nil";
        @try {
            if ([targetScene respondsToSelector:@selector(activationState)]) {
                NSInteger (*fn)(id, SEL) = (NSInteger (*)(id, SEL))objc_msgSend;
                actStr = [NSString stringWithFormat:@"%ld", (long)fn(targetScene, @selector(activationState))];
            }
        } @catch (NSException *e) { }
        // v0.3.5: 二级页面诊断 —— 目标 scene 当前 layer 数 + native 尺寸（app 内导航可能新增/更换 layer）
        NSInteger lc = 0;
        CGSize kn = CGSizeZero;
        NSString *ksrc = @"nil";
        @try {
            id lm2 = poc_tryKVC(targetScene, @[@"layerManager", @"_layerManager"]);
            id layers2 = poc_tryKVC(lm2, @[@"layers", @"_layers", @"sceneLayers"]);
            NSArray *arr2 = nil;
            if ([layers2 isKindOfClass:[NSArray class]]) arr2 = layers2;
            else if ([layers2 isKindOfClass:[NSSet class]]) arr2 = [layers2 allObjects];
            else if ([layers2 isKindOfClass:[NSOrderedSet class]]) arr2 = [layers2 array];
            else if ([layers2 respondsToSelector:@selector(allObjects)]) arr2 = [layers2 allObjects];
            lc = arr2.count;
            for (id l in arr2) {
                NSString *t2 = poc_str(poc_tryKVC(l, @[@"_type", @"type"]));
                if ([t2 isEqualToString:@"0"]) {
                    kn = poc_layer_native_size(l);
                    if (kn.width > 0) { ksrc = @"layer"; break; }
                }
            }
            if (kn.width <= 0) { kn = [[UIScreen mainScreen] bounds].size; ksrc = @"screen"; }
            // v0.3.7: lc 变化时打全 layer 明细（type/ctx），追踪页面切换
            static NSInteger g_diagLc = -1;
            if (g_diagLc != lc) {
                g_diagLc = lc;
                @try {
                    id lm3 = poc_tryKVC(targetScene, @[@"layerManager", @"_layerManager"]);
                    id layers3 = poc_tryKVC(lm3, @[@"layers", @"_layers", @"sceneLayers"]);
                    NSArray *arr3 = nil;
                    if ([layers3 isKindOfClass:[NSArray class]]) arr3 = layers3;
                    else if ([layers3 isKindOfClass:[NSSet class]]) arr3 = [layers3 allObjects];
                    else if ([layers3 isKindOfClass:[NSOrderedSet class]]) arr3 = [layers3 array];
                    else if ([layers3 respondsToSelector:@selector(allObjects)]) arr3 = [layers3 allObjects];
                    NSMutableString *ms = [NSMutableString string];
                    for (id l in arr3) {
                        NSString *t3 = poc_str(poc_tryKVC(l, @[@"_type", @"type"]));
                        NSInteger c3 = [poc_tryKVC(l, @[@"_contextID", @"contextID"]) integerValue];
                        // v0.3.9: 加 hidden 标志（判断哪个 layer 是当前显示层）
                        NSString *h3 = @"?";
                        @try {
                            id hv = [l valueForKey:@"hidden"];
                            if (hv) h3 = [hv boolValue] ? @"H" : @"V";
                        } @catch (NSException *e) { }
                        [ms appendFormat:@" t%@=ctx%ld(%@)", t3, (long)c3, h3];
                    }
                    poc_log(@"KEEP_L lc=%ld%@", (long)lc, ms);
                } @catch (NSException *e) { }
            }
        } @catch (NSException *e) { }
        poc_log(@"KEEP winAlive=%d hostAlive=%d act=%@ ctx=%ld last=%ld lc=%ld native=%@ src=%@", winAlive, hostAlive,
                actStr, (long)newCtx, (long)g_lastCtx, (long)lc, NSStringFromCGSize(kn), ksrc);
        // v0.3.14: app 重新打开（layer 重新出现）后，再次执行主屏回退 ——
        // SCREEN_HIDE 只在首次建窗时执行一次，lc=0 恢复显示后（SCREEN_SHOW_RESTORE）需重新隐藏
        // poc_screen_hide 幂等（g_sbContainer 非 nil 自动跳过；找不到只日志），每 3s 调用安全
        // v0.4.0: 主屏回退开关（设置）
        if (g_lastSid && newCtx > 0 && g_sbContainer == nil && poc_setting_bool(@"screenHide", YES)) {
            poc_screen_hide(g_lastSid);
        }
        // v0.2.0: 空窗（layer 被释放）时探测 scene 激活 API 面 —— 只一次
        if (newCtx == 0) {
            poc_probe_scene_apis(targetScene);
            // v0.3.12: 目标 app 退出（layer 清空）→ 恢复主屏显示
            if (lc == 0) poc_screen_restore();
            // v0.2.1: B 方案最小写 —— activateWithTransitionContext: 拉回 scene
            // v0.2.2: 已禁用！真机实锤：裸 FBSSceneTransitionContext 触发 SB 崩溃（安全模式）。
            //         保持只读，切换保留列为专项（需逆向 context 内部结构或 hook scene 生命周期）。
            // poc_scene_keepalive(targetScene, g_lastCtx);
        }
        // contextID 漂移 → 重建 host view（保持浮窗内容跟随 scene layer）
        if (newCtx > 0 && newCtx != g_lastCtx && newLayer) {
            poc_log(@"HOST_REFRESH ctx=%ld→%ld", (long)g_lastCtx, (long)newCtx);
            int path = 0;
            UIView *nhv = poc_make_host_view(newLayer, newCtx, &path);
            if (nhv) {
                // v0.3.0: 新 host 放回容器内容区（保持容器位置/大小不变）
                if (g_container) {
                    QSFloatContainer *c = (QSFloatContainer *)g_container;
                    // v0.3.3: 同步 native 尺寸（scene layer 可能随重建变化）
                    // v0.3.4: 多 key + 屏幕兜底
                    CGSize ns = poc_layer_native_size(newLayer);
                    if (ns.width <= 0) ns = [[UIScreen mainScreen] bounds].size;
                    c.nativeContentSize = ns;
                    [c.contentView removeFromSuperview];
                    c.contentView = nhv;
                    [c setNeedsLayout];
                } else {
                    nhv.frame = g_hostView.frame;
                    UIView *sup = g_hostView.superview;
                    if (sup) [sup insertSubview:nhv aboveSubview:g_hostView];
                    [g_hostView removeFromSuperview];
                }
                g_hostView = nhv;
                g_lastCtx = newCtx;
                poc_log(@"HOST_REFRESH_OK path=%d", path);
            } else {
                poc_log(@"HOST_REFRESH_FAIL path=0");
            }
        }
    } @catch (NSException *e) {
        poc_log(@"KEEP_EXC %@", e.name);
    }
}

static void poc_try_float(void) {
    // v0.4.0: 总开关（设置）
    if (!poc_setting_bool(@"enabled", YES)) return;
    if (g_win) {   // v0.1.8: 窗口已建立 → 保持模式
        poc_keep_float();
        return;
    }
    // v0.4.15: 手动触发 —— 只有"浮"按钮被按下才尝试建浮窗；不再每次自动弹
    if (!g_triggerArmed) return;
    g_triggerArmed = NO;
    // v0.4.20: 手动选择覆盖"关闭保持"—— 用户明确点选应用，即使 g_floatClosed=YES（曾点 ×）也必须建浮窗
    g_floatClosed = NO;

    // 1. 确定目标
    // v0.4.16: 手动选择（右缘滑动选择器）优先 > 设置 targets > /tmp/qsp_target（兼容）
    NSString *targetsSet = poc_setting_str(@"targets", @"");
    NSString *wanted = nil;
    if (g_manualSid.length) {
        wanted = g_manualSid;
    } else if (targetsSet.length) {
        wanted = targetsSet;
    } else {
        NSString *fileWanted = [NSString stringWithContentsOfFile:@"/tmp/qsp_target"
                                                        encoding:NSUTF8StringEncoding error:NULL];
        wanted = [fileWanted stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    NSDictionary *target = poc_pick_target(wanted);
    if (!target) {
        // v0.3.17: TARGET_NONE 日志节流（1s tick 下闲置会刷屏）——每 10s 一条
        static NSTimeInterval lastNoneLog = 0;
        NSTimeInterval nowT = CACurrentMediaTime();
        if (nowT - lastNoneLog >= 10.0) {
            lastNoneLog = nowT;
            poc_log(@"TARGET_NONE wanted=%@ — waiting for app scene", wanted ?: @"(auto)");
        }
        return;
    }
    NSString *sid = target[@"sid"];
    id scene = target[@"scene"];
    id layer = [target[@"layer"] isKindOfClass:[NSNull class]] ? nil : target[@"layer"];
    // v0.3.18: 关闭后保持关闭 —— 用户点 × 后浮窗不应 1s 后自动重建。
    // 仅当目标 app 的 scene 真正消失（app 退出）后复位，下次打开该 app 才重建浮窗。
    if (g_floatClosed) {
        if (g_lastSid && !poc_scene_alive(g_lastSid)) {
            g_floatClosed = NO;
            g_lastSid = nil;
            poc_log(@"FLOAT_REOPEN_ARMED — target scene gone, next launch will re-float");
        }
        return;
    }
    NSInteger ctx = [target[@"ctx"] integerValue];
    NSInteger pid = [target[@"pid"] integerValue];
    NSInteger layerCount = [target[@"layerCount"] integerValue];
    NSString *lmCls = target[@"lmCls"];
    NSString *layersKind = target[@"layersKind"];
    NSString *layerType = layer ? poc_str(poc_tryKVC(layer, @[@"_type", @"type"])) : @"nil";
    poc_log(@"TARGET sid=%@ pid=%ld lm=%@ layersKind=%@ layerCount=%ld layer=%@ layerType=%@ ctx=%ld",
            sid, (long)pid, lmCls, layersKind, (long)layerCount, poc_cls(layer), layerType, (long)ctx);

    // v0.1.9: 前台检测放宽 —— 不再阻塞前台 host！
    // v0.1.8 实锤：后台 app 的 scene layer 被 iOS 周期性重建/冻结（ctx 漂移+空窗），
    // 浮窗内容无法持续。Stheno 托管的 app 保持 foregroundActive(ACT=1)，layer 才稳定。
    // v0.1.6"主线程阻塞"实为误判（全屏窗口吞触摸 + 60s 未到截图太早，非真阻塞）。
    // 现在前台直接 host（保留 hitTest 穿透 + 心跳，若真阻塞 TICK 会立即暴露）。
    @try {
        NSNumber *act = poc_tryKVC(scene, @[@"activationState", @"_activationState"]);
        poc_log(@"TARGET_ACT sid=%@ act=%@", sid, act ?: @"nil");
    } @catch (NSException *e) { }

    // 2. 渲染 host view（Phase 0 核心风险点）
    //    轨道 A：FBSceneLayer 对象（后台/浮窗托管 app）→ 路径 1/2/3
    //    轨道 B：layerManager 为空（前台 app）→ 从系统宿主容器拿 contextID → 路径 3
    int path = 0;
    UIView *hv = nil;
    if (layer) {
        hv = poc_make_host_view(layer, ctx, &path);
    }
    if (!hv) {
        NSString *containerCls = nil;
        NSInteger layerCtx = 0;
        NSInteger winCtx = poc_find_container_ctx(sid, &containerCls, &layerCtx);
        if (layerCtx > 0) ctx = layerCtx;
        else if (winCtx > 0) ctx = winCtx;
        if (ctx > 0) {
            poc_log(@"TRACKB_USED container=%@ ctx=%ld", containerCls ?: @"nil", (long)ctx);
            hv = poc_host_view_from_ctx(ctx);
            if (hv) path = 3;
        }
    }
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
        // v0.1.5: SB 是 scene-based，未关联 windowScene 的窗口不渲染（SthenoWindow 实测 SCENE=SuperHighLevelSystemAperture）
        // 优先关联 SuperHighLevelSystemAperture scene，兜底第一个 UIWindowScene
        NSString *winScene = @"nil";
        @try {
            Class wsc = NSClassFromString(@"UIWindowScene");
            id chosen = nil; id fallback = nil;
            for (UIScene *sc in [[UIApplication sharedApplication] connectedScenes]) {
                if (!wsc || ![sc isKindOfClass:wsc]) continue;
                if (!fallback) fallback = sc;
                NSString *sid = poc_scene_id(sc);
                if ([sid containsString:@"SuperHighLevelSystemAperture"]) { chosen = sc; break; }
            }
            id use = chosen ?: fallback;
            if (use) {
                [g_win setValue:use forKey:@"windowScene"];
                winScene = poc_scene_id(use);
            }
        } @catch (NSException *e) { }
        // v0.1.4 可见性诊断 → v0.1.7 独立红色视图（背景 clear，红色全靠 g_diag，20s 后移除）
        POCController *vc = [[POCController alloc] init];
        vc.view.backgroundColor = [UIColor clearColor];
        g_win.rootViewController = vc;
        UIView *diag = [[UIView alloc] initWithFrame:vc.view.bounds];
        diag.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        diag.backgroundColor = [UIColor colorWithRed:1.0 green:0.0 blue:0.0 alpha:0.35];
        diag.userInteractionEnabled = NO;   // 不拦截触摸
        [vc.view addSubview:diag];
        g_diag = diag;
        // 3.1 v0.3.0: 浮窗容器（边框拖动/缩放）+ host view 作为内容
        // v0.3.3: 记录 scene layer 原始尺寸 → 容器 contain 等比缩放（内容不拉伸变形）
        // v0.3.4: native 获取失败 → 屏幕尺寸兜底（全屏 app 的 scene layer ≈ 屏幕）
        // v0.3.5: 初始容器按 native 比例（避免 contain 灰边过宽）
        CGSize native = poc_layer_native_size(layer);
        NSString *nsrc = @"layer";
        if (native.width <= 0 || native.height <= 0) {
            native = [[UIScreen mainScreen] bounds].size;
            nsrc = @"screen-fallback";
        }
        CGFloat cw = 340, ch = 500;
        if (native.width > 0 && native.height > 0) {
            ch = cw * (native.height / native.width);
            if (ch > 860) { ch = 860; cw = ch * (native.width / native.height); }
        }
        // v0.3.12: 优先恢复记忆的浮窗位置/尺寸（拖动/缩放结束时已持久化）
        CGRect memFrame = poc_load_float_state();
        CGRect cframe = CGRectMake((g_win.bounds.size.width - cw) / 2.0,
                                   (g_win.bounds.size.height - ch) / 2.0,
                                   cw, ch);
        if (memFrame.size.width > 0 && memFrame.size.height > 0) cframe = memFrame;
        QSFloatContainer *container = [[QSFloatContainer alloc] initWithFrame:cframe];
        container.nativeContentSize = native;
        container.contentView = hv;   // layoutSubviews 安排 14px 内边距 + contain 等比
        [vc.view addSubview:container];
        [container layoutIfNeeded];
        g_container = container;
        g_hostView = hv;
        poc_log(@"WINDOW_OK class=%@ level=%.1f frame=%@ container=%@ host=%@ scene=%@ bg=RED_DIAG native=%@ src=%@",
                poc_cls(g_win), g_win.windowLevel,
                NSStringFromCGRect(g_win.frame), poc_cls(container), poc_cls(hv), winScene,
                NSStringFromCGSize(native), nsrc);
        // v0.4.7: 打开转场 —— 借鉴 Stheno AnyTransition.scale+opacity（asymmetric 插入侧）：
        // scale 0.94→1.0 + alpha 0→1，0.22s easeOut
        g_win.alpha = 0.0;
        g_win.transform = CGAffineTransformMakeScale(0.94, 0.94);
        [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            g_win.alpha = 1.0;
            g_win.transform = CGAffineTransformIdentity;
        } completion:nil];
    } @catch (NSException *e) {
        poc_log(@"WINDOW_EXC %@ — abort", e.name);
        return;
    }

    // 4. Z-order（写操作 #2，最小：仅目标 scene 的 presenter，失败不阻断）
    poc_zorder_raise(sid, scene);

    // 5. 标记 OK（崩溃闸门复位）
    poc_mark_ok();
    g_lastSid = [sid copy];
    g_lastCtx = ctx;
    // v0.4.15: 浮窗建立 → 隐藏"浮"按钮（浮窗有关闭按钮，无需双入口）
    if (g_triggerWin) g_triggerWin.hidden = YES;
    poc_log(@"POC_OK sid=%@ path=%d — floating window established", sid, path);
    // v0.3.12: 主屏回退 —— 隐藏目标 app 的全屏呈现（露出桌面/主屏不显示）。
    // 在 POC_OK 后执行：若 SB 容器隐藏失败不影响浮窗（只日志）。
    // v0.4.0: 主屏回退开关（设置）
    if (poc_setting_bool(@"screenHide", YES)) poc_screen_hide(sid);
    // v0.1.7: 心跳日志验证主线程活性（若 10s/30s TICK 缺失 → 主线程被 host 阻塞）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        poc_log(@"TICK_10S main-thread-alive");
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        poc_log(@"TICK_30S main-thread-alive");
    });
    // v0.1.8: 红背景自动关闭缩短到 20s（用户要求减少等待）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        @try {
            if (g_diag) {
                [g_diag removeFromSuperview];
                g_diag = nil;
            }
            poc_log(@"RED_AUTOCLOSE done — red diagnostic background removed");
        } @catch (NSException *e) {
            poc_log(@"RED_AUTOCLOSE_EXC %@", e.name);
        }
    });
}

// 注入入口：延迟 5s 启动，之后每 1s 尝试一次（等待手动触发/目标 App scene 出现）
@interface POCBootstrap : NSObject
@end

// v0.4.16: 屏幕右侧滑动选择器（Stheno 风格）—— 右缘滑入 → 弹出运行中 App 列表 → 点选进浮窗
static UIViewController *g_pickerVC = nil;   // 承载面板的控制器（trigger window 的 rootVC 动态创建）

static void poc_picker_hide(void) {
    @try {
        if (g_pickerPanel) {
            [UIView animateWithDuration:0.2 animations:^{
                g_pickerPanel.frame = CGRectMake(430, g_pickerPanel.frame.origin.y,
                                                 g_pickerPanel.frame.size.width, g_pickerPanel.frame.size.height);
            } completion:^(BOOL done) {
                g_pickerPanel.hidden = YES;
            }];
        }
    } @catch (NSException *e) { }
}

// 运行中 App 列表（去重）：workspace scenes → sceneID:xxx → bundle id
static NSArray *poc_running_apps(void) {
    NSMutableArray *apps = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id sc in poc_all_scenes()) {
        NSString *sid = poc_scene_id(sc);
        if (![sid hasPrefix:@"sceneID:"]) continue;
        if ([sid containsString:@"com.apple."]) continue;
        if ([sid containsString:@"Stheno"] || [sid containsString:@"QingSplit"]) continue;
        NSString *bundle = [sid substringFromIndex:@"sceneID:".length];
        if ([bundle containsString:@"-"]) bundle = [bundle substringToIndex:[bundle rangeOfString:@"-"].location];
        if (!bundle.length || [seen containsObject:bundle]) continue;
        [seen addObject:bundle];
        [apps addObject:@{@"sid": sid, @"bundle": bundle}];
    }
    return apps;
}

static void poc_picker_select(NSString *sid) {
    g_manualSid = [sid copy];
    g_triggerArmed = YES;
    poc_log(@"PICKER_SELECT sid=%@ armed=1", sid);
    poc_picker_hide();
}

static void poc_picker_show(void) {
    @try {
        if (!g_triggerWin || g_win) return;   // 浮窗已激活 → 不弹选择器
        if (!g_pickerVC) {
            UIViewController *vc = [[UIViewController alloc] init];
            vc.view.backgroundColor = [UIColor clearColor];
            g_triggerWin.rootViewController = vc;
            g_pickerVC = vc;
        }
        // 面板 —— v0.4.22: 宽度 220，高度/位置自适应：行高铺满触发条(150pt)，行区对齐触发条 y=391
        UIView *panel = g_pickerPanel;
        NSArray *apps = poc_running_apps();
        NSUInteger n = apps.count ? apps.count : 1;
        CGFloat rowH = (n <= 3) ? (150.0 / n) : 50.0;         // 行高：1 行=150 铺满红线，2=75，3=50，多则 50
        if (rowH < 44) rowH = 44;
        g_pickerRowH = rowH;
        CGFloat pH = 54 + rowH * n + 20;
        CGFloat panelY = MIN(337, 932 - pH - 20);             // 行区起点=panelY+54=391 → 与触发条顶对齐
        if (!panel) {
            panel = [[UIView alloc] initWithFrame:CGRectMake(430, panelY, 220, pH)];
            panel.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.92];
            panel.layer.cornerRadius = 20;
            panel.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
            panel.clipsToBounds = YES;
            g_pickerPanel = panel;
            [g_pickerVC.view addSubview:panel];
        }
        [panel.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
        // 标题
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 12, 190, 30)];
        title.text = @"选择要悬浮的应用";
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:15];
        [panel addSubview:title];
        // 应用行 —— v0.4.22: 行高自适应(铺满触发条) + 应用图标(LSApplicationProxy→UIImage 私有，失败仅文本)
        CGFloat y = 54;
        NSMutableArray *rows = [NSMutableArray array];
        NSUInteger iconsShown = 0;
        for (NSDictionary *a in apps) {
            UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, y, 220, rowH)];
            row.tag = 0;
            row.backgroundColor = [UIColor clearColor];   // v0.4.19: 默认透明，跟手高亮时改色
            // 图标：1) LSApplicationProxy iconDataForVariant: 2) UIImage 私有 3) 仅文本
            UIImage *icon = nil;
            @try {
                id proxy = [NSClassFromString(@"LSApplicationProxy") performSelector:@selector(applicationProxyForIdentifier:) withObject:a[@"bundle"]];
                if (proxy) {
                    NSData *d = [proxy performSelector:@selector(iconDataForVariant:) withObject:@"2x"];
                    if ([d isKindOfClass:[NSData class]] && d.length) icon = [UIImage imageWithData:d];
                }
            } @catch (NSException *e) { icon = nil; }
            if (!icon) {
                @try {
                    SEL s = sel_registerName("_applicationIconImageForBundleIdentifier:");
                    if ([[UIImage class] respondsToSelector:s]) {
                        id (*fn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
                        icon = fn([UIImage class], s, a[@"bundle"]);
                    }
                } @catch (NSException *e) { }
            }
            if (icon) iconsShown++;
            UIView *txtWrap = [[UIView alloc] initWithFrame:CGRectMake(12, 0, 196, rowH)];
            if (icon) {
                UIImageView *iv = [[UIImageView alloc] initWithImage:icon];
                iv.frame = CGRectMake(0, (rowH - 36) / 2.0, 36, 36);
                iv.layer.cornerRadius = 7;
                iv.clipsToBounds = YES;
                [txtWrap addSubview:iv];
            }
            UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(icon ? 46 : 0, (rowH - 18) / 2.0, 150, 18)];
            lbl.text = a[@"bundle"];
            lbl.textColor = [UIColor whiteColor];
            lbl.font = [UIFont systemFontOfSize:14];
            lbl.adjustsFontSizeToFitWidth = YES;
            lbl.minimumScaleFactor = 0.6;
            [txtWrap addSubview:lbl];
            [row addSubview:txtWrap];
            // 点击 → 选中（兼容点选；主交互是跟手松手确认）
            UIButton *bt = [UIButton buttonWithType:UIButtonTypeCustom];
            bt.frame = row.bounds;
            bt.tag = 1000 + (NSInteger)(y / rowH);
            [bt addTarget:[POCBootstrap class] action:@selector(poc_picker_row:) forControlEvents:UIControlEventTouchUpInside];
            [row addSubview:bt];
            [panel addSubview:row];
            [rows addObject:row];
            y += rowH;
        }
        g_pickerRows = rows;   // v0.4.19: 供跟手高亮
        // 滑入动画（从右缘滑到面板位 202=430-220-8）
        panel.frame = CGRectMake(430, panelY, 220, pH);
        panel.hidden = NO;
        [UIView animateWithDuration:0.25 animations:^{
            panel.frame = CGRectMake(202, panelY, 220, pH);
        }];
        poc_log(@"PICKER_SHOW apps=%ld panelY=%.0f rowH=%.0f icons=%lu", (long)apps.count, panelY, rowH, (unsigned long)iconsShown);
    } @catch (NSException *e) {
        poc_log(@"PICKER_SHOW_EXC %@", e.name);
    }
}

static void poc_setup_edge_trigger(void) {
    @try {
        g_triggerWin = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
        g_triggerWin.windowLevel = 998.0;   // 低于浮窗 999.0（浮窗激活时窗口隐藏）
        g_triggerWin.userInteractionEnabled = YES;
        @try {
            Class wsc = NSClassFromString(@"UIWindowScene");
            id chosen = nil; id fallback = nil;
            for (UIScene *sc in [[UIApplication sharedApplication] connectedScenes]) {
                if (!wsc || ![sc isKindOfClass:wsc]) continue;
                if (!fallback) fallback = sc;
                NSString *sid = poc_scene_id(sc);
                if ([sid containsString:@"SuperHighLevelSystemAperture"]) { chosen = sc; break; }
            }
            id use = chosen ?: fallback;
            if (use) [g_triggerWin setValue:use forKey:@"windowScene"];
        } @catch (NSException *e) { }
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor clearColor];
        g_triggerWin.rootViewController = vc;
        g_pickerVC = vc;
        // v0.4.20: 右缘触发条（20px 宽 × 150 高，屏幕中部）—— 只是触发起点，滑入后手指可自由在面板内上下移动选择
        UIView *strip = [[UIView alloc] initWithFrame:CGRectMake(430 - 20, 391, 20, 150)];
        strip.userInteractionEnabled = YES;   // 该区域无系统内容（右侧中段），独占右缘手势
        strip.backgroundColor = [UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:0.12];   // 触发区提示（可后续去掉）
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                       initWithTarget:[POCBootstrap class]
                                       action:@selector(poc_edge_panned:)];
        pan.minimumNumberOfTouches = 1;
        pan.maximumNumberOfTouches = 1;
        [strip addGestureRecognizer:pan];
        [vc.view addSubview:strip];
        g_triggerWin.hidden = NO;
        poc_log(@"EDGE_TRIGGER armed strip=%@", NSStringFromCGRect(strip.frame));
    } @catch (NSException *e) {
        poc_log(@"EDGE_TRIGGER_EXC %@", e.name);
    }
}

@implementation POCBootstrap
+ (void)poc_edge_panned:(UIPanGestureRecognizer *)g {
    // v0.4.19: 跟手选择 —— 滑入弹选择器，手指在面板内上下移动高亮当前行，松手确认/关闭
    CGPoint p = [g locationInView:g.view];   // rootView 坐标 = 屏幕坐标
    if (g.state == UIGestureRecognizerStateBegan) {
        if (g_pickerPanel && !g_pickerPanel.hidden) poc_picker_hide();   // 重复滑入先收旧面板
        return;
    }
    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:g.view];
        if (t.x < -30 && !(g_pickerPanel && !g_pickerPanel.hidden)) {
            poc_picker_show();
            [g setTranslation:CGPointZero inView:g.view];
        }
        // 面板内行高亮跟随手指 —— v0.4.21: 最近行判定（手指 y 不必精确落在行内，高亮最近行作视觉反馈）；v0.4.22: 行高用 g_pickerRowH
        if (g_pickerPanel && !g_pickerPanel.hidden && g_pickerRows.count) {
            CGRect pf = g_pickerPanel.frame;
            CGFloat rowTop = pf.origin.y + 54;
            CGFloat rowBot = rowTop + g_pickerRowH * g_pickerRows.count;
            NSInteger idx = -1;
            if (p.y >= rowTop && p.y <= rowBot) {
                CGFloat frac = (p.y - rowTop) / g_pickerRowH;
                idx = (NSInteger)lround(frac);
                if (idx < 0) idx = 0;
                if (idx >= (NSInteger)g_pickerRows.count) idx = (NSInteger)g_pickerRows.count - 1;
            }
            for (NSUInteger i = 0; i < g_pickerRows.count; i++) {
                UIView *row = g_pickerRows[i];
                row.backgroundColor = (i == (NSUInteger)idx) ? [UIColor colorWithWhite:1.0 alpha:0.18]
                                                             : [UIColor clearColor];
            }
        }
    }
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        if (g_pickerPanel && !g_pickerPanel.hidden) {
            CGPoint t = [g translationInView:g.view];
            if (t.x > 30) { poc_picker_hide(); return; }   // v0.4.22: 向右回滑 → 取消
            CGRect pf = g_pickerPanel.frame;
            CGFloat rowTop = pf.origin.y + 54;
            CGFloat rowBot = rowTop + g_pickerRowH * g_pickerRows.count;
            NSInteger idx = -1;
            // v0.4.21: 手指在行区域（±10pt 容差）内 → 选最近行；否则未选中关闭
            if (p.y >= rowTop - 10 && p.y <= rowBot + 10) {
                CGFloat frac = (p.y - rowTop) / g_pickerRowH;
                idx = (NSInteger)lround(frac);
                if (idx < 0) idx = 0;
                if (idx >= (NSInteger)g_pickerRows.count) idx = (NSInteger)g_pickerRows.count - 1;
            }
            if (idx >= 0) {
                NSArray *apps = poc_running_apps();
                if (idx < (NSInteger)apps.count) {
                    poc_picker_select(apps[idx][@"sid"]);   // 松手停在某 App 附近 → 浮窗打开
                } else {
                    poc_picker_hide();
                }
            } else {
                poc_picker_hide();                           // 没停在任何 App → 自动关闭
            }
        }
    }
}
+ (void)poc_picker_row:(UIButton *)btn {
    // v0.4.16: 点击应用行 → 选中该 scene 进浮窗
    NSArray *apps = poc_running_apps();
    NSInteger idx = btn.tag - 1000;
    if (idx >= 0 && idx < (NSInteger)apps.count) {
        poc_picker_select(apps[idx][@"sid"]);
    }
}
+ (void)load {
    poc_open_log();
    poc_log(@"=== QingSplitPOC v0.4.22 LOADED pid=%d ===", (int)getpid());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (poc_safety_gate()) return;
        poc_log(@"BOOTSTRAP_START");
        // v0.4.16: 右侧滑动应用选择器（Stheno 风格入口）
        poc_setup_edge_trigger();
        // v0.3.15: KEEP tick 3s → 1s —— 主屏回退响应提速（app 重新打开后 ≤1s 隐藏全屏，缓解双 host 白屏闪烁）
        NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *tm) {
            poc_try_float();
            // v0.1.8: 窗口建立后不 invalidate —— 每 3s 进入保持模式（contextID 漂移检测）
        }];
        // 兜底：60s 后若仍无目标则停表并记录（不崩溃）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 65 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            // v0.3.17: idle 后不停表（用户随时打开目标 app 都能出浮窗，无需重启），并复位闸门 ok ——
        // 闲置启动无任何窗口写操作、SB 存活，不等于崩溃；防止 boot 累积误触发 SAFE_MODE
        if (!g_win) {
            poc_log(@"TIMEOUT no target scene in 60s — idle, keep polling");
            poc_mark_ok();
        }
        });
    });
}
@end
