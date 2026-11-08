#import "CatchObjC.h"

BOOL SLTryObjC(NS_NOESCAPE void (^block)(void), NSError * _Nullable * _Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: exception.name;
            *error = [NSError errorWithDomain:@"SpeaklessObjC" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: reason, @"exceptionName": exception.name}];
        }
        return NO;
    }
}
