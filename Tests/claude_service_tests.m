#import <Foundation/Foundation.h>
#import "TBUsageServices.h"

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
@property(nonatomic) NSInteger renewals;
@property(nonatomic) NSInteger interactiveReads;
@property(nonatomic) BOOL renewSucceeds;
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
    if (allow) self.interactiveReads++;
    if (error) *error = self.credentialError;
    return self.credential;
}
- (void)renewClaudeSession {
    self.renewals++;
    if (self.renewSucceeds) self.credential = @{@"accessToken": @"synthetic-new-token", @"expiresAt": @1800100000000};
}
- (NSDictionary *)requestUsageWithToken:(NSString *)token { self.requests++; return self.reply; }
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

static void TestExpiredCredentialRenewal(void) {
    TBTestClaudeService *service = Service(NULL);
    service.credential = @{@"accessToken": @"synthetic-expired-token", @"expiresAt": @1700000000000};
    NSError *error;
    Fetch(service, NO, &error);
    NSCAssert(error.code == TBClaudeErrorExpired && !service.requests && !service.renewals, @"Background work must neither send expired tokens nor launch the owner CLI");
    service.renewSucceeds = YES;
    NSCAssert(Fetch(service, YES, &error) && !error, @"Manual refresh may renew through the owner CLI");
    NSCAssert(service.renewals == 1 && service.requests == 1, @"Renew before requesting usage");
    service = Service(NULL);
    service.credential = @{@"accessToken": @"synthetic-expired-token", @"expiresAt": @1700000000000};
    Fetch(service, YES, &error);
    NSCAssert(error.code == TBClaudeErrorExpired && !service.requests, @"Failed renewal must not send the expired token");
}

static void TestUnauthorizedAndForbidden(void) {
    for (NSNumber *status in @[@401, @403]) {
        TBTestClaudeService *service = Service(NULL);
        service.reply = Reply(status.integerValue, @{}, @{});
        NSError *error;
        Fetch(service, NO, &error);
        NSCAssert(error && error.code != TBClaudeErrorSignInRequired, @"API rejection does not prove the local login is absent");
        NSCAssert(!service.renewals && !service.interactiveReads, @"Rejection must not trigger a background auth flow");
        Fetch(service, YES, &error);
        NSCAssert(error && service.requests == 1, @"Auth rejection must retain its error during cooldown");
    }
}

int main(void) {
    @autoreleasepool {
        TestCacheAndConcurrentRefresh();
        TestRateLimitsAndRestart();
        TestRetryAfterDateAndExponentialBackoff();
        TestNetworkAndMalformedResponses();
        TestCredentialFailureClassification();
        TestExpiredCredentialRenewal();
        TestUnauthorizedAndForbidden();
        NSLog(@"TokenBar Claude service tests passed");
    }
    return 0;
}
