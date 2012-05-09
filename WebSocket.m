//
//  WebSocket.m
//  Zimt
//
//  Created by Esad Hajdarevic on 2/14/10.
//  Copyright 2010 OpenResearch Software Development OG. All rights reserved.
//

#import "WebSocket.h"
#import "AsyncSocket.h"
#import <CommonCrypto/CommonDigest.h>


NSString* const WebSocketErrorDomain = @"WebSocketErrorDomain";
NSString* const WebSocketException = @"WebSocketException";

enum {
    WebSocketTagHandshake = 0,
    WebSocketTagMessage = 1
};

// Private methods & properties
@interface WebSocket ()
    @property (nonatomic, strong) NSData* expectedChallenge;
    @property (nonatomic,assign) BOOL handShakeHeaderReceived;
    static NSString* _generateSecWebSocketKey(uint32_t* number);
    static void _generateKey3(u_char key3[8]);
    static void _setChallengeNumber(unsigned char* buf, uint32_t number);
    static NSData* _generateExpectedChallengeResponse(uint32_t number1, uint32_t number2, u_char key3[8]);
@end

// Implementation
@implementation WebSocket

static const NSString* randomCharacterInSecWebSocketKey = @"!\"#$%&'()*+,-./:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";

@synthesize delegate, url, origin, connected, runLoopModes;
@synthesize expectedChallenge, handShakeHeaderReceived; // needed for supporting draft-hixie-thewebsocketprotocol-76
@synthesize cookie;
@synthesize timeout = _timeout;

#pragma mark Initializers

+ (id)webSocketWithURLString:(NSString*)urlString delegate:(id<WebSocketDelegate>)aDelegate {
    return [[WebSocket alloc] initWithURLString:urlString delegate:aDelegate];
}

-(id)initWithURLString:(NSString *)urlString delegate:(id<WebSocketDelegate>)aDelegate {
    self = [super init];
    if (self) {
        self.delegate = aDelegate;
        url = [NSURL URLWithString:urlString];
        if (![url.scheme isEqualToString:@"ws"] && ![url.scheme isEqualToString:@"wss"]) {
            [NSException raise:WebSocketException format:@"Unsupported protocol %@", url.scheme];
        }
        socket = [[AsyncSocket alloc] initWithDelegate:self];
        self.runLoopModes = [NSArray arrayWithObjects:NSRunLoopCommonModes, nil]; 
        
        // defaults
        _timeout = 5;
    }
    return self;
}

#pragma mark Delegate dispatch methods

-(void)_dispatchFailure:(NSNumber*)code {
    if(delegate && [delegate respondsToSelector:@selector(webSocket:didFailWithError:)]) {
        [delegate webSocket:self didFailWithError:[NSError errorWithDomain:WebSocketErrorDomain code:[code intValue] userInfo:nil]];
    }
}

-(void)_dispatchClosed {
    if (delegate && [delegate respondsToSelector:@selector(webSocketDidClose:)]) {
        [delegate webSocketDidClose:self];
    }
}

-(void)_dispatchOpened {
    if (delegate && [delegate respondsToSelector:@selector(webSocketDidOpen:)]) {
        [delegate webSocketDidOpen:self];
    }
}

-(void)_dispatchMessageReceived:(NSString*)message {
    if (delegate && [delegate respondsToSelector:@selector(webSocket:didReceiveMessage:)]) {
        [delegate webSocket:self didReceiveMessage:message];
    }
}

-(void)_dispatchMessageSent {
    if (delegate && [delegate respondsToSelector:@selector(webSocketDidSendMessage:)]) {
        [delegate webSocketDidSendMessage:self];
    }
}

#pragma mark Private

-(void)_readNextMessage {
    [socket readDataToData:[NSData dataWithBytes:"\xFF" length:1] withTimeout:-1 tag:WebSocketTagMessage];
}

#pragma mark Public interface

-(void)close {
    [socket disconnectAfterReadingAndWriting];
}

-(void)open {
    if (!connected) {
        [socket connectToHost:url.host onPort:[url.port intValue] withTimeout:_timeout error:nil];
        if (runLoopModes) [socket setRunLoopModes:runLoopModes];
    }
}

-(void)send:(NSString*)message {
    NSMutableData* data = [NSMutableData data];
    [data appendBytes:"\x00" length:1];
    [data appendData:[message dataUsingEncoding:NSUTF8StringEncoding]];
    [data appendBytes:"\xFF" length:1];
    [socket writeData:data withTimeout:-1 tag:WebSocketTagMessage];
}

#pragma mark AsyncSocket delegate methods

-(void)onSocketDidDisconnect:(AsyncSocket *)sock {
    connected = NO;
}

-(void)onSocket:(AsyncSocket *)sock willDisconnectWithError:(NSError *)err {
    if (!connected) {
        [self _dispatchFailure:[NSNumber numberWithInt:WebSocketErrorConnectionFailed]];
    } else {
        [self _dispatchClosed];
    }
}

- (void)onSocket:(AsyncSocket *)sock didConnectToHost:(NSString *)host port:(UInt16)port {
    // Secure connection requested?
    if ([url.scheme isEqualToString:@"wss"]) {
        // Configure SSL/TLS settings
        NSMutableDictionary *TLSSettings = [NSMutableDictionary dictionaryWithCapacity:1];

        // Allow self-signed certificates (good enough for now...)
        [TLSSettings setObject:[NSNumber numberWithBool:YES]
                        forKey:(NSString *)kCFStreamSSLAllowsAnyRoot];

        [sock startTLS:TLSSettings];
    }

    NSString* requestOrigin = self.origin;
    if (!requestOrigin) requestOrigin = [NSString stringWithFormat:@"http://%@:%@",url.host, url.port];

    NSString* requestPath = url.path;
    if (url.query) {
        requestPath = [requestPath stringByAppendingFormat:@"?%@", url.query];
    }

    NSString* cookieHeader = @"";
    if (cookie && [cookie length] > 0)
        cookieHeader = [cookieHeader stringByAppendingFormat:@"Cookie: %@\r\n", cookie];

    uint32_t webSocketKeyNumber1, webSocketKeyNumber2;
    NSString *webSocketKey1 = _generateSecWebSocketKey(&webSocketKeyNumber1);
    NSString *webSocketKey2 = _generateSecWebSocketKey(&webSocketKeyNumber2);
    _generateKey3(key3);

    [self setExpectedChallenge:_generateExpectedChallengeResponse(webSocketKeyNumber1, webSocketKeyNumber2, key3)];

    NSString* getRequest = [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\n"
                            "Upgrade: WebSocket\r\n"
                            "Connection: Upgrade\r\n"
                            "Host: %@\r\n"
                            "Origin: %@\r\n"
                            "%@"
                            "Sec-WebSocket-Key1: %@\r\n"
                            "Sec-WebSocket-Key2: %@\r\n"
                            "\r\n",
                            requestPath, url.host, requestOrigin, cookieHeader, webSocketKey1,  webSocketKey2];

    NSMutableData *requestData = [NSMutableData dataWithData:[getRequest dataUsingEncoding:NSASCIIStringEncoding]];
    [requestData appendBytes:key3 length:sizeof(key3)];

    [socket writeData:requestData withTimeout:-1 tag:WebSocketTagHandshake];
}

-(void)onSocket:(AsyncSocket *)sock didWriteDataWithTag:(long)tag {
    if (tag == WebSocketTagHandshake) {
        [sock readDataToData:[@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding] withTimeout:-1 tag:WebSocketTagHandshake];
    } else if (tag == WebSocketTagMessage) {
        [self _dispatchMessageSent];
    }
}

-(void)onSocket:(AsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
    if (tag == WebSocketTagHandshake) {
        NSString* response = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
        
        if ([response hasPrefix:@"HTTP/1.1 101 WebSocket Protocol Handshake\r\nUpgrade: WebSocket\r\nConnection: Upgrade\r\n"]) {
            [self setHandShakeHeaderReceived:YES];
            [self _readNextMessage];
        } else {
            [self _dispatchFailure:[NSNumber numberWithInt:WebSocketErrorHandshakeFailed]];
        }
    } else if (tag == WebSocketTagMessage) {
        char firstByte = 0xFF;
        [data getBytes:&firstByte length:1];

        // This is where the actual handshake challenge validation (WebSockets rev. 76) happens...
        if (firstByte == 0x00) {
            NSString* message = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(1, [data length]-2)] encoding:NSUTF8StringEncoding];
            [self _dispatchMessageReceived:message];
        } else if ([self handShakeHeaderReceived] == YES && ([data length] > [expectedChallenge length])) {
            
 
            NSData *actualChallenge = [data subdataWithRange:NSMakeRange(0, [expectedChallenge length])];
            if ([expectedChallenge isEqualToData:actualChallenge]) { // got our challenge!
                connected = YES;
                [self _dispatchOpened];
                
                // fixme: why [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(1, [data length]-2)] encoding:NSUTF8StringEncoding] autorelease]; doesn't work?
                NSString* message = @"1::";
               [self _dispatchMessageReceived:message];
                
            } else {
                [self _dispatchFailure:[NSNumber numberWithInt:WebSocketErrorHandshakeFailed]];
            }
            [self setHandShakeHeaderReceived:NO];
        } else {
            return;
        }

        [self _readNextMessage];
    }
}

#pragma mark Private stuff

static NSString* _generateSecWebSocketKey(uint32_t* number) {
    srandomdev();
    uint32_t space = (random() % 12) + 1;
    uint32_t max = 4294967295U / space;
    *number = (random() % max);
    uint32_t product = (*number) * space;

    NSMutableString *s = [[NSMutableString alloc] initWithFormat:@"%u", product];
    int n = (random() % 12) + 1;

    for (int i = 0; i < n; i++) {
        int pos = (random() % [s length]);
        int chpos = (random() % [randomCharacterInSecWebSocketKey length]);

        NSRange randomCharsRange = NSMakeRange(chpos, 1);
        [s insertString:[randomCharacterInSecWebSocketKey substringWithRange:randomCharsRange] atIndex:pos];
    }

    NSString *spaceChar = @" ";
    for (uint32_t i = 0; i < space; i++) {
        int pos = (random() % ([s length] - 2)) + 1;
        [s insertString:spaceChar atIndex:pos];
    }

    assert(![s hasPrefix:spaceChar]);
    assert(![s hasSuffix:spaceChar]);

    return s;
}

static void _generateKey3(u_char key3[8]) {
    srandomdev();
    for (int i = 0; i < 8; i++)
        key3[i] = (u_char) random() % 256;
}

static void _setChallengeNumber(unsigned char* buf, uint32_t number) {
    unsigned char* p = buf + 3;
    for (int i = 0; i < 4; i++) {
        *p = number & 0xFF;
        --p;
        number >>= 8;
    }
}

static NSData* _generateExpectedChallengeResponse(uint32_t number1, uint32_t number2, u_char key3[8]) {
    u_char theExpectedChallenge[CC_MD5_DIGEST_LENGTH];
    u_char challenge[16];
    _setChallengeNumber(&challenge[0], number1);
    _setChallengeNumber(&challenge[4], number2);
    memcpy(&challenge[8], key3, 8);

    // Calculate MD5 hash from challenge data
    CC_MD5(challenge, 16, theExpectedChallenge);

    NSData *expectedChallengeData = [[NSData alloc] initWithBytes:theExpectedChallenge length:CC_MD5_DIGEST_LENGTH];
    return expectedChallengeData;
}

#pragma mark Destructor

-(void)dealloc {
    socket.delegate = nil;
    [socket disconnect];
}

@end

