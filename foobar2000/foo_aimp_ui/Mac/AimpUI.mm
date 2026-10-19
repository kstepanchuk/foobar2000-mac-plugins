#import "stdafx.h"
#include "../version.h"
#include "../../nanor_shared/NanorUpdate.h"
#include <SDK/ui_element_mac.h>
#include <SDK/commonObjects-Apple.h>
#include <SDK/album_art.h>
#include <thread>
#include <vector>

// AIMP-style UI elements: header (now playing + transport), playlist tabs,
// grouped two-line playlist, footer (add/remove, quick search, totals).

static NSColor * accent() { return [NSColor colorWithSRGBRed:0.95 green:0.55 blue:0.13 alpha:1]; }

static NSString * str(const char * s) { return [NSString stringWithUTF8String:s ? s : ""] ?: @""; }

static titleformat_object::ptr compileTF(const char * spec) {
	titleformat_object::ptr p;
	titleformat_compiler::get()->compile_safe(p, spec);
	return p;
}

static NSString * formatDuration(double sec) {
	long s = (long)(sec + 0.5);
	if (s >= 86400) return [NSString stringWithFormat:@"%ld:%02ld:%02ld:%02ld", s / 86400, s / 3600 % 24, s / 60 % 60, s % 60];
	if (s >= 3600) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", s / 3600, s / 60 % 60, s % 60];
	return [NSString stringWithFormat:@"%ld:%02ld", s / 60, s % 60];
}

static NSString * formatSize(uint64_t bytes) {
	return [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
}

static NSButton * symbolButton(NSString * symbol, CGFloat pt, NSString * tip, id target, SEL action) {
	NSImageSymbolConfiguration * cfg = [NSImageSymbolConfiguration configurationWithPointSize:pt weight:NSFontWeightRegular];
	NSImage * img = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip] imageWithSymbolConfiguration:cfg];
	NSButton * b = [NSButton buttonWithImage:img target:target action:action];
	b.bordered = NO;
	b.toolTip = tip;
	b.contentTintColor = NSColor.labelColor;
	b.refusesFirstResponder = YES;
	b.focusRingType = NSFocusRingTypeNone;
	return b;
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

@interface FooAimpHeaderView : NSView
@end
@implementation FooAimpHeaderView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)r {
	[NSColor.windowBackgroundColor setFill];
	NSRectFill(self.bounds);
}
@end

@interface FooAimpHeader : NSViewController
@end

@implementation FooAimpHeader {
	NSImageView * _cover;
	NSTextField * _title, * _artist, * _album, * _tech, * _time;
	NSButton * _prev, * _stop, * _play, * _pause, * _next, * _shuffle, * _repeat, * _volIcon;
	NSSlider * _volume;
	NSTimer * _timer;
	titleformat_object::ptr _tfTitle, _tfArtist, _tfAlbum, _tfTech;
	metadb_handle_ptr _shownTrack;
	std::shared_ptr<abort_callback_impl> _artAbort;
}

- (NSTextField *)label:(CGFloat)size weight:(NSFontWeight)w secondary:(BOOL)sec {
	NSTextField * f = [NSTextField labelWithString:@""];
	f.font = [NSFont systemFontOfSize:size weight:w];
	f.textColor = sec ? NSColor.secondaryLabelColor : NSColor.labelColor;
	f.lineBreakMode = NSLineBreakByTruncatingTail;
	f.translatesAutoresizingMaskIntoConstraints = NO;
	return f;
}

- (void)loadView {
	FooAimpHeaderView * v = [[FooAimpHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 800, 96)];
	[v.heightAnchor constraintEqualToConstant:96].active = YES;

	_cover = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"music.note" accessibilityDescription:nil]];
	_cover.imageScaling = NSImageScaleProportionallyUpOrDown;
	_cover.wantsLayer = YES;
	_cover.layer.cornerRadius = 3;
	_cover.layer.masksToBounds = YES;
	_cover.contentTintColor = NSColor.tertiaryLabelColor;
	_cover.translatesAutoresizingMaskIntoConstraints = NO;

	_title = [self label:15 weight:NSFontWeightSemibold secondary:NO];
	_artist = [self label:12 weight:NSFontWeightRegular secondary:NO];
	_album = [self label:12 weight:NSFontWeightRegular secondary:YES];
	_tech = [self label:10 weight:NSFontWeightRegular secondary:YES];
	NSStackView * info = [NSStackView stackViewWithViews:@[_title, _artist, _album, _tech]];
	info.orientation = NSUserInterfaceLayoutOrientationVertical;
	info.alignment = NSLayoutAttributeLeading;
	info.spacing = 2;
	info.translatesAutoresizingMaskIntoConstraints = NO;

	_prev = symbolButton(@"backward.end.fill", 16, @"Previous", self, @selector(onPrev:));
	_stop = symbolButton(@"stop.fill", 16, @"Stop", self, @selector(onStop:));
	_play = symbolButton(@"play.fill", 30, @"Play", self, @selector(onPlay:));
	_pause = symbolButton(@"pause.fill", 16, @"Pause", self, @selector(onPause:));
	_next = symbolButton(@"forward.end.fill", 16, @"Next", self, @selector(onNext:));
	NSStackView * transport = [NSStackView stackViewWithViews:@[_prev, _stop, _play, _pause, _next]];
	transport.spacing = 22;
	transport.translatesAutoresizingMaskIntoConstraints = NO;

	_volIcon = symbolButton(@"speaker.wave.2.fill", 13, @"Mute", self, @selector(onMute:));
	_volume = [NSSlider sliderWithValue:1 minValue:0 maxValue:1 target:self action:@selector(onVolume:)];
	_volume.controlSize = NSControlSizeSmall;
	[_volume.widthAnchor constraintEqualToConstant:110].active = YES;
	NSStackView * vol = [NSStackView stackViewWithViews:@[_volIcon, _volume]];
	vol.spacing = 6;

	_shuffle = symbolButton(@"shuffle", 13, @"Shuffle", self, @selector(onShuffle:));
	_repeat = symbolButton(@"repeat", 13, @"Repeat playlist", self, @selector(onRepeat:));
	_time = [self label:12 weight:NSFontWeightRegular secondary:YES];
	_time.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
	NSStackView * modes = [NSStackView stackViewWithViews:@[_shuffle, _repeat, _time]];
	modes.spacing = 12;

	NSStackView * right = [NSStackView stackViewWithViews:@[vol, modes]];
	right.orientation = NSUserInterfaceLayoutOrientationVertical;
	right.alignment = NSLayoutAttributeTrailing;
	right.spacing = 10;
	right.translatesAutoresizingMaskIntoConstraints = NO;

	for (NSView * sub in @[_cover, info, transport, right]) [v addSubview:sub];
	[NSLayoutConstraint activateConstraints:@[
		[_cover.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:8],
		[_cover.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
		[_cover.widthAnchor constraintEqualToConstant:80],
		[_cover.heightAnchor constraintEqualToConstant:80],
		[info.leadingAnchor constraintEqualToAnchor:_cover.trailingAnchor constant:10],
		[info.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
		[info.trailingAnchor constraintLessThanOrEqualToAnchor:transport.leadingAnchor constant:-16],
		[transport.centerXAnchor constraintEqualToAnchor:v.centerXAnchor],
		[transport.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
		[right.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-12],
		[right.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
		[right.leadingAnchor constraintGreaterThanOrEqualToAnchor:transport.trailingAnchor constant:16],
	]];
	[info setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	for (NSTextField * f in @[_title, _artist, _album, _tech])
		[f setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

	self.view = v;

	_tfTitle = compileTF("[%title%]");
	_tfArtist = compileTF("[%artist%]");
	_tfAlbum = compileTF("[%album%][ '('%date%')']");
	_tfTech = compileTF("[%codec%][, $div(%samplerate%,1000) kHz][, %bitrate% kbps][, $caps(%channels%)]");
	[self refresh];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	__weak FooAimpHeader * weakSelf = self;
	_timer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *) { [weakSelf refresh]; }];
}

- (void)dealloc {
	[_timer invalidate];
	if (_artAbort) _artAbort->abort();
}

static size_t orderIndex(const char * name) {
	auto pm = playlist_manager::get();
	for (size_t i = 0, n = pm->playback_order_get_count(); i < n; ++i)
		if (pfc::stringEqualsI_ascii(pm->playback_order_get_name(i), name)) return i;
	return SIZE_MAX;
}

- (void)refresh {
	auto pc = playback_control::get();
	metadb_handle_ptr track;
	const bool playing = pc->get_now_playing(track);

	auto fmt = [&](titleformat_object::ptr const & s) {
		pfc::string8 out;
		pc->playback_format_title(nullptr, out, s, nullptr, playback_control::display_level_all);
		return str(out);
	};

	if (playing) {
		_title.stringValue = fmt(_tfTitle);
		_artist.stringValue = fmt(_tfArtist);
		_album.stringValue = fmt(_tfAlbum);
		_tech.stringValue = fmt(_tfTech);
		const double len = track->get_length();
		_time.stringValue = [NSString stringWithFormat:@"%@ / %@", formatDuration(pc->playback_get_position()), len > 0 ? formatDuration(len) : @"--:--"];
	} else {
		_title.stringValue = @"foobar2000";
		_artist.stringValue = @"";
		_album.stringValue = @"";
		_tech.stringValue = @"";
		_time.stringValue = @"";
	}
	if (track != _shownTrack) { _shownTrack = track; [self loadCover:track]; }

	const BOOL paused = pc->is_paused();
	_play.contentTintColor = playing && !paused ? accent() : NSColor.labelColor;
	_pause.contentTintColor = paused ? accent() : NSColor.labelColor;

	const float db = pc->get_volume();
	_volume.doubleValue = db <= -100 ? 0 : pow(10.0, db / 40.0); // perceptual-ish curve
	_volIcon.image = [NSImage imageWithSystemSymbolName:db <= -100 ? @"speaker.slash.fill" : @"speaker.wave.2.fill" accessibilityDescription:nil];

	auto active = playlist_manager::get()->playback_order_get_active();
	_shuffle.contentTintColor = active == orderIndex("Shuffle (tracks)") ? accent() : NSColor.secondaryLabelColor;
	_repeat.contentTintColor = active == orderIndex("Repeat (playlist)") ? accent() : NSColor.secondaryLabelColor;
}

- (void)loadCover:(metadb_handle_ptr)track {
	if (_artAbort) _artAbort->abort();
	NSImage * placeholder = [NSImage imageWithSystemSymbolName:@"music.note" accessibilityDescription:nil];
	_cover.image = placeholder;
	if (track.is_empty()) return;

	auto abort = std::make_shared<abort_callback_impl>();
	_artAbort = abort;
	__weak FooAimpHeader * weakSelf = self;
	std::thread([abort, track, weakSelf] {
		NSData * data = nil;
		try {
			auto api = album_art_manager_v2::get();
			auto inst = api->open(pfc::list_single_ref_t<metadb_handle_ptr>(track),
								  pfc::list_single_ref_t<GUID>(album_art_ids::cover_front), *abort);
			auto art = inst->query(album_art_ids::cover_front, *abort);
			data = [NSData dataWithBytes:art->get_ptr() length:art->get_size()];
		} catch (...) {}
		if (!data || abort->is_aborting()) return;
		NSImage * img = [[NSImage alloc] initWithData:data];
		dispatch_async(dispatch_get_main_queue(), ^{
			FooAimpHeader * s = weakSelf;
			if (s && img && !abort->is_aborting()) s->_cover.image = img;
		});
	}).detach();
}

- (void)onPrev:(id)s { playback_control::get()->start(playback_control::track_command_prev); }
- (void)onNext:(id)s { playback_control::get()->start(playback_control::track_command_next); }
- (void)onStop:(id)s { playback_control::get()->stop(); }
- (void)onPause:(id)s { playback_control::get()->pause(true); }
- (void)onPlay:(id)s {
	auto pc = playback_control::get();
	if (pc->is_paused()) pc->pause(false); else if (!pc->is_playing()) pc->start();
}
- (void)onVolume:(id)s {
	double v = _volume.doubleValue;
	playback_control::get()->set_volume(v <= 0.001 ? -100.f : (float)(40.0 * log10(v)));
}
- (void)onMute:(id)s { playback_control::get()->volume_mute_toggle(); }
- (void)toggleOrder:(const char *)name {
	auto pm = playlist_manager::get();
	size_t idx = orderIndex(name);
	if (idx == SIZE_MAX) return;
	pm->playback_order_set_active(pm->playback_order_get_active() == idx ? 0 : idx);
	[self refresh];
}
- (void)onShuffle:(id)s { [self toggleOrder:"Shuffle (tracks)"]; }
- (void)onRepeat:(id)s { [self toggleOrder:"Repeat (playlist)"]; }
@end

// ---------------------------------------------------------------------------
// Playlist tabs (AIMP style: flat text, accent underline on the active one)
// ---------------------------------------------------------------------------

@interface FooAimpTabsView : NSView
@property (nonatomic, copy) NSArray<NSString *> * names;
@property (nonatomic) NSInteger active;
@end

@implementation FooAimpTabsView {
	std::vector<NSRect> _rects;
	CGFloat _scroll, _contentWidth;
	NSInteger _menuIndex;
}

static constexpr CGFloat kArrowW = 18;

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }

static NSDictionary * tabAttrs(BOOL active) {
	return @{ NSFontAttributeName: [NSFont systemFontOfSize:12 weight:active ? NSFontWeightSemibold : NSFontWeightRegular],
			  NSForegroundColorAttributeName: active ? NSColor.labelColor : NSColor.secondaryLabelColor };
}

- (BOOL)overflows { return _contentWidth > self.bounds.size.width; }
- (CGFloat)visibleWidth { return self.bounds.size.width - (self.overflows ? kArrowW * 2 : 0); }
- (void)setScrollTo:(CGFloat)v {
	_scroll = std::clamp<CGFloat>(v, 0, std::max<CGFloat>(0, _contentWidth - self.visibleWidth));
	[self setNeedsDisplay:YES];
}

- (void)layoutTabs {
	_rects.clear();
	CGFloat x = 4;
	for (NSUInteger i = 0; i < _names.count; ++i) {
		CGFloat w = std::min<CGFloat>(220, [_names[i] sizeWithAttributes:tabAttrs(YES)].width + 24);
		_rects.push_back(NSMakeRect(x, 0, w, self.bounds.size.height));
		x += w;
	}
	_contentWidth = x + 4;
}

- (void)setNames:(NSArray<NSString *> *)n { _names = [n copy]; [self layoutTabs]; [self setScrollTo:_scroll]; }
- (void)setActive:(NSInteger)a {
	_active = a;
	[self layoutTabs];
	if (a >= 0 && (size_t)a < _rects.size()) {
		NSRect r = _rects[a];
		if (r.origin.x < _scroll) [self setScrollTo:r.origin.x - 4];
		else if (NSMaxX(r) > _scroll + self.visibleWidth) [self setScrollTo:NSMaxX(r) - self.visibleWidth + 4];
	}
	[self setNeedsDisplay:YES];
}
- (void)setFrameSize:(NSSize)sz { [super setFrameSize:sz]; [self layoutTabs]; [self setScrollTo:_scroll]; }

- (void)scrollWheel:(NSEvent *)e {
	CGFloat d = fabs(e.scrollingDeltaX) > fabs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY;
	if (!e.hasPreciseScrollingDeltas) d *= 20;
	[self setScrollTo:_scroll - d];
}

- (void)drawRect:(NSRect)dirty {
	NSRect b = self.bounds;
	[NSColor.windowBackgroundColor setFill];
	NSRectFill(b);
	[NSColor.separatorColor setFill];
	NSRectFill(NSMakeRect(0, b.size.height - 1, b.size.width, 1));

	[NSGraphicsContext saveGraphicsState];
	NSRectClip(NSMakeRect(0, 0, self.visibleWidth, b.size.height));
	NSAffineTransform * t = [NSAffineTransform transform];
	[t translateXBy:-_scroll yBy:0];
	[t concat];
	NSMutableParagraphStyle * ps = [NSMutableParagraphStyle new];
	ps.lineBreakMode = NSLineBreakByTruncatingTail;
	ps.alignment = NSTextAlignmentCenter;
	for (size_t i = 0; i < _rects.size() && i < _names.count; ++i) {
		const BOOL act = (NSInteger)i == _active;
		NSRect r = _rects[i];
		NSMutableDictionary * a = [tabAttrs(act) mutableCopy];
		a[NSParagraphStyleAttributeName] = ps;
		NSSize sz = [_names[i] sizeWithAttributes:a];
		[_names[i] drawInRect:NSMakeRect(r.origin.x + 8, NSMidY(r) - sz.height / 2 - 1, r.size.width - 16, sz.height) withAttributes:a];
		if (act) {
			[accent() setFill];
			NSRectFill(NSMakeRect(r.origin.x + 4, b.size.height - 3, r.size.width - 8, 3));
		}
	}
	[NSGraphicsContext restoreGraphicsState];

	if (self.overflows) {
		NSDictionary * aa = @{ NSFontAttributeName: [NSFont systemFontOfSize:9], NSForegroundColorAttributeName: NSColor.secondaryLabelColor };
		NSArray * glyphs = @[@"◀", @"▶"];
		for (int k = 0; k < 2; ++k) {
			NSRect r = NSMakeRect(self.visibleWidth + k * kArrowW, 0, kArrowW, b.size.height);
			NSSize sz = [glyphs[k] sizeWithAttributes:aa];
			[glyphs[k] drawAtPoint:NSMakePoint(NSMidX(r) - sz.width / 2, NSMidY(r) - sz.height / 2) withAttributes:aa];
		}
	}
}

- (NSInteger)tabAt:(NSEvent *)e {
	NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
	if (p.x >= self.visibleWidth) return -1;
	p.x += _scroll;
	for (size_t i = 0; i < _rects.size(); ++i) if (NSPointInRect(p, _rects[i])) return (NSInteger)i;
	return -1;
}

- (void)mouseDown:(NSEvent *)e {
	NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
	if (self.overflows && p.x >= self.visibleWidth) {
		const BOOL right = p.x >= self.visibleWidth + kArrowW;
		CGFloat target = _scroll;
		if (right) { for (auto & r : _rects) if (r.origin.x - 4 > _scroll + 1) { target = r.origin.x - 4; break; } }
		else { for (auto it = _rects.rbegin(); it != _rects.rend(); ++it) if (it->origin.x - 4 < _scroll - 1) { target = it->origin.x - 4; break; } }
		[self setScrollTo:target];
		return;
	}
	NSInteger i = [self tabAt:e];
	if (e.clickCount == 2) {
		if (i < 0) [self newPlaylist:nil]; else { _menuIndex = i; [self renamePlaylist:nil]; }
		return;
	}
	if (i >= 0) { playlist_manager::get()->set_active_playlist((size_t)i); self.active = i; }
}

- (NSMenu *)menuForEvent:(NSEvent *)e {
	_menuIndex = [self tabAt:e];
	NSMenu * m = [NSMenu new];
	[m addItemWithTitle:@"New Playlist" action:@selector(newPlaylist:) keyEquivalent:@""].target = self;
	if (_menuIndex >= 0) {
		[m addItemWithTitle:@"Rename…" action:@selector(renamePlaylist:) keyEquivalent:@""].target = self;
		[m addItemWithTitle:@"Remove" action:@selector(removePlaylist:) keyEquivalent:@""].target = self;
	}
	return m;
}

- (void)newPlaylist:(id)s {
	auto pm = playlist_manager::get();
	size_t idx = pm->create_playlist("New Playlist", SIZE_MAX, SIZE_MAX);
	if (idx != SIZE_MAX) pm->set_active_playlist(idx);
}
- (void)removePlaylist:(id)s { if (_menuIndex >= 0) playlist_manager::get()->remove_playlist_switch((size_t)_menuIndex); }
- (void)renamePlaylist:(id)s {
	if (_menuIndex < 0 || (NSUInteger)_menuIndex >= _names.count) return;
	const size_t idx = (size_t)_menuIndex;
	NSAlert * a = [NSAlert new];
	a.messageText = @"Rename playlist";
	[a addButtonWithTitle:@"OK"];
	[a addButtonWithTitle:@"Cancel"];
	NSTextField * f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 22)];
	f.stringValue = _names[idx];
	a.accessoryView = f;
	a.window.initialFirstResponder = f;
	void (^done)(NSModalResponse) = ^(NSModalResponse r) {
		if (r == NSAlertFirstButtonReturn && f.stringValue.length > 0)
			playlist_manager::get()->playlist_rename(idx, f.stringValue.UTF8String, SIZE_MAX);
	};
	if (self.window) [a beginSheetModalForWindow:self.window completionHandler:done]; else done([a runModal]);
}
@end

@interface FooAimpTabs : NSViewController
@end

@implementation FooAimpTabs {
	FooAimpTabsView * _tabs;
	NSTimer * _timer;
	id _keyMonitor;
}
- (void)loadView {
	_tabs = [[FooAimpTabsView alloc] initWithFrame:NSMakeRect(0, 0, 400, 28)];
	[_tabs.heightAnchor constraintEqualToConstant:28].active = YES;
	self.view = _tabs;
	[self refresh];
}
- (void)viewDidLoad {
	[super viewDidLoad];
	__weak FooAimpTabs * weakSelf = self;
	_timer = [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *) { [weakSelf refresh]; }];

	// Left/right arrows switch playlists, unless a text field is being edited.
	_keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent * e) {
		FooAimpTabs * s = weakSelf;
		if (!s || e.window != s.view.window) return e;
		if (e.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl | NSEventModifierFlagShift)) return e;
		if ([e.window.firstResponder isKindOfClass:NSText.class]) return e;
		const int dir = e.keyCode == 123 ? -1 : e.keyCode == 124 ? 1 : 0;
		if (dir == 0) return e;
		auto pm = playlist_manager::get();
		const size_t n = pm->get_playlist_count(), cur = pm->get_active_playlist();
		if (n == 0) return nil;
		pm->set_active_playlist(cur == SIZE_MAX ? 0 : (cur + n + dir) % n);
		[s refresh];
		return nil;
	}];
}
- (void)dealloc {
	[_timer invalidate];
	if (_keyMonitor) [NSEvent removeMonitor:_keyMonitor];
}
- (void)refresh {
	auto pm = playlist_manager::get();
	NSMutableArray * names = [NSMutableArray array];
	for (size_t i = 0, n = pm->get_playlist_count(); i < n; ++i) {
		pfc::string8 name;
		pm->playlist_get_name(i, name);
		[names addObject:str(name)];
	}
	const size_t act = pm->get_active_playlist();
	NSInteger active = act == SIZE_MAX ? -1 : (NSInteger)act;
	if (![names isEqualToArray:_tabs.names]) _tabs.names = names;
	if (active != _tabs.active) _tabs.active = active;
}
@end

// ---------------------------------------------------------------------------
// Playlist: group headers + two-line rows
// ---------------------------------------------------------------------------

struct AimpRow {
	bool header = false;
	size_t item = 0;          // playlist index (item rows)
	size_t number = 0;        // display number, 1-based
	NSString * line1 = nil;   // item: "Artist - Title"; header: group name
	NSString * line2 = nil;   // item: tech info;        header: "count / length"
	NSString * right = nil;   // item: duration
};

@class FooAimpPlaylist;

@interface FooAimpRowView : NSView
@property (nonatomic) BOOL header, selected, playing;
@property (nonatomic, copy) NSString * line1, * line2, * right;
@property (nonatomic) size_t number;
@end

@implementation FooAimpRowView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
	NSRect b = self.bounds;
	if (self.header) {
		NSDictionary * a1 = @{ NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: accent() };
		NSDictionary * a2 = @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: accent() };
		NSSize s2 = [self.line2 sizeWithAttributes:a2];
		NSMutableParagraphStyle * ps = [NSMutableParagraphStyle new];
		ps.lineBreakMode = NSLineBreakByTruncatingTail;
		NSMutableDictionary * a1m = [a1 mutableCopy]; a1m[NSParagraphStyleAttributeName] = ps;
		CGFloat y = b.size.height - 22;
		[self.line1 drawInRect:NSMakeRect(10, y, b.size.width - s2.width - 30, 18) withAttributes:a1m];
		[self.line2 drawAtPoint:NSMakePoint(b.size.width - s2.width - 10, y + 1) withAttributes:a2];
		[[accent() colorWithAlphaComponent:0.5] setFill];
		NSRectFill(NSMakeRect(10, b.size.height - 2, b.size.width - 20, 1));
		return;
	}

	NSColor * bg = nil;
	if (self.playing) bg = accent();
	else if (self.selected) bg = [accent() colorWithAlphaComponent:0.28];
	if (bg) { [bg setFill]; NSRectFill(b); }

	NSColor * c1 = self.playing ? NSColor.whiteColor : NSColor.labelColor;
	NSColor * c2 = self.playing ? [NSColor colorWithWhite:1 alpha:0.8] : NSColor.secondaryLabelColor;
	NSMutableParagraphStyle * ps = [NSMutableParagraphStyle new];
	ps.lineBreakMode = NSLineBreakByTruncatingTail;
	NSDictionary * a1 = @{ NSFontAttributeName: [NSFont systemFontOfSize:12], NSForegroundColorAttributeName: c1, NSParagraphStyleAttributeName: ps };
	NSDictionary * a2 = @{ NSFontAttributeName: [NSFont systemFontOfSize:10], NSForegroundColorAttributeName: c2, NSParagraphStyleAttributeName: ps };
	NSDictionary * ar = @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular], NSForegroundColorAttributeName: c1 };

	NSSize sr = [self.right sizeWithAttributes:ar];
	const CGFloat textW = b.size.width - sr.width - 30;
	NSString * l1 = [NSString stringWithFormat:@"%zu. %@", self.number, self.line1];
	[l1 drawInRect:NSMakeRect(10, 3, textW, 17) withAttributes:a1];
	[self.line2 drawInRect:NSMakeRect(10, 20, textW, 14) withAttributes:a2];
	[self.right drawAtPoint:NSMakePoint(b.size.width - sr.width - 10, 3) withAttributes:ar];
}
@end

@interface FooAimpTableView : NSTableView
@property (nonatomic, weak) FooAimpPlaylist * owner;
@end

@interface FooAimpPlaylist : NSViewController <NSTableViewDataSource, NSTableViewDelegate>
- (void)removeSelection;
- (void)playClicked;
@end

@implementation FooAimpTableView
- (void)keyDown:(NSEvent *)e {
	unichar c = e.charactersIgnoringModifiers.length ? [e.charactersIgnoringModifiers characterAtIndex:0] : 0;
	if (c == NSDeleteCharacter || c == NSDeleteFunctionKey) { [self.owner removeSelection]; return; }
	if (c == NSCarriageReturnCharacter || c == NSEnterCharacter) { [self.owner playClicked]; return; }
	[super keyDown:e];
}
@end

namespace {
	class AimpPlaylistCallback : public playlist_callback_impl_base {
	public:
		AimpPlaylistCallback(FooAimpPlaylist * o) : playlist_callback_impl_base(flag_all), m_owner(o) {}
		void on_items_added(t_size, t_size, metadb_handle_list_cref, const bit_array &) override { dirty(); }
		void on_items_reordered(t_size, const t_size *, t_size) override { dirty(); }
		void on_items_removed(t_size, const bit_array &, t_size, t_size) override { dirty(); }
		void on_items_modified(t_size, const bit_array &) override { dirty(); }
		void on_items_replaced(t_size, const bit_array &, const pfc::list_base_const_t<t_on_items_replaced_entry> &) override { dirty(); }
		void on_playlist_activate(t_size, t_size) override { dirty(); }
		void on_items_selection_change(t_size, const bit_array &, const bit_array &) override { [m_owner performSelector:@selector(syncSelection)]; }
		void on_item_ensure_visible(t_size p, t_size idx) override {
			if (p == playlist_manager::get()->get_active_playlist()) [m_owner performSelector:@selector(revealItem:) withObject:@(idx)];
		}
	private:
		void dirty() { [m_owner performSelector:@selector(scheduleRebuild)]; }
		__weak FooAimpPlaylist * m_owner;
	};

	class AimpPlayCallback : public play_callback_impl_base {
	public:
		AimpPlayCallback(FooAimpPlaylist * o) : play_callback_impl_base(flag_on_playback_new_track | flag_on_playback_stop), m_owner(o) {}
		void on_playback_new_track(metadb_handle_ptr) override { [m_owner performSelector:@selector(playingChanged)]; }
		void on_playback_stop(play_control::t_stop_reason) override { [m_owner performSelector:@selector(playingChanged)]; }
	private:
		__weak FooAimpPlaylist * m_owner;
	};
}

static NSPasteboardType const kAimpRowsType = @"com.foobar2000.foo-aimp-ui.rows";

@implementation FooAimpPlaylist {
	FooAimpTableView * _table;
	std::vector<AimpRow> _rows;
	std::vector<size_t> _itemToRow;
	std::unique_ptr<AimpPlaylistCallback> _plcb;
	std::unique_ptr<AimpPlayCallback> _pbcb;
	titleformat_object::ptr _tfGroup, _tfLine1, _tfLine2, _tfLen;
	BOOL _syncing, _rebuildPending, _playingRetry;
	size_t _playlist;
}

- (void)loadView {
	NSScrollView * sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 400, 400)];
	sv.hasVerticalScroller = YES;
	sv.autohidesScrollers = YES;
	sv.drawsBackground = YES;
	sv.backgroundColor = NSColor.controlBackgroundColor;

	_table = [[FooAimpTableView alloc] initWithFrame:sv.bounds];
	_table.owner = self;
	NSTableColumn * col = [[NSTableColumn alloc] initWithIdentifier:@"main"];
	col.resizingMask = NSTableColumnAutoresizingMask;
	col.width = sv.contentSize.width;
	[_table addTableColumn:col];
	_table.headerView = nil;
	_table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
	_table.autoresizingMask = NSViewWidthSizable;
	_table.allowsMultipleSelection = YES;
	_table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
	_table.intercellSpacing = NSMakeSize(0, 0);
	_table.backgroundColor = NSColor.controlBackgroundColor;
	_table.style = NSTableViewStylePlain;
	_table.dataSource = self;
	_table.delegate = self;
	_table.target = self;
	_table.doubleAction = @selector(playClicked);
	[_table registerForDraggedTypes:@[kAimpRowsType, NSPasteboardTypeFileURL]];
	[_table setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];
	_table.draggingDestinationFeedbackStyle = NSTableViewDraggingDestinationFeedbackStyleGap;
	sv.documentView = _table;
	self.view = sv;

	_tfGroup = compileTF("$if2(%album artist%,?)[ - %album%]");
	_tfLine1 = compileTF("[%artist% - ]%title%");
	_tfLine2 = compileTF("[%codec%][ :: $div(%samplerate%,1000) kHz][, %bitrate% kbps][, %filesize_natural%]");
	_tfLen = compileTF("[%length%]");
	[self rebuild];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	_plcb = std::make_unique<AimpPlaylistCallback>(self);
	_pbcb = std::make_unique<AimpPlayCallback>(self);
}

- (void)viewDidLayout {
	[super viewDidLayout];
	[_table sizeLastColumnToFit];
}

- (void)dealloc { _plcb.reset(); _pbcb.reset(); }

- (void)scheduleRebuild {
	if (_rebuildPending) return;
	_rebuildPending = YES;
	dispatch_async(dispatch_get_main_queue(), ^{ self->_rebuildPending = NO; [self rebuild]; });
}

- (void)rebuild {
	auto pm = playlist_manager::get();
	_playlist = pm->get_active_playlist();
	_rows.clear();
	_itemToRow.clear();
	if (_playlist != SIZE_MAX) {
		metadb_handle_list items;
		pm->playlist_get_all_items(_playlist, items);
		_itemToRow.resize(items.get_count());
		pfc::string8 group, prevGroup, s;
		size_t headerRow = SIZE_MAX, groupCount = 0;
		double groupLen = 0;
		auto closeGroup = [&] {
			if (headerRow != SIZE_MAX)
				_rows[headerRow].line2 = [NSString stringWithFormat:@"%zu / %@", groupCount, formatDuration(groupLen)];
		};
		for (size_t i = 0; i < items.get_count(); ++i) {
			auto const & h = items[i];
			h->format_title(nullptr, group, _tfGroup, nullptr);
			if (i == 0 || strcmp(group, prevGroup) != 0) {
				closeGroup();
				AimpRow hr; hr.header = true; hr.line1 = str(group);
				headerRow = _rows.size();
				_rows.push_back(hr);
				groupCount = 0; groupLen = 0;
				prevGroup = group;
			}
			AimpRow r;
			r.item = i;
			r.number = i + 1;
			h->format_title(nullptr, s, _tfLine1, nullptr); r.line1 = str(s);
			h->format_title(nullptr, s, _tfLine2, nullptr); r.line2 = str(s);
			h->format_title(nullptr, s, _tfLen, nullptr); r.right = str(s);
			_itemToRow[i] = _rows.size();
			_rows.push_back(r);
			groupCount++;
			const double len = h->get_length();
			if (len > 0) groupLen += len;
		}
		closeGroup();
	}
	[_table reloadData];
	[self syncSelection];
}

- (void)playingChanged {
	// On a new track foobar2000 reports the playing playlist position a moment later.
	if (!_playingRetry) {
		_playingRetry = YES;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			self->_playingRetry = NO;
			[self playingChanged];
		});
	}
	[_table reloadData];
	size_t pl, item;
	if (playlist_manager::get()->get_playing_item_location(&pl, &item) && pl == _playlist && item < _itemToRow.size())
		[_table scrollRowToVisible:(NSInteger)_itemToRow[item]];
}

- (void)syncSelection {
	if (_playlist == SIZE_MAX) return;
	auto pm = playlist_manager::get();
	NSMutableIndexSet * set = [NSMutableIndexSet indexSet];
	pfc::bit_array_bittable mask(pm->playlist_get_item_count(_playlist));
	pm->playlist_get_selection_mask(_playlist, mask);
	for (size_t i = 0; i < _itemToRow.size(); ++i) if (mask.get(i)) [set addIndex:_itemToRow[i]];
	_syncing = YES;
	[_table selectRowIndexes:set byExtendingSelection:NO];
	_syncing = NO;
	[_table setNeedsDisplay:YES];
	[_table enumerateAvailableRowViewsUsingBlock:^(NSTableRowView * rv, NSInteger row) {
		FooAimpRowView * v = [rv viewAtColumn:0];
		if ([v isKindOfClass:FooAimpRowView.class]) { v.selected = [set containsIndex:row]; [v setNeedsDisplay:YES]; }
	}];
}

- (void)revealItem:(NSNumber *)idx {
	size_t i = idx.unsignedLongValue;
	if (i < _itemToRow.size()) [_table scrollRowToVisible:(NSInteger)_itemToRow[i]];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)_rows.size(); }

- (CGFloat)tableView:(NSTableView *)tv heightOfRow:(NSInteger)row {
	return _rows[(size_t)row].header ? 30 : 38;
}

- (BOOL)tableView:(NSTableView *)tv shouldSelectRow:(NSInteger)row { return !_rows[(size_t)row].header; }

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
	FooAimpRowView * v = [tv makeViewWithIdentifier:@"row" owner:self];
	if (!v) { v = [[FooAimpRowView alloc] initWithFrame:NSZeroRect]; v.identifier = @"row"; }
	AimpRow const & r = _rows[(size_t)row];
	v.header = r.header;
	v.line1 = r.line1; v.line2 = r.line2; v.right = r.right; v.number = r.number;
	size_t pl, item;
	v.playing = !r.header && playlist_manager::get()->get_playing_item_location(&pl, &item) && pl == _playlist && item == r.item;
	v.selected = [tv isRowSelected:row];
	[v setNeedsDisplay:YES];
	return v;
}

- (void)tableViewSelectionDidChange:(NSNotification *)n {
	if (_syncing || _playlist == SIZE_MAX) return;
	auto pm = playlist_manager::get();
	const size_t count = pm->playlist_get_item_count(_playlist);
	pfc::bit_array_bittable mask(count);
	NSIndexSet * sel = _table.selectedRowIndexes;
	for (NSUInteger row = sel.firstIndex; row != NSNotFound; row = [sel indexGreaterThanIndex:row])
		if (row < _rows.size() && !_rows[row].header && _rows[row].item < count) mask.set(_rows[row].item, true);
	_syncing = YES;
	pm->playlist_set_selection(_playlist, pfc::bit_array_true(), mask);
	NSInteger clicked = _table.selectedRow;
	if (clicked >= 0 && !_rows[(size_t)clicked].header) pm->playlist_set_focus_item(_playlist, _rows[(size_t)clicked].item);
	_syncing = NO;
	[self syncSelection];
}

- (void)playClicked {
	NSInteger row = _table.clickedRow >= 0 ? _table.clickedRow : _table.selectedRow;
	if (row < 0 || _rows[(size_t)row].header) return;
	playlist_manager::get()->playlist_execute_default_action(_playlist, _rows[(size_t)row].item);
}

// --- Drag & drop ---------------------------------------------------------

- (id<NSPasteboardWriting>)tableView:(NSTableView *)tv pasteboardWriterForRow:(NSInteger)row {
	if (_rows[(size_t)row].header) return nil;
	NSPasteboardItem * it = [NSPasteboardItem new];
	[it setString:[NSString stringWithFormat:@"%zu", _rows[(size_t)row].item] forType:kAimpRowsType];
	return it;
}

// Playlist index at which a drop above `row` inserts.
- (size_t)insertIndexForRow:(NSInteger)row {
	for (size_t r = (size_t)row; r < _rows.size(); ++r)
		if (!_rows[r].header) return _rows[r].item;
	return _itemToRow.size();
}

- (NSDragOperation)tableView:(NSTableView *)tv validateDrop:(id<NSDraggingInfo>)info proposedRow:(NSInteger)row
	   proposedDropOperation:(NSTableViewDropOperation)op {
	if (_playlist == SIZE_MAX) return NSDragOperationNone;
	if (op == NSTableViewDropOn) [tv setDropRow:row dropOperation:NSTableViewDropAbove];
	if (info.draggingSource == tv) return NSDragOperationMove;
	if ([info.draggingPasteboard canReadObjectForClasses:@[NSURL.class] options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }])
		return NSDragOperationCopy;
	return NSDragOperationNone;
}

- (BOOL)tableView:(NSTableView *)tv acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)op {
	if (_playlist == SIZE_MAX) return NO;
	auto pm = playlist_manager::get();
	const size_t target = [self insertIndexForRow:row];

	if (info.draggingSource == tv) {
		// Move the dragged items so they start at `target`, keeping their relative order.
		const size_t n = pm->playlist_get_item_count(_playlist);
		std::vector<bool> moving(n, false);
		for (NSPasteboardItem * it in info.draggingPasteboard.pasteboardItems) {
			NSString * v = [it stringForType:kAimpRowsType];
			if (v) { size_t i = (size_t)v.longLongValue; if (i < n) moving[i] = true; }
		}
		std::vector<size_t> order;
		order.reserve(n);
		for (size_t i = 0; i < target && i < n; ++i) if (!moving[i]) order.push_back(i);
		for (size_t i = 0; i < n; ++i) if (moving[i]) order.push_back(i);
		for (size_t i = target; i < n; ++i) if (!moving[i]) order.push_back(i);
		if (order.size() != n) return NO;
		pm->playlist_reorder_items(_playlist, order.data(), n);
		return YES;
	}

	NSArray<NSURL *> * urls = [info.draggingPasteboard readObjectsForClasses:@[NSURL.class]
																	options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
	if (urls.count == 0) return NO;
	pfc::list_t<pfc::string8> paths;
	for (NSURL * u in urls) paths.add_item(u.path.UTF8String);
	pfc::list_t<const char *> ptrs;
	for (size_t i = 0; i < paths.get_count(); ++i) ptrs.add_item(paths[i].c_str());

	const size_t pl = _playlist;
	auto notify = process_locations_notify::create([pl, target](metadb_handle_list_cref items) {
		auto pm = playlist_manager::get();
		if (pl >= pm->get_playlist_count()) return;
		const size_t at = std::min(target, pm->playlist_get_item_count(pl));
		pm->playlist_clear_selection(pl);
		pm->playlist_insert_items(pl, at, items, pfc::bit_array_true());
	});
	playlist_incoming_item_filter_v2::get()->process_locations_async(
		ptrs, playlist_incoming_item_filter_v2::op_flag_background | playlist_incoming_item_filter_v2::op_flag_delay_ui,
		nullptr, nullptr, nullptr, notify);
	return YES;
}

- (void)removeSelection {
	if (_playlist != SIZE_MAX) playlist_manager::get()->playlist_remove_selection(_playlist);
}
@end

// ---------------------------------------------------------------------------
// Footer: + / − / quick search / totals
// ---------------------------------------------------------------------------

@interface FooAimpFooter : NSViewController <NSSearchFieldDelegate>
@end

@implementation FooAimpFooter {
	NSSearchField * _search;
	NSTextField * _stats;
	NSTimer * _timer;
	titleformat_object::ptr _tfSearch;
}

- (void)loadView {
	NSButton * add = symbolButton(@"plus", 13, @"Add files", self, @selector(onAdd:));
	NSButton * rem = symbolButton(@"minus", 13, @"Remove selected", self, @selector(onRemove:));
	_search = [NSSearchField new];
	_search.placeholderString = @"Quick search";
	_search.controlSize = NSControlSizeSmall;
	_search.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
	_search.delegate = self;
	_search.sendsSearchStringImmediately = YES;
	_search.target = self;
	_search.action = @selector(onSearch:);
	[_search.widthAnchor constraintEqualToConstant:200].active = YES;

	_stats = [NSTextField labelWithString:@""];
	_stats.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
	_stats.textColor = NSColor.secondaryLabelColor;
	_stats.alignment = NSTextAlignmentRight;
	[_stats setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

	NSStackView * row = [NSStackView stackViewWithViews:@[add, rem, _search, _stats]];
	row.spacing = 10;
	row.edgeInsets = NSEdgeInsetsMake(3, 10, 3, 10);
	[row setCustomSpacing:16 afterView:rem];
	[row.heightAnchor constraintEqualToConstant:30].active = YES;
	self.view = row;

	_tfSearch = compileTF("%artist% %title% %album%");
	[self refresh];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	__weak FooAimpFooter * weakSelf = self;
	_timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *) { [weakSelf refresh]; }];
}
- (void)dealloc { [_timer invalidate]; }

- (void)refresh {
	auto pm = playlist_manager::get();
	const size_t pl = pm->get_active_playlist();
	if (pl == SIZE_MAX) { _stats.stringValue = @""; return; }
	metadb_handle_list items;
	pm->playlist_get_all_items(pl, items);
	double len = 0; uint64_t size = 0;
	for (size_t i = 0; i < items.get_count(); ++i) {
		double l = items[i]->get_length(); if (l > 0) len += l;
		auto fs = items[i]->get_filesize(); if (fs != filesize_invalid) size += fs;
	}
	_stats.stringValue = [NSString stringWithFormat:@"%zu / %@ / %@", items.get_count(), formatDuration(len), formatSize(size)];
}

- (void)onAdd:(id)s { standard_commands::main_add_files(); }
- (void)onRemove:(id)s {
	auto pm = playlist_manager::get();
	const size_t pl = pm->get_active_playlist();
	if (pl != SIZE_MAX) pm->playlist_remove_selection(pl);
}

- (void)onSearch:(id)s {
	NSString * q = _search.stringValue;
	if (q.length == 0) return;
	auto pm = playlist_manager::get();
	const size_t pl = pm->get_active_playlist();
	if (pl == SIZE_MAX) return;
	metadb_handle_list items;
	pm->playlist_get_all_items(pl, items);
	pfc::string8 text;
	for (size_t i = 0; i < items.get_count(); ++i) {
		items[i]->format_title(nullptr, text, _tfSearch, nullptr);
		if ([str(text) rangeOfString:q options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) {
			pm->playlist_set_selection(pl, pfc::bit_array_true(), pfc::bit_array_one(i));
			pm->playlist_set_focus_item(pl, i);
			pm->playlist_ensure_visible(pl, i);
			return;
		}
	}
}
@end

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

namespace {
	template<typename T> struct AimpElement : public ui_element_mac {
		const char * m_name; const char * m_title; GUID m_guid;
		AimpElement(const char * n, const char * t, GUID g) : m_name(n), m_title(t), m_guid(g) {}
		service_ptr instantiate(service_ptr) override { return fb2k::wrapNSObject([T new]); }
		bool match_name(const char * name) override { return strcmp(name, m_name) == 0; }
		fb2k::stringRef get_name() override { return fb2k::makeString(m_title); }
		GUID get_guid() override { return m_guid; }
	};

	class el_header : public AimpElement<FooAimpHeader> { public: el_header() : AimpElement("aimp-header", "AIMP Header",
		GUID { 0x2a9e41c7, 0x5d1b, 0x4c86, { 0x93, 0x0f, 0x6e, 0x2b, 0xd8, 0x14, 0xa7, 0x51 } }) {} };
	class el_tabs : public AimpElement<FooAimpTabs> { public: el_tabs() : AimpElement("aimp-tabs", "AIMP Playlist Tabs",
		GUID { 0x7f03b85e, 0x19c4, 0x4a2d, { 0xb6, 0x71, 0x0c, 0x9e, 0x45, 0xf2, 0x3b, 0x88 } }) {} };
	class el_playlist : public AimpElement<FooAimpPlaylist> { public: el_playlist() : AimpElement("aimp-playlist", "AIMP Playlist",
		GUID { 0xc4d62a19, 0x8e70, 0x4f5b, { 0xa2, 0x3d, 0x91, 0x07, 0x6c, 0xe8, 0x5f, 0x24 } }) {} };
	class el_footer : public AimpElement<FooAimpFooter> { public: el_footer() : AimpElement("aimp-footer", "AIMP Footer",
		GUID { 0x58b1e0f4, 0x3a62, 0x47c9, { 0x8d, 0x15, 0xf7, 0x2c, 0x0a, 0x96, 0xe3, 0x6b } }) {} };

	FB2K_SERVICE_FACTORY(el_header);
	FB2K_SERVICE_FACTORY(el_tabs);
	FB2K_SERVICE_FACTORY(el_playlist);
	FB2K_SERVICE_FACTORY(el_footer);
}

NANOR_UPDATE_COMPONENT("foo_aimp_ui", "AIMP UI", COMPONENT_VERSION)
