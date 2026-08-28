// Detect and repair the "opted into a biometric this device cannot perform" state, which otherwise
// makes every purchase fall back to an Apple ID password prompt. See docs/GATES.md gate 2.
#import <Foundation/Foundation.h>

// Best-effort pre-flight, safe to call as root. Re-execs itself as mobile because the preferences
// involved live in mobile's domain. Never fails the caller: a purchase that would have worked still
// works if this does nothing.
void biometricPreflight(void);

// The mobile-side half, run via the internal _biometric-preflight subcommand. Refuses to run as any
// uid other than 501.
int cmdBiometricPreflight(void);
