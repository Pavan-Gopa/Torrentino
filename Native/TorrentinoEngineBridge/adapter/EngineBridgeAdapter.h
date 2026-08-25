// Torrentino engine bridge — ObjC-compatible adapter surface (WP-04).
//
// Role:    the only ObjC-visible entry point into the C++ engine. It wraps
//          EngineBridge (the C++ PIMPL facade) behind a strict ObjC API so the
//          Swift actor on the other side never sees a libtorrent, Boost or
//          std:: type: DTOs travel as JSON `NSData` envelopes, every failure
//          returns an `NSError`, and no exception can cross the boundary.
// Must not: expose C++ types in the `@interface` (this file is compiled as part
//          of the bridging header and is read by Swift), start its own threads,
//          or perform unbounded waits (delegated to EngineBridge deadlines).
// Threading: all methods are synchronous serialized inside EngineBridge; the
//          caller (the EngineCoordinator actor) serializes its own calls.
//
// Wire schema (frozen):
//   * SessionConfiguration, AddSpecification and every DTO are encoded as JSON
//     dictionaries. Key names are the kebab-case C++ member names ("peer-id",
//     "torrent-id", "info-hash", ...) so Swift decodes them with a matching
//     CodingKeys enum, exactly like the plist-key contract in the XPC layer.
//   * Errors are NSError with domain "com.torrentino.engine-bridge",
//     code = BridgeError raw value, userInfo[NSLocalizedDescriptionKey] =
//     the C++ failure message.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Frozen adapter error domain; codes mirror `torrentino::bridge::BridgeError`.
FOUNDATION_EXPORT NSErrorDomain const TorrentinoEngineBridgeErrorDomain;

/// Bridge adapter error codes (mirror of `torrentino::bridge::BridgeError`).
typedef NS_ENUM(NSInteger, TorrentinoEngineBridgeError) {
	TorrentinoEngineBridgeErrorNone = 0,
	TorrentinoEngineBridgeErrorNotStarted = 1,
	TorrentinoEngineBridgeErrorAlreadyStarted = 2,
	TorrentinoEngineBridgeErrorNotFound = 3,
	TorrentinoEngineBridgeErrorTimeout = 4,
	TorrentinoEngineBridgeErrorInvalidArgument = 5,
	TorrentinoEngineBridgeErrorEngineFailure = 6,
	TorrentinoEngineBridgeErrorIO = 7,
	TorrentinoEngineBridgeErrorStopped = 8,
	TorrentinoEngineBridgeErrorInternal = 9,
	TorrentinoEngineBridgeErrorUnsupportedOperation = 10,
};

/// ObjC-compatible facade over the C++ engine. One instance owns exactly one
/// EngineBridge; the Swift EngineCoordinator actor creates it inside the actor
/// so C++ pointers never cross the concurrency boundary.
@interface TorrentinoEngineBridgeAdapter : NSObject

/// Starts the engine with a JSON-encoded SessionConfiguration (kebab-case).
/// Returns a JSON BootReport on success, or an NSError (code reflects the
/// BridgeError). Rejects repeated start and non-conforming payloads.
- (nullable NSData *)startEngineWithConfigurationData:(NSData *)configurationData
														 error:(NSError *_Nullable *_Nullable)error;

/// Applies the same SessionConfiguration to the running session. Unlike a
/// restart, this keeps torrent handles alive; download-dir becomes the default
/// path for later adds and the remaining fields are sent to libtorrent.
- (nullable NSData *)applyEngineWithConfigurationData:(NSData *)configurationData
														 error:(NSError *_Nullable *_Nullable)error;

/// Adds a torrent from a JSON AddSpecification (exactly one of torrent-file
/// base64 or magnet-uri). Returns a JSON AddResult on success.
- (nullable NSData *)addTorrentWithSpecificationData:(NSData *)specificationData
															   error:(NSError *_Nullable *_Nullable)error;

/// Parses a complete .torrent byte payload through the pinned libtorrent
/// loader and returns {has-v1, has-v2, v1-hash, v2-hash}. This read-only call
/// does not require the engine session to be started.
- (nullable NSData *)verifyTorrentWithData:(NSData *)torrentData
															 error:(NSError *_Nullable *_Nullable)error;

/// Pauses, resumes, or rechecks the torrent identified by the JSON payload
/// {"torrent-id": "..."}. Void results return `{}`.
- (nullable NSData *)pauseWithPayloadData:(NSData *)payloadData
									error:(NSError *_Nullable *_Nullable)error;
- (nullable NSData *)resumeWithPayloadData:(NSData *)payloadData
									 error:(NSError *_Nullable *_Nullable)error;
- (nullable NSData *)recheckWithPayloadData:(NSData *)payloadData
															 error:(NSError *_Nullable *_Nullable)error;

/// Applies per-torrent bandwidth limits. Ratio/seed-time goals are rejected by
/// the bridge with the typed UnsupportedOperation error when non-zero because
/// libtorrent ABI 2 has no per-torrent setter for those goals.
- (nullable NSData *)setLimitsWithPayloadData:(NSData *)payloadData
																 error:(NSError *_Nullable *_Nullable)error;

/// Returns the raw native bandwidth limits for {"torrent-id"}. This pinned
/// libtorrent ABI reports 0 for an unlimited getter value.
- (nullable NSData *)currentLimitsWithPayloadData:(NSData *)payloadData
																 error:(NSError *_Nullable *_Nullable)error;

/// Applies the complete file-priority vector for {"torrent-id", "priorities"}
/// in metainfo order (WP22.D5, ADR-022). prioritize_files is asynchronous:
/// success means a bounded native read-back returned the exact vector before
/// the operation deadline; timeout/mismatch fails closed. Returns `{}`.
- (nullable NSData *)setFilePrioritiesWithPayloadData:(NSData *)payloadData
												error:(NSError *_Nullable *_Nullable)error;

/// WP22.D7 (ADR-022): guarded commit for a temporary metadata-only torrent:
/// {"torrent-id", "priorities", "paused"}. The bridge verifies the handle is
/// still tracked as metadata-only and carries metainfo, applies the exact
/// priority vector behind a bounded read-back, applies the paused state, then
/// clears upload_mode last. Any failure keeps the guard set. Returns `{}`.
- (nullable NSData *)commitMetadataOnlyWithPayloadData:(NSData *)payloadData
												error:(NSError *_Nullable *_Nullable)error;

/// Replaces the complete structured tracker topology for
/// {"torrent-id", "tracker-tiers"}. Scalar payloads are rejected.
- (nullable NSData *)editTrackersWithPayloadData:(NSData *)payloadData
															 error:(NSError *_Nullable *_Nullable)error;

/// Forces an immediate reannounce for {"torrent-id"}.
- (nullable NSData *)reannounceWithPayloadData:(NSData *)payloadData
															 error:(NSError *_Nullable *_Nullable)error;

/// Two-phase removal (ADR-010). prepare validates the record and returns an
/// opaque JSON RemovalToken; commit actually removes it. WP-10 (Gate 6): the
/// payload for prepare is only {"torrent-id": "..."} — no delete-files flag
/// exists on this surface, so libtorrent's permanent deletion is unreachable;
/// the payload for commit is the token itself.
- (nullable NSData *)prepareRemovalWithPayloadData:(NSData *)payloadData
											 error:(NSError *_Nullable *_Nullable)error;
- (nullable NSData *)commitRemovalWithTokenData:(NSData *)tokenData
										  error:(NSError *_Nullable *_Nullable)error;

/// WP-10: async storage move for {"torrent-id", "path"}. Returns `{}` when the
/// move completed (storage_moved_alert); the wait is bounded by the operation
/// timeout. dont_replace semantics: destination files are adopted, never
/// overwritten.
- (nullable NSData *)moveStorageWithPayloadData:(NSData *)payloadData
										  error:(NSError *_Nullable *_Nullable)error;

/// Drains pending alerts as a JSON array of EngineAlertDTO. The payload
/// {"max-count": N} bounds the batch; an empty payload uses the default.
/// Returns [] when the engine is not running or has been shut down.
- (nullable NSData *)drainAlertsWithPayloadData:(NSData *)payloadData
										  error:(NSError *_Nullable *_Nullable)error;

/// Requests resume data for {"torrent-id": "..."}; returns {"torrent-id",
/// "resume-data": base64}. The wait is bounded by the operation timeout.
- (nullable NSData *)requestResumeDataWithPayloadData:(NSData *)payloadData
												error:(NSError *_Nullable *_Nullable)error;

/// Returns the JSON HealthDTO snapshot (uptime, torrent count, rates, ...).
- (nullable NSData *)healthWithError:(NSError *_Nullable *_Nullable)error;

/// Re-bounds the operation deadline: {"millis": N}.
- (nullable NSData *)setOperationTimeoutWithPayloadData:(NSData *)payloadData
												  error:(NSError *_Nullable *_Nullable)error;

/// Deterministic shutdown. Idempotent; always succeeds, even if the engine was
/// never started or a wait was in flight (the wait is unblocked by the engine).
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
