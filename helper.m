// Reads the system now-playing info and prints one JSON line per change.
// Loaded into /usr/bin/perl, which macOS still lets read MediaRemote.
// Commands arrive on stdin, one per line: toggle, next, previous, seek <sec>, shuffle <mode>, repeat <mode>.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>

void np_run(void *a, void *b) {
  NSSet *allowed = [NSSet setWithObjects:@"com.apple.Music", @"com.apple.podcasts", nil];
  void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
  void (*getInfo)(dispatch_queue_t, void (^)(NSDictionary *)) = dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
  void (*getClient)(dispatch_queue_t, void (^)(id)) = dlsym(h, "MRMediaRemoteGetNowPlayingClient");
  NSString *(*bundleOf)(id) = dlsym(h, "MRNowPlayingClientGetBundleIdentifier");
  id (*localOrigin)(void) = dlsym(h, "MRMediaRemoteGetLocalOrigin");
  void (*getCommands)(id, dispatch_queue_t, void (^)(NSArray *)) = dlsym(h, "MRMediaRemoteGetSupportedCommandsForOrigin");
  int (*commandOf)(id) = dlsym(h, "MRMediaRemoteCommandInfoGetCommand");
  NSDictionary *(*optionsOf)(id) = dlsym(h, "MRMediaRemoteCommandInfoCopyOptions");
  Boolean (*send)(int, id) = dlsym(h, "MRMediaRemoteSendCommand");
  void (*setElapsed)(double) = dlsym(h, "MRMediaRemoteSetElapsedTime");
  void (*setShuffle)(int) = dlsym(h, "MRMediaRemoteSetShuffleMode");
  void (*setRepeat)(int) = dlsym(h, "MRMediaRemoteSetRepeatMode");
  if (!getInfo || !getClient || !bundleOf) { printf("{\"error\":\"MediaRemote unavailable\"}\n"); fflush(stdout); return; }

  dispatch_semaphore_t kick = dispatch_semaphore_create(0);
  [NSThread detachNewThreadWithBlock:^{
    char buf[128];
    while (fgets(buf, sizeof buf, stdin)) {
      double arg = 0;
      char *sp = strchr(buf, ' ');
      if (sp) arg = atof(sp + 1);
      if (!strncmp(buf, "toggle", 6) && send) send(2, nil);
      else if (!strncmp(buf, "next", 4) && send) send(4, nil);
      else if (!strncmp(buf, "previous", 8) && send) send(5, nil);
      else if (!strncmp(buf, "seek", 4) && setElapsed) setElapsed(arg);
      else if (!strncmp(buf, "shuffle", 7) && setShuffle) setShuffle((int)arg);
      else if (!strncmp(buf, "repeat", 6) && setRepeat) setRepeat((int)arg);
      else continue;
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.3, false);
      dispatch_semaphore_signal(kick);
    }
    exit(0);  // NowMusicBar closed its end: quit with it.
  }];

  NSString *last = nil;
  NSUInteger lastArt = 0;
  double anchorPos = 0, anchorRate = 0;
  NSDate *anchorAt = nil;
  while (getppid() != 1) {
    @autoreleasepool {
      __block NSString *bundle = nil;
      __block NSDictionary *info = nil;
      __block int shuffle = 0, repeat = 0;
      dispatch_semaphore_t sem = dispatch_semaphore_create(0);
      getClient(dispatch_get_global_queue(0, 0), ^(id c) { if (c) bundle = [bundleOf(c) copy]; dispatch_semaphore_signal(sem); });
      dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
      if (bundle && [allowed containsObject:bundle]) {
        getInfo(dispatch_get_global_queue(0, 0), ^(NSDictionary *i) { info = [i copy]; dispatch_semaphore_signal(sem); });
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        if (getCommands && localOrigin && commandOf && optionsOf) {
          getCommands(localOrigin(), dispatch_get_global_queue(0, 0), ^(NSArray *cmds) {
            for (id c in cmds) {
              int n = commandOf(c);
              if (n == 26) shuffle = [optionsOf(c)[@"kMRMediaRemoteCommandInfoShuffleMode"] intValue];
              if (n == 25) repeat = [optionsOf(c)[@"kMRMediaRemoteCommandInfoRepeatMode"] intValue];
            }
            dispatch_semaphore_signal(sem);
          });
          dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        }
      }

      NSMutableDictionary *out = [NSMutableDictionary dictionary];
      NSData *art = nil;
      double pos = 0, rate = 0;
      if (info[@"kMRMediaRemoteNowPlayingInfoTitle"]) {
        rate = [info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] doubleValue];
        NSDate *ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        pos = [info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] doubleValue];
        if (ts && rate > 0) pos += -[ts timeIntervalSinceNow] * rate;
        out[@"source"] = bundle;
        out[@"title"] = [info[@"kMRMediaRemoteNowPlayingInfoTitle"] description];
        out[@"artist"] = [info[@"kMRMediaRemoteNowPlayingInfoArtist"] description] ?: @"";
        out[@"playing"] = @(rate > 0);
        out[@"position"] = @(pos);
        out[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
        out[@"shuffle"] = @(shuffle);
        out[@"repeat"] = @(repeat);
        art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
      }
      NSString *key = [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@|%@", out[@"source"], out[@"title"], out[@"artist"],
                       out[@"playing"], out[@"duration"], out[@"shuffle"], out[@"repeat"]];
      // A seek shows up as the position drifting from where the last line said it would be.
      double expected = anchorAt ? anchorPos - [anchorAt timeIntervalSinceNow] * anchorRate : 0;
      BOOL jumped = out[@"title"] && fabs(pos - expected) > 1.5;
      NSUInteger artHash = art ? art.hash ^ art.length : 0;
      if (![key isEqualToString:last] || artHash != lastArt || jumped) {
        if (art && artHash != lastArt) out[@"art"] = [art base64EncodedStringWithOptions:0];
        else if (art) out[@"keepArt"] = @YES;
        NSData *j = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
        if (fwrite(j.bytes, 1, j.length, stdout) == 0 || fputc('\n', stdout) == EOF || fflush(stdout) != 0) return;
        last = key; lastArt = artHash;
        anchorPos = pos; anchorRate = rate; anchorAt = [NSDate date];
      }
    }
    dispatch_semaphore_wait(kick, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
  }
}
