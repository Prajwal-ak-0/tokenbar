#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "TBUsageModels.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^TBUsageCompletion)(TBProviderSnapshot *_Nullable snapshot,
                                  NSError *_Nullable error);
typedef void (^TBActionCompletion)(NSError *_Nullable error);

@interface TBCodexUsageService : NSObject
- (void)fetchWithCompletion:(TBUsageCompletion)completion;
@end

typedef NS_ENUM(NSInteger, TBClaudeErrorCode) {
    TBClaudeErrorUnavailable = 1,
    TBClaudeErrorSignInRequired,
    TBClaudeErrorKeychainAccess,
    TBClaudeErrorExpired,
};

@interface TBClaudeUsageService : NSObject
+ (void)disableAutomaticKeychainInteraction;
@property(nonatomic, readonly, nullable) NSDate *nextRequestAt;
- (void)fetchWithCompletion:(TBUsageCompletion)completion;
- (void)fetchWithUserInitiated:(BOOL)userInitiated completion:(TBUsageCompletion)completion;
- (void)authorizeWithCompletion:(TBActionCompletion)completion;

// Dependency seams keep regression tests away from real credentials and provider requests.
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
- (NSDate *)now;
- (nullable NSDictionary *)readCredentialAllowingInteraction:(BOOL)allowInteraction error:(NSError **)error;
- (OSStatus)copyKeychainItemMatching:(NSDictionary *)query result:(CFTypeRef _Nullable *_Nullable)result;
- (OSStatus)setKeychainInteractionAllowed:(BOOL)allowed;
- (NSDictionary *)requestUsageWithToken:(NSString *)token;
- (nullable NSString *)usageCLIPath;
- (NSDictionary *)requestUsageWithCLIAtPath:(NSString *)path;
+ (nullable NSDictionary *)claudePayloadFromCLIData:(NSData *)data error:(NSError **)error;
- (void)connectWithCompletion:(TBActionCompletion)completion;
@end

NS_ASSUME_NONNULL_END
