/*
 Copyright (c) 2012-present, salesforce.com, inc. All rights reserved.
 
 Redistribution and use of this software in source and binary forms, with or without modification,
 are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright notice, this list of conditions
 and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of
 conditions and the following disclaimer in the documentation and/or other materials provided
 with the distribution.
 * Neither the name of salesforce.com, inc. nor the names of its contributors may be used to
 endorse or promote products derived from this software without specific prior written
 permission of salesforce.com, inc.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
 IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
 FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY
 WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "SFSecurityLockout.h"
#import "SFSecurityLockout+Internal.h"
#import "SFInactivityTimerCenter.h"
#import "SFCrypto.h"
#import "SFOAuthCredentials.h"
#import "SFKeychainItemWrapper.h"
#import "SFUserAccountManager.h"
#import "SFPasscodeManager.h"
#import "SFSDKWindowManager.h"
#import "SFPreferences.h"
#import "SFUserActivityMonitor.h"
#import "SFIdentityData.h"
#import "SFApplicationHelper.h"
#import "SFApplication.h"
#import "SFSDKEventBuilderHelper.h"
#import "SalesforceSDKManager+Internal.h"
#import "SFSDKNavigationController.h"
#import "SFSDKAppLockViewConfig.h"
#import "SFSDKAppLockViewController.h"
#import <SalesforceAnalytics/NSUserDefaults+SFAdditions.h>
#import <LocalAuthentication/LocalAuthentication.h>

// Private constants

static NSString * const kTimerSecurity                       = @"security.timer";
static NSString * const kLegacyPasscodeLengthKey             = @"security.pinlength";
static NSString * const kPasscodeLengthKey                   = @"security.passcode.length";
static NSString * const kKeychainIdntifierPasscodeLengthKey  = @"com.salesforce.security.passcode.length";
static NSString * const kPasscodeScreenAlreadyPresentMessage = @"A passcode screen is already present.";
static NSString * const kKeychainIdentifierLockoutTime       = @"com.salesforce.security.lockoutTime";
static NSString * const kKeychainIdentifierIsLocked          = @"com.salesforce.security.isLocked";
static NSString * const kBiometricUnlockAllowedKey              = @"security.biometric.allowed"; // Enabled in the Org
static NSString * const kBiometricUnlockEnabledKey              = @"security.biometric.enabled"; // Should show biometric instead of passcode
static NSString * const kUserDeclinedBiometricKey               = @"security.biometric.declined"; // User declined biometric unlock


// Public constants

NSString * const kSFPasscodeFlowWillBegin                         = @"SFPasscodeFlowWillBegin";
NSString * const kSFPasscodeFlowCompleted                         = @"SFPasscodeFlowCompleted";
SFAppLockConfigurationData const SFAppLockConfigurationDataNull = { -1, NSUIntegerMax, NO };

// Static vars

static NSUInteger              securityLockoutTime;
static UIViewController        *sPasscodeViewController        = nil;
static SFLockScreenSuccessCallbackBlock sLockScreenSuccessCallbackBlock = NULL;
static SFLockScreenFailureCallbackBlock sLockScreenFailureCallbackBlock = NULL;
static SFPasscodeViewControllerCreationBlock sPasscodeViewControllerCreationBlock = NULL;
static SFPasscodeViewControllerPresentationBlock sPresentPasscodeViewControllerBlock = NULL;
static SFPasscodeViewControllerDismissBlock sDismissPasscodeViewControllerBlock = NULL;
static NSHashTable<id<SFSecurityLockoutDelegate>> *sDelegates = nil;
static BOOL sForcePasscodeDisplay = NO;
static BOOL sValidatePasscodeAtStartup = NO;
static SFSDKAppLockViewConfig *_passcodeViewConfig = nil;

// Flag used to prevent the display of the passcode view controller.
// Note: it is used by the unit tests only.
static BOOL _showPasscode = YES;

@implementation SFSecurityLockout

+ (void)initialize
{
    if (self == [SFSecurityLockout class]) {
        [SFSecurityLockout upgradeSettings];  // Ensures a lockout time value in the keychain.
        
        // If this is the first time the passcode functionality has been run in the lifetime of the app install,
        // reset passcode data, since keychain data can persist between app installs.
        if (![SFCrypto baseAppIdentifierIsConfigured] || [SFCrypto baseAppIdentifierConfiguredThisLaunch]) {
            [SFSecurityLockout setSecurityLockoutTime:0];
            [SFSecurityLockout setPasscodeLength:0];
            [SFSecurityLockout setBiometricUnlockEnabled:NO];
            [SFSecurityLockout setUserDeclinedBiometricUnlock:NO];
        } else {
            securityLockoutTime = [[SFSecurityLockout readLockoutTimeFromKeychain] unsignedIntegerValue];
        }
        
        sDelegates = [NSHashTable weakObjectsHashTable];
        
        [SFSecurityLockout setPasscodeViewControllerCreationBlock:^UIViewController *(SFAppLockControllerMode mode, SFAppLockConfigurationData configData,SFSDKAppLockViewConfig *viewConfig) {
            UIViewController *pvc = [[SFSDKAppLockViewController alloc] initWithAppLockConfigData:configData viewConfig:viewConfig mode:mode];
            return pvc;
        }];
        
        [SFSecurityLockout setPresentPasscodeViewControllerBlock:^(UIViewController *pvc) {
            [[SFSDKWindowManager sharedManager].passcodeWindow presentWindowAnimated:NO withCompletion:^{
                [[SFSDKWindowManager sharedManager].passcodeWindow.viewController  presentViewController:pvc animated:NO completion:nil];
            }];

        }];
        
        [SFSecurityLockout setDismissPasscodeViewControllerBlock:^(UIViewController * pvc, void(^ completionBlock)(void) ) {
                [[SFSDKWindowManager sharedManager].passcodeWindow.viewController  dismissViewControllerAnimated:NO completion:^{
                    [[SFSDKWindowManager sharedManager].passcodeWindow dismissWindowAnimated:NO
                                                                              withCompletion:^{
                                                   if (completionBlock)
                                                       completionBlock();
                                                    }];
                }];
        }];
    }
}

+ (void)upgradeSettings
{
    // Lockout time
    NSNumber *lockoutTime = [SFSecurityLockout readLockoutTimeFromKeychain];
	if (lockoutTime == nil) {
        // Try falling back to user defaults if there's no timeout in the keychain.
        lockoutTime = [[NSUserDefaults msdkUserDefaults] objectForKey:kSecurityTimeoutLegacyKey];
        if (lockoutTime == nil) {
            [SFSecurityLockout writeLockoutTimeToKeychain:@(kDefaultLockoutTime)];
        } else {
            [SFSecurityLockout writeLockoutTimeToKeychain:lockoutTime];
        }
    }
    
    BOOL biometricFileExists = [[SFPreferences globalPreferences] keyExists:kBiometricUnlockAllowedKey];
    if (!biometricFileExists) {
        [self setBiometricAllowed:YES];
    }
    
    // Is locked
    NSNumber *n = [SFSecurityLockout readIsLockedFromKeychain];
    if (n == nil) {
        // Try to fall back to the user defaults if isLocked isn't found in the keychain
        BOOL locked = [[NSUserDefaults msdkUserDefaults] boolForKey:kSecurityIsLockedLegacyKey];
        [SFSecurityLockout writeIsLockedToKeychain:@(locked)];
    }
    
    NSNumber *currentPasscodeLength = [SFSecurityLockout readPasscodeLengthFromKeychain];
    
    if (currentPasscodeLength) {
        NSNumber *previousLength = [[NSUserDefaults msdkUserDefaults] objectForKey:kLegacyPasscodeLengthKey];
        if (previousLength) {
            [[NSUserDefaults msdkUserDefaults] removeObjectForKey:kLegacyPasscodeLengthKey];
        }
        return;
    }
    
    NSNumber *previousLength = [[NSUserDefaults msdkUserDefaults] objectForKey:kLegacyPasscodeLengthKey];
    if (previousLength) {
        [[NSUserDefaults msdkUserDefaults] removeObjectForKey:kLegacyPasscodeLengthKey];
        [self setPasscodeLength:[previousLength unsignedIntegerValue]];
    }
}

+ (void)addDelegate:(id<SFSecurityLockoutDelegate>)delegate
{
    @synchronized (self) {
        if (delegate) {
            [sDelegates addObject:delegate];
        }
    }
}

+ (void)removeDelegate:(id<SFSecurityLockoutDelegate>)delegate
{
    @synchronized (self) {
        if (delegate) {
            [sDelegates removeObject:delegate];
        }
    }
}

+ (void)enumerateDelegates:(void (^)(id<SFSecurityLockoutDelegate>))block
{
    @synchronized (self) {
        for (id<SFSecurityLockoutDelegate> delegate in sDelegates) {
            if (block) block(delegate);
        }
    }
}

+ (void)validateTimer
{
    if ([SFSecurityLockout isPasscodeValid]) {
        if([SFSecurityLockout inactivityExpired] || [SFSecurityLockout locked]) {
            [SFSDKCoreLogger i:[self class] format:@"Timer expired."];
            [SFSecurityLockout lock];
        } 
        else {
            [SFSecurityLockout setupTimer];
            [SFSecurityLockout unlockSuccessPostProcessing:SFSecurityLockoutActionNone];  // "Unlock" was successful, as locking wasn't required.
        }
    } else {
        [SFSecurityLockout unlockSuccessPostProcessing:SFSecurityLockoutActionNone];  // "Unlock" was successful, as locking wasn't required.
    }
}

+ (void)setInactivityConfiguration:(NSUInteger)newPasscodeLength lockoutTime:(NSUInteger)newLockoutTime biometricAllowed:(BOOL)newBiometricAllowed
{
    
    SFAppLockConfigurationData configData;
    configData.lockoutTime = securityLockoutTime;
    configData.passcodeLength = [self passcodeLength];
    
    if (newBiometricAllowed) {
        // Biometric off -> on.
        // Don't set allowed if user had previously declined.
        if (!configData.biometricUnlockAllowed && ![self userDeclinedBiometricUnlock]) {
            [SFSDKCoreLogger i:[SFSecurityLockout class] format:@"Biometric unlock is allowed."];
            [self setBiometricAllowed:YES];
        }
    } else {
        // Biometric on -> off.
        if([self biometricUnlockAllowed]) {
            [SFSDKCoreLogger i:[SFSecurityLockout class] format:@"Biometric unlock is not not allowed."];
            [self setBiometricAllowed:NO];
        }
    }
    configData.biometricUnlockAllowed = [self biometricUnlockAllowed];
    
    // Cases where there's initially no passcode configured.
    if (securityLockoutTime == 0) {
        if (newLockoutTime == 0) {
            // Passcode off -> off.
            [SFSecurityLockout unlockSuccessPostProcessing:SFSecurityLockoutActionNone];
        } else {
            // Passcode off -> on.  Trigger passcode creation.
            configData.lockoutTime = newLockoutTime;
            configData.passcodeLength = newPasscodeLength;
            [SFSecurityLockout presentPasscodeController:SFPasscodeControllerModeCreate passcodeConfig:configData];
        }
        return;
    }
    
    //
    // From this point, there was already a passcode configured prior to calling this method.
    //
    
    // Lockout time can only go down, to enforce the most restrictive passcode policy across users.
    if (newLockoutTime < securityLockoutTime) {
        if (newLockoutTime > 0) {
            [SFSDKCoreLogger i:[SFSecurityLockout class] format:@"Setting lockout time to %lu seconds.", (unsigned long) newLockoutTime];
            [SFSecurityLockout setSecurityLockoutTime:newLockoutTime];
            configData.lockoutTime = newLockoutTime;
            [SFInactivityTimerCenter removeTimer:kTimerSecurity];
            [SFSecurityLockout setupTimer];
        } else {
            // '0' is a special case.  We can't turn off passcodes unless all other users' passcode policies
            // are also off.
            if (![SFSecurityLockout nonCurrentUsersHavePasscodePolicy]) {
                [SFSecurityLockout clearAllPasscodeState];
                [SFSecurityLockout unlock:YES action:SFSecurityLockoutActionPasscodeRemoved passcodeConfig:SFAppLockConfigurationDataNull];  // config values already cleared.
                return;
            }
        }
    }
    
    // Passcode lengths can only go up; same reason as lockout times only going down.
    NSUInteger currentPasscodeLength = [self passcodeLength];
    if (newPasscodeLength > currentPasscodeLength) {
        configData.passcodeLength = newPasscodeLength;
        [SFSecurityLockout presentPasscodeController:SFPasscodeControllerModeChange passcodeConfig:configData];
        return;
    }
    
    // If we got this far, no passcode action was taken.
    [SFSecurityLockout unlockSuccessPostProcessing:SFSecurityLockoutActionNone];
}

+ (void)setSecurityLockoutTime:(NSUInteger)newSecurityLockoutTime
{
    // NOTE: This method directly alters securityLockoutTime and its persisted value.  Do not call
    // if passcode policy evaluation is required.
    securityLockoutTime = newSecurityLockoutTime;
    [SFSecurityLockout writeLockoutTimeToKeychain:@(securityLockoutTime)];
}

+ (BOOL)nonCurrentUsersHavePasscodePolicy
{
    SFUserAccount *currentAccount = [SFUserAccountManager sharedInstance].currentUser;
    return [self otherUsersHavePasscodePolicy:currentAccount];
}

+ (BOOL)otherUsersHavePasscodePolicy:(SFUserAccount *)thisUser
{
    for (SFUserAccount *account in [SFUserAccountManager sharedInstance].allUserAccounts) {
        if (![account isEqual:thisUser]) {
            if (account.idData.mobileAppScreenLockTimeout > 0) {
                return YES;
            }
        }
    }
    return NO;
}

+ (void)clearPasscodeState
{
    // Public method that attempts to clear passcode state for the current user.  Clear state will be dependent
    // on passcode policies across users.  So for instance, if another configured user in the app still has
    // passcode policies which apply to that account, this method will effectively do nothing.  On the other hand,
    // if the current user is the only user of the app, this will remove passcode policies for the app.
    return [self clearPasscodeState:[SFUserAccountManager sharedInstance].currentUser];
}

+ (void)clearPasscodeState:(SFUserAccount *)userLoggingOut {
   
    if (![SFSecurityLockout otherUsersHavePasscodePolicy:userLoggingOut]) {
        [SFSecurityLockout clearAllPasscodeState];
    }
}

+ (void)clearAllPasscodeState
{
    // NOTE: This private method directly clears all of the persisted passcode state for the app.  It should only
    // be called in the event that the greater app state needs to be cleared; it's currently used internally in
    // cases where the passcode is no longer valid (user forgot the passcode, failed the maximum verification
    // attempts, etc.).  Calling this method should be reasonably followed upstream with a general resetting of
    // the app state.
    [SFSecurityLockout setSecurityLockoutTime:0];
    [SFSecurityLockout setPasscodeLength:0];
    [SFSecurityLockout setBiometricAllowed:NO];
    [SFSecurityLockout setBiometricUnlockEnabled:NO];
    [SFSecurityLockout setUserDeclinedBiometricUnlock:NO];
    [SFInactivityTimerCenter removeTimer:kTimerSecurity];
    [[SFPasscodeManager sharedManager] changePasscode:nil];
}

+ (NSUInteger)passcodeLength
{
    NSNumber *nPasscodeLength = [SFSecurityLockout readPasscodeLengthFromKeychain];
    return (nPasscodeLength != nil ? [nPasscodeLength integerValue] : 0);
}

+ (void)setPasscodeLength:(NSUInteger)newPasscodeLength
{
    // NOTE: This method directly alters the passcode length global preference persisted value.  Do not call if
    // passcode policy evaluation is required.
    [SFSecurityLockout writePasscodeLengthToKeychain:[NSNumber numberWithInteger:newPasscodeLength]];
}

+ (BOOL)biometricUnlockAllowed
{
    return [[SFPreferences globalPreferences] boolForKey:kBiometricUnlockAllowedKey] && [[SFPasscodeManager sharedManager] deviceHasBiometric];
}

+ (void)setBiometricAllowed:(BOOL)enabled
{
    [[SFPreferences globalPreferences] setBool:enabled forKey:kBiometricUnlockAllowedKey];
    [[SFPreferences globalPreferences] synchronize];
}

+ (BOOL)biometricUnlockEnabled
{
    return [[SFPreferences globalPreferences] boolForKey:kBiometricUnlockEnabledKey];
}

+ (void)setBiometricUnlockEnabled:(BOOL)enabled
{
    [[SFPreferences globalPreferences] setBool:enabled forKey:kBiometricUnlockEnabledKey];
    [[SFPreferences globalPreferences] synchronize];
}

+ (BOOL)userDeclinedBiometricUnlock
{
    return [[SFPreferences globalPreferences] boolForKey:kUserDeclinedBiometricKey];
}

+ (void)setUserDeclinedBiometricUnlock:(BOOL)declined
{
    [[SFPreferences globalPreferences] setBool:declined forKey:kUserDeclinedBiometricKey];
    [[SFPreferences globalPreferences] synchronize];
}

+ (BOOL)hasValidSession
{
    return [SFUserAccountManager sharedInstance].currentUser != nil && [SFUserAccountManager sharedInstance].currentUser.isSessionValid;
}

// For unit tests.
+ (void)setLockoutTimeInternal:(NSUInteger)seconds
{
    securityLockoutTime = seconds;
}

+ (NSUInteger)lockoutTime
{
	return securityLockoutTime;
}

+ (BOOL)inactivityExpired
{
	NSInteger elapsedTime = [[NSDate date] timeIntervalSinceDate:[SFInactivityTimerCenter lastActivityTimestamp]];
	return (securityLockoutTime > 0) && (elapsedTime >= securityLockoutTime);
}

+ (void)startActivityMonitoring
{
    if ([SFSecurityLockout lockoutTime] > 0) {
        [[SFUserActivityMonitor sharedInstance] startMonitoring];
    }
}

+ (void)stopActivityMonitoring
{
    [[SFUserActivityMonitor sharedInstance] stopMonitoring];
}

+ (void)setupTimer
{
	if(securityLockoutTime > 0) {
		[SFInactivityTimerCenter registerTimer:kTimerSecurity
                                        target:self
                                      selector:@selector(timerExpired:)
                                 timerInterval:securityLockoutTime];
	}
    [SFInactivityTimerCenter updateActivityTimestamp];
}

+ (void)removeTimer
{
    [SFInactivityTimerCenter removeTimer:kTimerSecurity];
}

+ (void)setPasscodeViewConfig:(SFSDKAppLockViewConfig *)passcodeViewConfig {
    _passcodeViewConfig = passcodeViewConfig;
    
    // This guarentees the user's passcode is the length specified in the connected app.
    if (_passcodeViewConfig.forcePasscodeLength) {
        // Set passcode length to the last minimum length we got from the connected app.
        NSNumber *oldPasscodeLength = [[SFPreferences globalPreferences] objectForKey:kPasscodeLengthKey];
        if (oldPasscodeLength) {
            [SFSecurityLockout setPasscodeLength:[oldPasscodeLength unsignedIntegerValue]];
        }
    }
}

+ (SFSDKAppLockViewConfig *)passcodeViewConfig {
    if (_passcodeViewConfig == nil) {
        _passcodeViewConfig = [SFSDKAppLockViewConfig createDefaultConfig];
    }
    return _passcodeViewConfig;
}

static NSString *const kSecurityLockoutSessionId = @"securityLockoutSession";

+ (void)unlock:(BOOL)success action:(SFSecurityLockoutAction)action passcodeConfig:(SFAppLockConfigurationData)configData
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self unlock:success action:action passcodeConfig:configData];
        });
        return;
    }
    [SFSDKEventBuilderHelper createAndStoreEvent:@"passcodeUnlock" userAccount:nil className:NSStringFromClass([self class]) attributes:nil];
    [self sendPasscodeFlowCompletedNotification:success];
    UIViewController *passVc = [SFSecurityLockout passcodeViewController];
    if (passVc != nil) {
        SFPasscodeViewControllerDismissBlock dismissBlock = [SFSecurityLockout dismissPasscodeViewControllerBlock];
        __weak typeof (self) weakSelf = self;
        dismissBlock(passVc, ^{
             __strong typeof (weakSelf) strongSelf = weakSelf;
            [SFSecurityLockout setPasscodeViewController:nil];
            if (success) {
                if (action == SFSecurityLockoutActionPasscodeCreated || action == SFSecurityLockoutActionPasscodeChanged) {
                    if (&configData != &SFAppLockConfigurationDataNull) {
                        [SFSecurityLockout setSecurityLockoutTime:configData.lockoutTime];
                        [SFSecurityLockout setPasscodeLength:configData.passcodeLength];
                    }
                    // Set passcode length if it was not known before
                } else if (action == SFSecurityLockoutActionPasscodeVerified && [SFSecurityLockout passcodeLength] == 0) {
                    [SFSecurityLockout setPasscodeLength:configData.passcodeLength];
                }
                [SFSecurityLockout unlockSuccessPostProcessing:action];
            } else {
                // Clear the SFSecurityLockout passcode state, as it's no longer valid.
                [SFSecurityLockout clearAllPasscodeState];
                [[SFUserAccountManager sharedInstance] logoutAllUsers];
                [SFSecurityLockout unlockFailurePostProcessing];
            }
            
            [SFSDKEventBuilderHelper createAndStoreEvent:@"passcodeUnlock" userAccount:nil className:NSStringFromClass([strongSelf class]) attributes:nil];
            [strongSelf sendPasscodeFlowCompletedNotification:success];
            
            [strongSelf enumerateDelegates:^(id<SFSecurityLockoutDelegate> delegate) {
                if ([delegate respondsToSelector:@selector(passcodeFlowDidComplete:)]) {
                    [delegate passcodeFlowDidComplete:success];
                }
            }];
        });
        
    }
}

+ (void)timerExpired:(NSTimer*)theTimer
{
    [SFSecurityLockout setLockScreenFailureCallbackBlock:^{
        [[SFUserAccountManager sharedInstance] logout];
    }];
    
    [SFSDKCoreLogger i:[self class] format:@"NSTimer expired, but checking lastUserEvent before locking!"];
    NSDate *lastEventAsOfNow = [(SFApplication *)[SFApplicationHelper sharedApplication] lastEventDate];
    NSInteger elapsedTime = [[NSDate date] timeIntervalSinceDate:lastEventAsOfNow];
    if (elapsedTime >= securityLockoutTime) {
        [SFSDKCoreLogger i:[self class] format:@"Inactivity NSTimer expired."];
        [SFSecurityLockout lock];
    } else {
        [SFInactivityTimerCenter removeTimer:kTimerSecurity];
        [SFSecurityLockout setupTimer];
    }
}

+ (void)setForcePasscodeDisplay:(BOOL)forceDisplay
{
    sForcePasscodeDisplay = forceDisplay;
}

+ (BOOL)forcePasscodeDisplay
{
    return sForcePasscodeDisplay;
}

+ (void)lock
{
    if (!sForcePasscodeDisplay) {
        // Only go through sanity checks for locking if we don't want to force the passcode screen.
        if (![SFSecurityLockout hasValidSession]) {
            [SFSDKCoreLogger i:[self class] format:@"Skipping 'lock' since not authenticated"];
            [SFSecurityLockout unlockSuccessPostProcessing:SFSecurityLockoutActionNone];
            return;
        }
        
        if ([SFSecurityLockout lockoutTime] == 0) {
            [SFSDKCoreLogger i:[self class] format:@"Skipping 'lock' since pin policies are not configured."];
            [SFSecurityLockout unlockSuccessPostProcessing:SFSecurityLockoutActionNone];
            return;
        }
    }
    
    SFAppLockConfigurationData configData;
    configData.lockoutTime = [self lockoutTime];
    configData.passcodeLength = [self passcodeLength];
    configData.biometricUnlockAllowed = [self biometricUnlockAllowed];
    if ([SFApplicationHelper sharedApplication].applicationState == UIApplicationStateActive || ![SFSDKWindowManager sharedManager].snapshotWindow.isEnabled) {
        if (![[SFPasscodeManager sharedManager] deviceHasBiometric]) {
            [self setBiometricUnlockEnabled:NO];
        }
        
        SFAppLockControllerMode lockType = ([self biometricUnlockEnabled]) ? SFBiometricControllerModeVerify : SFPasscodeControllerModeVerify;
        [SFSecurityLockout presentPasscodeController:lockType passcodeConfig:configData];
    }
    [SFSDKCoreLogger i:[self class] format:@"Device locked."];
    sForcePasscodeDisplay = NO;
}



+ (SFPasscodeViewControllerCreationBlock)passcodeViewControllerCreationBlock
{
    return sPasscodeViewControllerCreationBlock;
}

+ (void)setPasscodeViewControllerCreationBlock:(SFPasscodeViewControllerCreationBlock)vcBlock
{
    if (vcBlock != sPasscodeViewControllerCreationBlock) {
        sPasscodeViewControllerCreationBlock = [vcBlock copy];
    }
}

+ (SFPasscodeViewControllerPresentationBlock)presentPasscodeViewControllerBlock
{
    return sPresentPasscodeViewControllerBlock;
}

+ (void)setPresentPasscodeViewControllerBlock:(SFPasscodeViewControllerPresentationBlock)vcBlock
{
    if (vcBlock != sPresentPasscodeViewControllerBlock) {
        sPresentPasscodeViewControllerBlock = vcBlock;
    }
}

+ (SFPasscodeViewControllerDismissBlock)dismissPasscodeViewControllerBlock
{
    return sDismissPasscodeViewControllerBlock;
}

+ (void)setDismissPasscodeViewControllerBlock:(SFPasscodeViewControllerDismissBlock)vcBlock
{
    if (vcBlock != sDismissPasscodeViewControllerBlock) {
        sDismissPasscodeViewControllerBlock = vcBlock;
    }
}

+ (void)presentPasscodeController:(SFAppLockControllerMode)modeValue passcodeConfig:(SFAppLockConfigurationData)configData
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentPasscodeController:modeValue passcodeConfig:configData];
        });
        return;
    }
    
    if ([[SFSDKWindowManager sharedManager].snapshotWindow isEnabled]) {
        [[SFSDKWindowManager sharedManager].snapshotWindow dismissWindow];
    }
    // Don't present the passcode screen if it's already present.
    if ([SFSecurityLockout passcodeScreenIsPresent]) {
        return;
    }
    
    [self setIsLocked:YES];
    if (_showPasscode) {
        [self sendPasscodeFlowWillBeginNotification:modeValue];
        [self enumerateDelegates:^(id<SFSecurityLockoutDelegate> delegate) {
            if ([delegate respondsToSelector:@selector(passcodeFlowWillBegin:)]) {
                [delegate passcodeFlowWillBegin:modeValue];
            }
        }];
        
        SFPasscodeViewControllerCreationBlock passcodeVcCreationBlock = [SFSecurityLockout passcodeViewControllerCreationBlock];
        UIViewController *passcodeViewController = passcodeVcCreationBlock(modeValue, configData,self.passcodeViewConfig);
        [SFSecurityLockout setPasscodeViewController:passcodeViewController];
        SFPasscodeViewControllerPresentationBlock presentBlock = [SFSecurityLockout presentPasscodeViewControllerBlock];
        if (presentBlock != nil) {
            presentBlock(passcodeViewController);
        }
    }
}

+ (void)presentBiometricEnrollment:(SFSDKAppLockViewConfig*)viewConfig
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentBiometricEnrollment:viewConfig];
        });
        return;
    }
    
    SFSDKAppLockViewConfig *displayConfig = (viewConfig) ? viewConfig : self.passcodeViewConfig;
    [[SFSDKWindowManager sharedManager].passcodeWindow presentWindowAnimated:NO withCompletion:^{
        SFSDKAppLockViewController *navController = [[SFSDKAppLockViewController alloc] initWithAppLockConfigData:SFAppLockConfigurationDataNull viewConfig:displayConfig mode:SFBiometricControllerModeEnable];
        [[SFSDKWindowManager sharedManager].passcodeWindow.viewController presentViewController:navController animated:NO completion:^{}];
    }];
}

+ (void)sendPasscodeFlowWillBeginNotification:(SFAppLockControllerMode)mode
{
    [SFSDKCoreLogger d:[self class] format:@"Sending passcode flow will begin notification with mode %lu", (unsigned long)mode];
    NSNotification *n = [NSNotification notificationWithName:kSFPasscodeFlowWillBegin
                                                      object:[NSNumber numberWithInt:mode]
                                                    userInfo:nil];
    [[NSNotificationCenter defaultCenter] postNotification:n];
}

+ (void)sendPasscodeFlowCompletedNotification:(BOOL)validationSuccess
{
    [SFSDKCoreLogger d:[self class]
       format:@"Sending passcode flow completed notification with validation success = %d", validationSuccess];
    NSNotification *n = [NSNotification notificationWithName:kSFPasscodeFlowCompleted
                                                      object:@(validationSuccess)
                                                    userInfo:nil];
    [[NSNotificationCenter defaultCenter] postNotification:n];
}

+ (BOOL)validatePasscodeAtStartup
{
    return sValidatePasscodeAtStartup;
}

+ (void)setIsLocked:(BOOL)locked
{
    [SFSecurityLockout writeIsLockedToKeychain:@(locked)];
}

+ (BOOL)locked
{
    BOOL locked = NO;
    NSNumber *n = [self readIsLockedFromKeychain];
    if (n != nil) {
        locked = [n boolValue];
    }
    return locked;
}

+ (BOOL)isPasscodeValid
{
	if(securityLockoutTime == 0) return YES; // no passcode is required.
    return([[SFPasscodeManager sharedManager] passcodeIsSet]);
}

+ (BOOL)isPasscodeNeeded
{
    if(securityLockoutTime == 0) return NO; // no passcode is required.

    BOOL result = [SFSecurityLockout inactivityExpired] || [SFSecurityLockout validatePasscodeAtStartup] || ![SFSecurityLockout isPasscodeValid];
    result = result || sForcePasscodeDisplay;
    return result;
}

+ (BOOL)isLockoutEnabled
{
	return securityLockoutTime > 0;
}

+ (void)setPasscodeViewController:(UIViewController *)vc
{
    if (vc != sPasscodeViewController) {
        sPasscodeViewController = vc;
    }
}

+ (UIViewController *)passcodeViewController
{
    return sPasscodeViewController;
}

+ (void)cancelPasscodeScreen
{
    void (^cancelPasscodeBlock)(void) = ^{
        UIViewController *passVc = [SFSecurityLockout passcodeViewController];
        [SFSDKCoreLogger i:[SFSecurityLockout class] format:@"App requested passcode screen cancel.  Screen %@ displayed.", (passVc != nil ? @"is" : @"is not")];
        if (passVc != nil) {
            SFPasscodeViewControllerDismissBlock dismissBlock = [SFSecurityLockout dismissPasscodeViewControllerBlock];
            dismissBlock(passVc,^{
                [SFSecurityLockout setPasscodeViewController:nil];
            });
            
        }
    };
    
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), cancelPasscodeBlock);
    } else {
        cancelPasscodeBlock();
    }
}

+ (void)setLockScreenFailureCallbackBlock:(SFLockScreenFailureCallbackBlock)block
{
    // Callback blocks can't be altered if the passcode screen is already in progress.
    if (![SFSecurityLockout passcodeScreenIsPresent] && sLockScreenFailureCallbackBlock != block) {
        sLockScreenFailureCallbackBlock = [block copy];
    }
}

+ (SFLockScreenFailureCallbackBlock)lockScreenFailureCallbackBlock
{
    return sLockScreenFailureCallbackBlock;
}

+ (void)setLockScreenSuccessCallbackBlock:(SFLockScreenSuccessCallbackBlock)block
{
    // Callback blocks can't be altered if the passcode screen is already in progress.
    if (![SFSecurityLockout passcodeScreenIsPresent] && sLockScreenSuccessCallbackBlock != block) {
        sLockScreenSuccessCallbackBlock = [block copy];
    }
}

+ (SFLockScreenSuccessCallbackBlock)lockScreenSuccessCallbackBlock
{
    return sLockScreenSuccessCallbackBlock;
}

+ (BOOL)passcodeScreenIsPresent
{
    if ([SFSecurityLockout passcodeViewController] != nil && [[SFSecurityLockout  passcodeViewController] presentedViewController]!= nil) {
        [SFSDKCoreLogger i:[self class] format:kPasscodeScreenAlreadyPresentMessage];
        return YES;
    } else {
        return NO;
    }
}

+ (void)unlockSuccessPostProcessing:(SFSecurityLockoutAction)action
{
    [self setIsLocked:NO];
    [SFSecurityLockout setLockScreenFailureCallbackBlock:NULL];
    if ([SFSecurityLockout lockScreenSuccessCallbackBlock] != NULL) {
        SFLockScreenSuccessCallbackBlock blockCopy = [[SFSecurityLockout lockScreenSuccessCallbackBlock] copy];
        [SFSecurityLockout setLockScreenSuccessCallbackBlock:NULL];
        blockCopy(action);
    }
}

+ (void)unlockFailurePostProcessing
{
    [self setIsLocked:NO];
    [SFSecurityLockout setLockScreenSuccessCallbackBlock:NULL];
    if ([SFSecurityLockout lockScreenFailureCallbackBlock] != NULL) {
        SFLockScreenFailureCallbackBlock blockCopy = [[SFSecurityLockout lockScreenFailureCallbackBlock] copy];
        [SFSecurityLockout setLockScreenFailureCallbackBlock:NULL];
        blockCopy();
    }
}

#pragma mark keychain methods

+ (void)setCanShowPasscode:(BOOL)showPasscode
{
    _showPasscode = showPasscode;
}

+ (NSNumber *)readLockoutTimeFromKeychain
{
    return [SFSecurityLockout readNumberFromKeychain:kKeychainIdentifierLockoutTime];
}

+ (void)writeLockoutTimeToKeychain:(NSNumber *)time
{
    [SFSecurityLockout writeNumberToKeychain:time identifier:kKeychainIdentifierLockoutTime];
}

+ (NSNumber *)readPasscodeLengthFromKeychain
{
    return [SFSecurityLockout readNumberFromKeychain:kKeychainIdntifierPasscodeLengthKey];
}

+ (void)writePasscodeLengthToKeychain:(NSNumber *)length
{
    [SFSecurityLockout writeNumberToKeychain:length identifier:kKeychainIdntifierPasscodeLengthKey];
}

+ (NSNumber *)readIsLockedFromKeychain
{
    NSNumber *locked = nil;
    SFKeychainItemWrapper *keychainWrapper = [SFKeychainItemWrapper itemWithIdentifier:kKeychainIdentifierIsLocked account:nil];
    NSData *valueData = [keychainWrapper valueData];
    if (valueData) {
        BOOL b = NO;
        [valueData getBytes:&b length:sizeof(b)];
        locked = @(b);
    }
    return locked;
}

+ (void)writeIsLockedToKeychain:(NSNumber *)locked
{
    SFKeychainItemWrapper *keychainWrapper = [SFKeychainItemWrapper itemWithIdentifier:kKeychainIdentifierIsLocked account:nil];
    NSData *data = nil;
    if (locked != nil) {
        BOOL b = [locked boolValue];
        data = [NSData dataWithBytes:&b length:sizeof(b)];
    }
    if (data != nil)
        [keychainWrapper setValueData:data];
    else
        [keychainWrapper resetKeychainItem];  // Predominantly for unit tests
}

+ (NSNumber *)readNumberFromKeychain:(NSString *)identifier
{
    NSNumber *data = nil;
    SFKeychainItemWrapper *keychainWrapper = [SFKeychainItemWrapper itemWithIdentifier:identifier account:nil];
    NSData *valueData = [keychainWrapper valueData];
    if (valueData) {
        NSUInteger i = 0;
        [valueData getBytes:&i length:sizeof(i)];
        data = @(i);
    }
    return data;
}

+ (void)writeNumberToKeychain:(NSNumber *)number identifier: (NSString *)identifier
{
    SFKeychainItemWrapper *keychainWrapper = [SFKeychainItemWrapper itemWithIdentifier:identifier account:nil];
    NSData *data = nil;
    if (number != nil) {
        NSUInteger i = [number unsignedIntegerValue];
        data = [NSData dataWithBytes:&i length:sizeof(i)];
    }
    if (data != nil)
        [keychainWrapper setValueData:data];
    else
        [keychainWrapper resetKeychainItem];  // Predominantly for unit tests
}

@end

