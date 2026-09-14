#import <Cocoa/Cocoa.h>
#import <dispatch/dispatch.h>
#import <fcntl.h>

static NSString *ResetDate(NSTimeInterval reset, NSString *format, NSTimeZone *timeZone) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"ko_KR"];
    formatter.timeZone = timeZone;
    formatter.dateFormat = format;
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:reset]];
}

static NSString *FiveHourResetTime(NSTimeInterval reset, NSTimeInterval now, NSTimeZone *timeZone) {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    calendar.timeZone = timeZone;
    NSDate *resetDate = [NSDate dateWithTimeIntervalSince1970:reset];
    NSDate *nowDate = [NSDate dateWithTimeIntervalSince1970:now];
    NSDate *tomorrow = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:nowDate options:0];
    NSString *day = [calendar isDate:resetDate inSameDayAsDate:nowDate] ? @"오늘" :
        [calendar isDate:resetDate inSameDayAsDate:tomorrow] ? @"내일" : ResetDate(reset, @"M/d", timeZone);
    return [NSString stringWithFormat:@"%@ %@", day, ResetDate(reset, @"HH:mm", timeZone)];
}

static NSString *StatusTitle(double used, NSTimeInterval reset, NSTimeInterval now) {
    NSInteger remaining = MAX(0, MIN(100, lround(100 - used)));
    return [NSString stringWithFormat:@"%ld%% (%@)\u2009", remaining, FiveHourResetTime(reset, now, NSTimeZone.localTimeZone)];
}

static NSString *WeeklyStatusTitle(double used, NSTimeInterval reset, NSTimeZone *timeZone) {
    NSInteger remaining = MAX(0, MIN(100, lround(100 - used)));
    return [NSString stringWithFormat:@"%ld%% (%@)\u2009", remaining, ResetDate(reset, @"M/d EEE HH:mm", timeZone)];
}

static NSString *AllStatusTitle(NSDictionary *primary, NSDictionary *weekly, NSTimeInterval now) {
    NSInteger primaryRemaining = MAX(0, MIN(100, lround(100 - [primary[@"usedPercent"] doubleValue])));
    NSInteger weeklyRemaining = MAX(0, MIN(100, lround(100 - [weekly[@"usedPercent"] doubleValue])));
    return [NSString stringWithFormat:@"5h %ld%% (%@) / 주 %ld%% (%@)\u2009",
        primaryRemaining, FiveHourResetTime([primary[@"resetsAt"] doubleValue], now, NSTimeZone.localTimeZone),
        weeklyRemaining, ResetDate([weekly[@"resetsAt"] doubleValue], @"M/d EEE HH:mm", NSTimeZone.localTimeZone)];
}

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property NSStatusItem *statusItem;
@property NSMenuItem *updatedItem;
@property NSMenuItem *weeklyResetItem;
@property NSMenuItem *fiveHourItem;
@property NSMenuItem *weeklyItem;
@property NSMenuItem *allLimitsItem;
@property NSTask *process;
@property NSFileHandle *input;
@property NSMutableData *outputBuffer;
@property NSInteger nextRequestID;
@property NSDictionary *limits;
@property NSString *selectedLimit;
@property NSMutableArray *watchers;
@property BOOL conversationActive;
@property dispatch_block_t quietRefresh;
@property dispatch_block_t restart;
@end

@implementation AppDelegate

- (instancetype)init {
    if ((self = [super init])) {
        _outputBuffer = [NSMutableData data];
        _watchers = [NSMutableArray array];
        _nextRequestID = 2;
        NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:@"selectedLimit"];
        _selectedLimit = ([saved isEqual:@"primary"] || [saved isEqual:@"all"]) ? saved : @"secondary";
    }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [self configureStatusItem];
    [self startServer];
    [self watchConversationChanges];
    __weak typeof(self) weakSelf = self;
    [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refresh];
    }];
    [NSTimer scheduledTimerWithTimeInterval:60 repeats:YES block:^(NSTimer *timer) {
        [weakSelf updateTitle];
    }];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    if (self.quietRefresh) dispatch_block_cancel(self.quietRefresh);
    if (self.restart) dispatch_block_cancel(self.restart);
    for (dispatch_source_t source in self.watchers) dispatch_source_cancel(source);
    [self.input closeFile];
    [self.process terminate];
}

- (void)configureStatusItem {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSStatusBarButton *button = self.statusItem.button;
    button.title = @"—% (—)";
    button.imagePosition = NSImageRight;
    NSString *logo = [NSBundle.mainBundle pathForResource:@"chatgptTemplate@2x" ofType:@"png"];
    if (!logo) logo = @"/Applications/ChatGPT.app/Contents/Resources/chatgptTemplate@2x.png";
    if (![NSFileManager.defaultManager fileExistsAtPath:logo])
        logo = @"/Applications/ChatGPT.app/Contents/Resources/chatgptTemplate.png";
    NSImage *image = [[NSImage alloc] initWithContentsOfFile:logo];
    if (!image) image = [NSImage imageWithSystemSymbolName:@"gauge.with.dots.needle.67percent"
                                  accessibilityDescription:@"Codex Meter"];
    image.template = YES;
    image.size = NSMakeSize(18, 18);
    button.image = image;

    NSMenu *menu = [NSMenu new];
    self.fiveHourItem = [[NSMenuItem alloc] initWithTitle:@"5시간 한도" action:@selector(selectLimit:) keyEquivalent:@""];
    self.fiveHourItem.representedObject = @"primary";
    self.fiveHourItem.target = self;
    [menu addItem:self.fiveHourItem];
    self.weeklyItem = [[NSMenuItem alloc] initWithTitle:@"주간 한도" action:@selector(selectLimit:) keyEquivalent:@""];
    self.weeklyItem.representedObject = @"secondary";
    self.weeklyItem.target = self;
    [menu addItem:self.weeklyItem];
    self.allLimitsItem = [[NSMenuItem alloc] initWithTitle:@"모든 한도" action:@selector(selectLimit:) keyEquivalent:@""];
    self.allLimitsItem.representedObject = @"all";
    self.allLimitsItem.target = self;
    [menu addItem:self.allLimitsItem];
    [self updateSelectionChecks];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *refreshItem = [[NSMenuItem alloc] initWithTitle:@"지금 갱신" action:@selector(refreshNow) keyEquivalent:@"r"];
    refreshItem.target = self;
    [menu addItem:refreshItem];
    self.updatedItem = [[NSMenuItem alloc] initWithTitle:@"연결 중…" action:nil keyEquivalent:@""];
    [menu addItem:self.updatedItem];
    self.weeklyResetItem = [[NSMenuItem alloc] initWithTitle:@"주간 초기화: 확인 중…" action:nil keyEquivalent:@""];
    [menu addItem:self.weeklyResetItem];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"종료" action:@selector(quit) keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];
    self.statusItem.menu = menu;
}

- (void)startServer {
    if (self.process) return;
    NSArray<NSString *> *paths = @[
        @"/Applications/ChatGPT.app/Contents/Resources/codex",
        @"/opt/homebrew/bin/codex",
        @"/usr/local/bin/codex"
    ];
    NSString *codex;
    for (NSString *path in paths) {
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) { codex = path; break; }
    }
    if (!codex) { self.updatedItem.title = @"Codex를 찾을 수 없음"; return; }

    NSTask *process = [NSTask new];
    NSPipe *stdinPipe = [NSPipe pipe];
    NSPipe *stdoutPipe = [NSPipe pipe];
    process.executableURL = [NSURL fileURLWithPath:codex];
    process.arguments = @[@"app-server", @"--stdio"];
    process.standardInput = stdinPipe;
    process.standardOutput = stdoutPipe;
    process.standardError = NSFileHandle.fileHandleWithNullDevice;
    __weak typeof(self) weakSelf = self;
    process.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf serverStopped]; });
    };
    stdoutPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (!data.length) return;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf consume:data]; });
    };

    NSError *error;
    if (![process launchAndReturnError:&error]) {
        self.updatedItem.title = @"연결 실패";
        [self scheduleRestart];
        return;
    }
    self.process = process;
    self.input = stdinPipe.fileHandleForWriting;
    [self send:@{@"id": @1, @"method": @"initialize", @"params": @{
        @"clientInfo": @{@"name": @"codex-meter", @"version": @"1"}
    }}];
}

- (void)serverStopped {
    self.process = nil;
    self.input = nil;
    self.updatedItem.title = @"재연결 중…";
    [self scheduleRestart];
}

- (void)scheduleRestart {
    if (self.restart) dispatch_block_cancel(self.restart);
    __weak typeof(self) weakSelf = self;
    self.restart = dispatch_block_create(0, ^{ [weakSelf startServer]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), self.restart);
}

- (void)send:(NSDictionary *)message {
    if (!self.input) return;
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:message options:0 error:nil] mutableCopy];
    uint8_t newline = '\n';
    [data appendBytes:&newline length:1];
    @try { [self.input writeData:data]; } @catch (__unused NSException *exception) { [self serverStopped]; }
}

- (void)consume:(NSData *)data {
    [self.outputBuffer appendData:data];
    while (true) {
        const uint8_t *bytes = self.outputBuffer.bytes;
        const uint8_t *newline = memchr(bytes, '\n', self.outputBuffer.length);
        if (!newline) break;
        NSUInteger length = newline - bytes;
        NSData *line = [self.outputBuffer subdataWithRange:NSMakeRange(0, length)];
        [self.outputBuffer replaceBytesInRange:NSMakeRange(0, length + 1) withBytes:NULL length:0];
        NSDictionary *message = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
        NSInteger requestID = [message[@"id"] integerValue];
        if (requestID == 1) {
            [self send:@{@"method": @"initialized"}];
            [self refresh];
        } else if (requestID >= 2) {
            [self applyUsage:message];
        }
    }
}

- (void)applyUsage:(NSDictionary *)message {
    NSDictionary *limits = message[@"result"][@"rateLimits"];
    if (!limits[@"primary"] || !limits[@"secondary"]) { self.updatedItem.title = @"갱신 실패"; return; }
    self.limits = limits;
    NSString *time = [NSDateFormatter localizedStringFromDate:NSDate.date
                                                    dateStyle:NSDateFormatterNoStyle
                                                    timeStyle:NSDateFormatterShortStyle];
    self.updatedItem.title = [@"마지막 갱신 " stringByAppendingString:time];
    [self updateTitle];
}

- (void)updateTitle {
    NSNumber *weeklyReset = self.limits[@"secondary"][@"resetsAt"];
    if (weeklyReset) {
        NSString *date = ResetDate(weeklyReset.doubleValue, @"M/d EEE HH:mm:ss z", NSTimeZone.localTimeZone);
        self.weeklyResetItem.title = [@"주간 초기화: " stringByAppendingString:date];
    }
    if ([self.selectedLimit isEqual:@"all"]) {
        NSDictionary *primary = self.limits[@"primary"];
        NSDictionary *weekly = self.limits[@"secondary"];
        if (!primary[@"usedPercent"] || !primary[@"resetsAt"] || !weekly[@"usedPercent"] || !weekly[@"resetsAt"]) return;
        self.statusItem.button.title = AllStatusTitle(primary, weekly, NSDate.date.timeIntervalSince1970);
        return;
    }
    NSDictionary *limit = self.limits[self.selectedLimit];
    NSNumber *used = limit[@"usedPercent"];
    NSNumber *reset = limit[@"resetsAt"];
    if (!used || !reset) return;
    if ([self.selectedLimit isEqual:@"secondary"]) {
        self.statusItem.button.title = WeeklyStatusTitle(used.doubleValue, reset.doubleValue, NSTimeZone.localTimeZone);
    } else {
        self.statusItem.button.title = StatusTitle(used.doubleValue, reset.doubleValue, NSDate.date.timeIntervalSince1970);
    }
}

- (void)selectLimit:(NSMenuItem *)sender {
    self.selectedLimit = sender.representedObject;
    [NSUserDefaults.standardUserDefaults setObject:self.selectedLimit forKey:@"selectedLimit"];
    [self updateSelectionChecks];
    [self updateTitle];
}

- (void)updateSelectionChecks {
    self.fiveHourItem.state = [self.selectedLimit isEqual:@"primary"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.weeklyItem.state = [self.selectedLimit isEqual:@"secondary"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.allLimitsItem.state = [self.selectedLimit isEqual:@"all"] ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)refresh {
    if (!self.process.running) { [self startServer]; return; }
    [self send:@{@"id": @(self.nextRequestID++), @"method": @"account/rateLimits/read"}];
}

- (void)watchConversationChanges {
    NSString *root = [NSHomeDirectory() stringByAppendingPathComponent:@".codex"];
    for (NSString *name in @[@"thread_history_1.sqlite", @"thread_history_1.sqlite-wal"]) {
        NSString *path = [root stringByAppendingPathComponent:name];
        int descriptor = open(path.fileSystemRepresentation, O_EVTONLY);
        if (descriptor < 0) continue;
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, descriptor,
            DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND, dispatch_get_main_queue());
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(source, ^{ [weakSelf conversationChanged]; });
        dispatch_source_set_cancel_handler(source, ^{ close(descriptor); });
        dispatch_resume(source);
        [self.watchers addObject:source];
    }
}

- (void)conversationChanged {
    if (!self.conversationActive) {
        self.conversationActive = YES;
        [self refresh];
    }
    if (self.quietRefresh) dispatch_block_cancel(self.quietRefresh);
    __weak typeof(self) weakSelf = self;
    self.quietRefresh = dispatch_block_create(0, ^{
        weakSelf.conversationActive = NO;
        [weakSelf refresh];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), self.quietRefresh);
}

- (void)refreshNow { [self refresh]; }
- (void)quit { [NSApp terminate:nil]; }

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--self-test") == 0) {
            NSTimeInterval now = 1000000;
            NSTimeZone *tokyo = [NSTimeZone timeZoneWithName:@"Asia/Tokyo"];
            NSTimeInterval fiveHourReset = 1789810362 - 17 * 3600;
            NSCAssert([FiveHourResetTime(fiveHourReset, fiveHourReset - 3600, tokyo) isEqual:@"오늘 01:32"], @"same-day reset");
            NSCAssert([FiveHourResetTime(fiveHourReset, fiveHourReset - 2 * 3600, tokyo) isEqual:@"내일 01:32"], @"next-day reset");
            NSString *fiveHourTitle = [NSString stringWithFormat:@"50%% (%@)\u2009",
                FiveHourResetTime(now + 2 * 3600, now, NSTimeZone.localTimeZone)];
            NSCAssert([StatusTitle(50, now + 2 * 3600, now) isEqual:fiveHourTitle], @"title spacing");
            NSCAssert([ResetDate(1789810362, @"M/d EEE HH:mm", tokyo) isEqual:@"9/19 토 18:32"], @"weekly date and time");
            NSCAssert([ResetDate(1789810362, @"M/d EEE HH:mm:ss", tokyo) isEqual:@"9/19 토 18:32:42"], @"weekly exact reset");
            NSCAssert([WeeklyStatusTitle(2, 1789810362, tokyo) isEqual:@"98% (9/19 토 18:32)\u2009"], @"weekly status");
            NSDictionary *primary = @{@"usedPercent": @17, @"resetsAt": @(now + 2 * 3600)};
            NSDictionary *weekly = @{@"usedPercent": @61, @"resetsAt": @1789810362};
            NSString *expected = [NSString stringWithFormat:@"5h 83%% (%@) / 주 39%% (%@)\u2009",
                FiveHourResetTime(now + 2 * 3600, now, NSTimeZone.localTimeZone),
                ResetDate(1789810362, @"M/d EEE HH:mm", NSTimeZone.localTimeZone)];
            NSCAssert([AllStatusTitle(primary, weekly, now) isEqual:expected], @"all limits");
            puts("ok");
            return 0;
        }
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
