//
//  WebSocket.h
//  Zimt
//
//  Created by Esad Hajdarevic on 2/14/10.
//  Copyright 2010 OpenResearch Software Development OG. All rights reserved.
//

#import <Foundation/Foundation.h>

@class AsyncSocket;
@class WebSocket;

@protocol WebSocketDelegate<NSObject>
@optional 
    - (void)webSocket:(WebSocket*)webSocket didFailWithError:(NSError*)error;
    - (void)webSocketDidOpen:(WebSocket*)webSocket;
    - (void)webSocketDidClose:(WebSocket*)webSocket;
    - (void)webSocket:(WebSocket*)webSocket didReceiveMessage:(NSString*)message;
    - (void)webSocketDidSendMessage:(WebSocket*)webSocket;
@end

@interface WebSocket : NSObject {
    id<WebSocketDelegate> __unsafe_unretained delegate;
    NSURL* url;
    AsyncSocket* socket;
    BOOL connected;
    NSString* origin;
    
    NSArray* runLoopModes;
    NSString* cookie;

    u_char key3[8];
    NSData* expectedChallenge;
    BOOL handShakeHeaderReceived;
    NSInteger _timeout;
}

@property(nonatomic,unsafe_unretained) id<WebSocketDelegate> delegate;
@property(nonatomic,readonly) NSURL* url;
@property(nonatomic) NSString* origin;
@property(nonatomic,readonly) BOOL connected;
@property(nonatomic) NSArray* runLoopModes;
@property(nonatomic) NSString* cookie;
@property(nonatomic,assign) NSInteger timeout;

+ (id)webSocketWithURLString:(NSString*)urlString delegate:(id<WebSocketDelegate>)delegate;
- (id)initWithURLString:(NSString*)urlString delegate:(id<WebSocketDelegate>)delegate;

- (void)open;
- (void)close;
- (void)send:(NSString*)message;

@end

enum {
    WebSocketErrorConnectionFailed = 1,
    WebSocketErrorHandshakeFailed = 2
};

extern NSString *const WebSocketException;
extern NSString* const WebSocketErrorDomain;
