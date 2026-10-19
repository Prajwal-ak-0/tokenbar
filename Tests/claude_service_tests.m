#import <Foundation/Foundation.h>
#import "TBUsageServices.h"
#import <LocalAuthentication/LocalAuthentication.h>

// No real preferences, Keychain calls, CLI processes, or network traffic in this suite.
@interface TBMemoryDefaults : NSUserDefaults
@property(nonatomic) NSMutableDictionary *values;
@end
@implementation TBMemoryDefaults
- (instancetype)init { if ((self = [super initWithSuiteName:@"tokenbar-tests-unused"])) _values = [NSMutableDictionary new]; return self; }
- (id)objectForKey:(NSString *)key { return self.values[key]; }
- (void)setObject:(id)value forKey:(NSString *)key { self.values[key] = value; }
- (void)removeObjectForKey:(NSString *)key { [self.values removeObjectForKey:key]; }
- (NSInteger)integerForKey:(NSString *)key { return [self.values[key] integerValue]; }
- (void)setInteger:(NSInteger)value forKey:(NSString *)key { self.values[key] = @(value); }
- (NSString *)stringForKey:(NSString *)key { return self.values[key]; }
@end

@interface TBTestClaudeService : TBClaudeUsageService
@property(nonatomic) NSDate *clock;
@property(nonatomic) NSDictionary *credential;
@property(nonatomic) NSError *credentialError;
@property(nonatomic) NSDictionary *reply;
@property(nonatomic) NSInteger requests;
@property(nonatomic) NSInteger interactiveReads;
@property(nonatomic) BOOL useCLI;
@property(nonatomic) NSDictionary *cliReply;
@property(nonatomic) NSInteger cliRequests;
@property(nonatomic) NSInteger credentialReads;
@end
@implementation TBTestClaudeService
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    if ((self = [super initWithDefaults:defaults])) {
        self.clock = [NSDate dateWithTimeIntervalSince1970:1800000000];
        self.credential = @{@"accessToken": @"synthetic-test-token", @"expiresAt": @1800100000000};
    }
    return self;
}
- (NSDate *)now { return self.clock; }
- (NSDictionary *)readCredentialAllowingInteraction:(BOOL)allow error:(NSError **)error {
    self.credentialReads++;
    if (allow) self.interactiveReads++;
    if (error) *error = self.credentialError;
    return self.credential;
}
- (NSDictionary *)requestUsageWithToken:(NSString *)token { self.requests++; return self.reply; }
- (NSString *)usageCLIPath { return self.useCLI ? @"/synthetic/CodexBarCLI" : nil; }
- (NSDictionary *)requestUsageWithCLIAtPath:(NSString *)path { self.cliRequests++; return self.cliReply; }
@end

static NSDictionary *Reply(NSInteger status, NSDictionary *headers, id payload) {
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://example.invalid"]
        statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:headers];
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload ?: @{} options:NSJSONWritingFragmentsAllowed error:nil];
    return @{@"response": response, @"data": data};
}

static NSDictionary *Usage(void) { return @{@"five_hour": @{@"utilization": @42, @"resets_at": NSNull.null}}; }

static TBProviderSnapshot *Fetch(TBTestClaudeService *service, BOOL manual, NSError **error) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block TBProviderSnapshot *snapshot;
    __block NSError *failure;
    [service fetchWithUserInitiated:manual completion:^(TBProviderSnapshot *value, NSError *issue) {
        snapshot = value; failure = issue; dispatch_semaphore_signal(done);
    }];
    NSCAssert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0, @"Fetch must finish");
    if (error) *error = failure;
    return snapshot;
}

static TBTestClaudeService *Service(TBMemoryDefaults **store) {
    TBMemoryDefaults *defaults = [TBMemoryDefaults new];
    if (store) *store = defaults;
    TBTestClaudeService *service = [[TBTestClaudeService alloc] initWithDefaults:defaults];
    service.reply = Reply(200, @{}, Usage());
    return service;
}

static void TestCacheAndConcurrentRefresh(void) {
    TBTestClaudeService *service = Service(NULL);
    dispatch_group_t group = dispatch_group_create();
    for (int i = 0; i < 10; i++) {
        dispatch_group_enter(group);
        [service fetchWithUserInitiated:YES completion:^(TBProviderSnapshot *snapshot, NSError *error) {
            NSCAssert(snapshot && !error, @"Concurrent refresh should share cached success");
            dispatch_group_leave(group);
        }];
    }
    NSCAssert(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0, @"Requests must finish");
    NSCAssert(service.requests == 1 && service.interactiveReads == 0, @"Repeated refresh must not spam usage or prompt");
    NSDate *captured = Fetch(service, NO, NULL).fetchedAt;
    service.clock = [service.clock dateByAddingTimeInterval:240];
    NSCAssert([Fetch(service, YES, NULL).fetchedAt isEqual:captured], @"Cached timestamp must remain the original capture time");
    service.clock = [service.clock dateByAddingTimeInterval:60];
    Fetch(service, NO, NULL);
    NSCAssert(service.requests == 2, @"Refresh should resume at five minutes");
}

static void TestRateLimitsAndRestart(void) {
    TBMemoryDefaults *defaults;
    TBTestClaudeService *service = Service(&defaults);
    TBProviderSnapshot *first = Fetch(service, NO, NULL);
    service.clock = [service.clock dateByAddingTimeInterval:300];
    service.reply = Reply(429, @{@"Retry-After": @"720"}, @{});
    NSError *error;
    TBProviderSnapshot *cached = Fetch(service, NO, &error);
    NSCAssert(cached && error && cached.statusMessage.length > 0, @"Rate limit must remain visible alongside cached bars");
    NSCAssert([cached.fetchedAt isEqual:first.fetchedAt], @"A failed request must not look freshly captured");
    NSCAssert([cached.nextRefreshAt timeIntervalSinceDate:service.clock] == 720, @"Must honor server Retry-After");
    TBTestClaudeService *restarted = [[TBTestClaudeService alloc] initWithDefaults:defaults];
    restarted.clock = service.clock;
    restarted.reply = Reply(200, @{}, Usage());
    Fetch(restarted, YES, &error);
    NSCAssert(restarted.requests == 0 && error, @"Restart and manual refresh must respect persistent cooldown");
    restarted.clock = [restarted.clock dateByAddingTimeInterval:720];
    NSCAssert(Fetch(restarted, NO, &error) && !error && restarted.requests == 1, @"Success should recover at the deadline");
    NSCAssert(![defaults objectForKey:@"claudeRateLimitCount"], @"Success resets exponential backoff");
    NSCAssert(![defaults.values.description containsString:@"synthetic-test-token"], @"Persisted data must not contain access tokens");
}

static void TestRetryAfterDateAndExponentialBackoff(void) {
    TBTestClaudeService *service = Service(NULL);
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss zzz";
    NSString *date = [formatter stringFromDate:[service.clock dateByAddingTimeInterval:900]];
    service.reply = Reply(429, @{@"Retry-After": date}, @{});
    NSError *error;
    NSCAssert(Fetch(service, NO, &error) == nil && error, @"Rate limit without cache must show an error");
    NSUserDefaults *defaults = [service valueForKey:@"defaults"];
    NSCAssert([[defaults objectForKey:@"claudeNextRequestAt"] timeIntervalSinceDate:service.clock] == 900, @"HTTP-date Retry-After must parse");
    for (NSNumber *expected in @[@600, @1200, @1800, @1800]) {
        service.clock = [defaults objectForKey:@"claudeNextRequestAt"];
        service.reply = Reply(429, @{@"Retry-After": @"invalid"}, @{});
        Fetch(service, YES, NULL);
        NSCAssert([[defaults objectForKey:@"claudeNextRequestAt"] timeIntervalSinceDate:service.clock] == expected.doubleValue,
                  @"Backoff should grow and cap at thirty minutes");
    }
}

static void TestNetworkAndMalformedResponses(void) {
    for (id reply in @[
        @{@"error": [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]},
        Reply(500, @{}, @{}), Reply(200, @{}, @[]), Reply(200, @{}, @{@"five_hour": NSNull.null})]) {
        TBTestClaudeService *service = Service(NULL);
        TBProviderSnapshot *first = Fetch(service, NO, NULL);
        service.clock = [service.clock dateByAddingTimeInterval:300];
        service.reply = reply;
        NSError *error;
        TBProviderSnapshot *cached = Fetch(service, NO, &error);
        NSCAssert(error && [cached.fetchedAt isEqual:first.fetchedAt], @"Temporary failures must preserve a visibly stale capture");
        Fetch(service, YES, NULL);
        NSCAssert(service.requests == 2, @"Failed attempts must also throttle repeated clicks");
    }
}

static void TestCredentialFailureClassification(void) {
    TBTestClaudeService *service = Service(NULL);
    Fetch(service, NO, NULL);
    service.clock = [service.clock dateByAddingTimeInterval:300];
    service.credential = nil;
    service.credentialError = [NSError errorWithDomain:TBUsageErrorDomain code:TBClaudeErrorKeychainAccess
                                           userInfo:@{NSLocalizedDescriptionKey: @"Access unavailable"}];
    NSError *error;
    NSCAssert(Fetch(service, NO, &error) && error.code == TBClaudeErrorKeychainAccess, @"Permission loss must not masquerade as a lost login");
    NSCAssert(service.requests == 1 && service.interactiveReads == 0, @"Credential failure must not query usage or show UI");
    service.credentialError = [NSError errorWithDomain:TBUsageErrorDomain code:TBClaudeErrorSignInRequired userInfo:nil];
    Fetch(service, NO, &error);
    NSCAssert(error.code == TBClaudeErrorSignInRequired, @"A missing login must remain distinct");
}

static void TestExpiredCredentialsStaySilent(void) {
    TBTestClaudeService *service = Service(NULL);
    service.credential = @{@"accessToken": @"synthetic-expired-token", @"expiresAt": @1700000000000};
    NSError *error;
    Fetch(service, NO, &error);
    NSCAssert(error.code == TBClaudeErrorExpired && !service.requests && !service.interactiveReads,
              @"Background work must neither send expired tokens nor prompt");
    Fetch(service, YES, &error);
    NSCAssert(error.code == TBClaudeErrorExpired && !service.requests && !service.interactiveReads,
              @"Ordinary manual Refresh must also remain noninteractive");
    service.credential = @{@"accessToken": @"synthetic-renewed-token", @"expiresAt": @1800100000000};
    NSCAssert(Fetch(service, YES, &error) && !error && service.requests == 1,
              @"A credential renewed externally by Claude Code should recover without a new login");
}

static void TestUnauthorizedAndForbidden(void) {
    for (NSNumber *status in @[@401, @403]) {
        TBTestClaudeService *service = Service(NULL);
        service.reply = Reply(status.integerValue, @{}, @{});
        NSError *error;
        Fetch(service, NO, &error);
        NSCAssert(error && error.code != TBClaudeErrorSignInRequired, @"API rejection does not prove the local login is absent");
        NSCAssert(!service.interactiveReads, @"Rejection must not trigger a background auth flow");
        Fetch(service, YES, &error);
        NSCAssert(error && service.requests == 1, @"Auth rejection must retain its error during cooldown");
    }
}

static NSDictionary *CLIReply(NSDate *date, id percent) {
    NSString *stamp = [[NSISO8601DateFormatter new] stringFromDate:date];
    NSDictionary *entry = @{@"provider": @"claude", @"source": @"claude", @"usage": @{
        @"updatedAt": stamp, @"loginMethod": @"Max", @"accountEmail": @"private@example.invalid",
        @"primary": @{@"usedPercent": percent, @"resetsAt": @"2027-01-16T13:00:00Z"},
        @"secondary": @{@"usedPercent": @7},
        @"extraRateWindows": @[@{@"title": @"Fable only", @"window": @{@"usedPercent": @0, @"windowMinutes": @10080}}]}};
    return @{@"status": @0, @"data": [NSJSONSerialization dataWithJSONObject:@[entry] options:0 error:nil]};
}

static void TestAutomaticCLIRenewalAndPersistence(void) {
    TBMemoryDefaults *defaults;
    TBTestClaudeService *service = Service(&defaults);
    // Existing cached 42% and an inaccessible/expired credential must not block the owner CLI.
    TBProviderSnapshot *old = Fetch(service, NO, NULL);
    service.clock = [service.clock dateByAddingTimeInterval:300];
    service.credential = nil;
    service.useCLI = YES;
    service.cliReply = CLIReply(service.clock, @7);
    NSError *error;
    TBProviderSnapshot *fresh = Fetch(service, NO, &error);
    NSCAssert(!error && fresh.windows[0].usedPercent == 7 && fresh.windows.count == 3 && [fresh.plan isEqual:@"Max"],
              @"Background CLI probe must recover real session, weekly and scoped windows without permission");
    NSCAssert([fresh.fetchedAt compare:old.fetchedAt] == NSOrderedDescending && service.credentialReads == 1 &&
              service.requests == 1 && service.cliRequests == 1 && !service.interactiveReads,
              @"Preferred CLI must bypass both foreign Keychain and direct OAuth requests");
    for (int i = 0; i < 10; i++) Fetch(service, YES, NULL);
    NSCAssert(service.cliRequests == 1, @"CLI refresh clicks share the same five-minute throttle");
    TBTestClaudeService *restarted = [[TBTestClaudeService alloc] initWithDefaults:defaults];
    restarted.useCLI = YES;
    restarted.clock = service.clock;
    NSCAssert(Fetch(restarted, NO, &error) && !error && !restarted.cliRequests, @"Restart retains CLI cache and cooldown");
    restarted.clock = [restarted.clock dateByAddingTimeInterval:300];
    restarted.cliReply = CLIReply(restarted.clock, @9);
    NSCAssert(Fetch(restarted, NO, &error).windows[0].usedPercent == 9 && !error && restarted.cliRequests == 1,
              @"A subsequent scheduled refresh must update automatically without any authorization click");
    NSCAssert(![defaults.values.description containsString:@"private@example.invalid"], @"Cache stores only quota fields, not CLI account identity");
}

static void TestCLIFailuresKeepOriginalCapture(void) {
    TBTestClaudeService *service = Service(NULL);
    service.useCLI = YES;
    service.cliReply = CLIReply(service.clock, @7);
    TBProviderSnapshot *first = Fetch(service, NO, NULL);
    for (NSDictionary *reply in @[
        CLIReply([service.clock dateByAddingTimeInterval:-3600], @80),
        @{@"status": @1, @"data": [@"{\"error\":\"rate limited 429\"}" dataUsingEncoding:NSUTF8StringEncoding]},
        @{@"status": @(-1)},
        @{@"status": @0, @"data": [@"[]" dataUsingEncoding:NSUTF8StringEncoding]},
        @{@"status": @1, @"data": CLIReply(service.clock, @10)[@"data"]}]) {
        service.clock = service.nextRequestAt;
        service.cliReply = reply;
        NSError *error;
        TBProviderSnapshot *cached = Fetch(service, NO, &error);
        NSCAssert(error && [cached.fetchedAt isEqual:first.fetchedAt] && cached.windows[0].usedPercent == 7,
                  @"Stale, failed or malformed CLI probes must not overwrite a valid measurement");
        NSInteger attempts = service.cliRequests;
        Fetch(service, YES, NULL);
        NSCAssert(service.cliRequests == attempts && !service.requests && !service.credentialReads,
                  @"CLI failure must retain cooldown and never bypass it by switching to OAuth");
    }
    for (NSNumber *delay in @[@600, @1200, @1800, @1800]) {
        service.clock = service.nextRequestAt;
        service.cliReply = @{@"status": @1, @"data": [@"rate_limit_error" dataUsingEncoding:NSUTF8StringEncoding]};
        Fetch(service, NO, NULL);
        // A previous 429 above contributes one attempt; verify growing, capped backoff.
        NSCAssert([service.nextRequestAt timeIntervalSinceDate:service.clock] == delay.doubleValue,
                  @"CLI rate limits must grow backoff rather than causing repeated probes");
    }
    for (id entry in @[
        @{@"provider": @"claude", @"source": @"web", @"usage": @{}},
        @{@"provider": @"codex", @"source": @"cli", @"usage": @{}}, NSNull.null]) {
        NSError *error;
        NSData *data = [NSJSONSerialization dataWithJSONObject:@[entry] options:0 error:nil];
        NSCAssert(![TBClaudeUsageService claudePayloadFromCLIData:data error:&error] && error,
                  @"Unexpected providers, browser accounts and malformed rows must be rejected");
    }
}

// Exercise the real credential reader, replacing only the OS calls. The older tests
// mocked the whole reader and could not detect a missing legacy no-dialog policy.
@interface TBKeychainProbeService : TBClaudeUsageService
@property(nonatomic) NSMutableArray *events;
@property(nonatomic) NSDictionary *lastQuery;
@property(nonatomic) OSStatus copyStatus;
@property(nonatomic) OSStatus disableStatus;
@property(nonatomic) BOOL throwOnCopy;
@property(nonatomic) NSData *syntheticData;
@end

@implementation TBKeychainProbeService
- (instancetype)init {
    if ((self = [super initWithDefaults:[TBMemoryDefaults new]])) {
        _events = [NSMutableArray new];
        _copyStatus = errSecInteractionNotAllowed;
    }
    return self;
}
- (OSStatus)setKeychainInteractionAllowed:(BOOL)allowed {
    [self.events addObject:allowed ? @"allow" : @"deny"];
    return allowed ? errSecSuccess : self.disableStatus;
}
- (OSStatus)copyKeychainItemMatching:(NSDictionary *)query result:(CFTypeRef *)result {
    self.lastQuery = query;
    [self.events addObject:@"copy"];
    if (self.throwOnCopy) [NSException raise:@"SyntheticKeychainFailure" format:@"Test failure"];
    if (result && self.syntheticData) *result = CFBridgingRetain(self.syntheticData);
    return self.copyStatus;
}
@end

static void TestKeychainNoDialogBoundary(void) {
    TBKeychainProbeService *service = [TBKeychainProbeService new];
    NSError *error = nil;
    NSCAssert(![service readCredentialAllowingInteraction:NO error:&error], @"Locked credentials should be unavailable");
    NSCAssert(error.code == TBClaudeErrorKeychainAccess, @"Unavailable access should retain the manual recovery action");
    NSCAssert(([service.events isEqual:@[@"deny", @"copy", @"deny"]]), @"Disable process-wide dialogs before reading and keep them disabled afterward");
    LAContext *context = service.lastQuery[(__bridge id)kSecUseAuthenticationContext];
    NSCAssert(context.interactionNotAllowed, @"Background reader must also forbid LAContext interaction");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSCAssert([service.lastQuery[(__bridge id)kSecUseAuthenticationUI] isEqual:(__bridge id)kSecUseAuthenticationUIFail],
              @"Legacy Keychain requires explicit UI-fail policy in addition to LAContext");
#pragma clang diagnostic pop

    [service.events removeAllObjects];
    service.disableStatus = errSecNotAvailable;
    [service readCredentialAllowingInteraction:NO error:&error];
    NSCAssert(([service.events isEqual:@[@"deny", @"deny"]]), @"Fail closed without reading credentials if dialog suppression fails");

    [service.events removeAllObjects];
    service.disableStatus = errSecSuccess;
    service.throwOnCopy = YES;
    @try { [service readCredentialAllowingInteraction:YES error:&error]; }
    @catch (NSException *exception) { NSCAssert([exception.name isEqual:@"SyntheticKeychainFailure"], @"Expected injected failure"); }
    NSCAssert(([service.events isEqual:@[@"allow", @"copy", @"deny"]]), @"Even an exceptional interactive read must restore no-dialog mode");
}

static void TestExplicitAuthorizationBoundary(void) {
    TBKeychainProbeService *service = [TBKeychainProbeService new];
    service.copyStatus = errSecSuccess;
    service.syntheticData = [NSJSONSerialization dataWithJSONObject:
        @{@"claudeAiOauth": @{@"accessToken": @"synthetic-authorized-token"}} options:0 error:nil];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [service authorizeWithCompletion:^(NSError *error) {
        NSCAssert(!error, @"Explicit authorization should read the synthetic credential");
        dispatch_semaphore_signal(done);
    }];
    NSCAssert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0, @"Authorization must complete");
    NSCAssert(([service.events isEqual:@[@"allow", @"copy", @"deny"]]), @"Only explicit authorization may temporarily enable dialogs");
    LAContext *context = service.lastQuery[(__bridge id)kSecUseAuthenticationContext];
    NSCAssert(!context.interactionNotAllowed, @"Explicit authorization may permit the user-owned Keychain prompt");
    NSCAssert(![[(TBMemoryDefaults *)[service valueForKey:@"defaults"] values].description containsString:@"synthetic-authorized-token"],
              @"Authorization must not persist provider tokens");
}

int main(void) {
    @autoreleasepool {
        TestCacheAndConcurrentRefresh();
        TestRateLimitsAndRestart();
        TestRetryAfterDateAndExponentialBackoff();
        TestNetworkAndMalformedResponses();
        TestCredentialFailureClassification();
        TestExpiredCredentialsStaySilent();
        TestUnauthorizedAndForbidden();
        TestAutomaticCLIRenewalAndPersistence();
        TestCLIFailuresKeepOriginalCapture();
        TestKeychainNoDialogBoundary();
        TestExplicitAuthorizationBoundary();
        NSLog(@"TokenBar Claude service tests passed");
    }
    return 0;
}
