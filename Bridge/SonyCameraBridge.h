#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const SonyCameraBridgeStateDidChangeNotification;
extern NSString * const SonyCameraBridgeLogNotification;

@interface SonyCameraBridge : NSObject
- (void)connectHost:(NSString *)host
           username:(NSString *)username
           password:(NSString *)password
 trustedFingerprint:(NSString *)trustedFingerprint
         completion:(void (^)(BOOL connected, BOOL needsTrust, NSString *message, NSString *fingerprint))completion;
- (void)disconnect;
- (void)refresh:(void (^)(BOOL ok, NSString *message))completion;
- (void)setProperty:(uint16_t)property value:(int64_t)value completion:(void (^)(BOOL ok, NSString *message))completion;
- (void)control:(uint16_t)control value:(int64_t)value completion:(void (^)(BOOL ok, NSString *message))completion;
- (void)remoteTouchX:(uint16_t)x y:(uint16_t)y completion:(void (^)(BOOL ok, NSString *message))completion;
- (void)cancelRemoteTouch:(void (^)(BOOL ok, NSString *message))completion;
- (void)setRecording:(BOOL)recording completion:(void (^)(BOOL ok, NSString *message))completion;
- (void)requestLiveViewFrame:(void (^)(NSData * _Nullable jpegData, NSString *message))completion;
- (NSDictionary<NSNumber *, NSDictionary *> *)stateSnapshot;
@end

NS_ASSUME_NONNULL_END
