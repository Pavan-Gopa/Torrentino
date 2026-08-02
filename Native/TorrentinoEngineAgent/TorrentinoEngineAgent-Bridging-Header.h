// TorrentinoEngineAgent — Swift/ObjC++ bridging header (WP-04).
//
// Role:    the single bridge header for the EngineCoordinator Swift actor. It
//          exposes only the ObjC-compatible adapter surface (NSData/NSError
//          JSON envelopes) — no C++ type can reach Swift through this file.
// Must not: import EngineBridge.h (C++ PIMPL), libtorrent, Boost or OpenSSL.
// Invariants: the imported adapter header must stay pure Foundation; the wire
//          schema (kebab-case keys) is frozen in EngineBridgeAdapter.h.

#import "EngineBridgeAdapter.h"
