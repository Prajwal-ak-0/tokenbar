#import <Foundation/Foundation.h>
#import "TBUsageModels.h"

static void TestCodexWeeklySelection(void) {
    NSDictionary *result = @{
        @"rateLimits": @{
            @"limitId": @"codex",
            @"planType": @"prolite",
            @"primary": @{
                @"usedPercent": @19,
                @"windowDurationMins": @300,
                @"resetsAt": @1800000000,
            },
            @"secondary": @{
                @"usedPercent": @41,
                @"windowDurationMins": @10080,
                @"resetsAt": @1800100000,
            },
        },
    };
    NSError *error = nil;
    TBProviderSnapshot *snapshot = [TBUsageParser codexSnapshotFromResult:result error:&error];
    NSCAssert(error == nil, @"Codex parser returned an error");
    NSCAssert(snapshot.windows.count == 1, @"Expected one Codex window");
    NSCAssert([snapshot.windows.firstObject.identifier isEqualToString:@"codex-weekly"],
              @"Expected weekly Codex window");
    NSCAssert(snapshot.windows.firstObject.usedPercent == 41, @"Expected weekly utilization");
    NSCAssert([snapshot.plan isEqualToString:@"Max"], @"Expected Max plan label");
}

static void TestClaudeWindows(void) {
    NSDictionary *response = @{
        @"five_hour": @{
            @"utilization": @23.4,
            @"resets_at": @"2026-08-07T14:30:00Z",
        },
        @"seven_day": @{
            @"utilization": @48.2,
            @"resets_at": @"2026-08-11T02:00:00Z",
        },
        @"seven_day_sonnet": @{
            @"utilization": @31.8,
            @"resets_at": @"2026-08-11T02:00:00Z",
        },
        @"seven_day_opus": NSNull.null,
    };
    NSError *error = nil;
    TBProviderSnapshot *snapshot = [TBUsageParser claudeSnapshotFromResponse:response error:&error];
    NSCAssert(error == nil, @"Claude parser returned an error");
    NSCAssert(snapshot.windows.count == 3, @"Expected three Claude windows");
    NSCAssert([snapshot.windows[0].identifier isEqualToString:@"claude-session"],
              @"Expected session window first");
    NSCAssert(snapshot.windows[0].resetsAt != nil, @"Expected parsed reset date");
}

static void TestClaudeCachePreservesNullValues(void) {
    NSDictionary *response = @{
        @"five_hour": @{
            @"utilization": @7,
            @"resets_at": @"2026-08-07T13:50:00Z",
            @"limit_dollars": NSNull.null,
        },
        @"seven_day": @{
            @"utilization": @46,
            @"resets_at": @"2026-08-09T12:00:00Z",
        },
        @"seven_day_opus": NSNull.null,
    };
    NSData *cacheData = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
    NSCAssert(cacheData != nil, @"Expected Claude response to serialize as JSON data");
    NSDictionary *decoded = [NSJSONSerialization JSONObjectWithData:cacheData options:0 error:nil];
    NSCAssert([decoded[@"five_hour"][@"limit_dollars"] isEqual:NSNull.null],
              @"Expected JSON null to survive the cache round trip");
    NSError *error = nil;
    TBProviderSnapshot *snapshot = [TBUsageParser claudeSnapshotFromResponse:decoded error:&error];
    NSCAssert(error == nil && snapshot.windows.count == 2,
              @"Expected cached Claude payload to remain parseable");
}

static void TestClaudePlanAndInvalidPercentages(void) {
    NSCAssert([[TBUsageParser claudePlanFromCredential:@{@"subscriptionType": @"pro"}] isEqual:@"Pro"], @"Use actual subscription plan");
    NSCAssert([[TBUsageParser claudePlanFromCredential:@{@"rateLimitTier": @"default_claude_max_5x"}] isEqual:@"Max"], @"Tier fallback should recognize Max");
    NSCAssert([TBUsageParser claudePlanFromCredential:@{}] == nil, @"Unknown plan must not be invented");
    for (id value in @[@YES, @"42", @(-1), @101, NSNull.null]) {
        NSError *error = nil;
        TBProviderSnapshot *snapshot = [TBUsageParser claudeSnapshotFromResponse:@{@"five_hour": @{@"utilization": value}} error:&error];
        NSCAssert(!snapshot && error, @"Invalid percentages must never become fabricated usage");
    }
    TBProviderSnapshot *precise = [TBUsageParser claudeSnapshotFromResponse:@{@"five_hour": @{@"utilization": @15.37}} error:nil];
    NSCAssert(precise.windows.firstObject.usedPercent == 15.37 && precise.plan == nil, @"Preserve source precision and avoid hardcoded plan");
}

static void TestClaudeScopedWindows(void) {
    NSDictionary *response = @{@"limits": @[
        NSNull.null, @{@"kind": @"weekly_scoped", @"percent": @YES},
        @{@"kind": @"weekly_scoped", @"percent": @12.3, @"scope": @{@"model": @{@"display_name": @"Example model"}}, @"resets_at": @"2026-10-25T12:00:00Z"},
        @{@"kind": @"weekly_scoped", @"percent": @7, @"scope": @{@"model": @{@"display_name": @"All models"}}}
    ]};
    NSError *error = nil;
    TBProviderSnapshot *snapshot = [TBUsageParser claudeSnapshotFromResponse:response error:&error];
    NSCAssert(!error && snapshot.windows.count == 1, @"Scoped quota must survive malformed siblings without duplicating generic usage");
    NSCAssert(snapshot.windows.firstObject.usedPercent == 12.3 && snapshot.windows.firstObject.resetsAt != nil, @"Scoped percentage and reset must come from the response");
}

static void TestAdaptiveRefreshIntervals(void) {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1800000000];
    NSCAssert([TBRefreshPolicy intervalAt:now lastInteraction:now constrained:NO] == 300, @"Active checks retain a five-minute floor");
    NSCAssert([TBRefreshPolicy intervalAt:now lastInteraction:[now dateByAddingTimeInterval:-3601] constrained:NO] == 900, @"Idle checks slow to fifteen minutes");
    NSCAssert([TBRefreshPolicy intervalAt:now lastInteraction:nil constrained:NO] == 1800, @"No interaction means low-frequency checks");
    NSCAssert([TBRefreshPolicy intervalAt:now lastInteraction:now constrained:YES] == 1800, @"Constrained devices check less often");
    NSCAssert([TBRefreshPolicy intervalAt:now lastInteraction:[now dateByAddingTimeInterval:60] constrained:NO] == 300, @"Clock adjustment must not cause a refresh storm");
}

static void TestResetRefreshHonorsCooldown(void) {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1800000000];
    TBProviderSnapshot *snapshot = [TBProviderSnapshot new];
    snapshot.fetchedAt = [now dateByAddingTimeInterval:-600];
    TBUsageWindow *window = [TBUsageWindow new];
    window.resetsAt = [now dateByAddingTimeInterval:-30];
    snapshot.windows = @[window];
    NSDate *cooldown = [now dateByAddingTimeInterval:420];
    NSDate *next = [TBRefreshPolicy nextRefreshAt:now snapshot:snapshot lastAttempt:now lastInteraction:now
        constrained:NO earliestRequest:cooldown retrying:NO];
    NSCAssert([next isEqual:cooldown], @"A passed reset must not bypass provider cooldown");
    next = [TBRefreshPolicy nextRefreshAt:now snapshot:snapshot lastAttempt:now lastInteraction:now
        constrained:NO earliestRequest:nil retrying:YES];
    NSCAssert([next timeIntervalSinceDate:now] == 300, @"A failed reset refresh must not run in a tight retry loop");
    next = [TBRefreshPolicy nextRefreshAt:now snapshot:snapshot lastAttempt:now lastInteraction:now
        constrained:NO earliestRequest:nil retrying:NO];
    NSCAssert([next compare:now] == NSOrderedAscending, @"A reset should bring a measurement forward when eligible");
    NSCAssert(snapshot.windows.firstObject.usedPercent == 0 && [snapshot.fetchedAt timeIntervalSinceDate:now] == -600,
              @"Scheduling must not change measurements or their capture time");
}

int main(void) {
    @autoreleasepool {
        TestClaudePlanAndInvalidPercentages();
        TestAdaptiveRefreshIntervals();
        TestResetRefreshHonorsCooldown();
        TestClaudeScopedWindows();
        TestCodexWeeklySelection();
        TestClaudeWindows();
        TestClaudeCachePreservesNullValues();
        NSLog(@"TokenBar parser tests passed");
    }
    return 0;
}
