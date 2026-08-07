#import "TBUsageModels.h"

NSString *const TBUsageErrorDomain = @"com.prajwalak.tokenbar.usage";

@implementation TBUsageWindow
@end

@implementation TBProviderSnapshot
@end

@implementation TBUsageParser

+ (TBProviderSnapshot *)codexSnapshotFromResult:(NSDictionary *)result error:(NSError **)error {
    NSDictionary *limitsByID = result[@"rateLimitsByLimitId"];
    NSDictionary *limit = [limitsByID isKindOfClass:NSDictionary.class] ? limitsByID[@"codex"] : nil;
    if (![limit isKindOfClass:NSDictionary.class]) {
        limit = result[@"rateLimits"];
    }
    if (![limit isKindOfClass:NSDictionary.class]) {
        [self setError:error message:@"Codex did not return an account quota."];
        return nil;
    }

    NSDictionary *weekly = nil;
    for (id candidate in @[limit[@"primary"] ?: NSNull.null, limit[@"secondary"] ?: NSNull.null]) {
        if (![candidate isKindOfClass:NSDictionary.class]) {
            continue;
        }
        if ([candidate[@"windowDurationMins"] integerValue] >= 7 * 24 * 60) {
            weekly = candidate;
            break;
        }
    }
    if (weekly == nil) {
        [self setError:error message:@"Codex did not return a weekly quota window."];
        return nil;
    }

    TBUsageWindow *window = [TBUsageWindow new];
    window.identifier = @"codex-weekly";
    window.title = @"Weekly";
    window.usedPercent = [weekly[@"usedPercent"] doubleValue];
    if ([weekly[@"resetsAt"] respondsToSelector:@selector(doubleValue)]) {
        window.resetsAt = [NSDate dateWithTimeIntervalSince1970:[weekly[@"resetsAt"] doubleValue]];
    }

    TBProviderSnapshot *snapshot = [TBProviderSnapshot new];
    snapshot.provider = @"Codex";
    snapshot.plan = [self displayCodexPlan:limit[@"planType"]];
    snapshot.windows = @[window];
    snapshot.fetchedAt = NSDate.date;
    return snapshot;
}

+ (TBProviderSnapshot *)claudeSnapshotFromResponse:(NSDictionary *)response error:(NSError **)error {
    NSMutableArray<TBUsageWindow *> *windows = [NSMutableArray array];
    [self appendClaudeWindow:response[@"five_hour"]
                  identifier:@"claude-session"
                       title:@"5-hour session"
                          to:windows];
    [self appendClaudeWindow:response[@"seven_day"]
                  identifier:@"claude-weekly"
                       title:@"Weekly · All models"
                          to:windows];
    [self appendClaudeWindow:response[@"seven_day_sonnet"]
                  identifier:@"claude-weekly-sonnet"
                       title:@"Weekly · Sonnet"
                          to:windows];
    [self appendClaudeWindow:response[@"seven_day_opus"]
                  identifier:@"claude-weekly-opus"
                       title:@"Weekly · Opus"
                          to:windows];
    [self appendClaudeWindow:response[@"seven_day_overage_included"]
                  identifier:@"claude-weekly-fable"
                       title:@"Weekly · Fable"
                          to:windows];

    if (windows.count == 0) {
        [self setError:error message:@"Claude did not return any quota windows."];
        return nil;
    }

    TBProviderSnapshot *snapshot = [TBProviderSnapshot new];
    snapshot.provider = @"Claude";
    snapshot.plan = @"Max";
    snapshot.windows = windows;
    snapshot.fetchedAt = NSDate.date;
    return snapshot;
}

+ (void)appendClaudeWindow:(id)value
                 identifier:(NSString *)identifier
                      title:(NSString *)title
                         to:(NSMutableArray<TBUsageWindow *> *)windows {
    if (![value isKindOfClass:NSDictionary.class]) {
        return;
    }
    id utilization = value[@"utilization"];
    if (![utilization respondsToSelector:@selector(doubleValue)]) {
        return;
    }

    TBUsageWindow *window = [TBUsageWindow new];
    window.identifier = identifier;
    window.title = title;
    window.usedPercent = [utilization doubleValue];
    if ([value[@"resets_at"] isKindOfClass:NSString.class]) {
        window.resetsAt = [self dateFromISO8601:value[@"resets_at"]];
    }
    [windows addObject:window];
}

+ (NSDate *)dateFromISO8601:(NSString *)value {
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                              NSISO8601DateFormatWithFractionalSeconds;
    NSDate *date = [formatter dateFromString:value];
    if (date != nil) {
        return date;
    }
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [formatter dateFromString:value];
}

+ (NSString *)displayCodexPlan:(id)value {
    if (![value isKindOfClass:NSString.class] || [value length] == 0) {
        return nil;
    }
    NSString *plan = [value lowercaseString];
    if ([plan isEqualToString:@"prolite"]) return @"Max";
    if ([plan isEqualToString:@"pro"]) return @"Pro";
    if ([plan isEqualToString:@"plus"]) return @"Plus";
    if ([plan isEqualToString:@"team"]) return @"Team";
    if ([plan isEqualToString:@"enterprise"]) return @"Enterprise";
    return [[plan stringByReplacingOccurrencesOfString:@"_" withString:@" "] capitalizedString];
}

+ (void)setError:(NSError **)error message:(NSString *)message {
    if (error != NULL) {
        *error = [NSError errorWithDomain:TBUsageErrorDomain
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey: message}];
    }
}

@end
