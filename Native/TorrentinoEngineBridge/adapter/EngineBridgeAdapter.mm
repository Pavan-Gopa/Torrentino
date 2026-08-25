// Torrentino engine bridge — ObjC-compatible adapter implementation (WP-04).
//
// Role: translate between the ObjC NSData/JSON/NSError world and the C++
//       EngineBridge facade. All DTOs cross the boundary as JSON envelopes so
//       the Swift actor never imports a C++ type; all failures cross as NSError
//       so no exception (C++ or ObjC) can escape to Swift.
// Must not: let an exception escape any method (the trampolines below catch
//       C++ exceptions and NSExceptions), or hand a libtorrent type to ObjC.

#import "EngineBridgeAdapter.h"

#include "EngineBridge.h"

#import <Foundation/Foundation.h>

#include <arpa/inet.h>
#include <cctype>

using torrentino::bridge::AddResult;
using torrentino::bridge::AddSpecification;
using torrentino::bridge::AppliedTorrentLimits;
using torrentino::bridge::BootReport;
using torrentino::bridge::BridgeError;
using torrentino::bridge::EngineAlertDTO;
using torrentino::bridge::EngineAlertKind;
using torrentino::bridge::EngineBridge;
using torrentino::bridge::HealthDTO;
using torrentino::bridge::IndependentTorrentIdentity;
using torrentino::bridge::RemovalResult;
using torrentino::bridge::RemovalToken;
using torrentino::bridge::ResumeDataDTO;
using torrentino::bridge::SessionConfiguration;
using torrentino::bridge::TrackerTiers;
using torrentino::bridge::TorrentLimits;
using torrentino::bridge::TorrentRecordID;

NSErrorDomain const TorrentinoEngineBridgeErrorDomain = @"com.torrentino.engine-bridge";

namespace {

// ---------------------------------------------------------------------------
// Objective-C / C++ bridge helpers (kebab-case JSON wire schema, frozen).
// ---------------------------------------------------------------------------

NSString* jsonKey(const char* key)
{
	return [NSString stringWithUTF8String:key];
}

NSDictionary* toJSON(NSData* data, NSError** error)
{
	if (data == nil || data.length == 0) {
		if (error != nil) {
			*error = [NSError errorWithDomain:TorrentinoEngineBridgeErrorDomain
										 code:TorrentinoEngineBridgeErrorInvalidArgument
									 userInfo:@{NSLocalizedDescriptionKey : @"empty JSON payload"}];
		}
		return nil;
	}
	id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
	if (object == nil) {
		return nil;
	}
	if (![object isKindOfClass:[NSDictionary class]]) {
		if (error != nil) {
			*error = [NSError errorWithDomain:TorrentinoEngineBridgeErrorDomain
										 code:TorrentinoEngineBridgeErrorInvalidArgument
									 userInfo:@{NSLocalizedDescriptionKey : @"JSON payload is not a dictionary"}];
		}
		return nil;
	}
	return object;
}

NSData* fromJSON(id object)
{
	if (object == nil) {
		return nil;
	}
	NSError* error = nil;
	NSData* data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
	if (data == nil) {
		// JSON serialization of a dictionary built from literals cannot fail in
		// practice; guard anyway so the boundary stays total.
		NSLog(@"TorrentinoEngineBridgeAdapter: JSON serialization failed: %@", error);
		return nil;
	}
	return data;
}

NSString* stringValue(NSDictionary* dict, const char* key, NSString* fallback)
{
	id value = dict[jsonKey(key)];
	return [value isKindOfClass:[NSString class]] ? value : fallback;
}

int64_t int64Value(NSDictionary* dict, const char* key, int64_t fallback)
{
	id value = dict[jsonKey(key)];
	return [value isKindOfClass:[NSNumber class]] ? [value longLongValue] : fallback;
}

bool boolValue(NSDictionary* dict, const char* key, bool fallback)
{
	id value = dict[jsonKey(key)];
	return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : fallback;
}

uint32_t uint32Value(NSDictionary* dict, const char* key, uint32_t fallback)
{
	int64_t value = int64Value(dict, key, fallback);
	if (value < 0) {
		return fallback;
	}
	return static_cast<uint32_t>(value);
}

std::optional<int64_t> optionalInt64Value(NSDictionary* dict, const char* key)
{
	id value = dict[jsonKey(key)];
	return [value isKindOfClass:[NSNumber class]]
		? std::optional<int64_t>([value longLongValue]) : std::nullopt;
}

std::optional<double> optionalDoubleValue(NSDictionary* dict, const char* key)
{
	id value = dict[jsonKey(key)];
	return [value isKindOfClass:[NSNumber class]]
		? std::optional<double>([value doubleValue]) : std::nullopt;
}

void setInvalidArgument(NSError** error, NSString* message)
{
	if (error != nil) {
		*error = [NSError errorWithDomain:TorrentinoEngineBridgeErrorDomain
								 code:TorrentinoEngineBridgeErrorInvalidArgument
							 userInfo:@{NSLocalizedDescriptionKey : message}];
	}
}

bool validTrackerURLValue(NSString* value)
{
	if (value == nil || value.length == 0 || value.length > 2048) {
		return false;
	}
	for (NSUInteger index = 0; index < value.length; ++index) {
		unichar character = [value characterAtIndex:index];
		if ([[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:character]
			|| character < 0x20 || character == 0x7f) {
			return false;
		}
		if (character == '%') {
			if (index + 2 >= value.length) {
				return false;
			}
			for (NSUInteger escapeIndex = index + 1; escapeIndex <= index + 2; ++escapeIndex) {
				unichar escaped = [value characterAtIndex:escapeIndex];
				if (!std::isxdigit(static_cast<unsigned char>(escaped))) {
					return false;
				}
			}
			index += 2;
		}
	}
	NSURLComponents* components = [NSURLComponents componentsWithString:value];
	NSString* scheme = components.scheme.lowercaseString;
	if (!(scheme.length > 0
			&& ([scheme isEqualToString:@"http"]
				|| [scheme isEqualToString:@"https"]
				|| [scheme isEqualToString:@"udp"])
			&& components.host.length > 0
			&& components.user == nil)) {
		return false;
	}
	if (components.port != nil
		&& (components.port.longLongValue <= 0 || components.port.longLongValue > 65535)) {
		return false;
	}

	NSString* host = components.host;
	const char* hostBytes = host.UTF8String;
	struct in_addr ipv4;
	struct in6_addr ipv6;
	if ([host containsString:@":"]) {
		return hostBytes != nullptr && inet_pton(AF_INET6, hostBytes, &ipv6) == 1;
	}
	bool numericDottedHost = host.length > 0;
	for (NSUInteger index = 0; index < host.length; ++index) {
		unichar character = [host characterAtIndex:index];
		if ((character < '0' || character > '9') && character != '.') {
			numericDottedHost = false;
			break;
		}
	}
	if (numericDottedHost) {
		return hostBytes != nullptr && inet_pton(AF_INET, hostBytes, &ipv4) == 1;
	}

	NSArray<NSString*>* labels = [host componentsSeparatedByString:@"."];
	if (labels.count > 1 && [labels.lastObject length] == 0) {
		labels = [labels subarrayWithRange:NSMakeRange(0, labels.count - 1)];
	}
	for (NSString* label in labels) {
		if (label.length == 0 || label.length > 63) {
			return false;
		}
		unichar first = [label characterAtIndex:0];
		unichar last = [label characterAtIndex:label.length - 1];
		if (!((first >= 'A' && first <= 'Z') || (first >= 'a' && first <= 'z')
			|| (first >= '0' && first <= '9'))
			|| !((last >= 'A' && last <= 'Z') || (last >= 'a' && last <= 'z')
				|| (last >= '0' && last <= '9'))) {
			return false;
		}
		for (NSUInteger index = 0; index < label.length; ++index) {
			unichar character = [label characterAtIndex:index];
			const bool alphaNumeric = (character >= 'A' && character <= 'Z')
				|| (character >= 'a' && character <= 'z')
				|| (character >= '0' && character <= '9');
			if (!alphaNumeric && character != '-') {
				return false;
			}
		}
	}
	return labels.count > 0;
}

bool trackerTiersValue(
	NSDictionary* dict,
	TrackerTiers& result,
	NSError** error)
{
	if (dict[jsonKey("trackers")] != nil
		|| dict[jsonKey("addedURLs")] != nil
		|| dict[jsonKey("removedURLs")] != nil) {
		setInvalidArgument(error, @"mixed or scalar tracker payload is unsupported");
		return false;
	}
	id value = dict[jsonKey("tracker-tiers")];
	if (![value isKindOfClass:[NSArray class]]) {
		setInvalidArgument(error, @"tracker-tiers must be an array of arrays");
		return false;
	}
	NSArray* tiers = (NSArray*)value;
	std::size_t total = 0;
	result.reserve(tiers.count);
	for (id tierValue in tiers) {
		if (![tierValue isKindOfClass:[NSArray class]]) {
			setInvalidArgument(error, @"tracker-tiers must contain arrays");
			return false;
		}
		NSArray* tier = (NSArray*)tierValue;
		if (tier.count == 0) {
			setInvalidArgument(error, @"tracker-tiers cannot contain an empty tier");
			return false;
		}
		std::vector<std::string> urls;
		urls.reserve(tier.count);
		for (id urlValue in tier) {
			if (![urlValue isKindOfClass:[NSString class]]
				|| !validTrackerURLValue((NSString*)urlValue)) {
				setInvalidArgument(error, @"tracker-tiers contains an invalid URL");
				return false;
			}
			++total;
			if (total > 512) {
				setInvalidArgument(error, @"tracker-tiers exceeds the URL limit");
				return false;
			}
			urls.emplace_back([(NSString*)urlValue UTF8String]);
		}
		result.emplace_back(std::move(urls));
	}
	return true;
}

// The torrent-file field travels base64 because JSON strings are not a safe
// byte container; the C++ side receives the raw bytes back.
std::vector<char> base64ToBytes(NSDictionary* dict, const char* key)
{
	NSData* data = [[NSData alloc] initWithBase64EncodedString:stringValue(dict, key, @"")
													options:0];
	std::vector<char> bytes;
	if (data.length > 0) {
		bytes.assign(static_cast<const char*>(data.bytes),
			static_cast<const char*>(data.bytes) + data.length);
	}
	return bytes;
}

NSString* bytesToBase64(const std::vector<char>& bytes)
{
	if (bytes.empty()) {
		return @"";
	}
	return [[[NSData alloc] initWithBytes:bytes.data() length:bytes.size()] base64EncodedStringWithOptions:0];
}

NSError* toNSError(BridgeError code, const std::string& message)
{
	return [NSError errorWithDomain:TorrentinoEngineBridgeErrorDomain
							   code:static_cast<NSInteger>(code)
						   userInfo:@{
							   NSLocalizedDescriptionKey :
								   [NSString stringWithUTF8String:message.empty() ? "engine error" : message.c_str()],
						   }];
}

// ---------------------------------------------------------------------------
// DTO <-> JSON conversions.
// ---------------------------------------------------------------------------

SessionConfiguration configurationFromJSON(NSDictionary* dict)
{
	SessionConfiguration config;
	config.listen_port = static_cast<int>(int64Value(dict, "listen-port", 0));
	config.download_dir = std::string(stringValue(dict, "download-dir", @"").UTF8String);
	config.enable_dht = boolValue(dict, "enable-dht", false);
	config.enable_lsd = boolValue(dict, "enable-lsd", false);
	config.enable_upnp = boolValue(dict, "enable-upnp", false);
	config.enable_natpmp = boolValue(dict, "enable-natpmp", false);
	config.encryption_enabled = boolValue(dict, "encryption-enabled", true);
	config.max_connections = static_cast<int>(int64Value(dict, "max-connections", 120));
	config.max_active_downloads = static_cast<int>(int64Value(dict, "max-active-downloads", 4));
	config.max_active_seeds = static_cast<int>(int64Value(dict, "max-active-seeds", 8));
	config.max_connection_attempts = static_cast<int>(int64Value(dict, "max-connection-attempts", 20));
	config.cache_bytes = int64Value(dict, "cache-bytes", 64 * 1024 * 1024);
	config.max_download_bytes_per_sec = int64Value(dict, "max-download-bytes-per-sec", 0);
	config.max_upload_bytes_per_sec = int64Value(dict, "max-upload-bytes-per-sec", 0);
	NSDictionary* proxy = dict[jsonKey("proxy")];
	if ([proxy isKindOfClass:[NSDictionary class]]) {
		config.proxy_kind = std::string(stringValue(proxy, "kind", @"none").UTF8String);
		config.proxy_host = std::string(stringValue(proxy, "host", @"").UTF8String);
		config.proxy_port = static_cast<uint16_t>(uint32Value(proxy, "port", 0));
		config.proxy_username = std::string(stringValue(proxy, "username", @"").UTF8String);
		// SEC-1 memory-only credential (WP13-SEC-HARDEN-001); tolerated to be
		// absent so configurations from older coordinators decode unchanged.
		config.proxy_password = std::string(stringValue(proxy, "password", @"").UTF8String);
	}
	config.peer_id_prefix = std::string(stringValue(dict, "peer-id-prefix", @"-TT0400-").UTF8String);
	config.operation_timeout_ms = uint32Value(dict, "operation-timeout-ms", 10000);
	config.alert_queue_size = uint32Value(dict, "alert-queue-size", 8000);
	return config;
}

TorrentLimits torrentLimitsFromJSON(NSDictionary* dict)
{
	NSDictionary* limits = dict[jsonKey("limits")];
	if (![limits isKindOfClass:[NSDictionary class]]) {
		limits = @{};
	}
	TorrentLimits result;
	result.max_download_bytes_per_sec = optionalInt64Value(limits, "maxDownloadBytesPerSec");
	result.max_upload_bytes_per_sec = optionalInt64Value(limits, "maxUploadBytesPerSec");
	result.ratio_limit = optionalDoubleValue(limits, "ratioLimit");
	result.seed_time_seconds = optionalInt64Value(limits, "seedTimeSeconds");
	return result;
}

AddSpecification addSpecificationFromJSON(NSDictionary* dict)
{
	AddSpecification spec;
	spec.torrent_file = base64ToBytes(dict, "torrent-file");
	spec.magnet_uri = std::string(stringValue(dict, "magnet-uri", @"").UTF8String);
	spec.save_path = std::string(stringValue(dict, "save-path", @"").UTF8String);
	spec.paused = boolValue(dict, "paused", false);
	// WP22.D7 (ADR-022): missing key = false, so every existing caller adds a
	// normal torrent exactly as before.
	spec.metadata_only = boolValue(dict, "metadata-only", false);
	// Per-task policy: missing key = -1 (engine default), present = 0/1.
	spec.enable_dht = (int)int64Value(dict, "enable-dht", -1);
	spec.enable_pex = (int)int64Value(dict, "enable-pex", -1);
	spec.enable_lsd = (int)int64Value(dict, "enable-lsd", -1);
	return spec;
}

// Shared WP22.D5/WP22.D7 boundary contract: the vector must be an array of
// integral bytes. Rejection happens here, before any engine state can move.
bool priorityVectorFromJSON(NSDictionary* dict, std::vector<std::uint8_t>& out,
	NSError** error)
{
	id value = dict[jsonKey("priorities")];
	if (![value isKindOfClass:[NSArray class]]) {
		setInvalidArgument(error, @"priorities payload must be an array");
		return false;
	}
	out.reserve(((NSArray*)value).count);
	for (NSNumber* rawPriority in (NSArray*)value) {
		if (![rawPriority isKindOfClass:[NSNumber class]]
			|| rawPriority.doubleValue != rawPriority.longLongValue
			|| rawPriority.longLongValue < 0
			|| rawPriority.longLongValue > 255) {
			setInvalidArgument(error, @"priority entries must be integers in 0...255");
			return false;
		}
		out.push_back(static_cast<std::uint8_t>(rawPriority.unsignedIntValue));
	}
	return true;
}

std::vector<char> rawTorrentBytes(NSData* data)
{
	std::vector<char> bytes;
	if (data.length > 0) {
		bytes.assign(static_cast<const char*>(data.bytes),
			static_cast<const char*>(data.bytes) + data.length);
	}
	return bytes;
}

NSDictionary* bootReportToJSON(const BootReport& report)
{
	return @{
		jsonKey("version") : [NSString stringWithUTF8String:report.version.c_str()],
		jsonKey("peer-id") : [NSString stringWithUTF8String:report.peer_id.c_str()],
		jsonKey("listen-port") : @(report.listen_port),
	};
}

NSDictionary* addResultToJSON(const AddResult& result)
{
	return @{
		jsonKey("torrent-id") : [NSString stringWithUTF8String:result.torrent_id.c_str()],
		jsonKey("info-hash") : [NSString stringWithUTF8String:result.info_hash.c_str()],
		jsonKey("name") : [NSString stringWithUTF8String:result.name.c_str()],
		jsonKey("total-size") : @(result.total_size),
	};
}

NSDictionary* independentTorrentIdentityToJSON(const IndependentTorrentIdentity& identity)
{
	return @{
		jsonKey("has-v1") : @(identity.has_v1),
		jsonKey("has-v2") : @(identity.has_v2),
		jsonKey("v1-hash") : [NSString stringWithUTF8String:identity.v1_hash.c_str()],
		jsonKey("v2-hash") : [NSString stringWithUTF8String:identity.v2_hash.c_str()],
	};
}

NSDictionary* alertToJSON(const EngineAlertDTO& alert)
{
	return @{
		jsonKey("kind") : @(torrentino::bridge::engine_alert_kind_name(alert.kind)),
		jsonKey("torrent-id") : [NSString stringWithUTF8String:alert.torrent_id.c_str()],
		jsonKey("progress") : @(alert.progress),
		jsonKey("state") : @(alert.state),
		jsonKey("error") : [NSString stringWithUTF8String:alert.error.c_str()],
		jsonKey("message") : [NSString stringWithUTF8String:alert.message.c_str()],
		jsonKey("download-rate") : @(alert.download_rate),
		jsonKey("upload-rate") : @(alert.upload_rate),
		jsonKey("downloaded-bytes") : @(alert.downloaded_bytes),
		jsonKey("uploaded-bytes") : @(alert.uploaded_bytes),
		jsonKey("peers-connected") : @(alert.peers_connected),
		jsonKey("seeds-total") : @(alert.seeds_total),
		jsonKey("name") : [NSString stringWithUTF8String:alert.name.c_str()],
		jsonKey("total-size") : @(alert.total_size),
		jsonKey("flags") : @(alert.flags),
	};
}

NSDictionary* healthToJSON(const HealthDTO& health)
{
	return @{
		jsonKey("uptime-seconds") : @(health.uptime_seconds),
		jsonKey("active-torrents") : @(health.active_torrents),
		jsonKey("download-rate") : @(health.download_rate),
		jsonKey("upload-rate") : @(health.upload_rate),
		jsonKey("alerts-seen") : @(health.alerts_seen),
		jsonKey("running") : @(health.running),
	};
}

NSDictionary* appliedLimitsToJSON(const AppliedTorrentLimits& limits)
{
	return @{
		jsonKey("max-download-bytes-per-sec") : @(limits.max_download_bytes_per_sec),
		jsonKey("max-upload-bytes-per-sec") : @(limits.max_upload_bytes_per_sec),
	};
}

RemovalToken removalTokenFromJSON(NSDictionary* dict)
{
	RemovalToken token;
	token.torrent_id = std::string(stringValue(dict, "torrent-id", @"").UTF8String);
	token.nonce = static_cast<uint64_t>(int64Value(dict, "nonce", 0));
	return token;
}

NSDictionary* removalTokenToJSON(const RemovalToken& token)
{
	return @{
		jsonKey("torrent-id") : [NSString stringWithUTF8String:token.torrent_id.c_str()],
		jsonKey("nonce") : @(token.nonce),
	};
}

NSDictionary* removalResultToJSON(const RemovalResult& result)
{
	return @{
		jsonKey("torrent-id") : [NSString stringWithUTF8String:result.torrent_id.c_str()],
	};
}

NSDictionary* resumeDataToJSON(const ResumeDataDTO& resume)
{
	return @{
		jsonKey("torrent-id") : [NSString stringWithUTF8String:resume.torrent_id.c_str()],
		jsonKey("resume-data") : bytesToBase64(resume.resume_data),
	};
}

// Generic trampoline: runs `body`, converts any C++/ObjC exception into an
// NSError in `outError` and returns nil. Without this no engine call can crash
// or throw into Swift.
// @catch cannot bind a C++ type (only ObjC interface pointers), so C++
// exceptions are handled by the inner C++ try/catch (std::exception gets its
// what() into the message) and ObjC exceptions by the outer @catch (id).
template <class Fn>
NSData* runBridge(Fn&& body, NSError* __autoreleasing* error)
{
	@try {
		try {
			return body();
		} catch (const std::exception& e) {
			if (error != nil) {
				*error = toNSError(BridgeError::internal,
					std::string("bridge adapter exception: ") + e.what());
			}
			return nil;
		} catch (...) {
			if (error != nil) {
				*error = toNSError(BridgeError::internal,
					"bridge adapter exception: unknown");
			}
			return nil;
		}
	} @catch (id exception) {
		if (error != nil) {
			*error = toNSError(BridgeError::internal,
				"bridge adapter exception: objective-c");
		}
		return nil;
	}
}

// Converts a C++ Result into (NSData|NSError). The engine methods never throw;
// the trampoline above covers the adapter translation itself.
template <class T, class ToJSON>
NSData* resultToData(const torrentino::bridge::Result<T>& result, ToJSON&& toJSON,
	NSError* __autoreleasing* error, bool* ok = nullptr)
{
	if (result.is_ok()) {
		if (ok != nullptr) {
			*ok = true;
		}
		return fromJSON(toJSON(result.value()));
	}
	if (ok != nullptr) {
		*ok = false;
	}
	if (error != nil) {
		*error = toNSError(result.error_code(), result.error_message());
	}
	return nil;
}

NSData* voidResultToData(const torrentino::bridge::Result<void>& result,
	NSError* __autoreleasing* error)
{
	if (result.is_ok()) {
		return fromJSON(@{});
	}
	if (error != nil) {
		*error = toNSError(result.error_code(), result.error_message());
	}
	return nil;
}

} // namespace

@implementation TorrentinoEngineBridgeAdapter {
	std::unique_ptr<EngineBridge> _engine;
}

- (instancetype)init
{
	self = [super init];
	if (self != nil) {
		_engine = std::make_unique<EngineBridge>();
	}
	return self;
}

- (void)dealloc
{
	// Deterministic teardown: the C++ session must be shut down before the
	// facade is destroyed so libtorrent's network thread is joined cleanly.
	if (_engine) {
		_engine->shutdown();
	}
}

- (nullable NSData *)startEngineWithConfigurationData:(NSData *)configurationData
														 error:(NSError *_Nullable *_Nullable)error
{
	return runBridge([&]() -> NSData* {
		NSDictionary* dict = toJSON(configurationData, error);
		if (dict == nil) {
			return nil;
		}
		const SessionConfiguration config = configurationFromJSON(dict);
		auto result = _engine->start(config);
		return resultToData(result, bootReportToJSON, error);
	}, error);
}

- (nullable NSData *)applyEngineWithConfigurationData:(NSData *)configurationData
														 error:(NSError *_Nullable *_Nullable)error
{
	return runBridge([&]() -> NSData* {
		NSDictionary* dict = toJSON(configurationData, error);
		if (dict == nil) {
			return nil;
		}
		const SessionConfiguration config = configurationFromJSON(dict);
		return voidResultToData(_engine->apply(config), error);
	}, error);
}

- (nullable NSData *)addTorrentWithSpecificationData:(NSData *)specificationData
															   error:(NSError *_Nullable *_Nullable)error
{
	return runBridge([&]() -> NSData* {
		NSDictionary* dict = toJSON(specificationData, error);
		if (dict == nil) {
			return nil;
		}
		const AddSpecification spec = addSpecificationFromJSON(dict);
		auto result = _engine->add(spec);
		return resultToData(result, addResultToJSON, error);
	}, error);
}

- (nullable NSData *)verifyTorrentWithData:(NSData *)torrentData
															 error:(NSError *_Nullable *_Nullable)error
{
	return runBridge([&]() -> NSData* {
		if (torrentData == nil || torrentData.length == 0) {
			setInvalidArgument(error, @"empty torrent payload");
			return nil;
		}
		const std::vector<char> bytes = rawTorrentBytes(torrentData);
		return resultToData(_engine->verifyTorrent(bytes), independentTorrentIdentityToJSON, error);
	}, error);
}

- (nullable NSData *)pauseWithPayloadData:(NSData *)payloadData
									error:(NSError *_Nullable *_Nullable)error
{
	return runBridge([&]() -> NSData* {
		NSDictionary* dict = toJSON(payloadData, error);
		if (dict == nil) {
			return nil;
		}
		const TorrentRecordID id = std::string(stringValue(dict, "torrent-id", @"").UTF8String);
		return voidResultToData(_engine->pause(id), error);
	}, error);
}

- (nullable NSData *)resumeWithPayloadData:(NSData *)payloadData
									 error:(NSError *_Nullable *_Nullable)error
{
	return runBridge([&]() -> NSData* {
		NSDictionary* dict = toJSON(payloadData, error);
		if (dict == nil) {
			return nil;
		}
		const TorrentRecordID id = std::string(stringValue(dict, "torrent-id", @"").UTF8String);
		return voidResultToData(_engine->resume(id), error);
	}, error);
}

- (nullable NSData *)recheckWithPayloadData:(NSData *)payloadData
															 error:(NSError *_Nullable *_Nullable)error
{
	return runBridge([&]() -> NSData* {
		NSDictionary* dict = toJSON(payloadData, error);
		if (dict == nil) {
			return nil;
		}
		const TorrentRecordID id = std::string(stringValue(dict, "torrent-id", @"").UTF8String);
		return voidResultToData(_engine->requestRecheck(id), error);
	}, error);
}

- (nullable NSData *)moveStorageWithPayloadData:(NSData *)payloadData
										  error:(NSError *_Nullable *_Nullable)error
{
	return runBridge([&]() -> NSData* {
		NSDictionary* dict = toJSON(payloadData, error);
		if (dict == nil) {
			return nil;
		}
		const TorrentRecordID id = std::string(stringValue(dict, "torrent-id", @"").UTF8String);
		const std::string path = std::string(stringValue(dict, "path", @"").UTF8String);
		return voidResultToData(_engine->moveStorage(id, path), error);
	}, error);
}

- (nullable NSData *)setLimitsWithPayloadData:(NSData *)payloadData
																 error:(NSError *_Nullable *_Nullable)error
{
	return runBridge([&]() -> NSData* {
		NSDictionary* dict = toJSON(payloadData, error);
		if (dict == nil) {
			return nil;
		}
		const TorrentRecordID id = std::string(stringValue(dict, "torrent-id", @"").UTF8String);
		return voidResultToData(_engine->setLimits(id, torrentLimitsFromJSON(dict)), error);
	}, error);
}

- (nullable NSData *)setFilePrioritiesWithPayloadData:(NSData *)payloadData
												error:(NSError *_Nullable *_Nullable)error
{
	return runBridge([&]() -> NSData* {
		NSDictionary* dict = toJSON(payloadData, error);
		if (dict == nil) {
			return nil;
		}
		const TorrentRecordID id = std::string(stringValue(dict, "torrent-id", @"").UTF8String);
		// Full-vector boundary contract shared with the D7 commit payload.
		std::vector<std::uint8_t> priorities;
		if (!priorityVectorFromJSON(dict, priorities, error)) {
			return nil;
		}
		return voidResultToData(_engine->setFilePriorities(id, priorities), error);
	}, error);
}

- (nullable NSData *)commitMetadataOnlyWithPayloadData:(NSData *)payloadData
												error:(NSError *_Nullable *_Nullable)error
{
	return runBridge([&]() -> NSData* {
		NSDictionary* dict = toJSON(payloadData, error);
		if (dict == nil) {
			return nil;
		}
		const TorrentRecordID id = std::string(stringValue(dict, "torrent-id", @"").UTF8String);
		std::vector<std::uint8_t> priorities;
		if (!priorityVectorFromJSON(dict, priorities, error)) {
			return nil;
		}
		const bool paused = boolValue(dict, "paused", false);
		return voidResultToData(_engine->commitMetadataOnly(id, priorities, paused), error);
	}, error);
}

- (nullable NSData *)currentLimitsWithPayloadData:(NSData *)payloadData
																 error:(NSError *_Nullable *_Nullable)error
{
	return runBridge([&]() -> NSData* {
		NSDictionary* dict = toJSON(payloadData, error);
		if (dict == nil) {
			return nil;
		}
		const TorrentRecordID id = std::string(stringValue(dict, "torrent-id", @"").UTF8String);
		return resultToData(_engine->currentLimits(id), appliedLimitsToJSON, error);
	}, error);
}

- (nullable NSData *)editTrackersWithPayloadData:(NSData *)payloadData
															 error:(NSError *_Nullable *_Nullable)error
{
	return runBridge([&]() -> NSData* {
		NSDictionary* dict = toJSON(payloadData, error);
		if (dict == nil) {
			return nil;
		}
		const TorrentRecordID id = std::string(stringValue(dict, "torrent-id", @"").UTF8String);
		TrackerTiers trackerTiers;
		if (!trackerTiersValue(dict, trackerTiers, error)) {
			return nil;
		}
		return voidResultToData(_engine->editTrackers(id, trackerTiers), error);
	}, error);
}

- (nullable NSData *)reannounceWithPayloadData:(NSData *)payloadData
															 error:(NSError *_Nullable *_Nullable)error
{
	return runBridge([&]() -> NSData* {
		NSDictionary* dict = toJSON(payloadData, error);
		if (dict == nil) {
			return nil;
		}
		const TorrentRecordID id = std::string(stringValue(dict, "torrent-id", @"").UTF8String);
		return voidResultToData(_engine->reannounce(id), error);
	}, error);
}

- (nullable NSData *)prepareRemovalWithPayloadData:(NSData *)payloadData
											 error:(NSError *_Nullable *_Nullable)error
{
	return runBridge([&]() -> NSData* {
		NSDictionary* dict = toJSON(payloadData, error);
		if (dict == nil) {
			return nil;
		}
		// WP-10 (Gate 6): the bridge accepts NO delete-files flag — permanent
		// deletion is unreachable from the ObjC adapter public API.
		const TorrentRecordID id = std::string(stringValue(dict, "torrent-id", @"").UTF8String);
		auto result = _engine->prepareRemoval(id);
		return resultToData(result, removalTokenToJSON, error);
	}, error);
}

- (nullable NSData *)commitRemovalWithTokenData:(NSData *)tokenData
										  error:(NSError *_Nullable *_Nullable)error
{
	return runBridge([&]() -> NSData* {
		NSDictionary* dict = toJSON(tokenData, error);
		if (dict == nil) {
			return nil;
		}
		const RemovalToken token = removalTokenFromJSON(dict);
		auto result = _engine->commitRemoval(token);
		return resultToData(result, removalResultToJSON, error);
	}, error);
}

- (nullable NSData *)drainAlertsWithPayloadData:(NSData *)payloadData
										  error:(NSError *_Nullable *_Nullable)error
{
	return runBridge([&]() -> NSData* {
		std::size_t maxCount = 0;
		if (payloadData.length > 0) {
			NSDictionary* dict = toJSON(payloadData, error);
			if (dict == nil) {
				return nil;
			}
			const int64_t raw = int64Value(dict, "max-count", 0);
			maxCount = raw > 0 ? static_cast<std::size_t>(raw) : 0;
		}
		const std::vector<EngineAlertDTO> alerts = _engine->drainAlerts(maxCount);
		NSMutableArray* array = [NSMutableArray arrayWithCapacity:alerts.size()];
		for (const EngineAlertDTO& alert : alerts) {
			[array addObject:alertToJSON(alert)];
		}
		return fromJSON(array);
	}, error);
}

- (nullable NSData *)requestResumeDataWithPayloadData:(NSData *)payloadData
												error:(NSError *_Nullable *_Nullable)error
{
	return runBridge([&]() -> NSData* {
		NSDictionary* dict = toJSON(payloadData, error);
		if (dict == nil) {
			return nil;
		}
		const TorrentRecordID id = std::string(stringValue(dict, "torrent-id", @"").UTF8String);
		auto result = _engine->requestResumeData(id);
		return resultToData(result, resumeDataToJSON, error);
	}, error);
}

- (nullable NSData *)healthWithError:(NSError *_Nullable *_Nullable)error
{
	return runBridge([&]() -> NSData* {
		const HealthDTO health = _engine->health();
		return fromJSON(healthToJSON(health));
	}, error);
}

- (nullable NSData *)setOperationTimeoutWithPayloadData:(NSData *)payloadData
												  error:(NSError *_Nullable *_Nullable)error
{
	return runBridge([&]() -> NSData* {
		NSDictionary* dict = toJSON(payloadData, error);
		if (dict == nil) {
			return nil;
		}
		const uint32_t millis = uint32Value(dict, "millis", 0);
		return voidResultToData(_engine->setOperationTimeout(millis), error);
	}, error);
}

- (void)shutdown
{
	if (_engine) {
		_engine->shutdown();
	}
}

@end
