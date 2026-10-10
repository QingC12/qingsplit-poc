// QingSplit SwitcherRoute — Phase 0 只读探测（switcher-route 分支）
// ================================================================
// 安全契约（用户强制约定：保证手机安全，不出现卡开机/无法进系统）：
//   1. 本文件只做【只读】探测：NSClassFromString / respondsToSelector /
//      class_copyMethodList / dlsym / KVC 只读。绝不调用任何实例方法、
//      绝不创建对象、绝不修改任何状态、绝不 hook。
//   2. 带副作用的方法（_addAppLayoutToFront: / toggleMedusa / activate 等）
//      只探测【存在性】，绝不调用。
//   3. 失败闸门：任何异常只写日志，不触碰 SpringBoard 状态。
//   4. 日志：/var/mobile/QingSplitSwitcherProbe.log
// ================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static void sp_log(NSString *fmt, ...) {
    @try {
        va_list ap; va_start(ap, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        msg = [msg stringByAppendingString:@"\n"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/var/mobile/QingSplitSwitcherProbe.log"];
        if (!fh) {
            [msg writeToFile:@"/var/mobile/QingSplitSwitcherProbe.log" atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[msg dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
}

// 枚举类实例方法名（只读；按关键词过滤）
static NSArray<NSString *> *sp_methods(Class cls, NSArray<NSString *> *keywords, BOOL isClassMethods) {
    NSMutableArray *out_ = [NSMutableArray array];
    if (!cls) return out_;
    unsigned int mc = 0;
    Method *ms = isClassMethods ? class_copyMethodList(object_getClass(cls), &mc)
                                : class_copyMethodList(cls, &mc);
    if (!ms) return out_;
    for (unsigned int i = 0; i < mc; i++) {
        SEL sel = method_getName(ms[i]);
        NSString *name = NSStringFromSelector(sel);
        BOOL hit = (keywords.count == 0);
        for (NSString *kw in keywords) {
            if ([name rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) { hit = YES; break; }
        }
        if (hit) [out_ addObject:name];
    }
    free(ms);
    [out_ sortUsingSelector:@selector(compare:)];
    return out_;
}

// 类 + 指定 selector 存在性（只读，不调用）
static void sp_sel(NSString *clsName, NSString *selName, NSString *tag) {
    Class c = NSClassFromString(clsName);
    if (!c) { sp_log(@"SEL %@ %@ MISSING_CLASS", tag, selName); return; }
    SEL s = NSSelectorFromString(selName);
    BOOL inst = [c instancesRespondToSelector:s];
    BOOL clsM = [c respondsToSelector:s];
    sp_log(@"SEL %@ %@ inst=%d class=%d", tag, selName, inst, clsM);
}

// 符号存在性（dlsym 只读）
static void sp_symbol(const char *sym, NSString *tag) {
    void *p = dlsym(RTLD_DEFAULT, sym);
    sp_log(@"SYM %@ %s %@", tag, sym, p ? @"FOUND" : @"missing");
}

// KVC 只读取值
static id sp_kvc(id obj, NSString *key) {
    @try { return [obj valueForKey:key]; } @catch (NSException *e) { return nil; }
}

__attribute__((constructor))
static void switcher_probe_main(void) {
    @try {
        sp_log(@"=== QingSplit SwitcherRoute Phase0 PROBE v0.1 === pid=%d", getpid());
        // 设备/系统
        UIDevice *dev = [UIDevice currentDevice];
        sp_log(@"DEVICE %@ iOS %@", dev.model, dev.systemVersion);
        sp_log(@"SCREEN %@", NSStringFromCGRect([UIScreen mainScreen].bounds));

        // 1. SBAppLayout 类 + 方法
        Class sbAppLayout = NSClassFromString(@"SBAppLayout");
        sp_log(@"CLASS SBAppLayout %@", sbAppLayout ? @"EXISTS" : @"MISSING");
        if (sbAppLayout) {
            NSArray *m1 = sp_methods(sbAppLayout, @[@"init", @"layout", @"role", @"item", @"config"], NO);
            sp_log(@"METH SBAppLayout-inst(%lu): %@", (unsigned long)[m1 count], [m1 componentsJoinedByString:@","]);
            NSArray *m2 = sp_methods(sbAppLayout, @[@"init", @"layout", @"role", @"item", @"config"], YES);
            sp_log(@"METH SBAppLayout-class(%lu): %@", (unsigned long)[m2 count], [m2 componentsJoinedByString:@","]);
        }
        // 2. initWithItemsForLayoutRoles: 变体
        sp_sel(@"SBAppLayout", @"initWithItemsForLayoutRoles:configuration:environment:", @"INIT_ROLES_3");
        sp_sel(@"SBAppLayout", @"initWithItemsForLayoutRoles:configuration:environment:preferredDisplayOrdinal:", @"INIT_ROLES_4");
        sp_sel(@"SBAppLayout", @"initWithItemsForLayoutRoles:", @"INIT_ROLES_1");
        sp_sel(@"SBAppLayout", @"initWithItems:", @"INIT_ITEMS");

        // 3. 布局角色类/枚举
        sp_log(@"CLASS SBLayoutRole %@", NSClassFromString(@"SBLayoutRole") ? @"EXISTS" : @"missing");
        sp_log(@"CLASS SBMainDisplayLayoutRole %@", NSClassFromString(@"SBMainDisplayLayoutRole") ? @"EXISTS" : @"missing");
        sp_log(@"CLASS SBAppLayoutRole %@", NSClassFromString(@"SBAppLayoutRole") ? @"EXISTS" : @"missing");
        sp_log(@"CLASS SBFloatingApplicationLayoutRole %@", NSClassFromString(@"SBFloatingApplicationLayoutRole") ? @"EXISTS" : @"missing");

        // 4. switcher 相关类
        NSArray *switcherCls = @[
            @"SBMainSwitcherViewController", @"SBMainSwitcherControllerCoordinator",
            @"SBFluidSwitcherGestureManager", @"SBAppSwitcherController",
            @"SBSwitcherController", @"_SBRecentlyUsedSceneIdentityCache",
            @"SBFluidSwitcherViewController", @"SBAppLayoutElement",
        ];
        for (NSString *cn in switcherCls) {
            Class c = NSClassFromString(cn);
            sp_log(@"CLASS %@ %@", cn, c ? @"EXISTS" : @"MISSING");
            if (c) {
                NSArray *mm = sp_methods(c, @[@"switcher", @"layout", @"medusa", @"deck", @"addApp", @"presenter", @"gesture", @"role", @"front"], NO);
                sp_log(@"  METH-inst(%lu): %@", (unsigned long)[mm count],
                       [[mm subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)30, mm.count))] componentsJoinedByString:@","]);
            }
        }

        // 5. 关键动作存在性（只探测，绝不调用）
        sp_sel(@"SBMainSwitcherViewController", @"_addAppLayoutToFront:", @"ADD_APP_LAYOUT");
        sp_sel(@"SBMainSwitcherViewController", @"addAppLayoutToFront:", @"ADD_APP_LAYOUT_PUB");
        sp_sel(@"SBAppSwitcherController", @"_addAppLayoutToFront:", @"ADD_APP_LAYOUT_ALT");
        sp_sel(@"SBSwitcherController", @"toggleMedusa", @"TOGGLE_MEDUSA");
        sp_sel(@"SBMainSwitcherViewController", @"toggleMedusa", @"TOGGLE_MEDUSA_ALT");
        sp_sel(@"SBMainSwitcherViewController", @"isAnySwitcherVisible", @"ANY_VISIBLE");
        sp_sel(@"SBMainSwitcherViewController", @"isMainSwitcherVisible", @"MAIN_VISIBLE");
        sp_sel(@"SBFluidSwitcherGestureManager", @"_handleDeckSwitcherPanGesture:", @"DECK_PAN");
        sp_sel(@"SBFluidSwitcherGestureManager", @"_handleClickAndDragHomeGesture:", @"HOME_DRAG");
        sp_sel(@"SBFluidSwitcherGestureManager", @"_handlePullGesture:", @"PULL_GESTURE");
        sp_sel(@"SBFluidSwitcherGestureManager", @"createPresenterWithIdentifier:priority:", @"CREATE_PRESENTER");

        // 6. FBScene 管理
        sp_log(@"CLASS FBSceneManager %@", NSClassFromString(@"FBSceneManager") ? @"EXISTS" : @"missing");
        sp_log(@"CLASS FBSceneWorkspace %@", NSClassFromString(@"FBSceneWorkspace") ? @"EXISTS" : @"missing");
        Class fbw = NSClassFromString(@"FBSceneWorkspace");
        if (fbw) {
            NSArray *fm = sp_methods(fbw, @[@"scene", @"workspace", @"create", @"identifier", @"client"], NO);
            sp_log(@"METH FBSceneWorkspace-inst(%lu): %@", (unsigned long)[fm count],
                   [[fm subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)25, fm.count))] componentsJoinedByString:@","]);
            NSArray *fcm = sp_methods(fbw, @[@"workspace", @"shared", @"default", @"scene"], YES);
            sp_log(@"METH FBSceneWorkspace-class(%lu): %@", (unsigned long)[fcm count], [fcm componentsJoinedByString:@","]);
        }
        Class fbm = NSClassFromString(@"FBSceneManager");
        if (fbm) {
            NSArray *fm2 = sp_methods(fbm, @[@"scene", @"create", @"identifier", @"client", @"add"], NO);
            sp_log(@"METH FBSceneManager-inst(%lu): %@", (unsigned long)[fm2 count],
                   [[fm2 subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)25, fm2.count))] componentsJoinedByString:@","]);
            NSArray *fcm2 = sp_methods(fbm, @[@"shared", @"default", @"scene"], YES);
            sp_log(@"METH FBSceneManager-class(%lu): %@", (unsigned long)[fcm2 count], [fcm2 componentsJoinedByString:@","]);
        }

        // 7. _FBSOpenApplicationOptionKeyActivateSuspended 常量符号
        sp_symbol("_FBSOpenApplicationOptionKeyActivateSuspended", @"FBS_ACTIVATE_SUSPENDED");
        sp_symbol("_FBSOpenApplicationOptionKeyLaunchOrigin", @"FBS_LAUNCH_ORIGIN");
        sp_symbol("_FBSOpenApplicationOptionKeyPayloadURL", @"FBS_PAYLOAD_URL");

        // 8. 当前 connectedScenes 布局角色（KVC 只读）
        @try {
            NSSet *scenes = [UIApplication sharedApplication].connectedScenes;
            sp_log(@"SCENES_COUNT %lu", (unsigned long)scenes.count);
            for (id sc in scenes) {
                NSString *cls = NSStringFromClass([sc class]);
                NSString *role = sp_kvc(sc, @"role");
                NSString *layoutRole = sp_kvc(sc, @"layoutRole");
                NSString *lifecycle = sp_kvc(sc, @"activationState");
                sp_log(@"SCENE class=%@ role=%@ layoutRole=%@ state=%@", cls, role, layoutRole, lifecycle);
            }
        } @catch (NSException *e) { sp_log(@"SCENES_EXC %@", e.name); }

        // 9. UIWindowScene 现存窗口层级快照（只读）
        @try {
            NSArray *wins = [UIApplication sharedApplication].windows;
            for (UIWindow *w in wins) {
                sp_log(@"WINDOW %@ level=%.0f hidden=%d key=%d", NSStringFromClass([w class]), w.windowLevel, w.hidden, (w == [UIApplication sharedApplication].keyWindow));
            }
        } @catch (NSException *e) { sp_log(@"WINDOWS_EXC %@", e.name); }

        // 10. LSApplicationWorkspace 中目标 app 的 scene 配置（只读）
        @try {
            Class ls = NSClassFromString(@"LSApplicationWorkspace");
            if (ls) {
                id ws = [ls performSelector:@selector(defaultWorkspace)];
                NSArray *apps = [ws performSelector:@selector(allApplications)];
                sp_log(@"APPS_COUNT %lu", (unsigned long)apps.count);
            }
        } @catch (NSException *e) { sp_log(@"APPS_EXC %@", e.name); }

        // 11. _setActivePrioritizedPresenter: 存在性（Stheno z-order 关键）
        sp_sel(@"SBFluidSwitcherGestureManager", @"_setActivePrioritizedPresenter:", @"SET_PRESENTER");
        sp_sel(@"SBMainSwitcherViewController", @"_setActivePrioritizedPresenter:", @"SET_PRESENTER_ALT");
        sp_sel(@"UIWindowScene", @"_setActivePrioritizedPresenter:", @"SET_PRESENTER_SCENE");

        sp_log(@"=== PROBE COMPLETE === no-state-written");
    } @catch (NSException *e) {
        sp_log(@"PROBE_FATAL %@", e.name);
    }
}
