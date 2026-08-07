#import <Foundation/Foundation.h>
#import "TBUsageModels.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^TBUsageCompletion)(TBProviderSnapshot *_Nullable snapshot,
                                  NSError *_Nullable error);
typedef void (^TBActionCompletion)(NSError *_Nullable error);

@interface TBCodexUsageService : NSObject
- (void)fetchWithCompletion:(TBUsageCompletion)completion;
@end

@interface TBClaudeUsageService : NSObject
- (void)fetchWithCompletion:(TBUsageCompletion)completion;
- (void)connectWithCompletion:(TBActionCompletion)completion;
@end

NS_ASSUME_NONNULL_END
