//
//  SUCoreBasedUpdateDriver.m
//  Sparkle
//
//  Created by Mayur Pawashe on 3/18/16.
//  Copyright © 2016 Sparkle Project. All rights reserved.
//

#import "SUCoreBasedUpdateDriver.h"
#import "SUHost.h"
#import "SUUpdaterDelegate.h"
#import "SUBasicUpdateDriver.h"
#import "SUInstallerDriver.h"
#import "SUDownloadDriver.h"

#ifdef _APPKITDEFINES_H
#error This is a "core" class and should NOT import AppKit
#endif

@interface SUCoreBasedUpdateDriver () <SUBasicUpdateDriverDelegate, SUDownloadDriverDelegate, SUInstallerDriverDelegate>

@property (nonatomic, readonly) SUBasicUpdateDriver *basicDriver;
@property (nonatomic) SUDownloadDriver *downloadDriver;
@property (nonatomic, readonly) SUInstallerDriver *installerDriver;
@property (nonatomic, weak, readonly) id<SUCoreBasedUpdateDriverDelegate> delegate;
@property (nonatomic) SUAppcastItem *updateItem;

@property (nonatomic, readonly) SUHost *host;
@property (nonatomic, readonly, weak) id updater; // if we didn't have legacy support, I'd remove this..
@property (nullable, nonatomic, readonly, weak) id <SUUpdaterDelegate>updaterDelegate;
@property (nonatomic) NSString *userAgent;

@end

@implementation SUCoreBasedUpdateDriver

@synthesize basicDriver = _basicDriver;
@synthesize downloadDriver = _downloadDriver;
@synthesize installerDriver = _installerDriver;
@synthesize delegate = _delegate;
@synthesize updateItem = _updateItem;
@synthesize host = _host;
@synthesize updater = _updater;
@synthesize updaterDelegate = _updaterDelegate;
@synthesize userAgent = _userAgent;

- (instancetype)initWithHost:(SUHost *)host sparkleBundle:(NSBundle *)sparkleBundle updater:(id)updater updaterDelegate:(nullable id <SUUpdaterDelegate>)updaterDelegate delegate:(id<SUCoreBasedUpdateDriverDelegate>)delegate
{
    self = [super init];
    if (self != nil) {
        _delegate = delegate;
        _basicDriver = [[SUBasicUpdateDriver alloc] initWithHost:host updater:updater updaterDelegate:updaterDelegate delegate:self];
        _installerDriver = [[SUInstallerDriver alloc] initWithHost:host sparkleBundle:sparkleBundle updater:updater updaterDelegate:updaterDelegate delegate:self];
        _host = host;
        _updater = updater;
        _updaterDelegate = updaterDelegate;
    }
    return self;
}

- (void)checkForUpdatesAtAppcastURL:(NSURL *)appcastURL withUserAgent:(NSString *)userAgent httpHeaders:(NSDictionary *)httpHeaders includesSkippedUpdates:(BOOL)includesSkippedUpdates completion:(SUUpdateDriverCompletion)completionBlock
{
    self.userAgent = userAgent;
    
    [self.basicDriver checkForUpdatesAtAppcastURL:appcastURL withUserAgent:userAgent httpHeaders:httpHeaders includesSkippedUpdates:includesSkippedUpdates completion:completionBlock];
}

- (void)resumeUpdateWithCompletion:(SUUpdateDriverCompletion)completionBlock
{
    [self.basicDriver resumeUpdateWithCompletion:completionBlock];
}

- (void)basicDriverDidFinishLoadingAppcast
{
    if ([self.delegate respondsToSelector:@selector(basicDriverDidFinishLoadingAppcast)]) {
        [self.delegate basicDriverDidFinishLoadingAppcast];
    }
}

- (void)basicDriverDidFindUpdateWithAppcastItem:(SUAppcastItem *)updateItem
{
    self.updateItem = updateItem;
    
    [self.delegate basicDriverDidFindUpdateWithAppcastItem:updateItem];
}

- (void)downloadUpdateFromAppcastItem:(SUAppcastItem *)updateItem
{
    self.downloadDriver = [[SUDownloadDriver alloc] initWithUpdateItem:updateItem host:self.host userAgent:self.userAgent delegate:self];
    
    if ([self.updaterDelegate respondsToSelector:@selector(updater:willDownloadUpdate:withRequest:)]) {
        [self.updaterDelegate updater:self.updater
                               willDownloadUpdate:updateItem
                                      withRequest:self.downloadDriver.request];
    }
    
    [self.downloadDriver downloadUpdate];
}

- (void)downloadDriverDidDownloadUpdate
{
    // Now we have to extract the downloaded archive.
    if ([self.delegate respondsToSelector:@selector(coreDriverDidFinishDownloadingUpdate)]) {
        [self.delegate coreDriverDidFinishDownloadingUpdate];
    }
    
    NSString *downloadPath = self.downloadDriver.downloadPath;
    assert(downloadPath != nil);
    
    NSString *temporaryDirectory = self.downloadDriver.temporaryDirectory;
    assert(temporaryDirectory != nil);
    
    NSError *error = nil;
    if (![self.installerDriver extractDownloadPath:downloadPath withUpdateItem:self.updateItem temporaryDirectory:temporaryDirectory error:&error]) {
        [self.delegate coreDriverIsRequestingAbortUpdateWithError:error];
    } else {
        [self.downloadDriver cancelTrashCleanup];
    }
}

- (void)downloadDriverDidFailToDownloadUpdateWithError:(NSError *)error
{
    if ([self.updaterDelegate respondsToSelector:@selector(updater:failedToDownloadUpdate:error:)]) {
        [self.updaterDelegate updater:self.updater
                           failedToDownloadUpdate:self.updateItem
                                            error:error.userInfo[NSUnderlyingErrorKey]];
    }
    
    [self.delegate coreDriverIsRequestingAbortUpdateWithError:error];
}

- (void)installerDidStartInstalling
{
    if ([self.delegate respondsToSelector:@selector(installerDidStartInstalling)]) {
        [self.delegate installerDidStartInstalling];
    }
}

- (void)installerDidExtractUpdateWithProgress:(double)progress
{
    if ([self.delegate respondsToSelector:@selector(installerDidExtractUpdateWithProgress:)]) {
        [self.delegate installerDidExtractUpdateWithProgress:progress];
    }
}

- (void)installerDidFinishRelaunchPreparation
{
    [self.delegate installerDidFinishRelaunchPreparation];
}

- (void)finishInstallationWithResponse:(SUInstallUpdateStatus)installUpdateStatus
{
    switch (installUpdateStatus) {
        case SUDismissUpdateInstallation:
            [self.delegate coreDriverIsRequestingAbortUpdateWithError:nil];
            break;
        case SUInstallAndRelaunchUpdateNow:
            [self.installerDriver installWithToolAndRelaunch:YES displayingUserInterface:YES];
            break;
    }
}

- (void)installerIsRequestingAppTermination
{
    if ([self.updaterDelegate respondsToSelector:@selector(updater:willInstallUpdate:)]) {
        [self.updaterDelegate updater:self.updater willInstallUpdate:self.updateItem];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:SUUpdaterWillRestartNotification object:self];
    if ([self.updaterDelegate respondsToSelector:@selector(updaterWillRelaunchApplication:)]) {
        [self.updaterDelegate updaterWillRelaunchApplication:self.updater];
    }
    
    // If they don't respond or do anything, we'll just install after the user terminates the app anyway
    if ([self.delegate respondsToSelector:@selector(coreDriverIsRequestingAppTermination)]) {
        [self.delegate coreDriverIsRequestingAppTermination];
    }
}

- (void)installerIsRequestingAbortInstallWithError:(nullable NSError *)error
{
    [self.delegate coreDriverIsRequestingAbortUpdateWithError:error];
}

- (void)basicDriverIsRequestingAbortUpdateWithError:(nullable NSError *)error
{
    // A delegate may want to handle this type of error specially
    [self.delegate basicDriverIsRequestingAbortUpdateWithError:error];
}

- (void)installerDidFailToApplyDeltaUpdate
{
    SUAppcastItem *nonDeltaUpdateItem = self.basicDriver.nonDeltaUpdateItem;
    assert(nonDeltaUpdateItem != nil);
    
    self.updateItem = nonDeltaUpdateItem;
    
    [self downloadUpdateFromAppcastItem:nonDeltaUpdateItem];
}

- (BOOL)basicDriverShouldSignalShowingUpdateImmediately
{
    return [self.delegate basicDriverShouldSignalShowingUpdateImmediately];
}

- (void)abortUpdateWithError:(nullable NSError *)error
{
    [self.installerDriver abortInstall];
    [self.basicDriver abortUpdateWithError:error];
    [self.downloadDriver cleanup];
}

@end
