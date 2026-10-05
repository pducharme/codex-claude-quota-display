#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>

// Information-only SDK probe: no installer, helper cancellation or archive download.
@interface FeedProbe : NSObject <SPUUpdaterDelegate>
@property BOOL finished;
@property BOOL loaded;
@property BOOL noUpdate;
@property NSString *foundVersion;
@property BOOL foundInformational;
@property NSString *feedURL;
@property NSString *archiveDirectory;
@property NSError *error;
@property NSMutableArray<NSDictionary *> *roundTrips;
@end

@implementation FeedProbe
- (NSString *)feedURLStringForUpdater:(SPUUpdater *)updater { return self.feedURL; }
- (BOOL)updaterShouldPromptForPermissionToCheckForUpdates:(SPUUpdater *)updater { return NO; }
- (NSArray<NSString *> *)allowedSystemProfileKeysForUpdater:(SPUUpdater *)updater { return @[]; }
- (BOOL)updater:(SPUUpdater *)updater mayPerformUpdateCheck:(SPUUpdateCheck)check error:(NSError **)error {
    return check == SPUUpdateCheckUpdateInformation;
}
- (BOOL)updater:(SPUUpdater *)updater shouldDownloadReleaseNotesForUpdate:(SUAppcastItem *)item { return NO; }
- (void)updater:(SPUUpdater *)updater didFinishLoadingAppcast:(SUAppcast *)appcast {
    self.loaded = YES;
    self.roundTrips = [NSMutableArray new];
    NSUInteger index = 0;
    for (SUAppcastItem *item in appcast.items) {
        NSError *encodeError = nil;
        NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:item requiringSecureCoding:YES error:&encodeError];
        NSError *decodeError = nil;
        SUAppcastItem *decoded = archive ? [NSKeyedUnarchiver unarchivedObjectOfClass:SUAppcastItem.class fromData:archive error:&decodeError] : nil;
        if (archive && self.archiveDirectory) {
            NSString *path = [self.archiveDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%lu.archive", (unsigned long)index]];
            [archive writeToFile:path atomically:YES];
        }
        index++;
        NSError *error = encodeError ?: decodeError;
        [self.roundTrips addObject:@{@"version": item.versionString,
            @"decoded": @(decoded != nil), @"encoded": @(archive != nil),
            @"url_preserved": @(decoded != nil && ((item.fileURL && [decoded.fileURL isEqual:item.fileURL]) || (item.infoURL && [decoded.infoURL isEqual:item.infoURL]))),
            @"error_code": error ? @(error.code) : [NSNull null]}];
    }
}
- (void)updater:(SPUUpdater *)updater didFindValidUpdate:(SUAppcastItem *)item {
    self.foundVersion = item.versionString;
    self.foundInformational = item.informationOnlyUpdate;
}
- (void)updaterDidNotFindUpdate:(SPUUpdater *)updater error:(NSError *)error { self.noUpdate = YES; }
- (void)updater:(SPUUpdater *)updater didFinishUpdateCycleForUpdateCheck:(SPUUpdateCheck)check error:(NSError *)error {
    self.error = error;
    self.finished = YES;
}
@end

static void printJSON(NSDictionary *report) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL];
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "--decode") == 0) {
            NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]];
            NSError *error = nil;
            SUAppcastItem *item = data ? [NSKeyedUnarchiver unarchivedObjectOfClass:SUAppcastItem.class fromData:data error:&error] : nil;
            printJSON(@{@"decoded": @(item != nil), @"version": item.versionString ?: [NSNull null],
                @"error_code": error ? @(error.code) : [NSNull null]});
            return item ? 0 : 1;
        }
        if (argc != 4) return 2;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSBundle *host = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
        FeedProbe *probe = [FeedProbe new];
        probe.feedURL = [NSString stringWithUTF8String:argv[2]];
        probe.archiveDirectory = [NSString stringWithUTF8String:argv[3]];
        SPUStandardUserDriver *driver = [[SPUStandardUserDriver alloc] initWithHostBundle:host delegate:nil];
        SPUUpdater *updater = [[SPUUpdater alloc] initWithHostBundle:host applicationBundle:host userDriver:driver delegate:probe];
        NSError *startError = nil;
        BOOL started = [updater startUpdater:&startError];
        if (started) {
            [updater checkForUpdateInformation];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
            while (!probe.finished && deadline.timeIntervalSinceNow > 0) {
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
        }
        NSError *error = startError ?: probe.error;
        BOOL success = started && probe.finished && probe.loaded && (error == nil || error.code == SUNoUpdateError);
        printJSON(@{@"completed": @(success), @"host_version": [host objectForInfoDictionaryKey:@"CFBundleVersion"] ?: [NSNull null],
            @"offered_version": probe.foundVersion ?: [NSNull null], @"informational": @(probe.foundInformational),
            @"no_update": @(probe.noUpdate), @"round_trips": probe.roundTrips ?: @[],
            @"error_code": error ? @(error.code) : [NSNull null]});
        return success ? 0 : 1;
    }
}
