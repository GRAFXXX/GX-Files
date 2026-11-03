// GX Files — делегат приложения
#import "GXCore.h"

#pragma mark - Приложение

@interface GXAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation GXAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    // старые временные файлы
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{ [FM() removeItemAtPath:[caches stringByAppendingPathComponent:@"GXTemp"] error:nil]; });
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [GXPanelsVC new];
    self.window.tintColor = [UIColor colorWithRed:0.35 green:0.45 blue:1.0 alpha:1.0];
    [self.window makeKeyAndVisible];
    return YES;
}

// Файлы, открытые в GX Files из других приложений («Открыть в…»)
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary *)options {
    if (!url.isFileURL) return NO;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    // Файл из «Файлов» открыт на месте — работаем с оригиналом, без копии во «Входящие»
    if ([options[UIApplicationOpenURLOptionsOpenInPlaceKey] boolValue] && [FM() isReadableFileAtPath:url.path]) {
        static NSMutableArray<NSURL *> *keep;            // доступ к файлу держим до конца работы приложения
        if (!keep) keep = [NSMutableArray array];
        if (scoped) [keep addObject:url];
        UINavigationController *nav = [GXPanelsVC.shared currentNav];
        [nav popToRootViewControllerAnimated:NO];
        [GXOpener open:url.path from:nav.topViewController];
        return YES;
    }
    NSString *inbox = [GXDocsDir() stringByAppendingPathComponent:@"Входящие"]; // noi18n
    [FM() createDirectoryAtPath:inbox withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dest = GXUniquePath(inbox, url.lastPathComponent);
    [FM() copyItemAtURL:url toURL:[NSURL fileURLWithPath:dest] error:nil];
    if (scoped) [url stopAccessingSecurityScopedResource];
    UINavigationController *nav = [GXPanelsVC.shared currentNav];
    [nav popToRootViewControllerAnimated:NO];
    [nav pushViewController:[[GXBrowserVC alloc] initWithPath:inbox] animated:NO];
    [GXOpener open:dest from:nav.topViewController];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(GXAppDelegate.class));
    }
}
