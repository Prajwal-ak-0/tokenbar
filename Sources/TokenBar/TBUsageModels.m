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

    if (![self isValidPercent:weekly[@"usedPercent"]]) {
        [self setError:error message:@"Codex returned an invalid weekly percentage."];
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
                  identifier:@"claude-weekly-included"
                       title:@"Weekly · Included allowance"
                          to:windows];

    // The current endpoint also reports model-specific windows in a scoped limits array.
    // Read each entry independently so one malformed sibling cannot discard valid measurements.
    id limits = response[@"limits"];
    if ([limits isKindOfClass:NSArray.class]) for (id entry in limits) {
        if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"kind"] isEqual:@"weekly_scoped"] ||
            ![self isValidPercent:entry[@"percent"]]) continue;
        id scope = entry[@"scope"];
        id model = [scope isKindOfClass:NSDictionary.class] ? scope[@"model"] : nil;
        if (![model isKindOfClass:NSDictionary.class]) continue;
        id displayName = model[@"display_name"];
        if (![displayName isKindOfClass:NSString.class] || [displayName length] == 0) continue;
        NSString *name = [displayName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *normalized = name.lowercaseString;
        if (name.length == 0 || [normalized isEqual:@"all models"] || [normalized isEqual:@"all"]) continue;
        NSString *identifier = [@"claude-weekly-scoped-" stringByAppendingString:normalized];
        if ([normalized containsString:@"sonnet"]) identifier = @"claude-weekly-sonnet";
        if ([normalized containsString:@"opus"]) identifier = @"claude-weekly-opus";
        BOOL duplicate = NO;
        for (TBUsageWindow *existing in windows) if ([existing.identifier isEqual:identifier]) { duplicate = YES; break; }
        if (duplicate) continue;
        [self appendClaudeWindow:@{@"utilization": entry[@"percent"], @"resets_at": entry[@"resets_at"] ?: NSNull.null}
                      identifier:identifier title:[@"Weekly · " stringByAppendingString:name] to:windows];
    }

    if (windows.count == 0) {
        [self setError:error message:@"Claude did not return any quota windows."];
        return nil;
    }

    TBProviderSnapshot *snapshot = [TBProviderSnapshot new];
    snapshot.provider = @"Claude";
    snapshot.plan = nil;
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
    if (![self isValidPercent:utilization]) return;

    TBUsageWindow *window = [TBUsageWindow new];
    window.identifier = identifier;
    window.title = title;
    window.usedPercent = [utilization doubleValue];
    if ([value[@"resets_at"] isKindOfClass:NSString.class]) {
        window.resetsAt = [self dateFromISO8601:value[@"resets_at"]];
    }
    [windows addObject:window];
}

+ (BOOL)isValidPercent:(id)value {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        isfinite([value doubleValue]) && [value doubleValue] >= 0 && [value doubleValue] <= 100;
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

+ (NSString *)claudePlanFromCredential:(NSDictionary *)credential {
    id subscription = credential[@"subscriptionType"];
    id tier = credential[@"rateLimitTier"] ?: credential[@"rate_limit_tier"];
    NSString *value = [subscription isKindOfClass:NSString.class] ? [subscription lowercaseString] :
        [tier isKindOfClass:NSString.class] ? [tier lowercaseString] : @"";
    for (NSString *plan in @[@"enterprise", @"team", @"max", @"pro"]) {
        if ([value isEqualToString:plan] || [value hasPrefix:[plan stringByAppendingString:@"_"]] ||
            [value containsString:[@"_" stringByAppendingString:plan]]) return plan.capitalizedString;
    }
    return nil;
}

+ (void)setError:(NSError **)error message:(NSString *)message {
    if (error != NULL) {
        *error = [NSError errorWithDomain:TBUsageErrorDomain
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey: message}];
    }
}

@end

@implementation TBRefreshPolicy
+ (NSTimeInterval)intervalAt:(NSDate *)now lastInteraction:(NSDate *)lastInteraction constrained:(BOOL)constrained {
    if (constrained || !lastInteraction) return 30 * 60;
    NSTimeInterval age = [now timeIntervalSinceDate:lastInteraction];
    if (age <= 60 * 60) return 5 * 60;
    if (age < 4 * 60 * 60) return 15 * 60;
    return 30 * 60;
}
+ (NSDate *)nextRefreshAt:(NSDate *)now snapshot:(TBProviderSnapshot *)snapshot
             lastAttempt:(NSDate *)lastAttempt lastInteraction:(NSDate *)lastInteraction
             constrained:(BOOL)constrained earliestRequest:(NSDate *)earliestRequest retrying:(BOOL)retrying {
    NSTimeInterval interval = [self intervalAt:now lastInteraction:lastInteraction constrained:constrained];
    NSDate *base = snapshot.fetchedAt ?: lastAttempt ?: now;
    NSDate *next = [base dateByAddingTimeInterval:interval];
    if (retrying) next = earliestRequest ?: [(lastAttempt ?: now) dateByAddingTimeInterval:interval];
    if (!constrained && !retrying) {
        for (TBUsageWindow *window in snapshot.windows) {
            if (!window.resetsAt || [snapshot.fetchedAt compare:window.resetsAt] != NSOrderedAscending) continue;
            NSDate *resetCheck = [window.resetsAt dateByAddingTimeInterval:20];
            if ([resetCheck compare:next] == NSOrderedAscending) next = resetCheck;
        }
    }
    // Neither reset boundaries nor menu interaction can bypass a provider's persisted cooldown.
    if (earliestRequest && [earliestRequest compare:next] == NSOrderedDescending) next = earliestRequest;
    return next;
}
@end
