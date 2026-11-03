// Передача файлов по Wi‑Fi: маленький HTTP-сервер + веб-страница
#import "GXCore.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <dirent.h>

static NSString *const kPage = /* noi18n */ @"<!doctype html><html lang=ru><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
"<title>GX Files</title><style>"
":root{--bg:#f4f5f8;--card:#fff;--fg:#14161c;--mut:#6b7080;--acc:#5a6cff;--line:#e3e5ec}"
"@media(prefers-color-scheme:dark){:root{--bg:#0f1115;--card:#181b22;--fg:#e9ebf2;--mut:#8b90a0;--acc:#7d8bff;--line:#262a35}}"
"*{box-sizing:border-box}body{margin:0;font:15px -apple-system,system-ui,Segoe UI,Roboto,sans-serif;background:var(--bg);color:var(--fg)}"
"header{position:sticky;top:0;background:var(--card);border-bottom:1px solid var(--line);padding:12px 16px;display:flex;gap:10px;align-items:center;flex-wrap:wrap}"
"h1{font-size:18px;margin:0 12px 0 0}#crumbs{flex:1;min-width:200px;color:var(--mut);overflow:auto;white-space:nowrap}#crumbs a{color:var(--acc);text-decoration:none}"
"button,label.btn{background:var(--acc);color:#fff;border:0;border-radius:8px;padding:8px 12px;font:inherit;cursor:pointer}"
"button.ghost{background:transparent;color:var(--mut);padding:4px 8px}main{max-width:1000px;margin:16px auto;padding:0 16px}"
"#drop{border:2px dashed var(--line);border-radius:12px;padding:18px;text-align:center;color:var(--mut);margin-bottom:12px}#drop.on{border-color:var(--acc);color:var(--acc)}"
"table{width:100%;border-collapse:collapse;background:var(--card);border-radius:12px;overflow:hidden}td{padding:10px 12px;border-top:1px solid var(--line)}"
"td.n a{color:var(--fg);text-decoration:none}td.s,td.m{color:var(--mut);white-space:nowrap;font-size:13px}tr:hover td{background:rgba(127,127,127,.06)}"
"#prog{height:4px;background:var(--acc);width:0;transition:width .2s;position:fixed;top:0;left:0}"
"@media(max-width:600px){td.m{display:none}}</style></head><body><div id=prog></div>"
"<header><h1>GX Files</h1><div id=crumbs></div><label class=btn>Загрузить<input id=f type=file multiple hidden></label><button onclick=mk()>Папка</button></header>"
"<main><div id=drop>Перетащите файлы сюда для загрузки</div><table><tbody id=t></tbody></table></main><script>"
"let cur='';const $=s=>document.querySelector(s);"
"function fmt(b){if(b<1024)return b+' Б';const u=['КБ','МБ','ГБ','ТБ'];let i=-1;do{b/=1024;i++}while(b>=1024&&i<3);return b.toFixed(1)+' '+u[i]}"
"function esc(s){return s.replace(/[&<>\"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;'}[c]))}"
"async function load(p){cur=p;const r=await fetch('/api/list?p='+encodeURIComponent(p));const j=await r.json();"
"let c='<a href=# onclick=\"load(\\'\\');return false\">⌂</a>';let acc='';for(const part of p.split('/').filter(Boolean)){acc+=(acc?'/':'')+part;"
"c+=' / <a href=# onclick=\"load(decodeURIComponent(\\''+encodeURIComponent(acc).replace(/'/g,'%27')+'\\'));return false\">'+esc(part)+'</a>'}$('#crumbs').innerHTML=c;"
"j.sort((a,b)=>(b.d-a.d)||a.n.localeCompare(b.n));let h='';if(p)h+='<tr><td class=n colspan=4><a href=# onclick=\"up();return false\">⬆︎ ..</a></td></tr>';"
"for(const e of j){const rp=(p?p+'/':'')+e.n;const q=encodeURIComponent(rp).replace(/'/g,'%27');"
"h+='<tr><td class=n>'+(e.d?'<a href=# onclick=\"load(decodeURIComponent(\\''+q+'\\'));return false\">📁 '+esc(e.n)+'</a>':'<a href=\"/dl?p='+q+'\">📄 '+esc(e.n)+'</a>')+'</td>'"
"+'<td class=s>'+(e.d?'':fmt(e.s))+'</td><td class=m>'+new Date(e.m*1000).toLocaleString()+'</td>'"
"+'<td><button class=ghost title=Удалить onclick=\"rm(decodeURIComponent(\\''+q+'\\'))\">✕</button></td></tr>'}$('#t').innerHTML=h||'<tr><td>Пусто</td></tr>'}"
"function up(){const a=cur.split('/');a.pop();load(a.join('/'))}"
"async function rm(p){if(!confirm('Удалить '+p+'?'))return;await fetch('/rm?p='+encodeURIComponent(p),{method:'POST'});load(cur)}"
"async function mk(){const n=prompt('Имя папки');if(!n)return;await fetch('/mkdir?p='+encodeURIComponent(cur)+'&n='+encodeURIComponent(n),{method:'POST'});load(cur)}"
"function send(files){let i=0;const next=()=>{if(i>=files.length){$('#prog').style.width=0;load(cur);return}const f=files[i++];const x=new XMLHttpRequest();"
"x.open('PUT','/up?p='+encodeURIComponent(cur)+'&n='+encodeURIComponent(f.name));x.upload.onprogress=e=>{$('#prog').style.width=(100*((i-1)+e.loaded/e.total)/files.length)+'%'};"
"x.onload=next;x.onerror=()=>{alert('Ошибка загрузки '+f.name);next()};x.send(f)};next()}"
"$('#f').onchange=e=>send([...e.target.files]);const d=$('#drop');"
"['dragenter','dragover'].forEach(t=>document.addEventListener(t,e=>{e.preventDefault();d.classList.add('on')}));"
"['dragleave','drop'].forEach(t=>document.addEventListener(t,e=>{e.preventDefault();d.classList.remove('on')}));"
"document.addEventListener('drop',e=>send([...e.dataTransfer.files]));load('')</script></body></html>";

@interface GXServer : NSObject
@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly) int port;
@property (nonatomic, copy) NSString *root;
+ (instancetype)shared;
- (NSString *)start;
- (void)stop;
@end

@implementation GXServer {
    int _sock;
    volatile BOOL _stopFlag;
}
+ (instancetype)shared { static GXServer *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [GXServer new]; }); return s; }

- (NSString *)start {
    if (_running) return nil;
    _sock = socket(AF_INET, SOCK_STREAM, 0);
    if (_sock < 0) return GXL(@"Не удалось создать сокет");
    int yes = 1;
    setsockopt(_sock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    setsockopt(_sock, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof yes);
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    int port = 0;
    for (int p = 8080; p < 8100; p++) {
        a.sin_port = htons(p);
        if (bind(_sock, (struct sockaddr *)&a, sizeof a) == 0) { port = p; break; }
    }
    if (!port || listen(_sock, 16) != 0) { close(_sock); return GXL(@"Порт занят"); }
    _port = port;
    _running = YES;
    _stopFlag = NO;
    int s = _sock;
    [NSThread detachNewThreadWithBlock:^{
        while (!self->_stopFlag) {
            int c = accept(s, NULL, NULL);
            if (c < 0) { if (self->_stopFlag) break; continue; }
            int one = 1;
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [self handle:c]; close(c); });
        }
    }];
    return nil;
}

- (void)stop {
    if (!_running) return;
    _stopFlag = YES;
    shutdown(_sock, SHUT_RDWR);
    close(_sock);
    _running = NO;
}

static BOOL sendAll(int c, const void *b, size_t n) {
    while (n) {
        ssize_t w = send(c, b, n, 0);
        if (w <= 0) return NO;
        b = (const char *)b + w;
        n -= (size_t)w;
    }
    return YES;
}

static void reply(int c, int code, NSString *type, NSData *body) {
    NSString *h = [NSString stringWithFormat:@"HTTP/1.1 %d %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n",
                   code, code == 200 ? @"OK" : code == 404 ? @"Not Found" : code == 403 ? @"Forbidden" : @"Error", type, (unsigned long)body.length];
    NSData *hd = [h dataUsingEncoding:NSUTF8StringEncoding];
    sendAll(c, hd.bytes, hd.length);
    if (body.length) sendAll(c, body.bytes, body.length);
}

- (NSString *)safe:(NSString *)rel {
    NSString *r = [[_root stringByAppendingPathComponent:rel ?: @""] stringByStandardizingPath];
    NSString *root = _root.stringByStandardizingPath;
    if (![r isEqualToString:root] && ![r hasPrefix:[root stringByAppendingString:@"/"]]) return nil;
    return r;
}

- (void)handle:(int)c {
    struct timeval tv = {30, 0};
    setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    NSMutableData *buf = [NSMutableData data];
    char tmp[16384];
    NSRange end = {NSNotFound, 0};
    while (buf.length < 65536) {
        ssize_t n = recv(c, tmp, sizeof tmp, 0);
        if (n <= 0) return;
        [buf appendBytes:tmp length:(NSUInteger)n];
        end = [buf rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4] options:0 range:NSMakeRange(0, buf.length)];
        if (end.location != NSNotFound) break;
    }
    if (end.location == NSNotFound) return;
    NSString *head = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, end.location)] encoding:NSUTF8StringEncoding];
    NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
    NSArray *req = [lines.firstObject componentsSeparatedByString:@" "];
    if (req.count < 2) return;
    NSString *method = req[0];
    NSURLComponents *u = [NSURLComponents componentsWithString:[@"http://x" stringByAppendingString:req[1]]];
    NSMutableDictionary *q = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *i in u.queryItems) if (i.value) q[i.name] = i.value;
    long long clen = 0;
    for (NSString *l in lines) if ([l.lowercaseString hasPrefix:@"content-length:"]) clen = [[l substringFromIndex:15] longLongValue];
    NSData *rest = [buf subdataWithRange:NSMakeRange(NSMaxRange(end), buf.length - NSMaxRange(end))];
    NSString *path = u.path;

    if ([method isEqualToString:@"GET"] && ([path isEqualToString:@"/"] || [path isEqualToString:@"/index.html"])) {
        NSString *pg = kPage;
        // перевод видимых слов веб-страницы
        for (NSArray *w in @[@[@"Перетащите файлы сюда для загрузки", GXL(@"Перетащите файлы сюда для загрузки")], @[@"Загрузить", GXL(@"Загрузить")], @[@"Папка", GXL(@"Папка")], @[@"Удалить", GXL(@"Удалить")], @[@"Пусто", GXL(@"Пусто")], @[@"Имя папки", GXL(@"Имя папки")], @[@"Ошибка загрузки", GXL(@"Ошибка загрузки")], @[@"КБ", GXL(@"КБ")], @[@"МБ", GXL(@"МБ")], @[@"ГБ", GXL(@"ГБ")], @[@"ТБ", GXL(@"ТБ")]]) // noi18n
            pg = [pg stringByReplacingOccurrencesOfString:w[0] withString:w[1]];
        pg = [pg stringByReplacingOccurrencesOfString:@"+' Б'" withString:[NSString stringWithFormat:@"+' %@'", GXL(@"Б")]]; // noi18n
        pg = [pg stringByReplacingOccurrencesOfString:@"lang=ru" withString:[@"lang=" stringByAppendingString:GXLangCode()]];
        reply(c, 200, @"text/html; charset=utf-8", [pg dataUsingEncoding:NSUTF8StringEncoding]);
    } else if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/list"]) {
        NSString *dir = [self safe:q[@"p"]];
        if (!dir) { reply(c, 403, @"text/plain", nil); return; }
        NSMutableArray *arr = [NSMutableArray array];
        for (NSString *n in [FM() contentsOfDirectoryAtPath:dir error:nil]) {
            struct stat st;
            if (stat([dir stringByAppendingPathComponent:n].fileSystemRepresentation, &st) != 0) continue;
            [arr addObject:@{@"n": n, @"d": @(S_ISDIR(st.st_mode) ? 1 : 0), @"s": @(st.st_size), @"m": @(st.st_mtimespec.tv_sec)}];
        }
        reply(c, 200, @"application/json", [NSJSONSerialization dataWithJSONObject:arr options:0 error:nil]);
    } else if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/dl"]) {
        NSString *f = [self safe:q[@"p"]];
        struct stat st;
        if (!f || stat(f.fileSystemRepresentation, &st) != 0 || S_ISDIR(st.st_mode)) { reply(c, 404, @"text/plain", nil); return; }
        int fd = open(f.fileSystemRepresentation, O_RDONLY);
        if (fd < 0) { reply(c, 403, @"text/plain", nil); return; }
        NSString *enc = [f.lastPathComponent stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
        NSString *h = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: %lld\r\nContent-Disposition: attachment; filename*=UTF-8''%@\r\nConnection: close\r\n\r\n", (long long)st.st_size, enc];
        NSData *hd = [h dataUsingEncoding:NSUTF8StringEncoding];
        if (sendAll(c, hd.bytes, hd.length)) {
            char *b = malloc(1 << 20);
            ssize_t n;
            while ((n = read(fd, b, 1 << 20)) > 0) if (!sendAll(c, b, (size_t)n)) break;
            free(b);
        }
        close(fd);
    } else if ([method isEqualToString:@"PUT"] && [path isEqualToString:@"/up"]) {
        NSString *dir = [self safe:q[@"p"]];
        NSString *name = [q[@"n"] lastPathComponent];
        if (!dir || !name.length || [name isEqualToString:@".."]) { reply(c, 403, @"text/plain", nil); return; }
        NSString *dest = GXUniquePath(dir, name);
        int fd = open(dest.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) { reply(c, 403, @"text/plain", nil); return; }
        long long left = clen;
        if (rest.length) { write(fd, rest.bytes, rest.length); left -= (long long)rest.length; }
        char *b = malloc(1 << 20);
        while (left > 0) {
            ssize_t n = recv(c, b, (size_t)MIN(left, 1 << 20), 0);
            if (n <= 0) break;
            if (write(fd, b, (size_t)n) != n) break;
            left -= n;
        }
        free(b);
        close(fd);
        if (left > 0) { unlink(dest.fileSystemRepresentation); reply(c, 500, @"text/plain", nil); return; }
        reply(c, 200, @"text/plain", [@"ok" dataUsingEncoding:NSUTF8StringEncoding]);
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/mkdir"]) {
        NSString *dir = [self safe:q[@"p"]];
        NSString *name = [q[@"n"] lastPathComponent];
        if (!dir || !name.length) { reply(c, 403, @"text/plain", nil); return; }
        [FM() createDirectoryAtPath:GXUniquePath(dir, name) withIntermediateDirectories:NO attributes:nil error:nil];
        reply(c, 200, @"text/plain", nil);
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/rm"]) {
        NSString *f = [self safe:q[@"p"]];
        if (!f || [f isEqualToString:_root.stringByStandardizingPath]) { reply(c, 403, @"text/plain", nil); return; }
        [FM() removeItemAtPath:f error:nil];
        reply(c, 200, @"text/plain", nil);
    } else {
        reply(c, 404, @"text/plain", [@"not found" dataUsingEncoding:NSUTF8StringEncoding]);
    }
}
@end

static NSArray<NSString *> *GXLocalIPs(void) {
    NSMutableArray *r = [NSMutableArray array];
    struct ifaddrs *ifs;
    if (getifaddrs(&ifs) != 0) return r;
    for (struct ifaddrs *i = ifs; i; i = i->ifa_next) {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET || (i->ifa_flags & IFF_LOOPBACK) || !(i->ifa_flags & IFF_UP)) continue;
        char buf[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, buf, sizeof buf);
        NSString *name = @(i->ifa_name);
        NSString *ip = @(buf);
        if ([name hasPrefix:@"en"] || [name hasPrefix:@"bridge"]) [r insertObject:ip atIndex:0];
        else if (![name hasPrefix:@"utun"] && ![name hasPrefix:@"pdp"]) [r addObject:ip];
    }
    freeifaddrs(ifs);
    return r;
}

@implementation GXServerVC { NSString *_root; }
- (instancetype)initWithRoot:(NSString *)root { if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _root = root; return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = GXL(@"Wi‑Fi передача");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
}
- (void)viewWillAppear:(BOOL)a { [super viewWillAppear:a]; [self.navigationController setToolbarHidden:YES animated:a]; [self.tableView reloadData]; }
- (void)viewWillDisappear:(BOOL)a { [super viewWillDisappear:a]; UIApplication.sharedApplication.idleTimerDisabled = NO; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    GXServer *srv = GXServer.shared;
    return s == 0 ? 2 : (srv.running ? MAX(1, (NSInteger)GXLocalIPs().count) : 1);
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 0) return GXL(@"Пока этот экран открыт, iPhone не уснёт. Компьютер и iPhone должны быть в одной сети Wi‑Fi. Если iOS спросит про доступ к локальной сети — разрешите.");
    return GXServer.shared.running ? GXL(@"Откройте адрес в браузере на компьютере: можно скачивать и загружать файлы, создавать папки, удалять.") : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    GXServer *srv = GXServer.shared;
    if (ip.section == 0 && ip.row == 0) {
        c.textLabel.text = GXL(@"Сервер");
        UISwitch *sw = [UISwitch new];
        sw.on = srv.running;
        [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (ip.section == 0) {
        c.textLabel.text = GXL(@"Папка");
        c.detailTextLabel.text = srv.running ? srv.root : _root;
        c.detailTextLabel.numberOfLines = 0;
        c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    } else {
        if (!srv.running) { c.textLabel.text = GXL(@"Сервер выключен"); c.textLabel.textColor = UIColor.secondaryLabelColor; return c; }
        NSArray *ips = GXLocalIPs();
        NSString *ip4 = ips.count ? ips[ip.row] : GXL(@"нет сети");
        c.textLabel.text = [NSString stringWithFormat:@"http://%@:%d", ip4, srv.port];
        c.textLabel.font = [UIFont monospacedSystemFontOfSize:18 weight:UIFontWeightSemibold];
        c.textLabel.textColor = self.view.tintColor;
        c.detailTextLabel.text = GXL(@"Нажмите, чтобы скопировать");
    }
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1 && GXServer.shared.running) {
        UIPasteboard.generalPasteboard.string = [tv cellForRowAtIndexPath:ip].textLabel.text;
        GXToast(self.view, GXL(@"Адрес скопирован"));
    }
}
- (void)toggle:(UISwitch *)sw {
    GXServer *srv = GXServer.shared;
    if (sw.on) {
        srv.root = _root;
        NSString *err = [srv start];
        if (err) { GXAlert(self, GXL(@"Не удалось запустить"), err); sw.on = NO; }
        UIApplication.sharedApplication.idleTimerDisabled = srv.running;
    } else {
        [srv stop];
        UIApplication.sharedApplication.idleTimerDisabled = NO;
    }
    [self.tableView reloadData];
}
@end
