#import "MixerObjCBridge.h"
#import <objc/message.h>

static NSError *MXBExceptionError(NSException *exception) {
    NSString *reason = exception.reason ?: exception.name;
    return [NSError errorWithDomain:@"com.codex.mixer.objc-exception"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: reason}];
}

AVAudioEngine *MXBCreateEngine(NSError **error) {
    @try {
        return [[AVAudioEngine alloc] init];
    } @catch (NSException *exception) {
        if (error) *error = MXBExceptionError(exception);
        return nil;
    }
}

AVAudioOutputNode *MXBOutputNode(AVAudioEngine *engine, NSError **error) {
    @try {
        return engine.outputNode;
    } @catch (NSException *exception) {
        if (error) *error = MXBExceptionError(exception);
        return nil;
    }
}

AVAudioNode *MXBMainMixerNode(AVAudioEngine *engine, NSError **error) {
    @try {
        return engine.mainMixerNode;
    } @catch (NSException *exception) {
        if (error) *error = MXBExceptionError(exception);
        return nil;
    }
}

AudioUnit MXBOutputAudioUnit(AVAudioOutputNode *node, NSError **error) {
    @try {
        return node.audioUnit;
    } @catch (NSException *exception) {
        if (error) *error = MXBExceptionError(exception);
        return NULL;
    }
}

AVAudioSourceNode *MXBCreateSourceNode(AVAudioFormat *format, AVAudioSourceNodeRenderBlock renderBlock, NSError **error) {
    @try {
        return [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:renderBlock];
    } @catch (NSException *exception) {
        if (error) *error = MXBExceptionError(exception);
        return nil;
    }
}

BOOL MXBAttachNode(AVAudioEngine *engine, AVAudioNode *node, NSError **error) {
    @try {
        [engine attachNode:node];
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = MXBExceptionError(exception);
        return NO;
    }
}

BOOL MXBConnectNode(AVAudioEngine *engine, AVAudioNode *source, AVAudioNode *target, AVAudioFormat *format, NSError **error) {
    @try {
        if (@available(macOS 27.0, *)) {
            NSError *connectionError = nil;
            BOOL connected = [engine connect:source to:target format:format error:&connectionError];
            if (!connected && error) *error = connectionError;
            return connected;
        }
        [engine connect:source to:target format:format];
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = MXBExceptionError(exception);
        return NO;
    }
}

AVAudioFormat *MXBNodeOutputFormat(AVAudioNode *node, AVAudioNodeBus bus, NSError **error) {
    @try {
        return [node outputFormatForBus:bus];
    } @catch (NSException *exception) {
        if (error) *error = MXBExceptionError(exception);
        return nil;
    }
}

BOOL MXBPrepareEngine(AVAudioEngine *engine, NSError **error) {
    @try {
        [engine prepare];
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = MXBExceptionError(exception);
        return NO;
    }
}

BOOL MXBStartEngine(AVAudioEngine *engine, NSError **error) {
    @try {
        NSError *startError = nil;
        BOOL started = [engine startAndReturnError:&startError];
        if (!started && error) *error = startError;
        return started;
    } @catch (NSException *exception) {
        if (error) *error = MXBExceptionError(exception);
        return NO;
    }
}

BOOL MXBStopEngine(AVAudioEngine *engine, NSError **error) {
    @try {
        [engine stop];
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = MXBExceptionError(exception);
        return NO;
    }
}

BOOL MXBResetEngine(AVAudioEngine *engine, NSError **error) {
    @try {
        [engine reset];
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = MXBExceptionError(exception);
        return NO;
    }
}

BOOL MXBTestExceptionCatcher(BOOL shouldThrow, NSError **error) {
    @try {
        if (shouldThrow) {
            @throw [NSException exceptionWithName:@"MixerBridgeTest" reason:@"synthetic exception" userInfo:nil];
        }
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = MXBExceptionError(exception);
        return NO;
    }
}

static id MXBMediaRemoteCallObject(id receiver, const char *selectorName) {
    if (!receiver) return nil;
    SEL selector = sel_registerName(selectorName);
    if (![receiver respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

NSDictionary *MXBReadMediaRemoteNowPlaying(void) {
    NSMutableDictionary *result = [@{
        @"frameworkLoaded": @NO,
        @"classAvailable": @NO,
        @"playerPathAvailable": @NO,
        @"clientAvailable": @NO,
        @"bundleIdentifier": [NSNull null],
        @"title": [NSNull null],
        @"rate": [NSNull null],
        @"status": @"not-started",
        @"exception": @""
    } mutableCopy];

    @try {
        NSBundle *framework = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/MediaRemote.framework"];
        BOOL loaded = framework && [framework load];
        result[@"frameworkLoaded"] = @(loaded);
        if (!loaded) {
            result[@"status"] = @"framework-unavailable";
            return result;
        }

        Class requestClass = NSClassFromString(@"MRNowPlayingRequest");
        result[@"classAvailable"] = @(requestClass != Nil);
        if (!requestClass) {
            result[@"status"] = @"request-class-unavailable";
            return result;
        }

        id playerPath = MXBMediaRemoteCallObject((id)requestClass, "localNowPlayingPlayerPath");
        result[@"playerPathAvailable"] = @(playerPath != nil);
        if (!playerPath) {
            result[@"status"] = @"player-path-unavailable";
            return result;
        }

        id client = MXBMediaRemoteCallObject(playerPath, "client");
        result[@"clientAvailable"] = @(client != nil);
        if (!client) {
            result[@"status"] = @"client-unavailable";
            return result;
        }

        id bundleIdentifier = MXBMediaRemoteCallObject(client, "bundleIdentifier");
        if ([bundleIdentifier isKindOfClass:[NSString class]]) {
            result[@"bundleIdentifier"] = bundleIdentifier;
        }
        if (![bundleIdentifier isKindOfClass:[NSString class]] || [bundleIdentifier length] == 0) {
            result[@"status"] = @"client-bundle-unavailable";
            return result;
        }

        id item = MXBMediaRemoteCallObject((id)requestClass, "localNowPlayingItem");
        id nowPlayingInfo = MXBMediaRemoteCallObject(item, "nowPlayingInfo");
        if (![nowPlayingInfo isKindOfClass:[NSDictionary class]]) {
            result[@"status"] = item ? @"media-info-unavailable" : @"media-item-unavailable";
            return result;
        }

        id currentPath = MXBMediaRemoteCallObject((id)requestClass, "localNowPlayingPlayerPath");
        id currentClient = MXBMediaRemoteCallObject(currentPath, "client");
        id currentBundleIdentifier = MXBMediaRemoteCallObject(currentClient, "bundleIdentifier");
        if (![currentBundleIdentifier isEqual:bundleIdentifier]) {
            result[@"bundleIdentifier"] = [currentBundleIdentifier isKindOfClass:[NSString class]]
                ? currentBundleIdentifier
                : [NSNull null];
            result[@"status"] = @"client-changed";
            return result;
        }

        id title = nowPlayingInfo[@"kMRMediaRemoteNowPlayingInfoTitle"];
        if ([title isKindOfClass:[NSString class]] && [title length] > 0) {
            result[@"title"] = title;
            id artist = nowPlayingInfo[@"kMRMediaRemoteNowPlayingInfoArtist"];
            if ([artist isKindOfClass:[NSString class]]) result[@"artist"] = artist;
        }
        id rate = nowPlayingInfo[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
        if ([rate isKindOfClass:[NSNumber class]]) {
            result[@"rate"] = rate;
        }
        if (![result[@"title"] isKindOfClass:[NSString class]]) {
            result[@"status"] = @"media-title-unavailable";
        } else if (![rate isKindOfClass:[NSNumber class]]) {
            result[@"status"] = @"media-rate-unavailable";
        } else if ([rate doubleValue] <= 0.0) {
            result[@"status"] = @"media-paused";
        } else {
            result[@"status"] = @"media-now-playing";
        }
    } @catch (NSException *exception) {
        result[@"status"] = @"exception";
        result[@"exception"] = exception.name ?: @"NSException";
    }

    return result;
}

// Read-only requests scoped to the real Core Audio client, rather than the
// system's single most-recent player. No playback commands or registration.
@interface NSObject (MixerMediaReadOnly)
- (instancetype)initWithProcessIdentifier:(int)pid bundleIdentifier:(NSString *)bundle;
- (instancetype)initWithOrigin:(id)origin client:(id)client player:(id)player;
- (instancetype)initWithPlayerPath:(id)path;
- (void)requestNowPlayingInfoOnQueue:(dispatch_queue_t)queue completion:(void (^)(id info))completion;
@end

NSArray<NSDictionary *> *MXBReadMediaRemoteClients(NSArray<NSDictionary *> *clients) {
    NSMutableArray *records = [NSMutableArray array];
    @try {
        if (![[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/MediaRemote.framework"] load]) return records;
        Class clientClass = NSClassFromString(@"MRClient");
        Class pathClass = NSClassFromString(@"MRPlayerPath");
        Class requestClass = NSClassFromString(@"MRNowPlayingRequest");
        if (![clientClass instancesRespondToSelector:@selector(initWithProcessIdentifier:bundleIdentifier:)] ||
            ![pathClass instancesRespondToSelector:@selector(initWithOrigin:client:player:)] ||
            ![requestClass instancesRespondToSelector:@selector(initWithPlayerPath:)] ||
            ![requestClass instancesRespondToSelector:@selector(requestNowPlayingInfoOnQueue:completion:)]) return records;
        id origin = MXBMediaRemoteCallObject((id)NSClassFromString(@"MROrigin"), "localOrigin");
        id player = MXBMediaRemoteCallObject((id)NSClassFromString(@"MRPlayer"), "defaultPlayer");
        if (!origin || !player) return records;
        for (NSDictionary *target in [clients subarrayWithRange:NSMakeRange(0, MIN(clients.count, 8))]) {
            @try {
                NSString *bundle = target[@"bundleIdentifier"];
                NSNumber *pid = target[@"pid"];
                if (![bundle isKindOfClass:[NSString class]] || ![pid isKindOfClass:[NSNumber class]] || pid.intValue <= 0) continue;
                id client = [[clientClass alloc] initWithProcessIdentifier:pid.intValue bundleIdentifier:bundle];
                id path = [[pathClass alloc] initWithOrigin:origin client:client player:player];
                id request = [[requestClass alloc] initWithPlayerPath:path];
                dispatch_semaphore_t done = dispatch_semaphore_create(0);
                __block NSDictionary *info = nil;
                [request requestNowPlayingInfoOnQueue:dispatch_get_global_queue(QOS_CLASS_UTILITY, 0) completion:^(id value) {
                    if ([value isKindOfClass:[NSDictionary class]]) info = value;
                    dispatch_semaphore_signal(done);
                }];
                long timedOut = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC));
                // On timeout never read callback-owned state while it may still be changing.
                NSDictionary *response = timedOut ? nil : info;
                NSString *title = response[@"kMRMediaRemoteNowPlayingInfoTitle"];
                NSMutableDictionary *record = [target mutableCopy];
                record[@"status"] = timedOut ? @"timeout" : @"empty";
                NSNumber *rate = response[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
                BOOL paused = [rate isKindOfClass:[NSNumber class]] && rate.doubleValue <= 0;
                if (paused) record[@"status"] = @"paused";
                if ([title isKindOfClass:[NSString class]] && title.length > 0 && !paused) {
                    record[@"title"] = title;
                    id artist = response[@"kMRMediaRemoteNowPlayingInfoArtist"];
                    if ([artist isKindOfClass:[NSString class]]) record[@"artist"] = artist;
                    record[@"status"] = @"metadata";
                }
                [records addObject:record];
            } @catch (NSException *exception) {
                NSMutableDictionary *record = [target mutableCopy];
                record[@"status"] = @"exception";
                [records addObject:record];
            }
        }
    } @catch (NSException *exception) { }
    return records;
}
