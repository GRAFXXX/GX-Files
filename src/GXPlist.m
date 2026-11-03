// Древовидный редактор plist / .strings / .stringsdict / JSON / mobileprovision
#import "GXCore.h"

typedef NS_ENUM(NSInteger, GXPlistFormat) { GXFmtXML, GXFmtBinary, GXFmtStrings, GXFmtJSON };

@interface GXPlistDoc : NSObject
@property (nonatomic, strong) id root;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) GXPlistFormat format;
@property (nonatomic) BOOL dirty, readOnly, utf16;
@end

static BOOL GXIsBool(id v) { return [v isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID(); }

static NSString *GXTypeName(id v) {
    if ([v isKindOfClass:NSDictionary.class]) return @"Dictionary";
    if ([v isKindOfClass:NSArray.class]) return @"Array";
    if ([v isKindOfClass:NSString.class]) return @"String";
    if (GXIsBool(v)) return @"Boolean";
    if ([v isKindOfClass:NSNumber.class]) return @"Number";
    if ([v isKindOfClass:NSDate.class]) return @"Date";
    if ([v isKindOfClass:NSData.class]) return @"Data";
    if ([v isKindOfClass:NSNull.class]) return @"null";
    return NSStringFromClass([v class]);
}

static NSString *GXPreview(id v) {
    if ([v isKindOfClass:NSDictionary.class]) return [NSString stringWithFormat:GXL(@"%lu элементов"), (unsigned long)[v count]];
    if ([v isKindOfClass:NSArray.class]) return [NSString stringWithFormat:GXL(@"%lu элементов"), (unsigned long)[v count]];
    if ([v isKindOfClass:NSString.class]) return [(NSString *)v length] > 300 ? [[v substringToIndex:300] stringByAppendingString:@"…"] : v;
    if (GXIsBool(v)) return [v boolValue] ? @"true" : @"false";
    if ([v isKindOfClass:NSNumber.class]) return [v stringValue];
    if ([v isKindOfClass:NSDate.class]) return [GXDateFmt() stringFromDate:v];
    if ([v isKindOfClass:NSData.class]) return [NSString stringWithFormat:@"%@ · %@", GXHuman([v length]), GXHexString(v, 24)];
    if ([v isKindOfClass:NSNull.class]) return @"null";
    return [v description];
}

static NSString *GXEscapeStrings(NSString *s) {
    s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    s = [s stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    s = [s stringByReplacingOccurrencesOfString:@"\t" withString:@"\\t"];
    return s;
}

static id GXDeepMutable(id v) {
    if ([v isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        [(NSDictionary *)v enumerateKeysAndObjectsUsingBlock:^(id k, id o, BOOL *st) { m[k] = GXDeepMutable(o); }];
        return m;
    }
    if ([v isKindOfClass:NSArray.class]) {
        NSMutableArray *m = [NSMutableArray array];
        for (id o in v) [m addObject:GXDeepMutable(o)];
        return m;
    }
    return v;
}

@implementation GXPlistDoc
- (NSString *)save {
    NSError *err;
    NSData *out = nil;
    switch (_format) {
        case GXFmtJSON:
            if (![NSJSONSerialization isValidJSONObject:_root]) return GXL(@"Данные нельзя записать как JSON");
            out = [NSJSONSerialization dataWithJSONObject:_root options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes error:&err];
            break;
        case GXFmtStrings: {
            if (![_root isKindOfClass:NSDictionary.class]) return GXL(@"Файл .strings должен быть словарём");
            NSMutableString *s = [NSMutableString string];
            for (NSString *k in [[_root allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
                id v = _root[k];
                if (![v isKindOfClass:NSString.class]) return [NSString stringWithFormat:GXL(@"Значение «%@» не строка — формат .strings это не поддерживает"), k];
                [s appendFormat:@"\"%@\" = \"%@\";\n", GXEscapeStrings(k), GXEscapeStrings(v)];
            }
            if (_utf16) {
                NSMutableData *d = [NSMutableData dataWithBytes:"\xFF\xFE" length:2];
                [d appendData:[s dataUsingEncoding:NSUTF16LittleEndianStringEncoding]];
                out = d;
            } else out = [s dataUsingEncoding:NSUTF8StringEncoding];
            break;
        }
        case GXFmtBinary:
            out = [NSPropertyListSerialization dataWithPropertyList:_root format:NSPropertyListBinaryFormat_v1_0 options:0 error:&err];
            break;
        default:
            out = [NSPropertyListSerialization dataWithPropertyList:_root format:NSPropertyListXMLFormat_v1_0 options:0 error:&err];
    }
    if (!out) return err.localizedDescription ?: GXL(@"Не удалось сериализовать");
    if (![out writeToFile:_path options:NSDataWritingAtomic error:&err]) return err.localizedDescription;
    _dirty = NO;
    return nil;
}

- (NSString *)xmlText {
    if (_format == GXFmtJSON) {
        if (![NSJSONSerialization isValidJSONObject:_root]) return [_root description];
        NSData *d = [NSJSONSerialization dataWithJSONObject:_root options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes error:nil];
        return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"";
    }
    NSData *d = [NSPropertyListSerialization dataWithPropertyList:_root format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"";
}

- (NSString *)setFromText:(NSString *)text {
    NSError *err;
    NSData *d = [text dataUsingEncoding:NSUTF8StringEncoding];
    id v = _format == GXFmtJSON
        ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:&err]
        : [NSPropertyListSerialization propertyListWithData:d options:NSPropertyListMutableContainersAndLeaves format:nil error:&err];
    if (!v) return err.localizedDescription ?: GXL(@"Ошибка разбора");
    if (![v isKindOfClass:NSDictionary.class] && ![v isKindOfClass:NSArray.class]) return GXL(@"Корень должен быть словарём или массивом");
    _root = GXDeepMutable(v);
    return [self save];
}
@end

#pragma mark - Редактор значения

@interface GXValueEditVC : UIViewController
@property (nonatomic, copy) void (^onSave)(NSString *text);
@property (nonatomic, copy) NSString *text;
@end
@implementation GXValueEditVC { UITextView *_tv; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    _tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tv.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    _tv.text = _text;
    _tv.autocorrectionType = UITextAutocorrectionTypeNo;
    _tv.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _tv.textContainerInset = UIEdgeInsetsMake(12, 8, 12, 8);
    [self.view addSubview:_tv];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
}
- (void)viewDidAppear:(BOOL)a { [super viewDidAppear:a]; [_tv becomeFirstResponder]; }
- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)done { if (_onSave) _onSave(_tv.text); [self dismissViewControllerAnimated:YES completion:nil]; }
@end

#pragma mark - Экран контейнера

@interface GXPlistVC () <UISearchResultsUpdating>
- (instancetype)initWithDoc:(GXPlistDoc *)doc container:(id)container title:(NSString *)title;
@end

@implementation GXPlistVC {
    GXPlistDoc *_doc;
    id _container;
    NSArray *_keys;   // ключи словаря либо индексы массива (NSNumber)
    UISearchController *_search;
}

- (instancetype)initWithPath:(NSString *)path error:(NSString **)errOut {
    GXPlistDoc *doc = [GXPlistDoc new];
    doc.path = path;
    NSString *ext = path.pathExtension.lowercaseString;
    NSData *d = nil;
    if ([ext isEqualToString:@"mobileprovision"] || [ext isEqualToString:@"provisionprofile"]) {
        d = GXProvisionPlist(path);
        doc.readOnly = YES;
    } else d = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!d) { if (errOut) *errOut = GXL(@"Не удалось прочитать файл"); return nil; }
    NSError *err;
    id root = nil;
    BOOL json = [@[@"json", @"geojson", @"har", @"webmanifest", @"ipynb"] containsObject:ext];
    if (!json && d.length && (((const char *)d.bytes)[0] == '{' || ((const char *)d.bytes)[0] == '[') && ![ext isEqualToString:@"strings"]) json = YES;
    if (json) {
        root = [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:&err];
        doc.format = GXFmtJSON;
    }
    if (!root) {
        NSPropertyListFormat fmt = 0;
        root = [NSPropertyListSerialization propertyListWithData:d options:NSPropertyListMutableContainersAndLeaves format:&fmt error:&err];
        if (root) {
            doc.format = fmt == NSPropertyListBinaryFormat_v1_0 ? GXFmtBinary : fmt == NSPropertyListOpenStepFormat ? GXFmtStrings : GXFmtXML;
            const uint8_t *b = d.bytes;
            doc.utf16 = d.length >= 2 && ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF) || b[1] == 0);
        }
    }
    if (!root || (![root isKindOfClass:NSDictionary.class] && ![root isKindOfClass:NSArray.class])) {
        if (errOut) *errOut = err.localizedDescription ?: GXL(@"Корень не словарь и не массив");
        return nil;
    }
    doc.root = GXDeepMutable(root);
    return [self initWithDoc:doc container:doc.root title:path.lastPathComponent];
}

- (instancetype)initWithDoc:(GXPlistDoc *)doc container:(id)container title:(NSString *)title {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _doc = doc;
        _container = container;
        self.title = title;
        _readOnly = doc.readOnly;
    }
    return self;
}

- (void)setReadOnly:(BOOL)readOnly { _readOnly = readOnly; _doc.readOnly = readOnly; }

- (void)viewDidLoad {
    [super viewDidLoad];
    _search = [[UISearchController alloc] initWithSearchResultsController:nil];
    _search.searchResultsUpdater = self;
    _search.obscuresBackgroundDuringPresentation = NO;
    _search.searchBar.placeholder = GXL(@"Поиск по ключам и значениям");
    self.navigationItem.searchController = _search;
    if (self.navigationController.viewControllers.firstObject == self)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:GXL(@"Закрыть") style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    [self buildItems];
    [self rebuild];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.navigationController.viewControllers.firstObject == self && _container != _doc.root) _container = _doc.root;
    [self rebuild];
    [self buildItems];
}

- (void)buildItems {
    __weak typeof(self) ws = self;
    NSMutableArray *items = [NSMutableArray array];
    NSMutableArray *menu = [NSMutableArray array];
    NSString *fmtName = @[@"XML plist", @"Binary plist", GXL(@".strings (текст)"), @"JSON"][_doc.format];
    [menu addObject:[UIAction actionWithTitle:[NSString stringWithFormat:GXL(@"Формат: %@"), fmtName] image:[UIImage systemImageNamed:@"info.circle"] identifier:nil handler:^(UIAction *a) {}]];
    [menu addObject:[UIAction actionWithTitle:_readOnly ? GXL(@"Показать как текст") : GXL(@"Редактировать как текст") image:[UIImage systemImageNamed:@"doc.plaintext"] identifier:nil handler:^(UIAction *a) { [ws asText]; }]];
    if (!_readOnly && _doc.format != GXFmtStrings && _doc.format != GXFmtJSON) {
        [menu addObject:[UIAction actionWithTitle:_doc.format == GXFmtBinary ? GXL(@"Сохранять как XML") : GXL(@"Сохранять как Binary") image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"] identifier:nil handler:^(UIAction *a) {
            self->_doc.format = self->_doc.format == GXFmtBinary ? GXFmtXML : GXFmtBinary;
            self->_doc.dirty = YES;
            [ws buildItems];
        }]];
    }
    [menu addObject:[UIAction actionWithTitle:GXL(@"Копировать как текст") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *a) {
        NSData *d = [NSPropertyListSerialization dataWithPropertyList:self->_container format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
        UIPasteboard.generalPasteboard.string = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : [self->_container description];
        GXToast(ws.view, GXL(@"Скопировано"));
    }]];
    [items addObject:[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[UIMenu menuWithTitle:@"" children:menu]]];
    if (!_readOnly) {
        [items addObject:[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addItem)]];
        UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithTitle:GXL(@"Сохранить") style:UIBarButtonItemStyleDone target:self action:@selector(save)];
        save.enabled = _doc.dirty;
        [items insertObject:save atIndex:0];
    }
    self.navigationItem.rightBarButtonItems = items;
}

- (void)rebuild {
    NSString *q = _search.searchBar.text;
    NSArray *keys;
    if ([_container isKindOfClass:NSDictionary.class]) keys = [[_container allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        return [[a description] localizedStandardCompare:[b description]];
    }];
    else {
        NSMutableArray *m = [NSMutableArray array];
        for (NSUInteger i = 0; i < [_container count]; i++) [m addObject:@(i)];
        keys = m;
    }
    if (q.length) keys = [keys filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id k, id b) {
        return [[k description] localizedCaseInsensitiveContainsString:q] || [GXPreview([self valueFor:k]) localizedCaseInsensitiveContainsString:q];
    }]];
    _keys = keys;
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)sc { [self rebuild]; }

- (id)valueFor:(id)key {
    if ([_container isKindOfClass:NSDictionary.class]) return _container[key];
    NSUInteger i = [key unsignedIntegerValue];
    return i < [_container count] ? _container[i] : nil;
}

- (void)setValue:(id)v forKeyObj:(id)key {
    if ([_container isKindOfClass:NSDictionary.class]) ((NSMutableDictionary *)_container)[key] = v;
    else ((NSMutableArray *)_container)[[key unsignedIntegerValue]] = v;
    [self changed];
}

- (void)changed {
    _doc.dirty = YES;
    [self buildItems];
    [self rebuild];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _keys.count; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return [NSString stringWithFormat:@"%@ · %lu", [_container isKindOfClass:NSDictionary.class] ? @"Dictionary" : @"Array", (unsigned long)[_container count]];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"p"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"p"];
    id k = _keys[ip.row];
    id v = [self valueFor:k];
    c.textLabel.text = [k isKindOfClass:NSNumber.class] && [_container isKindOfClass:NSArray.class] ? [NSString stringWithFormat:GXL(@"Элемент %@"), k] : [k description];
    c.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    c.textLabel.numberOfLines = 2;
    NSString *type = GXTypeName(v);
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@  ·  %@", type, GXPreview(v)];
    c.detailTextLabel.numberOfLines = 4;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    BOOL cont = [v isKindOfClass:NSDictionary.class] || [v isKindOfClass:NSArray.class];
    c.accessoryType = cont ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    NSString *sym = cont ? ([v isKindOfClass:NSDictionary.class] ? @"curlybraces" : @"list.number") : [v isKindOfClass:NSString.class] ? @"textformat" :
                    GXIsBool(v) ? @"switch.2" : [v isKindOfClass:NSNumber.class] ? @"number" : [v isKindOfClass:NSDate.class] ? @"calendar" :
                    [v isKindOfClass:NSData.class] ? @"01.square" : @"questionmark";
    c.imageView.image = GXSymbolTile(sym, cont ? UIColor.systemBlueColor : UIColor.systemOrangeColor, 26);
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    id k = _keys[ip.row];
    id v = [self valueFor:k];
    if ([v isKindOfClass:NSDictionary.class] || [v isKindOfClass:NSArray.class]) {
        GXPlistVC *sub = [[GXPlistVC alloc] initWithDoc:_doc container:v title:[k description]];
        [self.navigationController pushViewController:sub animated:YES];
        return;
    }
    if ([v isKindOfClass:NSData.class]) {
        id inner = [NSPropertyListSerialization propertyListWithData:v options:NSPropertyListMutableContainersAndLeaves format:nil error:nil];
        if ([inner isKindOfClass:NSDictionary.class] || [inner isKindOfClass:NSArray.class]) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:[k description] message:GXL(@"Внутри данных — вложенный plist") preferredStyle:UIAlertControllerStyleActionSheet];
            [a addAction:[UIAlertAction actionWithTitle:GXL(@"Открыть вложенный plist (просмотр)") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
                GXPlistDoc *d = [GXPlistDoc new];
                d.root = GXDeepMutable(inner);
                d.readOnly = YES;
                GXPlistVC *sub = [[GXPlistVC alloc] initWithDoc:d container:d.root title:[k description]];
                [self.navigationController pushViewController:sub animated:YES];
            }]];
            if (!_readOnly) [a addAction:[UIAlertAction actionWithTitle:GXL(@"Изменить как base64") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self editKey:k]; }]];
            [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
            a.popoverPresentationController.sourceView = [tv cellForRowAtIndexPath:ip];
            [self presentViewController:a animated:YES completion:nil];
            return;
        }
    }
    if (_readOnly) {
        GXReportVC *r = [[GXReportVC alloc] initWithTitle:[k description] text:[v isKindOfClass:NSData.class] ? [v base64EncodedStringWithOptions:NSDataBase64Encoding76CharacterLineLength] : GXPreview(v)];
        [self.navigationController pushViewController:r animated:YES];
        return;
    }
    [self editKey:k];
}

- (void)editKey:(id)k {
    id v = [self valueFor:k];
    __weak typeof(self) ws = self;
    if (GXIsBool(v)) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:[k description] message:nil preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"true" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [ws setValue:@YES forKeyObj:k]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"false" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [ws setValue:@NO forKeyObj:k]; }]];
        [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    } else if ([v isKindOfClass:NSNumber.class]) {
        GXPrompt(self, [k description], GXL(@"Число"), [v stringValue], nil, GXL(@"Готово"), ^(NSString *s) {
            NSNumber *n = [s containsString:@"."] || [s containsString:@"e"] ? @(s.doubleValue) : @(s.longLongValue);
            [ws setValue:n forKeyObj:k];
        });
    } else if ([v isKindOfClass:NSDate.class]) {
        NSISO8601DateFormatter *f = [NSISO8601DateFormatter new];
        GXPrompt(self, [k description], GXL(@"Дата в формате ISO 8601 (2026-01-31T12:00:00Z)"), [f stringFromDate:v], nil, GXL(@"Готово"), ^(NSString *s) {
            NSDate *d = [f dateFromString:s];
            if (d) [ws setValue:d forKeyObj:k]; else GXAlert(ws, GXL(@"Ошибка"), GXL(@"Неверный формат даты"));
        });
    } else if ([v isKindOfClass:NSData.class]) {
        GXValueEditVC *e = [GXValueEditVC new];
        e.title = [NSString stringWithFormat:@"%@ (base64)", k];
        e.text = [v base64EncodedStringWithOptions:NSDataBase64Encoding76CharacterLineLength];
        e.onSave = ^(NSString *t) {
            NSData *d = [[NSData alloc] initWithBase64EncodedString:t options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (d) [ws setValue:d forKeyObj:k]; else GXAlert(ws, GXL(@"Ошибка"), GXL(@"Неверный base64"));
        };
        GXPresentNav(self, e, NO);
    } else if ([v isKindOfClass:NSString.class]) {
        GXValueEditVC *e = [GXValueEditVC new];
        e.title = [k description];
        e.text = v;
        e.onSave = ^(NSString *t) { [ws setValue:[t mutableCopy] forKeyObj:k]; };
        GXPresentNav(self, e, NO);
    }
}

static id GXDefaultValue(NSString *type) {
    if ([type isEqualToString:@"Dictionary"]) return [NSMutableDictionary dictionary];
    if ([type isEqualToString:@"Array"]) return [NSMutableArray array];
    if ([type isEqualToString:@"Number"]) return @0;
    if ([type isEqualToString:@"Boolean"]) return @NO;
    if ([type isEqualToString:@"Date"]) return [NSDate date];
    if ([type isEqualToString:@"Data"]) return [NSData data];
    return [NSMutableString string];
}

static id GXConvert(id v, NSString *type) {
    if ([type isEqualToString:@"String"]) return [GXPreview(v) mutableCopy];
    if ([type isEqualToString:@"Number"]) return [v respondsToSelector:@selector(doubleValue)] ? @([v doubleValue]) : @0;
    if ([type isEqualToString:@"Boolean"]) return [v respondsToSelector:@selector(boolValue)] ? @([v boolValue]) : @NO;
    if ([type isEqualToString:@"Data"]) return [v isKindOfClass:NSString.class] ? [v dataUsingEncoding:NSUTF8StringEncoding] : [NSData data];
    return GXDefaultValue(type);
}

- (NSArray<NSString *> *)types {
    return _doc.format == GXFmtJSON ? @[@"String", @"Number", @"Boolean", @"Dictionary", @"Array"]
         : _doc.format == GXFmtStrings ? @[@"String"]
         : @[@"String", @"Number", @"Boolean", @"Date", @"Data", @"Dictionary", @"Array"];
}

- (void)pickType:(NSString *)title then:(void (^)(NSString *))block {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *t in [self types]) [a addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { block(t); }]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.lastObject;
    [self presentViewController:a animated:YES completion:nil];
}

- (void)addItem {
    __weak typeof(self) ws = self;
    if ([_container isKindOfClass:NSDictionary.class]) {
        GXPrompt(self, GXL(@"Новый ключ"), nil, nil, GXL(@"Ключ"), GXL(@"Далее"), ^(NSString *key) {
            if (!key.length) return;
            if (self->_container[key]) { GXAlert(ws, GXL(@"Ошибка"), GXL(@"Такой ключ уже есть")); return; }
            if ([ws types].count == 1) { [ws setValue:[NSMutableString string] forKeyObj:key]; [ws editKey:key]; return; }
            [ws pickType:GXL(@"Тип значения") then:^(NSString *t) { [ws setValue:GXDefaultValue(t) forKeyObj:key]; }];
        });
    } else {
        [self pickType:GXL(@"Добавить элемент") then:^(NSString *t) {
            [(NSMutableArray *)self->_container addObject:GXDefaultValue(t)];
            [ws changed];
        }];
    }
}

- (void)deleteKey:(id)k {
    if ([_container isKindOfClass:NSDictionary.class]) [(NSMutableDictionary *)_container removeObjectForKey:k];
    else [(NSMutableArray *)_container removeObjectAtIndex:[k unsignedIntegerValue]];
    [self changed];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (_readOnly) return nil;
    id k = _keys[ip.row];
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:GXL(@"Удалить") handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [self deleteKey:k];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tv contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)pt {
    id k = _keys[ip.row];
    id v = [self valueFor:k];
    __weak typeof(self) ws = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *s) {
        NSMutableArray *acts = [NSMutableArray array];
        [acts addObject:[UIAction actionWithTitle:GXL(@"Копировать значение") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *a) {
            UIPasteboard.generalPasteboard.string = GXPreview(v);
        }]];
        [acts addObject:[UIAction actionWithTitle:GXL(@"Копировать ключ") image:[UIImage systemImageNamed:@"key"] identifier:nil handler:^(UIAction *a) {
            UIPasteboard.generalPasteboard.string = [k description];
        }]];
        if (!self->_readOnly) {
            if ([self->_container isKindOfClass:NSDictionary.class]) {
                [acts addObject:[UIAction actionWithTitle:GXL(@"Переименовать ключ") image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(UIAction *a) {
                    GXPrompt(ws, GXL(@"Новое имя ключа"), nil, [k description], nil, GXL(@"Готово"), ^(NSString *nk) {
                        if (!nk.length || [nk isEqualToString:k]) return;
                        NSMutableDictionary *d = self->_container;
                        if (d[nk]) { GXAlert(ws, GXL(@"Ошибка"), GXL(@"Такой ключ уже есть")); return; }
                        d[nk] = d[k];
                        [d removeObjectForKey:k];
                        [ws changed];
                    });
                }]];
            }
            NSMutableArray *types = [NSMutableArray array];
            for (NSString *t in [self types]) {
                UIAction *ta = [UIAction actionWithTitle:t image:nil identifier:nil handler:^(UIAction *a) { [ws setValue:GXConvert(v, t) forKeyObj:k]; }];
                if ([GXTypeName(v) isEqualToString:t]) ta.state = UIMenuElementStateOn;
                [types addObject:ta];
            }
            [acts addObject:[UIMenu menuWithTitle:GXL(@"Тип") image:[UIImage systemImageNamed:@"arrow.triangle.swap"] identifier:nil options:0 children:types]];
            [acts addObject:[UIAction actionWithTitle:GXL(@"Дублировать") image:[UIImage systemImageNamed:@"plus.square.on.square"] identifier:nil handler:^(UIAction *a) {
                id copy = GXDeepMutable([v copy]);
                if ([self->_container isKindOfClass:NSDictionary.class]) {
                    NSString *nk = [NSString stringWithFormat:GXL(@"%@ копия"), k];
                    ((NSMutableDictionary *)self->_container)[nk] = copy;
                } else [(NSMutableArray *)self->_container insertObject:copy atIndex:[k unsignedIntegerValue] + 1];
                [ws changed];
            }]];
            UIAction *del = [UIAction actionWithTitle:GXL(@"Удалить") image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a) { [ws deleteKey:k]; }];
            del.attributes = UIMenuElementAttributesDestructive;
            [acts addObject:del];
        }
        return [UIMenu menuWithTitle:[k description] children:acts];
    }];
}

- (void)asText {
    GXTextEditorVC *ed = [[GXTextEditorVC alloc] initWithText:[_doc xmlText] title:self.title];
    ed.highlightExt = _doc.format == GXFmtJSON ? @"json" : @"xml";
    if (!_readOnly && _doc.path) {
        __weak GXPlistDoc *doc = _doc;
        __weak UINavigationController *nav = self.navigationController;
        ed.saveHandler = ^NSString *(NSString *text) {
            NSString *err = [doc setFromText:text];
            if (!err) [nav popToRootViewControllerAnimated:NO];
            return err;
        };
    }
    GXPresentNav(self, ed, YES);
}

- (void)save {
    NSString *err = [_doc save];
    if (err) { GXAlert(self, GXL(@"Не удалось сохранить"), err); return; }
    [self buildItems];
    GXToast(self.view, GXL(@"Сохранено"));
}

- (void)close {
    if (!_doc.dirty) { [self dismissViewControllerAnimated:YES completion:nil]; return; }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"Есть несохранённые изменения") message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Сохранить") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *err = [self->_doc save];
        if (err) GXAlert(self, GXL(@"Ошибка"), err); else [self dismissViewControllerAnimated:YES completion:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Не сохранять") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { [self dismissViewControllerAnimated:YES completion:nil]; }]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
@end
