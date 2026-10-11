// Unit driver for the Now Playing helper, run by Scripts/test-helper.sh.
//
// The helper is one Objective-C file loaded into /usr/bin/perl, and the only
// check it had was the live one: load the built dylib, send `get`, read a line.
// That cannot reach the two failures this driver exists for, because both need
// a Now Playing record the build machine does not have — a live stream whose
// duration is +Inf, which made NSJSONSerialization raise and the helper abort
// on every publish, and a command that arrives before the feed has finished
// starting, which the helper used to drop without a word.
//
// So the helper is included whole and compiled with ISLA_HELPER_UNIT, which
// leaves out its constructor. Nothing here dlopens MediaRemote or loads a dylib
// into anything: the MediaRemote entry points are static C functions of the
// same types that answer from a fixture dictionary, and each case starts only
// the thread it needs. Every case prints what the helper emitted on stdout and
// the script judges it; a case that dies is the helper dying.
//
//   helper-unit nonfinite            record with NaN / ±Inf numbers, `get`
//   helper-unit invalid              unserialisable payloads straight to emit
//   helper-unit early-command        `get` buffered before the feed is ready
//   helper-unit artwork <fixture>    an oversized cover, written to <fixture>
//   helper-unit artwork-small <fix>  a small cover, written to <fix>

#include "../../Sources/IslaMediaHelper/helper.m"

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <math.h>
#include <unistd.h>

static NSDictionary *sFixture;
static BOOL sFixturePlaying;

static void stubGetInfo(dispatch_queue_t queue, void (^block)(CFDictionaryRef)) {
    // Asynchronous on the queue it was given, as MediaRemote answers.
    dispatch_async(queue, ^{ block((__bridge CFDictionaryRef)sFixture); });
}

static void stubGetIsPlaying(dispatch_queue_t queue, void (^block)(Boolean)) {
    dispatch_async(queue, ^{ block(sFixturePlaying); });
}

static void installStubs(NSDictionary *fixture) {
    sFixture = fixture;
    sFixturePlaying = YES;
    sGetInfo = stubGetInfo;
    sGetIsPlaying = stubGetIsPlaying;
}

/// Lets every hop of a publish run to the end. A publish is a short chain of
/// blocks on the serial queue, each enqueueing the next before it returns, so
/// a few empty synchronous blocks behind it are enough to see it finish.
static void drainQueue(void) {
    for (int i = 0; i < 16; i++) dispatch_sync(sQueue, ^{});
}

/// A PNG of noise, which PNG cannot compress — so `side` sets the byte size
/// as well as the pixel size, and 1600 px is comfortably over the app's 4 MB
/// artwork cap.
static NSData *noisePNG(size_t side) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, side, side, 8, side * 4, space,
                                                 (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(space);
    arc4random_buf(CGBitmapContextGetData(context), side * side * 4);
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination =
        CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(destination, image, NULL);
    CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    return data;
}

static NSDictionary *record(NSDictionary *extra) {
    NSMutableDictionary *info = [@{
        @"kMRMediaRemoteNowPlayingInfoTitle": @"Live radio",
        @"kMRMediaRemoteNowPlayingInfoArtist": @"Station",
        @"kMRMediaRemoteNowPlayingInfoDuration": @0,
        @"kMRMediaRemoteNowPlayingInfoElapsedTime": @0,
        @"kMRMediaRemoteNowPlayingInfoPlaybackRate": @1,
    } mutableCopy];
    [info addEntriesFromDictionary:extra];
    return info;
}

static int caseNonfinite(void) {
    // What a live HLS stream in a browser tab reports: no end, so no duration
    // and an elapsed time that is not a number either.
    installStubs(record(@{
        @"kMRMediaRemoteNowPlayingInfoDuration": @(NAN),
        @"kMRMediaRemoteNowPlayingInfoElapsedTime": @(INFINITY),
        @"kMRMediaRemoteNowPlayingInfoPlaybackRate": @(-INFINITY),
        @"kMRMediaRemoteNowPlayingInfoTimestamp": [NSDate dateWithTimeIntervalSince1970:INFINITY],
    }));
    markFeedReady();
    publishForced(YES);
    drainQueue();
    return 0;
}

static int caseInvalid(void) {
    // Straight to the emitter, past any cleaning the record gets on the way:
    // whatever slips through must cost a line, never the process.
    emitPayload(@{@"bad": @(NAN)}, YES);
    emitPayload(@{@"date": [NSDate date]}, YES);
    emitPayload(@{@"ok": @YES}, YES);
    return 0;
}

static int caseEarlyCommand(void) {
    // The app writes a held command the instant a restarted helper launches,
    // while the feed thread is still inside dlopen. A pipe stands in for the
    // app's stdin, with the line already in it before the reader starts.
    int fds[2];
    if (pipe(fds) != 0) return 2;
    dup2(fds[0], STDIN_FILENO);
    close(fds[0]);
    write(fds[1], "get\n", 4);
    // The write end stays open: closing it is how the app says goodbye, and
    // the reader would exit on it.

    installStubs(record(@{}));
    startCommandReader();
    usleep(300 * 1000);
    markFeedReady();
    // The script wants the answer within two seconds of the feed being ready.
    usleep(2000 * 1000);
    return 0;
}

static int caseArtwork(const char *fixturePath, size_t side) {
    NSData *cover = noisePNG(side);
    [cover writeToFile:@(fixturePath) atomically:NO];
    installStubs(record(@{@"kMRMediaRemoteNowPlayingInfoArtworkData": cover}));
    markFeedReady();
    publishForced(YES);
    drainQueue();
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) return 2;
        setUpGlobals();
        NSString *mode = @(argv[1]);
        int status = 2;
        if ([mode isEqualToString:@"nonfinite"]) status = caseNonfinite();
        else if ([mode isEqualToString:@"invalid"]) status = caseInvalid();
        else if ([mode isEqualToString:@"early-command"]) status = caseEarlyCommand();
        else if ([mode isEqualToString:@"artwork"] && argc > 2) status = caseArtwork(argv[2], 1600);
        else if ([mode isEqualToString:@"artwork-small"] && argc > 2) status = caseArtwork(argv[2], 300);
        fflush(stdout);
        // exit, not return: the reader thread is parked in fgets and the run
        // loop of nothing here needs unwinding.
        exit(status);
    }
}
