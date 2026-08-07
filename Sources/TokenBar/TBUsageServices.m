#import "TBUsageServices.h"

static NSError *TBError(NSString *message) {
    return [NSError errorWithDomain:TBUsageErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *const TBClaudeCachedPayloadKey = @"claudeCachedUsagePayload";
static NSString *const TBClaudeCachedAtKey = @"claudeCachedUsageAt";
static NSString *const TBClaudeNextRequestAtKey = @"claudeNextRequestAt";
static NSString *const TBClaudeRateLimitCountKey = @"claudeRateLimitCount";
static const NSTimeInterval TBClaudeMinimumRequestInterval = 15 * 60;
static const NSTimeInterval TBClaudeInitialRateLimitBackoff = 60 * 60;
static const NSTimeInterval TBClaudeMaximumRateLimitBackoff = 6 * 60 * 60;

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
    return snapshot;
}

static NSTimeInterval TBRetryAfterSeconds(NSHTTPURLResponse *response) {
    for (id key in response.allHeaderFields) {
        if ([[key description] caseInsensitiveCompare:@"retry-after"] == NSOrderedSame) {
            return MAX([[response.allHeaderFields objectForKey:key] doubleValue], 0);
        }
    }
    return 0;
}

static NSString *TBExecutable(NSString *name) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray<NSString *> *candidates = @[
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
    task.standardOutput = output;
    task.standardError = error;
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        return @{ @"status": @(-1), @"errorObject": launchError };
    }
    [task waitUntilExit];
    return @{
        @"status": @(task.terminationStatus),
        @"output": [output.fileHandleForReading readDataToEndOfFile],
        @"error": [error.fileHandleForReading readDataToEndOfFile],
    };
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

@implementation TBClaudeUsageService

- (void)fetchWithCompletion:(TBUsageCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSDate *now = NSDate.date;
        TBProviderSnapshot *cachedSnapshot = TBCachedClaudeSnapshot(defaults);
        NSDate *cachedAt = [defaults objectForKey:TBClaudeCachedAtKey];
        NSDate *nextRequestAt = [defaults objectForKey:TBClaudeNextRequestAtKey];

        BOOL cacheIsFresh = cachedAt != nil &&
            [now timeIntervalSinceDate:cachedAt] < TBClaudeMinimumRequestInterval;
        BOOL requestIsBackedOff = [nextRequestAt isKindOfClass:NSDate.class] &&
            [nextRequestAt compare:now] == NSOrderedDescending;
        if (cachedSnapshot != nil && (cacheIsFresh || requestIsBackedOff)) {
            completion(cachedSnapshot, nil);
            return;
        }
        if (requestIsBackedOff) {
            completion(nil, TBError(@"Claude refresh is paused after rate limiting."));
            return;
        }

        NSString *claude = TBExecutable(@"claude");
        if (claude == nil) {
            completion(nil, TBError(@"Could not find Claude Code on this Mac."));
            return;
        }

        // Claude Code owns OAuth refresh and Keychain persistence. Asking it for auth status first
        // keeps TokenBar from using a stale access token without ever exposing that token in logs.
        NSDictionary *authStatus = TBRunTask(claude, @[@"auth", @"status", @"--json"]);
        NSDictionary *authPayload = [NSJSONSerialization
            JSONObjectWithData:authStatus[@"output"] ?: NSData.data
                       options:0
                         error:nil];
        if ([authStatus[@"status"] intValue] != 0 || ![authPayload[@"loggedIn"] boolValue]) {
            completion(nil, TBError(@"CONNECT_CLAUDE"));
            return;
        }

        NSDictionary *keychain = TBRunTask(
            @"/usr/bin/security",
            @[@"find-generic-password", @"-s", @"Claude Code-credentials", @"-w"]
        );
        NSData *credentialData = keychain[@"output"];
        if ([keychain[@"status"] intValue] != 0 || credentialData.length == 0) {
            completion(nil, TBError(@"CONNECT_CLAUDE"));
            return;
        }

        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:credentialData
                                                               options:0
                                                                 error:nil];
        NSDictionary *oauth = nil;
        for (NSString *key in root) {
            NSString *normalized = [[[key lowercaseString] stringByReplacingOccurrencesOfString:@"_"
                                                                                      withString:@""]
                                    stringByReplacingOccurrencesOfString:@"-" withString:@""];
            if ([normalized containsString:@"claudeaioauth"] && [root[key] isKindOfClass:NSDictionary.class]) {
                oauth = root[key];
                break;
            }
        }
        NSString *accessToken = oauth[@"accessToken"];
        if (![accessToken isKindOfClass:NSString.class] || accessToken.length == 0) {
            completion(nil, TBError(@"CONNECT_CLAUDE"));
            return;
        }

        NSMutableURLRequest *request = [NSMutableURLRequest
            requestWithURL:[NSURL URLWithString:@"https://api.anthropic.com/api/oauth/usage"]];
        request.HTTPMethod = @"GET";
        request.timeoutInterval = 15;
        [request setValue:[@"Bearer " stringByAppendingString:accessToken]
       forHTTPHeaderField:@"Authorization"];
        [request setValue:@"oauth-2025-04-20" forHTTPHeaderField:@"anthropic-beta"];
        [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        __block NSData *responseData = nil;
        __block NSHTTPURLResponse *httpResponse = nil;
        __block NSError *networkError = nil;
        NSURLSessionDataTask *dataTask = [NSURLSession.sharedSession
            dataTaskWithRequest:request
              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                  responseData = data;
                  httpResponse = (NSHTTPURLResponse *)response;
                  networkError = error;
                  dispatch_semaphore_signal(semaphore);
              }];
        [dataTask resume];
        long waitResult = dispatch_semaphore_wait(
            semaphore,
            dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_SEC)
        );

        if (waitResult != 0) {
            [dataTask cancel];
            if (cachedSnapshot != nil) {
                completion(cachedSnapshot, nil);
            } else {
                completion(nil, TBError(@"Claude usage request timed out."));
            }
            return;
        }

        if (networkError != nil) {
            completion(cachedSnapshot, cachedSnapshot != nil ? nil : networkError);
            return;
        }
        if (httpResponse.statusCode == 401 || httpResponse.statusCode == 403) {
            completion(nil, TBError(@"CONNECT_CLAUDE"));
            return;
        }
        if (httpResponse.statusCode == 429) {
            NSInteger rateLimitCount = [defaults integerForKey:TBClaudeRateLimitCountKey] + 1;
            double multiplier = 1 << MIN(rateLimitCount - 1, 3);
            NSTimeInterval localBackoff = MIN(TBClaudeInitialRateLimitBackoff * multiplier,
                                              TBClaudeMaximumRateLimitBackoff);
            NSTimeInterval delay = MAX(localBackoff, TBRetryAfterSeconds(httpResponse));
            [defaults setInteger:rateLimitCount forKey:TBClaudeRateLimitCountKey];
            [defaults setObject:[NSDate dateWithTimeIntervalSinceNow:delay]
                         forKey:TBClaudeNextRequestAtKey];
            completion(cachedSnapshot,
                       cachedSnapshot != nil ? nil : TBError(@"Claude refresh is paused after rate limiting."));
            return;
        }
        if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
            if (cachedSnapshot != nil) {
                completion(cachedSnapshot, nil);
                return;
            }
            completion(nil, TBError([NSString stringWithFormat:@"Claude usage returned HTTP %ld.",
                                                               httpResponse.statusCode]));
            return;
        }

        NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:responseData
                                                                   options:0
                                                                     error:&networkError];
        if (![payload isKindOfClass:NSDictionary.class]) {
            completion(nil, networkError ?: TBError(@"Claude returned an unreadable response."));
            return;
        }
        NSError *parseError = nil;
        TBProviderSnapshot *snapshot = [TBUsageParser claudeSnapshotFromResponse:payload
                                                                           error:&parseError];
        if (snapshot != nil) {
            NSData *cacheData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
            if (cacheData != nil) {
                [defaults setObject:cacheData forKey:TBClaudeCachedPayloadKey];
            }
            [defaults setObject:snapshot.fetchedAt forKey:TBClaudeCachedAtKey];
            [defaults removeObjectForKey:TBClaudeNextRequestAtKey];
            [defaults removeObjectForKey:TBClaudeRateLimitCountKey];
        }
        completion(snapshot, parseError);
    });
}

- (void)connectWithCompletion:(TBActionCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *claude = TBExecutable(@"claude");
        if (claude == nil) {
            completion(TBError(@"Could not find Claude Code on this Mac."));
            return;
        }
        NSDictionary *result = TBRunTask(claude, @[@"auth", @"login", @"--claudeai"]);
        if ([result[@"status"] intValue] == 0) {
            completion(nil);
            return;
        }
        NSData *errorData = result[@"error"];
        NSString *message = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
        completion(TBError(message.length > 0 ? message : @"Claude sign-in did not finish."));
    });
}

@end
