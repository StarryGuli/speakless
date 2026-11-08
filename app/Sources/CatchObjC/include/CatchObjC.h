#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 在 block 里执行「可能抛 Objective-C 异常」的调用（AVFoundation 的 installTap 等经常这样）。
/// Swift 接不住 Objective-C 异常，一抛出来整个程序就崩了（SIGABRT）。
/// 用这个包一层：抛了就返回 NO 并带出原因，由调用方当成普通错误处理。
BOOL SLTryObjC(NS_NOESCAPE void (^block)(void), NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
