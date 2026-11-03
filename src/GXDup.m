// Поиск дубликатов файлов (по размеру, затем SHA-256)
#import "GXCore.h"

@implementation GXDupVC {
    NSString *_root;
    NSMutableArray<NSMutableArray<NSString *> *> *_groups;
    unsigned long long _waste;
    BOOL _done;
    NSInteger _gen;
}

- (instancetype)initWithRoot:(NSString *)root {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) { _root = root; _groups = [NSMutableArray array]; }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = GXL(@"Дубликаты");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:GXL(@"Оставить по одному") style:UIBarButtonItemStylePlain target:self action:@selector(keepOne)];
    NSInteger gen = ++_gen;
    NSString *root = _root;
    [GXHUD showCancellableIn:self.view text:GXL(@"Ищу дубликаты…")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary<NSNumber *, NSMutableArray *> *bySize = [NSMutableDictionary dictionary];
        NSDirectoryEnumerator *en = [FM() enumeratorAtURL:[NSURL fileURLWithPath:root] includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey] options:0 errorHandler:^BOOL(NSURL *u, NSError *e) { return YES; }];
        for (NSURL *u in en) {
            if ([GXHUD cancelled]) break;
            NSNumber *reg, *sz;
            [u getResourceValue:&reg forKey:NSURLIsRegularFileKey error:nil];
            [u getResourceValue:&sz forKey:NSURLFileSizeKey error:nil];
            if (!reg.boolValue || sz.unsignedLongLongValue < 1) continue;
            NSMutableArray *l = bySize[sz];
            if (!l) bySize[sz] = l = [NSMutableArray array];
            [l addObject:u.path];
        }
        NSMutableArray *groups = [NSMutableArray array];
        unsigned long long waste = 0;
        NSUInteger k = 0, total = bySize.count;
        for (NSNumber *sz in bySize) {
            k++;
            if ([GXHUD cancelled]) break;
            NSArray *l = bySize[sz];
            if (l.count < 2) continue;
            [GXHUD setProgress:(double)k / MAX(total, 1u)];
            NSMutableDictionary<NSString *, NSMutableArray *> *byHash = [NSMutableDictionary dictionary];
            for (NSString *p in l) {
                NSString *h = GXHashFile(p, @"sha256");
                if (!h) continue;
                NSMutableArray *g = byHash[h];
                if (!g) byHash[h] = g = [NSMutableArray array];
                [g addObject:p];
            }
            for (NSMutableArray *g in byHash.allValues) if (g.count > 1) { [groups addObject:g]; waste += sz.unsignedLongLongValue * (g.count - 1); }
        }
        [groups sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
            unsigned long long x = [[FM() attributesOfItemAtPath:a[0] error:nil] fileSize] * a.count, y = [[FM() attributesOfItemAtPath:b[0] error:nil] fileSize] * b.count;
            return x > y ? NSOrderedAscending : x < y ? NSOrderedDescending : NSOrderedSame;
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            if (gen != self->_gen) return;
            [self->_groups setArray:groups];
            self->_waste = waste;
            self->_done = YES;
            [self.tableView reloadData];
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return MAX(1, (NSInteger)_groups.count); }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _groups.count ? (NSInteger)_groups[s].count : 0; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (!_groups.count) return _done ? GXL(@"Дубликатов нет") : nil;
    unsigned long long sz = [[FM() attributesOfItemAtPath:_groups[s][0] error:nil] fileSize];
    NSString *h = [NSString stringWithFormat:GXL(@"%lu копии · %@ каждая"), (unsigned long)_groups[s].count, GXHuman(sz)];
    return s == 0 ? [NSString stringWithFormat:GXL(@"Можно освободить %@\n\n%@"), GXHuman(_waste), h] : h;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"d"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"d"];
    NSString *p = _groups[ip.section][ip.row];
    c.textLabel.text = p.lastPathComponent;
    NSString *rel = [p hasPrefix:_root] ? [p substringFromIndex:_root.length] : p;
    c.detailTextLabel.text = rel.stringByDeletingLastPathComponent.length ? rel.stringByDeletingLastPathComponent : @"/";
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingHead;
    GXKind k = GXKindForName(p.lastPathComponent, NO);
    c.imageView.image = GXSymbolTile(GXSymbolForKind(k), GXColorForKind(k), 30);
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    [GXOpener open:_groups[ip.section][ip.row] from:self];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    UIContextualAction *d = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:GXL(@"Удалить") handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        NSString *p = self->_groups[ip.section][ip.row];
        [FM() removeItemAtPath:p error:nil];
        [self->_groups[ip.section] removeObjectAtIndex:ip.row];
        if (self->_groups[ip.section].count < 2) [self->_groups removeObjectAtIndex:ip.section];
        [tv reloadData];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[d]];
}
- (void)keepOne {
    if (!_groups.count) return;
    GXConfirm(self, GXL(@"Удалить лишние копии?"), [NSString stringWithFormat:GXL(@"В каждой группе останется первый файл. Освободится %@."), GXHuman(_waste)], GXL(@"Удалить"), YES, ^{
        NSUInteger n = 0;
        for (NSArray *g in self->_groups) for (NSUInteger i = 1; i < g.count; i++) if ([FM() removeItemAtPath:g[i] error:nil]) n++;
        [self->_groups removeAllObjects];
        [self.tableView reloadData];
        GXToast(self.view, [NSString stringWithFormat:GXL(@"Удалено: %lu"), (unsigned long)n]);
    });
}
@end
