#import <Foundation/Foundation.h>
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
@property(nonatomic, readonly, nullable) NSDate *nextRequestAt;
- (void)fetchWithCompletion:(TBUsageCompletion)completion;
- (void)fetchWithUserInitiated:(BOOL)userInitiated completion:(TBUsageCompletion)completion;
- (void)authorizeWithCompletion:(TBActionCompletion)completion;

// Dependency seams keep regression tests away from real credentials and provider requests.
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
- (NSDate *)now;
- (nullable NSDictionary *)readCredentialAllowingInteraction:(BOOL)allowInteraction error:(NSError **)error;
- (void)renewClaudeSession;
- (NSDictionary *)requestUsageWithToken:(NSString *)token;
- (void)connectWithCompletion:(TBActionCompletion)completion;
@end

NS_ASSUME_NONNULL_END
