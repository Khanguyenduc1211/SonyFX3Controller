#import "SonyCameraBridge.h"
#import <UIKit/UIKit.h>

#include "SonyPtpIp.hpp"

NSString * const SonyCameraBridgeStateDidChangeNotification = @"SonyCameraBridgeStateDidChange";
NSString * const SonyCameraBridgeLogNotification = @"SonyCameraBridgeLog";

@implementation SonyCameraBridge {
    std::unique_ptr<sony::SonyPtpIp> _camera;
    dispatch_queue_t _queue;
    NSMutableDictionary<NSNumber *, NSDictionary *> *_snapshot;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("sony.camera.command.queue", DISPATCH_QUEUE_SERIAL);
        _snapshot = [NSMutableDictionary dictionary];
        _camera = std::make_unique<sony::SonyPtpIp>();
        _camera->setClientGuid(UIDevice.currentDevice.identifierForVendor.UUIDString.UTF8String);
        __weak typeof(self) weakSelf = self;
        _camera->setStateCallback([weakSelf](const sony::CameraState &state) {
            typeof(self) self = weakSelf; if (!self) return;
            dispatch_async(dispatch_get_main_queue(), ^{ [self publishState:state]; });
        });
        _camera->setEventCallback([weakSelf](const std::string &message) {
            dispatch_async(dispatch_get_main_queue(), ^{ [[NSNotificationCenter defaultCenter] postNotificationName:SonyCameraBridgeLogNotification object:weakSelf userInfo:@{ @"message": @(message.c_str()) }]; });
        });
    }
    return self;
}

- (void)publishState:(const sony::CameraState&)state {
    [_snapshot removeAllObjects];
    for (const auto &[code, property] : state.properties) {
        NSMutableArray *setValues = [NSMutableArray array];
        for (const auto &value : property.setValues) [setValues addObject:@(value.signedNumber())];
        NSMutableArray *getSetValues = [NSMutableArray array];
        for (const auto &value : property.getSetValues) [getSetValues addObject:@(value.signedNumber())];
        _snapshot[@(code)] = @{ @"type": @(property.type), @"current": @(property.current.signedNumber()), @"writable": @(property.writable), @"enabled": @(property.enabled), @"form": @(property.form), @"setValues": setValues, @"getSetValues": getSetValues };
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:SonyCameraBridgeStateDidChangeNotification object:self userInfo:@{ @"recordState": @((uint32_t)state.recordState), @"vendorVersion": @(state.vendorVersion) }];
}

- (void)connectHost:(NSString *)host username:(NSString *)username password:(NSString *)password trustedFingerprint:(NSString *)fingerprint completion:(void (^)(BOOL, BOOL, NSString *, NSString *))completion {
    dispatch_async(_queue, ^{
        auto result = self->_camera->connect(host.UTF8String, username.UTF8String, password.UTF8String, fingerprint.UTF8String);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result.ok, result.needsTrust, @(result.message.c_str()), @(result.fingerprint.c_str())); });
    });
}
- (void)disconnect { dispatch_async(_queue, ^{ self->_camera->disconnect(); }); }
- (void)refresh:(void (^)(BOOL, NSString *))completion { dispatch_async(_queue, ^{ std::string error; BOOL ok = self->_camera->refresh(error); dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, ok ? @"Camera state refreshed" : @(error.c_str())); }); }); }
- (void)setProperty:(uint16_t)property value:(int64_t)value completion:(void (^)(BOOL, NSString *))completion {
    dispatch_async(_queue, ^{
        auto snapshot = self->_camera->state().property(property); std::string error;
        BOOL ok = snapshot && self->_camera->setProperty(property, sony::Value::number(snapshot->type, value), error);
        if (!snapshot) error = "Property is not exposed by this camera mode";
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, ok ? @"Applied and verified" : @(error.c_str())); });
    });
}
- (void)control:(uint16_t)control value:(int64_t)value completion:(void (^)(BOOL, NSString *))completion { dispatch_async(_queue, ^{ std::string error; BOOL ok = self->_camera->control(control, sony::Value::number(sony::kDataInt16, value), error); dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, ok ? @"Control sent" : @(error.c_str())); }); }); }
- (void)setRecording:(BOOL)recording completion:(void (^)(BOOL, NSString *))completion { dispatch_async(_queue, ^{ std::string error; BOOL ok = recording ? self->_camera->startRecording(error) : self->_camera->stopRecording(error); dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, ok ? @"Recording state verified" : @(error.c_str())); }); }); }
- (NSDictionary<NSNumber *,NSDictionary *> *)stateSnapshot { return [_snapshot copy]; }
@end
