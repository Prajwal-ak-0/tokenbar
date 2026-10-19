#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TBUsageWindow : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *title;
@property(nonatomic) double usedPercent;
@property(nonatomic, nullable) NSDate *resetsAt;
@end

@interface TBProviderSnapshot : NSObject
@property(nonatomic, copy) NSString *provider;
@property(nonatomic, nullable, copy) NSString *plan;
@property(nonatomic, copy) NSArray<TBUsageWindow *> *windows;
@property(nonatomic) NSDate *fetchedAt;
@property(nonatomic, nullable, copy) NSString *statusMessage;
@property(nonatomic, nullable) NSDate *nextRefreshAt;
@end

@interface TBUsageParser : NSObject
+ (nullable NSString *)claudePlanFromCredential:(NSDictionary *)credential;
+ (nullable TBProviderSnapshot *)codexSnapshotFromResult:(NSDictionary *)result
                                                   error:(NSError **)error;
+ (nullable TBProviderSnapshot *)claudeSnapshotFromResponse:(NSDictionary *)response
                                                       error:(NSError **)error;
@end

@interface TBRefreshPolicy : NSObject
+ (NSTimeInterval)intervalAt:(NSDate *)now lastInteraction:(nullable NSDate *)lastInteraction constrained:(BOOL)constrained;
+ (NSDate *)nextRefreshAt:(NSDate *)now snapshot:(nullable TBProviderSnapshot *)snapshot
             lastAttempt:(nullable NSDate *)lastAttempt lastInteraction:(nullable NSDate *)lastInteraction
             constrained:(BOOL)constrained earliestRequest:(nullable NSDate *)earliestRequest retrying:(BOOL)retrying;
@end

extern NSString *const TBUsageErrorDomain;

NS_ASSUME_NONNULL_END
