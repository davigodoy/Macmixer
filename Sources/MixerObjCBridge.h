#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

AVAudioEngine * _Nullable MXBCreateEngine(NSError * _Nullable * _Nullable error);
AVAudioOutputNode * _Nullable MXBOutputNode(AVAudioEngine *engine, NSError * _Nullable * _Nullable error);
AVAudioNode * _Nullable MXBMainMixerNode(AVAudioEngine *engine, NSError * _Nullable * _Nullable error);
AudioUnit _Nullable MXBOutputAudioUnit(AVAudioOutputNode *node, NSError * _Nullable * _Nullable error);
AVAudioSourceNode * _Nullable MXBCreateSourceNode(AVAudioFormat *format, AVAudioSourceNodeRenderBlock renderBlock, NSError * _Nullable * _Nullable error);
BOOL MXBAttachNode(AVAudioEngine *engine, AVAudioNode *node, NSError * _Nullable * _Nullable error);
BOOL MXBConnectNode(AVAudioEngine *engine, AVAudioNode *source, AVAudioNode *target, AVAudioFormat * _Nullable format, NSError * _Nullable * _Nullable error);
AVAudioFormat * _Nullable MXBNodeOutputFormat(AVAudioNode *node, AVAudioNodeBus bus, NSError * _Nullable * _Nullable error);
BOOL MXBPrepareEngine(AVAudioEngine *engine, NSError * _Nullable * _Nullable error);
BOOL MXBStartEngine(AVAudioEngine *engine, NSError * _Nullable * _Nullable error);
BOOL MXBStopEngine(AVAudioEngine *engine, NSError * _Nullable * _Nullable error);
BOOL MXBResetEngine(AVAudioEngine *engine, NSError * _Nullable * _Nullable error);
BOOL MXBTestExceptionCatcher(BOOL shouldThrow, NSError * _Nullable * _Nullable error);
NSDictionary *MXBReadMediaRemoteNowPlaying(void);
NSArray<NSDictionary *> *MXBReadMediaRemoteClients(NSArray<NSDictionary *> *clients);

NS_ASSUME_NONNULL_END
