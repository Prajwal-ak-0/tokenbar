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
@end

@interface TBUsageParser : NSObject
+ (nullable TBProviderSnapshot *)codexSnapshotFromResult:(NSDictionary *)result
                                                   error:(NSError **)error;
+ (nullable TBProviderSnapshot *)claudeSnapshotFromResponse:(NSDictionary *)response
                                                       error:(NSError **)error;
@end

extern NSString *const TBUsageErrorDomain;

NS_ASSUME_NONNULL_END
