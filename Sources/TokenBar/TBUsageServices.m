#import "TBUsageServices.h"
#import <Security/Security.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <signal.h>
#import <unistd.h>

static NSError *TBError(NSString *message) {
    return [NSError errorWithDomain:TBUsageErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *const TBClaudeCachedPayloadKey = @"claudeCachedUsagePayload";
static NSString *const TBClaudeCachedPlanKey = @"claudeCachedPlan";
static NSString *const TBClaudeCachedAtKey = @"claudeCachedUsageAt";
static NSString *const TBClaudeNextRequestAtKey = @"claudeNextRequestAt";
static NSString *const TBClaudeIssueCodeKey = @"claudeRefreshIssueCode";
static NSString *const TBClaudeIssueKey = @"claudeRefreshIssue";
static NSString *const TBClaudeRateLimitCountKey = @"claudeRateLimitCount";
static const NSTimeInterval TBClaudeMinimumRequestInterval = 5 * 60;
static const NSTimeInterval TBClaudeInitialRateLimitBackoff = 5 * 60;
static const NSTimeInterval TBClaudeMaximumRateLimitBackoff = 30 * 60;

static TBProviderSnapshot *TBCachedClaudeSnapshot(NSUserDefaults *defaults) {
    id cachedValue = [defaults objectForKey:TBClaudeCachedPayloadKey];
    NSDictionary *payload = nil;
    if ([cachedValue isKindOfClass:NSData.class]) {
        id decoded = [NSJSONSerialization JSONObjectWithData:cachedValue options:0 error:nil];
        if ([decoded isKindOfClass:NSDictionary.class]) {
            payload = decoded;
        }
    } else if ([cachedValue isKindOfClass:NSDictionary.class]) {
        // Compatibility with early cache builds that stored property-list-safe responses directly.
        payload = cachedValue;
    }
    NSDate *cachedAt = [defaults objectForKey:TBClaudeCachedAtKey];
    if (![payload isKindOfClass:NSDictionary.class] || ![cachedAt isKindOfClass:NSDate.class]) {
        return nil;
    }
    NSError *error = nil;
    TBProviderSnapshot *snapshot = [TBUsageParser claudeSnapshotFromResponse:payload error:&error];
    snapshot.fetchedAt = cachedAt;
    snapshot.plan = [defaults stringForKey:TBClaudeCachedPlanKey];
    return snapshot;
}

static NSError *TBClaudeError(TBClaudeErrorCode code, NSString *message) {
    return [NSError errorWithDomain:TBUsageErrorDomain code:code
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSTimeInterval TBRetryAfterSeconds(NSHTTPURLResponse *response, NSDate *now) {
    NSString *raw = [response valueForHTTPHeaderField:@"Retry-After"];
    if (raw.length == 0) return 0;
    NSScanner *scanner = [NSScanner scannerWithString:raw];
    double seconds = 0;
    if ([scanner scanDouble:&seconds] && scanner.isAtEnd && isfinite(seconds)) return MAX(seconds, 0);
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss zzz";
    NSDate *date = [formatter dateFromString:raw];
    return date != nil ? MAX([date timeIntervalSinceDate:now], 0) : 0;
}

static NSString *TBExecutable(NSString *name) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray<NSString *> *candidates = @[
        [NSHomeDirectory() stringByAppendingPathComponent:[@".local/bin" stringByAppendingPathComponent:name]],
        [@"/opt/homebrew/bin" stringByAppendingPathComponent:name],
        [@"/usr/local/bin" stringByAppendingPathComponent:name],
        [@"/usr/bin" stringByAppendingPathComponent:name],
    ];
    for (NSString *path in candidates) {
        if ([manager isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
}

static NSDictionary *TBRunTask(NSString *executable, NSArray<NSString *> *arguments) {
    NSTask *task = [NSTask new];
    NSPipe *output = [NSPipe pipe];
    NSPipe *error = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = arguments;
    task.currentDirectoryURL = [NSURL fileURLWithPath:NSHomeDirectory()];
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    task.standardOutput = output;
    task.standardError = error;
    // Drain both pipes while the CLI runs; waiting first can deadlock on a full pipe.
    NSMutableData *stdoutData = [NSMutableData data];
    NSMutableData *stderrData = [NSMutableData data];
    output.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        @synchronized (stdoutData) { if (stdoutData.length + data.length <= 65536) [stdoutData appendData:data]; }
    };
    error.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        @synchronized (stderrData) { if (stderrData.length + data.length <= 65536) [stderrData appendData:data]; }
    };
    dispatch_semaphore_t exited = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask *finished) { dispatch_semaphore_signal(exited); };
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        output.fileHandleForReading.readabilityHandler = nil;
        error.fileHandleForReading.readabilityHandler = nil;
        return @{@"status": @(-1)};
    }
    BOOL timedOut = dispatch_semaphore_wait(exited, dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_SEC)) != 0;
    if (timedOut && task.running) {
        [task terminate];
        if (dispatch_semaphore_wait(exited, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) != 0 && task.running) {
            kill(task.processIdentifier, SIGKILL);
        }
    }
    output.fileHandleForReading.readabilityHandler = nil;
    error.fileHandleForReading.readabilityHandler = nil;
    return @{@"status": timedOut ? @(-1) : @(task.terminationStatus)};
}

@implementation TBCodexUsageService

- (void)fetchWithCompletion:(TBUsageCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *codex = TBExecutable(@"codex");
        if (codex == nil) {
            completion(nil, TBError(@"Could not find Codex on this Mac."));
            return;
        }

        NSTask *task = [NSTask new];
        NSPipe *input = [NSPipe pipe];
        NSPipe *output = [NSPipe pipe];
        NSPipe *errorPipe = [NSPipe pipe];
        task.executableURL = [NSURL fileURLWithPath:codex];
        task.arguments = @[@"app-server", @"--stdio"];
        task.standardInput = input;
        task.standardOutput = output;
        task.standardError = errorPipe;

        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        __block NSMutableData *buffer = [NSMutableData data];
        __block NSDictionary *rateResult = nil;
        __block NSError *responseError = nil;
        NSObject *guard = [NSObject new];

        output.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
            NSData *data = handle.availableData;
            if (data.length == 0) return;
            @synchronized (guard) {
                [buffer appendData:data];
                while (true) {
                    const unsigned char *bytes = buffer.bytes;
                    NSUInteger newline = NSNotFound;
                    for (NSUInteger index = 0; index < buffer.length; index++) {
                        if (bytes[index] == '\n') {
                            newline = index;
                            break;
                        }
                    }
                    if (newline == NSNotFound) break;
                    NSData *line = [buffer subdataWithRange:NSMakeRange(0, newline)];
                    [buffer replaceBytesInRange:NSMakeRange(0, newline + 1)
                                      withBytes:NULL
                                         length:0];
                    NSDictionary *message = [NSJSONSerialization JSONObjectWithData:line
                                                                             options:0
                                                                               error:nil];
                    if ([message[@"id"] integerValue] == 6) {
                        rateResult = message[@"result"];
                        if (![rateResult isKindOfClass:NSDictionary.class]) {
                            NSString *detail = message[@"error"][@"message"];
                            responseError = TBError(detail ?: @"Codex returned an unreadable quota response.");
                        }
                        dispatch_semaphore_signal(semaphore);
                    }
                }
            }
        };

        NSError *launchError = nil;
        if (![task launchAndReturnError:&launchError]) {
            output.fileHandleForReading.readabilityHandler = nil;
            completion(nil, launchError);
            return;
        }

        NSArray *messages = @[
            @{
                @"method": @"initialize",
                @"id": @0,
                @"params": @{
                    @"clientInfo": @{
                        @"name": @"tokenbar",
                        @"title": @"TokenBar",
                        @"version": @"0.1.0",
                    },
                },
            },
            @{@"method": @"initialized", @"params": @{}},
            @{@"method": @"account/rateLimits/read", @"id": @6},
        ];
        for (NSDictionary *message in messages) {
            NSData *json = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
            [input.fileHandleForWriting writeData:json];
            [input.fileHandleForWriting writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        }

        long waitResult = dispatch_semaphore_wait(
            semaphore,
            dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)
        );
        output.fileHandleForReading.readabilityHandler = nil;
        if (task.running) [task terminate];

        if (waitResult != 0) {
            completion(nil, TBError(@"Codex took too long to respond."));
            return;
        }
        if (responseError != nil) {
            completion(nil, responseError);
            return;
        }

        NSError *parseError = nil;
        TBProviderSnapshot *snapshot = [TBUsageParser codexSnapshotFromResult:rateResult
                                                                       error:&parseError];
        completion(snapshot, parseError);
    });
}

@end

@interface TBClaudeUsageService ()
@property(nonatomic) NSUserDefaults *defaults;
@property(nonatomic) dispatch_queue_t queue;
@end

@implementation TBClaudeUsageService

+ (void)disableAutomaticKeychainInteraction {
    // Legacy generic-password ACL dialogs are not reliably governed by LAContext alone.
    // Keep this deprecated macOS control until Security offers an equivalent for legacy items.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    SecKeychainSetUserInteractionAllowed(false);
#pragma clang diagnostic pop
}

- (OSStatus)setKeychainInteractionAllowed:(BOOL)allowed {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return SecKeychainSetUserInteractionAllowed(allowed);
#pragma clang diagnostic pop
}

- (OSStatus)copyKeychainItemMatching:(NSDictionary *)query result:(CFTypeRef *)result {
    return SecItemCopyMatching((__bridge CFDictionaryRef)query, result);
}

- (instancetype)init {
    return [self initWithDefaults:NSUserDefaults.standardUserDefaults];
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    if ((self = [super init])) {
        _defaults = defaults;
        _queue = dispatch_queue_create("com.prajwalak.tokenbar.claude", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (NSDate *)now { return NSDate.date; }

- (NSDate *)nextRequestAt {
    id date = [self.defaults objectForKey:TBClaudeNextRequestAtKey];
    return [date isKindOfClass:NSDate.class] ? date : nil;
}

- (NSDictionary *)readCredentialAllowingInteraction:(BOOL)allowInteraction error:(NSError **)error {
    LAContext *context = [LAContext new];
    context.interactionNotAllowed = !allowInteraction;
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"Claude Code-credentials",
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
        (__bridge id)kSecUseAuthenticationContext: context,
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        // Required in addition to LAContext for macOS legacy Keychain ACL prompts.
        (__bridge id)kSecUseAuthenticationUI: allowInteraction
            ? (__bridge id)kSecUseAuthenticationUIAllow : (__bridge id)kSecUseAuthenticationUIFail,
#pragma clang diagnostic pop
    };
    static NSLock *interactionLock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ interactionLock = [NSLock new]; });
    CFTypeRef result = NULL;
    OSStatus status;
    // Serialize the process-wide switch across all service instances. Only the explicit
    // Authorize action may enable dialogs, and always restore the no-dialog default.
    [interactionLock lock];
    @try {
        status = [self setKeychainInteractionAllowed:allowInteraction];
        if (status == errSecSuccess) status = [self copyKeychainItemMatching:query result:&result];
    } @finally {
        [self setKeychainInteractionAllowed:NO];
        [interactionLock unlock];
    }
    NSData *data = CFBridgingRelease(result);
    if (status != errSecSuccess) {
        if (error) *error = status == errSecItemNotFound
            ? TBClaudeError(TBClaudeErrorSignInRequired, @"Claude Code has no saved sign-in. Connect Claude to continue.")
            : TBClaudeError(TBClaudeErrorKeychainAccess,
                @"Claude Keychain access is unavailable. Authorize access when ready; automatic checks will stay silent.");
        return nil;
    }
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([root isKindOfClass:NSDictionary.class]) {
        for (NSString *key in root) {
            NSString *normalized = [[[key lowercaseString] stringByReplacingOccurrencesOfString:@"_" withString:@""]
                                    stringByReplacingOccurrencesOfString:@"-" withString:@""];
            id oauth = root[key];
            if ([normalized isEqualToString:@"claudeaioauth"] && [oauth isKindOfClass:NSDictionary.class] &&
                [oauth[@"accessToken"] isKindOfClass:NSString.class] && [oauth[@"accessToken"] length] > 0) {
                return oauth;
            }
        }
    }
    if (error) *error = TBClaudeError(TBClaudeErrorSignInRequired, @"Claude Code has no saved subscription credential.");
    return nil;
}

- (NSDictionary *)requestUsageWithToken:(NSString *)token {
    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:@"https://api.anthropic.com/api/oauth/usage"]
           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"oauth-2025-04-20" forHTTPHeaderField:@"anthropic-beta"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.URLCache = nil;
    configuration.HTTPCookieStorage = nil;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSDictionary *result = nil;
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            result = @{@"data": data ?: NSData.data, @"response": response ?: NSNull.null,
                       @"error": error ?: NSNull.null};
            dispatch_semaphore_signal(semaphore);
        }];
    [task resume];
    if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_SEC)) != 0) {
        [session invalidateAndCancel];
        return @{@"error": TBError(@"Claude usage request timed out.")};
    }
    [session finishTasksAndInvalidate];
    return result;
}

- (void)fetchWithCompletion:(TBUsageCompletion)completion {
    [self fetchWithUserInitiated:NO completion:completion];
}

- (void)finishWithCache:(TBProviderSnapshot *)cache error:(NSError *)error completion:(TBUsageCompletion)completion {
    NSDate *next = [self.defaults objectForKey:TBClaudeNextRequestAtKey];
    if (!cache && error && [next isKindOfClass:NSDate.class] && [next compare:[self now]] == NSOrderedDescending) {
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.timeStyle = NSDateFormatterShortStyle;
        error = [NSError errorWithDomain:error.domain code:error.code userInfo:@{NSLocalizedDescriptionKey:
            [error.localizedDescription stringByAppendingFormat:@" Next check %@.", [formatter stringFromDate:next]]}];
    }
    cache.statusMessage = error.localizedDescription;
    cache.nextRefreshAt = [next isKindOfClass:NSDate.class] ? next : nil;
    // Return both: the old measurement remains useful, but must not hide why it is stale.
    completion(cache, error);
}

- (void)fetchWithUserInitiated:(BOOL)userInitiated completion:(TBUsageCompletion)completion {
    dispatch_async(self.queue, ^{
        NSUserDefaults *defaults = self.defaults;
        NSDate *now = [self now];
        TBProviderSnapshot *cache = TBCachedClaudeSnapshot(defaults);
        NSDate *next = [defaults objectForKey:TBClaudeNextRequestAtKey];
        if ([next isKindOfClass:NSDate.class] && [next compare:now] == NSOrderedDescending) {
            NSString *issue = [defaults stringForKey:TBClaudeIssueKey];
            [self finishWithCache:cache error:issue ? TBClaudeError([defaults integerForKey:TBClaudeIssueCodeKey], issue) : nil completion:completion];
            return;
        }
        // Throttle every attempt, including offline, unreadable credentials and malformed responses.
        [defaults setObject:[now dateByAddingTimeInterval:TBClaudeMinimumRequestInterval]
                     forKey:TBClaudeNextRequestAtKey];
        NSError *credentialError = nil;
        NSDictionary *oauth = [self readCredentialAllowingInteraction:NO error:&credentialError];
        NSNumber *expiresAt = oauth[@"expiresAt"];
        BOOL expired = [expiresAt respondsToSelector:@selector(doubleValue)] &&
            expiresAt.doubleValue / 1000.0 <= now.timeIntervalSince1970 + 60;
        // Ordinary Refresh must not launch Claude Code: the CLI owns its own Keychain
        // behavior and can raise password dialogs outside this process's no-UI controls.
        if (!oauth || expired) {
            NSError *error = !oauth ? credentialError : TBClaudeError(TBClaudeErrorExpired,
                @"Claude session expired. Open Claude Code to renew it, then click Refresh.");
            // A manual action can retry credentials immediately without making an API request.
            [defaults removeObjectForKey:TBClaudeNextRequestAtKey];
            [self finishWithCache:cache error:error completion:completion];
            return;
        }
        NSDictionary *result = [self requestUsageWithToken:oauth[@"accessToken"]];
        NSError *error = [result[@"error"] isKindOfClass:NSError.class] ? result[@"error"] : nil;
        NSHTTPURLResponse *response = [result[@"response"] isKindOfClass:NSHTTPURLResponse.class] ? result[@"response"] : nil;
        if (!error && response.statusCode == 429) {
            NSInteger count = MIN([defaults integerForKey:TBClaudeRateLimitCountKey] + 1, 10);
            NSTimeInterval delay = MAX(MIN(TBClaudeInitialRateLimitBackoff * pow(2, count - 1),
                                          TBClaudeMaximumRateLimitBackoff), TBRetryAfterSeconds(response, [self now]));
            [defaults setInteger:count forKey:TBClaudeRateLimitCountKey];
            [defaults setObject:[[self now] dateByAddingTimeInterval:delay] forKey:TBClaudeNextRequestAtKey];
            error = TBError(@"Anthropic is rate limiting usage checks. Automatic retry is scheduled.");
        } else if (!error && response.statusCode == 401) {
            error = TBClaudeError(TBClaudeErrorExpired,
                @"Claude rejected this session. Open Claude Code to renew it, then click Refresh.");
        } else if (!error && response.statusCode == 403) {
            error = TBError(@"Claude denied usage access (HTTP 403). Check your account permissions on the Claude usage page.");
        } else if (!error && (!response || response.statusCode < 200 || response.statusCode >= 300)) {
            error = TBError([NSString stringWithFormat:@"Claude usage returned HTTP %ld.", response.statusCode]);
        }
        TBProviderSnapshot *snapshot = nil;
        if (!error) {
            id payload = [NSJSONSerialization JSONObjectWithData:result[@"data"] ?: NSData.data options:0 error:&error];
            if ([payload isKindOfClass:NSDictionary.class]) {
                snapshot = [TBUsageParser claudeSnapshotFromResponse:payload error:&error];
                if (snapshot) {
                    snapshot.fetchedAt = [self now];
                    snapshot.plan = [TBUsageParser claudePlanFromCredential:oauth];
                    if (snapshot.plan) [defaults setObject:snapshot.plan forKey:TBClaudeCachedPlanKey];
                    else [defaults removeObjectForKey:TBClaudeCachedPlanKey];
                    [defaults setObject:[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil]
                                 forKey:TBClaudeCachedPayloadKey];
                    [defaults setObject:snapshot.fetchedAt forKey:TBClaudeCachedAtKey];
                    [defaults removeObjectForKey:TBClaudeRateLimitCountKey];
                    [defaults removeObjectForKey:TBClaudeIssueKey];
                    [defaults removeObjectForKey:TBClaudeIssueCodeKey];
                }
            } else if (!error) {
                error = TBError(@"Claude returned an unreadable response.");
            }
        }
        if (error) {
            [defaults setObject:error.localizedDescription forKey:TBClaudeIssueKey];
            [defaults setInteger:error.code forKey:TBClaudeIssueCodeKey];
        }
        [self finishWithCache:snapshot ?: cache error:error completion:completion];
    });
}

- (void)authorizeWithCompletion:(TBActionCompletion)completion {
    dispatch_async(self.queue, ^{
        NSError *error = nil;
        if ([self readCredentialAllowingInteraction:YES error:&error]) {
            [self.defaults removeObjectForKey:TBClaudeNextRequestAtKey];
            [self.defaults removeObjectForKey:TBClaudeIssueKey];
        }
        completion(error);
    });
}

- (void)connectWithCompletion:(TBActionCompletion)completion {
    dispatch_async(self.queue, ^{
        NSString *claude = TBExecutable(@"claude");
        if (!claude) { completion(TBError(@"Could not find Claude Code on this Mac.")); return; }
        // Only the explicit Connect action starts a browser sign-in.
        NSDictionary *result = TBRunTask(claude, @[@"auth", @"login", @"--claudeai"]);
        if ([result[@"status"] intValue] != 0) {
            completion(TBError(@"Claude sign-in did not finish. Try signing in from Claude Code."));
            return;
        }
        for (NSString *key in @[TBClaudeCachedPayloadKey, TBClaudeCachedAtKey, TBClaudeCachedPlanKey, TBClaudeNextRequestAtKey,
                                TBClaudeRateLimitCountKey, TBClaudeIssueKey, TBClaudeIssueCodeKey]) {
            [self.defaults removeObjectForKey:key];
        }
        completion(nil);
    });
}

@end
