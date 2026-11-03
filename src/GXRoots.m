// GX Files — главный экран и настройки
#import "GXCore.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface GXRootsVC () <UIDocumentPickerDelegate>
@end

#pragma mark - Главный экран


@implementation GXRootsVC {
    NSArray<NSDictionary *> *_sections;
    NSArray<NSString *> *_favs, *_recents;
}
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"GX Files";
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.right.circle"] style:UIBarButtonItemStylePlain target:self action:@selector(gotoPath)],
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"] style:UIBarButtonItemStylePlain target:self action:@selector(search)]];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"rectangle.split.2x1"] style:UIBarButtonItemStylePlain target:self action:@selector(switchPanel)];
    self.tableView.rowHeight = 62;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:YES animated:animated];
    [GXLCApp allApps:YES];
    _sections = GXRootSections();
    _favs = GXFavorites();
    NSMutableArray *rec = [NSMutableArray array];
    for (NSString *p in GXRecents()) if ([FM() fileExistsAtPath:p]) [rec addObject:p];
    _recents = [rec subarrayWithRange:NSMakeRange(0, MIN(rec.count, 6))];
    [self.tableView reloadData];
}

- (NSString *)searchRoot { return GXLCHome() ?: NSHomeDirectory(); }

- (void)gotoPath {
    GXBrowserVC *b = [[GXBrowserVC alloc] initWithPath:[self searchRoot]];
    [self.navigationController pushViewController:b animated:NO];
    dispatch_async(dispatch_get_main_queue(), ^{ [b promptGoto]; });
}

- (void)switchPanel { [GXPanelsVC.shared switchPanel]; }

- (void)search { [self.navigationController pushViewController:[[GXSearchVC alloc] initWithRoot:[self searchRoot]] animated:YES]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return _sections.count + (_favs.count ? 1 : 0) + (_recents.count ? 1 : 0); }

// Индексы: [секции корней...] [избранное?] [недавние?]
- (NSInteger)favIndex { return _favs.count ? (NSInteger)_sections.count : -1; }
- (NSInteger)recIndex { return _recents.count ? (NSInteger)_sections.count + (_favs.count ? 1 : 0) : -1; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s < (NSInteger)_sections.count) return [_sections[s][@"rows"] count];
    if (s == [self favIndex]) return _favs.count;
    return _recents.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s < (NSInteger)_sections.count) return _sections[s][@"title"];
    return s == [self favIndex] ? GXL(@"Избранное") : GXL(@"Недавние файлы");
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 0) return GXInLiveContainer() ? [NSString stringWithFormat:GXL(@"Контейнер: %@"), GXLCHome()] : GXL(@"Обычная установка: доступна своя папка и подключённые папки из «Файлов». Чужие приложения закрыты песочницей iOS.");
    if (s == [self favIndex]) return GXL(@"Смахните влево, чтобы убрать.");
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"r"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"r"];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.detailTextLabel.numberOfLines = 2;
    c.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    c.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    c.accessibilityIdentifier = nil;
    if (ip.section < (NSInteger)_sections.count) {
        NSDictionary *r = _sections[ip.section][@"rows"][ip.row];
        c.imageView.image = GXSymbolTile(r[@"icon"], r[@"color"], 32);
        c.textLabel.text = r[@"title"];
        c.detailTextLabel.text = r[@"subtitle"];
        if ([r[@"action"] isEqualToString:@"none"]) c.accessoryType = UITableViewCellAccessoryNone;
    } else {
        BOOL fav = ip.section == [self favIndex];
        NSString *p = fav ? _favs[ip.row] : _recents[ip.row];
        BOOL dir = GXIsDir(p);
        GXKind k = GXKindForName(p.lastPathComponent, dir);
        c.imageView.image = fav ? GXSymbolTile(@"star.fill", UIColor.systemYellowColor, 32) : GXSymbolTile(GXSymbolForKind(k), GXColorForKind(k), 32);
        c.textLabel.text = p.lastPathComponent.length ? p.lastPathComponent : p;
        c.detailTextLabel.text = p.stringByDeletingLastPathComponent;
        c.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingHead;
        if (!fav && (k == GXKindAndroid || k == GXKindIPA || k == GXKindImage)) {
            c.accessibilityIdentifier = p;
            [GXIcons iconForPath:p kind:k side:32 completion:^(UIImage *img) { if (img && [c.accessibilityIdentifier isEqualToString:p]) { c.imageView.image = img; [c setNeedsLayout]; } }];
        }
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section < (NSInteger)_sections.count) {
        NSDictionary *r = _sections[ip.section][@"rows"][ip.row];
        NSString *act = r[@"action"];
        if (r[@"path"]) { [self.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:r[@"path"]] animated:YES]; return; }
        if ([act isEqualToString:@"apps"]) [self.navigationController pushViewController:[GXAppsVC new] animated:YES];
        else if ([act isEqualToString:@"wifi"]) [self.navigationController pushViewController:[[GXServerVC alloc] initWithRoot:GXDocsDir()] animated:YES];
        else if ([act isEqualToString:@"search"]) [self search];
        else if ([act isEqualToString:@"addfolder"]) [self pickFolderFrom:[tv cellForRowAtIndexPath:ip]];
        else if ([act isEqualToString:@"compiler"]) [self.navigationController pushViewController:[[GXCompilerVC alloc] initWithPath:nil] animated:YES];
        else if ([act isEqualToString:@"findreplace"]) [self.navigationController pushViewController:[[GXFindVC alloc] initWithRoot:[self searchRoot]] animated:YES];
        else if ([act isEqualToString:@"signinfo"]) GXAlert(self, GXL(@"Ключ подписи APK"), GXSignerInfo());
        else if ([act isEqualToString:@"usage"]) [self.navigationController pushViewController:[[GXUsageVC alloc] initWithPath:[self searchRoot]] animated:YES];
        else if ([act isEqualToString:@"settings"]) [self.navigationController pushViewController:[GXSettingsVC new] animated:YES];
        else if ([act isEqualToString:@"download"]) {
            GXBrowserVC *b = [[GXBrowserVC alloc] initWithPath:GXDocsDir()];
            [self.navigationController pushViewController:b animated:YES];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [b downloadURL];
            });
        }
        return;
    }
    NSString *p = ip.section == [self favIndex] ? _favs[ip.row] : _recents[ip.row];
    if (GXIsDir(p)) [self.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:p] animated:YES];
    else [GXOpener open:p from:self];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tv contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)pt {
    NSString *p = nil;
    if (ip.section < (NSInteger)_sections.count) p = _sections[ip.section][@"rows"][ip.row][@"path"];
    else p = ip.section == [self favIndex] ? _favs[ip.row] : _recents[ip.row];
    if (!p) return nil;
    __weak typeof(self) ws = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *s) {
        return [UIMenu menuWithTitle:p children:@[
            [UIAction actionWithTitle:GXL(@"Копировать путь") image:[UIImage systemImageNamed:@"link"] identifier:nil handler:^(UIAction *a) { UIPasteboard.generalPasteboard.string = p; GXToast(ws.view, GXL(@"Путь скопирован")); }],
            [UIAction actionWithTitle:GXL(@"Показать в папке") image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(UIAction *a) {
                [ws.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:GXIsDir(p) ? p : p.stringByDeletingLastPathComponent] animated:YES]; }],
            [UIAction actionWithTitle:GXL(@"Анализ места") image:[UIImage systemImageNamed:@"chart.pie"] identifier:nil handler:^(UIAction *a) {
                [ws.navigationController pushViewController:[[GXUsageVC alloc] initWithPath:GXIsDir(p) ? p : p.stringByDeletingLastPathComponent] animated:YES]; }],
            [UIAction actionWithTitle:GXL(@"Свойства") image:[UIImage systemImageNamed:@"info.circle"] identifier:nil handler:^(UIAction *a) { GXPresentNav(ws, [[GXInfoVC alloc] initWithPath:p], NO); }]]];
    }];
}

// Два способа: новый API (iOS 14+) и старый «Open»-режим — на некоторых версиях iOS работает только один из них
- (void)pickFolderFrom:(UIView *)src {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"Подключить папку") message:GXL(@"Зайди внутрь нужной папки и нажми «Открыть». Если кнопка не нажимается — попробуй второй способ.") preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Способ 1 (обычный)") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
        p.delegate = self;
        p.modalPresentationStyle = UIModalPresentationFormSheet;
        [self presentViewController:p animated:YES completion:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Способ 2 (совместимый)") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.folder"] inMode:UIDocumentPickerModeOpen];
#pragma clang diagnostic pop
        p.delegate = self;
        p.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:p animated:YES completion:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = src ?: self.view;
    a.popoverPresentationController.sourceRect = (src ?: self.view).bounds;
    [self presentViewController:a animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (!urls.count) return;
    int ok = 0; NSString *err = nil; NSString *last = nil;
    for (NSURL *u in urls) {
        NSString *e = GXAddLinkedFolder(u);
        if (e) err = e; else { ok++; last = u.lastPathComponent; }
    }
    [self viewWillAppear:NO];
    if (ok == 1) GXToast(self.view, [NSString stringWithFormat:GXL(@"Папка «%@» подключена"), last]);
    else if (ok > 1) GXToast(self.view, [NSString stringWithFormat:GXL(@"Подключено папок: %d"), ok]);
    else GXAlert(self, GXL(@"Не удалось подключить папку"), err ?: @"");
}

- (NSDictionary *)rowAt:(NSIndexPath *)ip { return ip.section < (NSInteger)_sections.count ? _sections[ip.section][@"rows"][ip.row] : nil; }
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return ip.section == [self favIndex] || ip.section == [self recIndex] || [self rowAt:ip][@"linked"] != nil; }
- (NSString *)tableView:(UITableView *)tv titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip { return [self rowAt:ip][@"linked"] ? GXL(@"Отключить") : GXL(@"Удалить"); }
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)st forRowAtIndexPath:(NSIndexPath *)ip {
    if (st != UITableViewCellEditingStyleDelete) return;
    NSString *lk = [self rowAt:ip][@"linked"];
    if (lk) { GXRemoveLinkedFolder(lk); [self viewWillAppear:NO]; return; }
    if (ip.section == [self favIndex]) {
        NSMutableArray *f = _favs.mutableCopy;
        [f removeObjectAtIndex:ip.row];
        GXSetFavorites(f);
    } else {
        NSMutableArray *r = GXRecents().mutableCopy;
        [r removeObject:_recents[ip.row]];
        [GXDefaults() setObject:r forKey:@"gxRecents"];
    }
    [self viewWillAppear:NO];
}
@end

#pragma mark - Настройки

@interface GXLanguageVC : UITableViewController
@end
@implementation GXLanguageVC
- (instancetype)init { if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = GXL(@"Язык / Language"); return self; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return s == 0 ? 1 : (NSInteger)GXLanguages().count; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return s == 1 ? GXL(@"Перевод сделан автоматически и может быть неточным. Исправления принимаются на GitHub: файлы i18n/<код>.tsv.") : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSString *cur = GXLangSetting();
    if (ip.section == 0) {
        c.textLabel.text = GXL(@"Как в системе");
        c.detailTextLabel.text = GXL(@"Язык iPhone, если он поддерживается, иначе английский");
        c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        c.accessoryType = cur ? UITableViewCellAccessoryNone : UITableViewCellAccessoryCheckmark;
        return c;
    }
    NSArray *l = GXLanguages()[ip.row];
    c.textLabel.text = l[1];
    c.detailTextLabel.text = l[0];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.accessoryType = [cur isEqualToString:l[0]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    GXSetLanguage(ip.section == 0 ? nil : GXLanguages()[ip.row][0]);
    // пересобрать интерфейс на новом языке
    UIWindow *w = self.view.window;
    [UIView transitionWithView:w duration:0.3 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{ w.rootViewController = [GXPanelsVC new]; } completion:nil];
}
@end

@implementation GXSettingsVC
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = GXL(@"Настройки");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
}
- (NSArray *)toggles {
    return @[@[GXL(@"Показывать скрытые файлы"), @"gxShowHidden", @YES], @[GXL(@"Крупные значки"), @"gxBigIcons", @NO], @[GXL(@"Миниатюры фото и видео"), @"gxThumbnails", @YES]];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 4; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return s == 0 ? 1 : s == 1 ? (NSInteger)[self toggles].count : 2; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return @[GXL(@"Язык"), GXL(@"Вид"), GXL(@"Данные"), GXL(@"О программе")][s]; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    if (ip.section == 0) {
        c.textLabel.text = GXL(@"Язык / Language");
        c.imageView.image = [UIImage systemImageNamed:@"globe"];
        NSString *cur = GXLangSetting();
        NSString *name = GXL(@"Как в системе");
        for (NSArray *l in GXLanguages()) if ([l[0] isEqualToString:cur]) name = l[1];
        c.detailTextLabel.text = name;
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.section == 1) {
        NSArray *t = [self toggles][ip.row];
        c.textLabel.text = t[0];
        UISwitch *sw = [UISwitch new];
        sw.on = [GXDefaults() objectForKey:t[1]] ? [GXDefaults() boolForKey:t[1]] : [t[2] boolValue];
        sw.tag = ip.row;
        [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (ip.section == 2) {
        c.textLabel.text = ip.row == 0 ? GXL(@"Очистить кэш иконок и временных файлов") : GXL(@"Очистить недавние");
        c.textLabel.textColor = self.view.tintColor;
    } else {
        NSArray *rows = @[@[GXL(@"Версия"), [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?"],
                          @[GXL(@"Режим"), GXInLiveContainer() ? @"LiveContainer" : GXL(@"Обычное приложение")]];
        c.textLabel.text = rows[ip.row][0];
        c.detailTextLabel.text = rows[ip.row][1];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return c;
}
- (void)toggle:(UISwitch *)sw { [GXDefaults() setBool:sw.on forKey:[self toggles][sw.tag][1]]; }
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) { [self.navigationController pushViewController:[GXLanguageVC new] animated:YES]; return; }
    if (ip.section != 2) return;
    if (ip.row == 0) { [GXIcons clearCache]; GXToast(self.view, GXL(@"Кэш очищен")); }
    else { [GXDefaults() removeObjectForKey:@"gxRecents"]; GXToast(self.view, GXL(@"Готово")); }
}
@end

