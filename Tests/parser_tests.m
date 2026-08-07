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

int main(void) {
    @autoreleasepool {
        TestCodexWeeklySelection();
        TestClaudeWindows();
        TestClaudeCachePreservesNullValues();
        NSLog(@"TokenBar parser tests passed");
    }
    return 0;
}
