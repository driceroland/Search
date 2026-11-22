#import <Foundation/Foundation.h>

/// Keeps every window of the test process off the person's screen. Installed
/// on its own when the test bundle loads (+load); calling it again is free.
void NoWindowsInstall(void);
