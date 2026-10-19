#pragma once
// Update check + auto-install against https://nanor.ru/foobar/updates.json,
// shared by the nanor.ru foobar2000 components.
//
// Manifest format:
// {
//   "foo_classic_ui": {
//     "version": "0.15",
//     "url":     "https://nanor.ru/foobar/",                                              (page, fallback)
//     "file":    "https://nanor.ru/foobar2000-mac-plugins/classic-ui/foo_classic_ui.fb2k-component",
//     "sha256":  "…64 hex…",
//     "notes":   "Что нового"
//   }, …
// }
//
// Include from exactly one Objective-C++ file per component and declare:
//   NANOR_UPDATE_COMPONENT("foo_classic_ui", "Classic UI", COMPONENT_VERSION)
// The component then checks once a day, shortly after foobar2000 starts.

#import <Cocoa/Cocoa.h>
#include <CommonCrypto/CommonDigest.h>

namespace nanor_update {
	static NSString * const kManifestURL = @"https://nanor.ru/foobar/updates.json";

	// -1 / 0 / 1, numeric per dot-separated part ("0.10" > "0.9").
	static inline int compareVersions(NSString * a, NSString * b) {
		NSArray * pa = [a componentsSeparatedByString:@"."], * pb = [b componentsSeparatedByString:@"."];
		for (NSUInteger i = 0; i < MAX(pa.count, pb.count); ++i) {
			NSInteger x = i < pa.count ? [pa[i] integerValue] : 0, y = i < pb.count ? [pb[i] integerValue] : 0;
			if (x != y) return x < y ? -1 : 1;
		}
		return 0;
	}

	static inline NSURLSession * session() {
		NSURLSessionConfiguration * cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
		cfg.timeoutIntervalForRequest = 30;
		cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
		return [NSURLSession sessionWithConfiguration:cfg];
	}

	static inline void fetchManifest(void (^done)(NSDictionary * manifest, NSError * error)) {
		[[session() dataTaskWithURL:[NSURL URLWithString:kManifestURL]
			completionHandler:^(NSData * data, NSURLResponse * resp, NSError * err) {
				NSDictionary * json = nil;
				if (data && !err) {
					id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
					if ([obj isKindOfClass:NSDictionary.class]) json = obj;
				}
				dispatch_async(dispatch_get_main_queue(), ^{ done(json, err); });
			}] resume];
	}

	// Entry for `key` if it is newer than `current`, else nil.
	static inline NSDictionary * newerEntry(NSDictionary * manifest, NSString * key, NSString * current) {
		NSDictionary * e = manifest[key];
		if (![e isKindOfClass:NSDictionary.class] || ![e[@"version"] isKindOfClass:NSString.class]) return nil;
		return compareVersions(current, e[@"version"]) < 0 ? e : nil;
	}

	static inline NSString * str(NSDictionary * e, NSString * k) { return [e[k] isKindOfClass:NSString.class] ? e[k] : nil; }

	static inline NSString * sha256Hex(NSData * d) {
		unsigned char h[CC_SHA256_DIGEST_LENGTH];
		CC_SHA256(d.bytes, (CC_LONG)d.length, h);
		NSMutableString * s = [NSMutableString string];
		for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) [s appendFormat:@"%02x", h[i]];
		return s;
	}

	static inline void message(NSString * title, NSString * text) {
		NSAlert * a = [NSAlert new];
		a.messageText = title;
		a.informativeText = text ?: @"";
		[a runModal];
	}

	// Quit foobar2000 and start it again once it has exited.
	static inline void relaunch() {
		NSString * app = NSBundle.mainBundle.bundlePath;
		NSString * script = [NSString stringWithFormat:@"while /bin/kill -0 %d 2>/dev/null; do sleep 0.3; done; /usr/bin/open \"%@\"",
							 NSProcessInfo.processInfo.processIdentifier, app];
		NSTask * t = [NSTask new];
		t.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
		t.arguments = @[@"-c", script];
		[t launchAndReturnError:nil];
		[NSApp terminate:nil];
	}

	// Folder foobar2000 loads this component from: <profile>/user-components/<key>/
	static inline NSString * componentFolder(NSString * key) {
		NSString * profile = [NSString stringWithUTF8String:core_api::get_profile_path()];
		if ([profile hasPrefix:@"file://"]) profile = [profile substringFromIndex:7];
		return [[profile stringByAppendingPathComponent:@"user-components"] stringByAppendingPathComponent:key];
	}

	// Replaces <key>.component with the one from the verified package. Returns an error text or nil.
	static inline NSString * installPackage(NSData * package, NSString * key) {
		NSFileManager * fm = NSFileManager.defaultManager;
		NSString * tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"nanor-update-%@-%@", key, NSUUID.UUID.UUIDString]];
		[fm createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:nil];
		NSString * zip = [tmp stringByAppendingPathComponent:@"package.zip"];
		[package writeToFile:zip atomically:YES];

		NSTask * unzip = [NSTask new];
		unzip.executableURL = [NSURL fileURLWithPath:@"/usr/bin/ditto"];
		unzip.arguments = @[@"-x", @"-k", zip, tmp];
		if (![unzip launchAndReturnError:nil]) return @"Could not unpack the update.";
		[unzip waitUntilExit];
		NSString * bundleName = [key stringByAppendingPathExtension:@"component"];
		NSString * fresh = [[tmp stringByAppendingPathComponent:@"mac"] stringByAppendingPathComponent:bundleName];
		if (unzip.terminationStatus != 0 || ![fm fileExistsAtPath:fresh]) return @"The update package has an unexpected layout.";

		NSString * folder = componentFolder(key);
		NSString * target = [folder stringByAppendingPathComponent:bundleName];
		// Previous version is kept outside user-components so foobar2000 never loads it twice.
		NSString * backupDir = [folder.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"user-components-backup"];
		NSString * backup = [backupDir stringByAppendingPathComponent:bundleName];
		[fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
		[fm createDirectoryAtPath:backupDir withIntermediateDirectories:YES attributes:nil error:nil];
		[fm removeItemAtPath:backup error:nil];

		NSError * err = nil;
		const BOOL hadOld = [fm fileExistsAtPath:target];
		if (hadOld && ![fm moveItemAtPath:target toPath:backup error:&err]) return err.localizedDescription;
		if (![fm moveItemAtPath:fresh toPath:target error:&err]) {
			if (hadOld) [fm moveItemAtPath:backup toPath:target error:nil]; // put the old one back
			return err.localizedDescription;
		}
		[fm removeItemAtPath:tmp error:nil];
		return nil;
	}

	// Downloads, verifies and installs one package; calls done(nil) on success or done(problem).
	static inline void fetchAndInstall(NSString * key, NSDictionary * entry, void (^done)(NSString * problem)) {
		NSString * file = str(entry, @"file"), * sha = str(entry, @"sha256").lowercaseString;
		[[session() dataTaskWithURL:[NSURL URLWithString:file] completionHandler:^(NSData * data, NSURLResponse * resp, NSError * err) {
			dispatch_async(dispatch_get_main_queue(), ^{
				if (!data || err) done(err.localizedDescription ?: @"Download failed.");
				else if (![sha256Hex(data) isEqualToString:sha]) done(@"The downloaded file does not match its checksum. Nothing was installed.");
				else done(installPackage(data, key));
			});
		}] resume];
	}

	static inline BOOL canAutoInstall(NSDictionary * entry) { return str(entry, @"file") && str(entry, @"sha256").length == 64; }

	// Several updates at once: one prompt, sequential installs, one restart.
	// items: @[ @[key, title, currentVersion, entry], … ]
	static inline void offerMany(NSArray<NSArray *> * items) {
		NSMutableArray * lines = [NSMutableArray array];
		BOOL allAuto = YES;
		for (NSArray * it in items) {
			[lines addObject:[NSString stringWithFormat:@"• %@ %@ → %@", it[1], it[2], it[3][@"version"]]];
			allAuto = allAuto && canAutoInstall(it[3]);
		}
		NSAlert * a = [NSAlert new];
		a.messageText = @"Plugin updates are available";
		a.informativeText = [lines componentsJoinedByString:@"\n"];
		[a addButtonWithTitle:allAuto ? @"Install All and Restart" : @"Open Download Page"];
		[a addButtonWithTitle:@"Later"];
		if ([a runModal] != NSAlertFirstButtonReturn) return;
		if (!allAuto) { [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:str(items[0][3], @"url") ?: @"https://nanor.ru/"]]; return; }

		__block NSMutableArray * problems = [NSMutableArray array];
		__block void (^next)(NSUInteger);
		__block void (^nextRef)(NSUInteger);
		next = ^(NSUInteger i) {
			if (i >= items.count) {
				NSAlert * b = [NSAlert new];
				b.messageText = problems.count ? @"Some updates could not be installed" : @"Updates installed";
				b.informativeText = problems.count ? [problems componentsJoinedByString:@"\n"] : @"Restart foobar2000 to start using them.";
				[b addButtonWithTitle:@"Restart Now"];
				[b addButtonWithTitle:@"Later"];
				if ([b runModal] == NSAlertFirstButtonReturn) relaunch();
				nextRef = nil;
				return;
			}
			NSArray * it = items[i];
			fetchAndInstall(it[0], it[3], ^(NSString * problem) {
				if (problem) [problems addObject:[NSString stringWithFormat:@"%@: %@", it[1], problem]];
				nextRef(i + 1);
			});
		};
		nextRef = next;
		next(0);
	}

	static inline void downloadAndInstall(NSString * key, NSString * title, NSDictionary * entry) {
		NSString * file = str(entry, @"file"), * sha = str(entry, @"sha256").lowercaseString;
		if (!file || sha.length != 64) { // manifest without auto-install data: open the page instead
			[NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:str(entry, @"url") ?: @"https://nanor.ru/"]];
			return;
		}
		[[session() dataTaskWithURL:[NSURL URLWithString:file] completionHandler:^(NSData * data, NSURLResponse * resp, NSError * err) {
			dispatch_async(dispatch_get_main_queue(), ^{
				NSString * problem = nil;
				if (!data || err) problem = err.localizedDescription ?: @"Download failed.";
				else if (![sha256Hex(data) isEqualToString:sha]) problem = @"The downloaded file does not match its checksum. Nothing was installed.";
				else problem = installPackage(data, key);
				if (problem) { message([NSString stringWithFormat:@"Could not update %@", title], problem); return; }

				NSAlert * a = [NSAlert new];
				a.messageText = [NSString stringWithFormat:@"%@ %@ installed", title, entry[@"version"]];
				a.informativeText = @"Restart foobar2000 to start using it.";
				[a addButtonWithTitle:@"Restart Now"];
				[a addButtonWithTitle:@"Later"];
				if ([a runModal] == NSAlertFirstButtonReturn) relaunch();
			});
		}] resume];
	}

	static inline void showUpdate(NSString * key, NSString * title, NSString * current, NSDictionary * entry, BOOL manual) {
		NSString * skipKey = [NSString stringWithFormat:@"nanor.update.%@.skip", key];
		if (!manual && [[NSUserDefaults.standardUserDefaults stringForKey:skipKey] isEqualToString:entry[@"version"]]) return;
		const BOOL canInstall = str(entry, @"file") && str(entry, @"sha256").length == 64;
		NSAlert * a = [NSAlert new];
		a.messageText = [NSString stringWithFormat:@"%@ %@ is available", title, entry[@"version"]];
		NSString * notes = str(entry, @"notes") ?: @"";
		a.informativeText = [NSString stringWithFormat:@"You have version %@.%@%@", current, notes.length ? @"\n\n" : @"", notes];
		[a addButtonWithTitle:canInstall ? @"Install and Restart" : @"Download"];
		[a addButtonWithTitle:@"Later"];
		if (!manual) [a addButtonWithTitle:@"Skip This Version"];
		NSModalResponse r = [a runModal];
		if (r == NSAlertFirstButtonReturn) downloadAndInstall(key, title, entry);
		else if (r == NSAlertThirdButtonReturn) [NSUserDefaults.standardUserDefaults setObject:entry[@"version"] forKey:skipKey];
	}

	// Automatic daily check for one component.
	static inline void autoCheck(NSString * key, NSString * title, NSString * current) {
		NSString * lastKey = [NSString stringWithFormat:@"nanor.update.%@.last", key];
		NSDate * last = [NSUserDefaults.standardUserDefaults objectForKey:lastKey];
		if ([last isKindOfClass:NSDate.class] && -last.timeIntervalSinceNow < 24 * 3600) return;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			fetchManifest(^(NSDictionary * manifest, NSError * err) {
				if (!manifest) return; // offline or site down: try again next launch
				[NSUserDefaults.standardUserDefaults setObject:[NSDate date] forKey:lastKey];
				if (NSDictionary * e = newerEntry(manifest, key, current)) showUpdate(key, title, current, e, NO);
			});
		});
	}
}

#define NANOR_UPDATE_COMPONENT(KEY, TITLE, VERSION) \
	namespace { class nanor_update_initquit : public initquit { \
		public: void on_init() override { nanor_update::autoCheck(@KEY, @TITLE, @VERSION); } \
	}; FB2K_SERVICE_FACTORY(nanor_update_initquit); }
