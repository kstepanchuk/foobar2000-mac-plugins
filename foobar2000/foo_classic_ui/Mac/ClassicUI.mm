#import "stdafx.h"
#include "../version.h"
#include "../../nanor_shared/NanorUpdate.h"
#include <SDK/ui_element_mac.h>
#include <SDK/commonObjects-Apple.h>

// Tracks being dragged out of a classic-playlist, shared with classic-tabs.
static NSPasteboardType const kClassicRowsType = @"com.foobar2000.foo-classic-ui.rows";
struct ClassicDrag {
	bool active = false;
	size_t playlist = SIZE_MAX;   // source playlist
	std::vector<size_t> indices;  // source item indices
	metadb_handle_list items;
};
static ClassicDrag g_drag;

// Preferences (View > Preferences > Display > Classic UI).
static cfg_string cfg_fontName(GUID { 0x1f6c0a93, 0x52d7, 0x4b1e, { 0x86, 0x3a, 0x0d, 0xe9, 0x27, 0xb4, 0x51, 0x7c } }, "");
static cfg_int cfg_fontSize(GUID { 0x8a43d1f0, 0x6e29, 0x4c85, { 0xb7, 0x10, 0x95, 0x3e, 0x2c, 0x68, 0xa1, 0x4d } }, 12);
static cfg_int cfg_tabClose(GUID { 0xb83e2f61, 0x4ca9, 0x4d17, { 0x95, 0x0e, 0x7a, 0x31, 0xc6, 0x0d, 0x52, 0xe8 } }, 0); // × on hovered tab
// Window title while playing (foobar2000 for Windows default); empty = leave the title alone.
static const char * kWindowTitleDefault = "[%album artist% - ]['['%album%[ CD%discnumber%][ #%tracknumber%]'] ']%title%[ '//' %track artist%] '['foobar2000']'";
static cfg_string cfg_windowTitle(GUID { 0x2b6e91d4, 0x83f0, 0x4a5c, { 0xbe, 0x17, 0x49, 0xd2, 0x0a, 0x6c, 0xf3, 0x8e } }, kWindowTitleDefault);
static cfg_int cfg_rowHeight(GUID { 0xe50b72c8, 0x0d94, 0x47a1, { 0x9f, 0x5e, 0x31, 0x86, 0xc4, 0x0b, 0x7d, 0x22 } }, 18);
static NSNotificationName const kClassicPrefsChanged = @"FooClassicUIPrefsChanged";

static NSFont * playlistFont(BOOL bold) {
	const CGFloat size = (CGFloat)std::clamp<int64_t>(cfg_fontSize.get(), 8, 32);
	NSString * name = [NSString stringWithUTF8String:cfg_fontName.get().c_str()];
	NSFont * f = name.length ? [NSFontManager.sharedFontManager fontWithFamily:name traits:0 weight:5 size:size] : nil;
	if (!f) return [NSFont systemFontOfSize:size weight:bold ? NSFontWeightSemibold : NSFontWeightRegular];
	return bold ? [NSFontManager.sharedFontManager convertFont:f toHaveTrait:NSBoldFontMask] : f;
}
static CGFloat playlistRowHeight() { return (CGFloat)std::clamp<int64_t>(cfg_rowHeight.get(), 12, 48); }

// ---------------------------------------------------------------------------
// Theme: appearance + accent color (Preferences > Display > Classic UI)
// ---------------------------------------------------------------------------

// 0 = follow macOS, 1 = light, 2 = dark, 3 = dark monochrome (Windows-like greys)
static cfg_int cfg_theme(GUID { 0x93c1e7a4, 0x2f58, 0x4b0d, { 0x8a, 0x61, 0x5e, 0x0c, 0xb7, 0x42, 0x19, 0xd3 } }, 0);
static cfg_string cfg_accent(GUID { 0x4e7b20d9, 0xc613, 0x4f8a, { 0xb2, 0x9d, 0x70, 0x18, 0xe5, 0x3a, 0xc6, 0x4f } }, ""); // RRGGBB, "" = system

static NSColor * customAccent() {
	NSString * hex = [NSString stringWithUTF8String:cfg_accent.get().c_str()];
	unsigned v = 0;
	if (hex.length != 6 || ![[NSScanner scannerWithString:hex] scanHexInt:&v]) return nil;
	return [NSColor colorWithSRGBRed:((v >> 16) & 0xFF) / 255.0 green:((v >> 8) & 0xFF) / 255.0 blue:(v & 0xFF) / 255.0 alpha:1];
}
static BOOL themeMonochrome() { return cfg_theme.get() == 3; }
static NSColor * accentColor() {
	if (NSColor * c = customAccent()) return c;
	return themeMonochrome() ? [NSColor colorWithWhite:0.86 alpha:1] : NSColor.controlAccentColor;
}
// Selection fill when the theme overrides the system highlight; nil = system default.
static NSColor * selectionColor() {
	if (themeMonochrome()) return [NSColor colorWithWhite:1 alpha:0.16];
	if (NSColor * c = customAccent()) return [c colorWithAlphaComponent:0.45];
	return nil;
}
static void applyTheme() {
	switch (cfg_theme.get()) {
		case 1: NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua]; break;
		case 2: case 3: NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]; break;
		default: NSApp.appearance = nil;
	}
}

// ---------------------------------------------------------------------------
// Playlist locks (tab menu > Lock Playlist), remembered across restarts
// ---------------------------------------------------------------------------

static const GUID kLockProperty = { 0x6a0c4d93, 0x7e21, 0x4b58, { 0x9f, 0x36, 0xd1, 0x84, 0x2b, 0x5e, 0x70, 0xa9 } };

namespace {
	class ClassicLock : public playlist_lock {
	public:
		bool query_items_add(t_size, const pfc::list_base_const_t<metadb_handle_ptr> &, const bit_array &) override { return false; }
		bool query_items_reorder(const t_size *, t_size) override { return false; }
		bool query_items_remove(const bit_array &, bool) override { return false; }
		bool query_item_replace(t_size, const metadb_handle_ptr &, const metadb_handle_ptr &) override { return true; }
		bool query_playlist_rename(const char *, t_size) override { return true; }
		bool query_playlist_remove() override { return false; }
		bool execute_default_action(t_size) override { return false; }
		void on_playlist_index_change(t_size) override {}
		void on_playlist_remove() override {}
		void get_lock_name(pfc::string_base & out) override { out = "Locked (Classic UI)"; }
		void show_ui() override {}
		t_uint32 get_filter_mask() override { return filter_add | filter_remove | filter_reorder | filter_remove_playlist; }
	};
	static std::vector<service_ptr_t<playlist_lock>> g_locks;
}

static BOOL isLockedByUs(size_t pl) { return playlist_manager_v2::get()->playlist_have_property(pl, kLockProperty); }

static void setPlaylistLocked(size_t pl, BOOL locked) {
	auto pm = playlist_manager::get();
	if (locked) {
		if (isLockedByUs(pl)) return;
		service_ptr_t<playlist_lock> lock = new service_impl_t<ClassicLock>();
		if (!pm->playlist_lock_install(pl, lock)) { NSBeep(); return; } // another component already locks it
		g_locks.push_back(lock);
		pfc::array_t<t_uint8> flag; flag.append_single(1);
		playlist_manager_v2::get()->playlist_set_property(pl, kLockProperty, flag);
	} else {
		for (auto it = g_locks.begin(); it != g_locks.end(); ++it)
			if (pm->playlist_lock_uninstall(pl, *it)) { g_locks.erase(it); break; }
		playlist_manager_v2::get()->playlist_remove_property(pl, kLockProperty);
	}
}

static void restoreLocks() {
	auto pm = playlist_manager::get();
	for (size_t i = 0, n = pm->get_playlist_count(); i < n; ++i) {
		if (!isLockedByUs(i) || pm->playlist_lock_is_present(i)) continue;
		service_ptr_t<playlist_lock> lock = new service_impl_t<ClassicLock>();
		if (pm->playlist_lock_install(i, lock)) g_locks.push_back(lock);
	}
}

// ---------------------------------------------------------------------------
// Recently closed playlists (tab menu, ⇧⌘T)
// ---------------------------------------------------------------------------

struct ClosedPlaylist { pfc::string8 name; metadb_handle_list items; };
static std::vector<ClosedPlaylist> g_closed; // newest last
static constexpr size_t kClosedMax = 10;

namespace {
	class ClosedTracker : public playlist_callback_impl_base {
	public:
		ClosedTracker() : playlist_callback_impl_base(flag_on_playlists_removing) {}
		void on_playlists_removing(const bit_array & mask, t_size oldCount, t_size) override {
			auto pm = playlist_manager::get();
			for (size_t i = 0; i < oldCount; ++i) {
				if (!mask.get(i)) continue;
				ClosedPlaylist c;
				pm->playlist_get_name(i, c.name);
				pm->playlist_get_all_items(i, c.items);
				g_closed.push_back(std::move(c));
				if (g_closed.size() > kClosedMax) g_closed.erase(g_closed.begin());
			}
		}
	};
	static std::unique_ptr<ClosedTracker> g_closedTracker;
}

// index into g_closed; SIZE_MAX = most recent
static void restoreClosed(size_t index = SIZE_MAX) {
	if (g_closed.empty()) { NSBeep(); return; }
	if (index >= g_closed.size()) index = g_closed.size() - 1;
	ClosedPlaylist c = g_closed[index];
	g_closed.erase(g_closed.begin() + (ptrdiff_t)index);
	auto pm = playlist_manager::get();
	const size_t pl = pm->create_playlist(c.name, SIZE_MAX, SIZE_MAX);
	if (pl == SIZE_MAX) return;
	pm->playlist_add_items(pl, c.items, pfc::bit_array_false());
	pm->set_active_playlist(pl);
}

// ---------------------------------------------------------------------------
// Playback queue
// ---------------------------------------------------------------------------

static NSNotificationName const kClassicQueueChanged = @"FooClassicUIQueueChanged";
namespace {
	class ClassicQueueCallback : public playback_queue_callback {
	public:
		void on_changed(t_change_origin) override {
			[NSNotificationCenter.defaultCenter postNotificationName:kClassicQueueChanged object:nil];
		}
	};
	FB2K_SERVICE_FACTORY(ClassicQueueCallback);
}

static void goToPlaying() {
	auto pm = playlist_manager::get();
	size_t pl, item;
	if (!pm->get_playing_item_location(&pl, &item)) { NSBeep(); return; }
	pm->set_active_playlist(pl);
	pm->playlist_set_selection(pl, pfc::bit_array_true(), pfc::bit_array_one(item));
	pm->playlist_set_focus_item(pl, item);
	pm->playlist_ensure_visible(pl, item);
}

namespace {
	class ClassicInit : public initquit {
	public:
		void on_init() override {
			applyTheme();
			restoreLocks();
			g_closedTracker = std::make_unique<ClassicTracker_t>();
		}
		void on_quit() override { g_closedTracker.reset(); }
	private:
		typedef ClosedTracker ClassicTracker_t;
	};
	FB2K_SERVICE_FACTORY(ClassicInit);
}

// ---------------------------------------------------------------------------
// Toolbar: playback buttons + playback order
// ---------------------------------------------------------------------------

@interface FooClassicToolbar : NSViewController
@end

@implementation FooClassicToolbar {
	NSPopUpButton * _order;
	NSTimer * _timer;
	NSButton * _mute;
	NSSlider * _volume;
	NSTextField * _volumePct;
}

- (NSButton *)button:(NSString *)symbol tip:(NSString *)tip action:(SEL)action {
	NSImage * img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip];
	NSButton * b = [NSButton buttonWithImage:img target:self action:action];
	b.bezelStyle = NSBezelStyleTexturedRounded;
	b.bordered = NO;
	b.toolTip = tip;
	[b.widthAnchor constraintEqualToConstant:24].active = YES;
	return b;
}

- (void)loadView {
	NSStackView * row = [NSStackView stackViewWithViews:@[
		[self button:@"stop.fill" tip:@"Stop" action:@selector(onStop:)],
		[self button:@"pause.fill" tip:@"Pause" action:@selector(onPause:)],
		[self button:@"play.fill" tip:@"Play" action:@selector(onPlay:)],
		[self button:@"backward.end.fill" tip:@"Previous" action:@selector(onPrev:)],
		[self button:@"forward.end.fill" tip:@"Next" action:@selector(onNext:)],
		[self button:@"shuffle" tip:@"Random" action:@selector(onRandom:)],
		[self button:@"eject.fill" tip:@"Open" action:@selector(onOpen:)],
	]];
	row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	row.spacing = 2;
	row.edgeInsets = NSEdgeInsetsMake(2, 6, 2, 6);

	NSTextField * label = [NSTextField labelWithString:@"Order"];
	label.textColor = NSColor.secondaryLabelColor;
	[row addView:label inGravity:NSStackViewGravityLeading];
	[row setCustomSpacing:10 afterView:row.views[row.views.count - 2]];

	_order = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	_order.controlSize = NSControlSizeSmall;
	_order.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
	_order.target = self;
	_order.action = @selector(onOrder:);
	auto pm = playlist_manager::get();
	for (size_t i = 0, n = pm->playback_order_get_count(); i < n; ++i)
		[_order addItemWithTitle:[NSString stringWithUTF8String:pm->playback_order_get_name(i)]];
	[row addView:_order inGravity:NSStackViewGravityLeading];

	// Volume: speaker toggles mute, slider uses a perceptual curve over foobar2000's dB range.
	_mute = [self button:@"speaker.wave.2.fill" tip:@"Mute" action:@selector(onMute:)];
	_volume = [NSSlider sliderWithValue:1 minValue:0 maxValue:1 target:self action:@selector(onVolume:)];
	_volume.controlSize = NSControlSizeSmall;
	_volume.toolTip = @"Volume";
	[_volume.widthAnchor constraintEqualToConstant:140].active = YES;
	[row addView:_mute inGravity:NSStackViewGravityLeading];
	[row addView:_volume inGravity:NSStackViewGravityLeading];
	_volumePct = [NSTextField labelWithString:@"100%"];
	_volumePct.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
	_volumePct.textColor = NSColor.secondaryLabelColor;
	_volumePct.alignment = NSTextAlignmentRight;
	[_volumePct.widthAnchor constraintEqualToConstant:36].active = YES;
	[row addView:_volumePct inGravity:NSStackViewGravityLeading];
	[row setCustomSpacing:14 afterView:_order];

	[row.heightAnchor constraintEqualToConstant:28].active = YES;
	self.view = row;
	[self syncOrder];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	__weak FooClassicToolbar * weakSelf = self;
	_timer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *) { [weakSelf syncOrder]; [weakSelf syncVolume]; [weakSelf syncWindowTitle]; }];
}

- (void)dealloc { [_timer invalidate]; }

- (void)syncOrder {
	auto active = playlist_manager::get()->playback_order_get_active();
	if ((NSInteger)active != _order.indexOfSelectedItem) [_order selectItemAtIndex:(NSInteger)active];
}

- (void)syncWindowTitle {
	NSWindow * w = self.view.window;
	if (!w) return;
	pfc::string8 fmt = cfg_windowTitle.get();
	if (fmt.is_empty()) return;
	NSString * title = @"foobar2000";
	auto pc = playback_control::get();
	if (pc->is_playing()) {
		titleformat_object::ptr script;
		titleformat_compiler::get()->compile_safe(script, fmt);
		pfc::string8 out;
		pc->playback_format_title(nullptr, out, script, nullptr, playback_control::display_level_titles);
		if (out.length()) title = [NSString stringWithUTF8String:out.c_str()] ?: title;
	}
	if (![w.title isEqualToString:title]) w.title = title;
}

- (void)syncVolume {
	if (!_volume || NSEvent.pressedMouseButtons) return; // don't fight the user's drag
	const float db = playback_control::get()->get_volume();
	_volume.doubleValue = db <= -100 ? 0 : pow(10.0, db / 40.0);
	_mute.image = [NSImage imageWithSystemSymbolName:db <= -100 ? @"speaker.slash.fill" : db < -20 ? @"speaker.wave.1.fill" : @"speaker.wave.2.fill"
							accessibilityDescription:@"Mute"];
	_volume.toolTip = [NSString stringWithFormat:@"Volume: %.1f dB", db];
	[self updatePercent];
}
- (void)updatePercent {
	_volumePct.stringValue = [NSString stringWithFormat:@"%ld%%", lround(_volume.doubleValue * 100)];
}
- (void)onVolume:(id)s {
	const double v = _volume.doubleValue;
	playback_control::get()->set_volume(v <= 0.001 ? -100.f : (float)(40.0 * log10(v)));
	_volume.toolTip = [NSString stringWithFormat:@"Volume: %.1f dB", playback_control::get()->get_volume()];
	[self updatePercent];
}
- (void)onMute:(id)s { playback_control::get()->volume_mute_toggle(); [self syncVolume]; }

- (void)onStop:(id)s { playback_control::get()->stop(); }
- (void)onPause:(id)s { playback_control::get()->pause(true); }
- (void)onPlay:(id)s {
	auto pc = playback_control::get();
	if (pc->is_paused()) pc->pause(false); else pc->start();
}
- (void)onPrev:(id)s { playback_control::get()->start(playback_control::track_command_prev); }
- (void)onNext:(id)s { playback_control::get()->start(playback_control::track_command_next); }
- (void)onRandom:(id)s { playback_control::get()->start(playback_control::track_command_rand); }
- (void)onOpen:(id)s { standard_commands::main_open(); }
- (void)onOrder:(id)s { playlist_manager::get()->playback_order_set_active((size_t)_order.indexOfSelectedItem); }
@end

// ---------------------------------------------------------------------------
// Status bar: track info + time on the left, volume on the right
// ---------------------------------------------------------------------------

// Editable via right-click on the status bar. %volume% is replaced with the current volume.
static const char * kStatusLeftDefault = "%codec% %bitrate%kbps %samplerate%Hz %channels% ¤ %playback_time%[ / %length%]";
static const char * kStatusRightDefault = "%volume%";
static cfg_string cfg_statusLeft(GUID { 0x4b1f8e27, 0x93a0, 0x4c5d, { 0xa8, 0x61, 0x2e, 0x7d, 0x30, 0xb9, 0x14, 0xf6 } }, kStatusLeftDefault);
static cfg_string cfg_statusRight(GUID { 0xd2836a4c, 0x0f71, 0x4e98, { 0x95, 0x3b, 0x6c, 0x14, 0xe2, 0x8a, 0x57, 0x09 } }, kStatusRightDefault);

@interface FooClassicStatusbar : NSViewController
@end

@implementation FooClassicStatusbar {
	NSTextField * _left;
	NSTextField * _right;
	NSTimer * _timer;
}

- (NSTextField *)label {
	NSTextField * f = [NSTextField labelWithString:@""];
	f.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
	f.textColor = NSColor.secondaryLabelColor;
	f.lineBreakMode = NSLineBreakByTruncatingTail;
	return f;
}

- (void)loadView {
	_left = [self label];
	_right = [self label];
	_right.alignment = NSTextAlignmentRight;
	[_left setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

	NSStackView * row = [NSStackView stackViewWithViews:@[_left, _right]];
	row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	row.distribution = NSStackViewDistributionFill;
	row.edgeInsets = NSEdgeInsetsMake(2, 6, 2, 8);
	[row.heightAnchor constraintEqualToConstant:20].active = YES;
	NSMenu * m = [NSMenu new];
	[m addItemWithTitle:@"Edit Status Bar Format…" action:@selector(editFormat:) keyEquivalent:@""].target = self;
	[m addItemWithTitle:@"Reset to Default" action:@selector(resetFormat:) keyEquivalent:@""].target = self;
	row.menu = m;
	self.view = row;
	[self refresh];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	__weak FooClassicStatusbar * weakSelf = self;
	_timer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *) { [weakSelf refresh]; }];
}

- (void)dealloc { [_timer invalidate]; }

static NSString * renderStatus(const char * format, bool playing) {
	auto pc = playback_control::get();
	pfc::string8 vol;
	vol << pfc::format_float(pc->get_volume(), 0, 2) << "dB";
	pfc::string8 spec = format;
	spec.replace_string("%volume%", vol);
	if (!playing) // without a track only a bare %volume% makes sense
		return strcmp(format, "%volume%") == 0 ? [NSString stringWithUTF8String:vol.c_str()] : @"";
	titleformat_object::ptr script;
	titleformat_compiler::get()->compile_safe(script, spec);
	pfc::string8 out;
	pc->playback_format_title(nullptr, out, script, nullptr, playback_control::display_level_all);
	return [NSString stringWithUTF8String:out.c_str()] ?: @"";
}

- (void)refresh {
	auto pc = playback_control::get();
	const bool playing = pc->is_playing();
	NSString * left = renderStatus(cfg_statusLeft.get().c_str(), playing);
	if (!playing) left = @"Stopped.";
	else if (pc->is_paused()) left = [@"Paused · " stringByAppendingString:left];
	_left.stringValue = left;
	_right.stringValue = renderStatus(cfg_statusRight.get().c_str(), playing);
}

- (void)editFormat:(id)s {
	NSAlert * a = [NSAlert new];
	a.messageText = @"Status bar format";
	a.informativeText = @"Title formatting, e.g. %codec% %bitrate%kbps ¤ %playback_time%[ / %length%]. Use %volume% for the volume.";
	[a addButtonWithTitle:@"OK"];
	[a addButtonWithTitle:@"Cancel"];
	NSTextField * left = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 30, 460, 22)];
	left.stringValue = [NSString stringWithUTF8String:cfg_statusLeft.get().c_str()];
	left.placeholderString = @"Left";
	NSTextField * right = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 460, 22)];
	right.stringValue = [NSString stringWithUTF8String:cfg_statusRight.get().c_str()];
	right.placeholderString = @"Right";
	NSView * box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 460, 52)];
	[box addSubview:left];
	[box addSubview:right];
	a.accessoryView = box;
	a.window.initialFirstResponder = left;
	void (^done)(NSModalResponse) = ^(NSModalResponse r) {
		if (r != NSAlertFirstButtonReturn) return;
		cfg_statusLeft = left.stringValue.UTF8String;
		cfg_statusRight = right.stringValue.UTF8String;
		[self refresh];
	};
	if (self.view.window) [a beginSheetModalForWindow:self.view.window completionHandler:done]; else done([a runModal]);
}

- (void)resetFormat:(id)s {
	cfg_statusLeft = kStatusLeftDefault;
	cfg_statusRight = kStatusRightDefault;
	[self refresh];
}
@end

// ---------------------------------------------------------------------------
// Playlist tabs, Windows style
// ---------------------------------------------------------------------------

@interface FooClassicTabsView : NSView
@property (nonatomic, copy) NSArray<NSString *> * names;
@property (nonatomic) NSInteger active;
@property (nonatomic) NSInteger dropIndex;
@property (nonatomic, copy) NSArray<NSNumber *> * locked;
@end

@implementation FooClassicTabsView {
	NSMutableArray<NSValue *> * _rects; // in content coordinates (before scrolling)
	NSInteger _menuIndex;
	CGFloat _scroll;
	CGFloat _contentWidth;
	NSInteger _dropIndex;   // tab under a drag, -1 = empty area, -2 = no drag
	NSInteger _moveTo;      // insertion index while dragging a tab to reorder, -1 = none
	NSTimer * _hoverTimer;  // switches to the hovered tab during a drag
	metadb_handle_list _dragItems; // tracks dragged out of a foobar2000 playlist view
	NSInteger _hover;       // tab under the mouse (shows the close button), -1 = none
	NSTrackingArea * _tracking;
}

static constexpr CGFloat kCloseBtn = 14; // close button area at the right of each tab, when enabled
static CGFloat closeW() { return cfg_tabClose.get() ? kCloseBtn : 0; }
static constexpr CGFloat kLockW = 13;    // lock icon area at the left of locked tabs

static constexpr CGFloat kArrowW = 18;

- (instancetype)initWithFrame:(NSRect)r {
	if ((self = [super initWithFrame:r])) { _moveTo = -1; _dropIndex = -2; _hover = -1; }
	return self;
}

- (void)updateTrackingAreas {
	[super updateTrackingAreas];
	if (_tracking) [self removeTrackingArea:_tracking];
	_tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
		options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
		owner:self userInfo:nil];
	[self addTrackingArea:_tracking];
}
- (void)mouseMoved:(NSEvent *)e {
	NSInteger h = [self tabAt:e];
	if (h != _hover) { _hover = h; [self setNeedsDisplay:YES]; }
}
- (void)mouseExited:(NSEvent *)e { _hover = -1; [self setNeedsDisplay:YES]; }

- (BOOL)isLocked:(NSUInteger)i { return i < _locked.count && _locked[i].boolValue; }
- (void)setLocked:(NSArray<NSNumber *> *)l { _locked = [l copy]; [self layoutTabs]; [self setNeedsDisplay:YES]; }

// Close button rect of tab i, in content coordinates.
- (NSRect)closeRectOf:(NSUInteger)i {
	NSRect r = _rects[i].rectValue;
	return NSMakeRect(NSMaxX(r) - kCloseBtn - 3, NSMidY(r) - kCloseBtn / 2, kCloseBtn, kCloseBtn);
}

- (BOOL)overflows { return _contentWidth > self.bounds.size.width; }
- (CGFloat)visibleWidth { return self.bounds.size.width - (self.overflows ? kArrowW * 2 : 0); }
- (CGFloat)maxScroll { return std::max<CGFloat>(0, _contentWidth - self.visibleWidth); }
- (void)setScrollTo:(CGFloat)v { _scroll = std::clamp<CGFloat>(v, 0, self.maxScroll); [self setNeedsDisplay:YES]; }

- (void)revealActive {
	[self layoutTabs];
	if (_active < 0 || (NSUInteger)_active >= _rects.count) return;
	NSRect r = _rects[_active].rectValue;
	if (r.origin.x < _scroll) [self setScrollTo:r.origin.x - 2];
	else if (NSMaxX(r) > _scroll + self.visibleWidth) [self setScrollTo:NSMaxX(r) - self.visibleWidth + 2];
}

- (void)scrollWheel:(NSEvent *)e {
	CGFloat d = fabs(e.scrollingDeltaX) > fabs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY;
	if (!e.hasPreciseScrollingDeltas) d *= 20;
	[self setScrollTo:_scroll - d];
}

- (void)setFrameSize:(NSSize)sz { [super setFrameSize:sz]; [self layoutTabs]; [self setScrollTo:_scroll]; }

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }

static NSDictionary * tabAttrs(BOOL active) {
	return @{
		NSFontAttributeName: [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:active ? NSFontWeightMedium : NSFontWeightRegular],
		NSForegroundColorAttributeName: active ? NSColor.labelColor : NSColor.secondaryLabelColor,
	};
}

- (void)setNames:(NSArray<NSString *> *)n { _names = [n copy]; [self layoutTabs]; [self setScrollTo:_scroll]; }
- (void)setActive:(NSInteger)a { _active = a; [self revealActive]; [self setNeedsDisplay:YES]; }

- (void)layoutTabs {
	_rects = [NSMutableArray array];
	CGFloat x = 2;
	const CGFloat h = self.bounds.size.height;
	for (NSUInteger i = 0; i < _names.count; ++i) {
		CGFloat w = std::min<CGFloat>(240, [_names[i] sizeWithAttributes:tabAttrs(i == (NSUInteger)_active)].width + 16
										 + closeW() + ([self isLocked:i] ? kLockW : 0));
		[_rects addObject:[NSValue valueWithRect:NSMakeRect(x, 3, w, h - 3)]];
		x += w + 1;
	}
	_contentWidth = x + 2;
}

- (void)drawRect:(NSRect)dirty {
	NSRect b = self.bounds;
	[NSColor.windowBackgroundColor setFill];
	NSRectFill(b);
	[self layoutTabs];

	[NSColor.separatorColor setFill];
	NSRectFill(NSMakeRect(0, b.size.height - 1, b.size.width, 1));

	[NSGraphicsContext saveGraphicsState];
	NSRectClip(NSMakeRect(0, 0, self.visibleWidth, b.size.height));
	NSAffineTransform * t = [NSAffineTransform transform];
	[t translateXBy:-_scroll yBy:0];
	[t concat];
	for (NSUInteger i = 0; i < _names.count; ++i) {
		NSRect r = _rects[i].rectValue;
		const BOOL act = (NSInteger)i == _active;
		NSBezierPath * path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 0, 0) xRadius:3 yRadius:3];
		[(act ? NSColor.controlBackgroundColor : [NSColor.quaternaryLabelColor colorWithAlphaComponent:0.15]) setFill];
		[path fill];
		[NSColor.separatorColor setStroke];
		[path stroke];
		if ((NSInteger)i == _dropIndex) {
			[[accentColor() colorWithAlphaComponent:0.35] setFill];
			[path fill];
		}
		if (act) { // merge the active tab into the list below
			[NSColor.controlBackgroundColor setFill];
			NSRectFill(NSMakeRect(r.origin.x + 1, b.size.height - 2, r.size.width - 2, 2));
		}
		NSDictionary * a = tabAttrs(act);
		NSMutableParagraphStyle * ps = [NSMutableParagraphStyle new];
		ps.lineBreakMode = NSLineBreakByTruncatingTail;
		NSMutableDictionary * am = [a mutableCopy];
		am[NSParagraphStyleAttributeName] = ps;
		NSSize sz = [_names[i] sizeWithAttributes:a];
		CGFloat tx = r.origin.x + 8;
		if ([self isLocked:i]) {
			NSImage * lock = [NSImage imageWithSystemSymbolName:@"lock.fill" accessibilityDescription:@"Locked"];
			[lock drawInRect:NSMakeRect(tx, NSMidY(r) - 5, 9, 10)];
			tx += kLockW;
		}
		[_names[i] drawInRect:NSMakeRect(tx, NSMidY(r) - sz.height / 2, NSMaxX(r) - tx - closeW() - 8, sz.height) withAttributes:am];
		if (cfg_tabClose.get() && (NSInteger)i == _hover && ![self isLocked:i] && _moveTo < 0) {
			NSDictionary * xa = @{ NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
								   NSForegroundColorAttributeName: NSColor.secondaryLabelColor };
			NSRect cr = [self closeRectOf:i];
			NSSize xs = [@"×" sizeWithAttributes:xa];
			[@"×" drawAtPoint:NSMakePoint(NSMidX(cr) - xs.width / 2, NSMidY(cr) - xs.height / 2) withAttributes:xa];
		}
	}
	if (_moveTo >= 0 && _rects.count) {
		const CGFloat mx = (NSUInteger)_moveTo < _rects.count ? _rects[_moveTo].rectValue.origin.x - 1
															  : NSMaxX(_rects.lastObject.rectValue) + 1;
		[accentColor() setFill];
		NSRectFill(NSMakeRect(mx - 1, 2, 3, b.size.height - 3));
	}
	[NSGraphicsContext restoreGraphicsState];

	if (self.overflows) {
		const CGFloat x0 = self.visibleWidth;
		NSDictionary * aa = @{ NSFontAttributeName: [NSFont systemFontOfSize:9],
							   NSForegroundColorAttributeName: NSColor.secondaryLabelColor };
		NSArray * glyphs = @[@"◀", @"▶"];
		for (int k = 0; k < 2; ++k) {
			NSRect r = NSMakeRect(x0 + k * kArrowW, 3, kArrowW, b.size.height - 4);
			NSSize sz = [glyphs[k] sizeWithAttributes:aa];
			[glyphs[k] drawAtPoint:NSMakePoint(NSMidX(r) - sz.width / 2, NSMidY(r) - sz.height / 2) withAttributes:aa];
		}
	}
}

- (NSInteger)tabAt:(NSEvent *)e {
	NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
	if (p.x >= self.visibleWidth) return -1;
	p.x += _scroll;
	for (NSUInteger i = 0; i < _rects.count; ++i)
		if (NSPointInRect(p, _rects[i].rectValue)) return (NSInteger)i;
	return -1;
}

- (void)mouseDown:(NSEvent *)e {
	NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
	if (self.overflows && p.x >= self.visibleWidth) { // arrow buttons: step one tab
		const BOOL right = p.x >= self.visibleWidth + kArrowW;
		CGFloat target = _scroll;
		for (NSValue * v in right ? _rects : _rects.reverseObjectEnumerator.allObjects) {
			CGFloat x = v.rectValue.origin.x - 2;
			if (right ? x > _scroll + 1 : x < _scroll - 1) { target = x; break; }
		}
		[self setScrollTo:target];
		return;
	}
	NSInteger i = [self tabAt:e];
	if (i >= 0 && cfg_tabClose.get() && ![self isLocked:(NSUInteger)i] && NSPointInRect(NSMakePoint(p.x + _scroll, p.y), [self closeRectOf:(NSUInteger)i])) {
		playlist_manager::get()->remove_playlist_switch((size_t)i); // close button
		_hover = -1;
		return;
	}
	if (e.clickCount == 2) {
		if (i < 0) [self newPlaylist:nil];
		else { _menuIndex = i; [self renamePlaylist:nil]; }
		return;
	}
	if (i < 0) return;
	playlist_manager::get()->set_active_playlist((size_t)i);
	self.active = i;
	[self trackTabMove:i from:e];
}

// Insertion index for x (view coordinates): before the tab whose middle is right of x.
- (NSInteger)insertIndexAtX:(CGFloat)x {
	x += _scroll;
	for (NSUInteger k = 0; k < _rects.count; ++k)
		if (x < NSMidX(_rects[k].rectValue)) return (NSInteger)k;
	return (NSInteger)_rects.count;
}

// Drag a tab sideways to reorder playlists.
- (void)trackTabMove:(NSInteger)from from:(NSEvent *)down {
	const NSPoint start = [self convertPoint:down.locationInWindow fromView:nil];
	BOOL moving = NO;
	_moveTo = -1;
	while (true) {
		NSEvent * e = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
		const NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
		if (e.type == NSEventTypeLeftMouseUp) break;
		if (!moving && fabs(p.x - start.x) < 5) continue;
		moving = YES;
		if (p.x < 10) [self setScrollTo:_scroll - 12];
		else if (p.x > self.visibleWidth - 10) [self setScrollTo:_scroll + 12];
		_moveTo = [self insertIndexAtX:p.x];
		[self setNeedsDisplay:YES];
	}
	const NSInteger to = _moveTo;
	_moveTo = -1;
	[self setNeedsDisplay:YES];
	if (!moving || to < 0 || to == from || to == from + 1) return;

	auto pm = playlist_manager::get();
	const size_t n = pm->get_playlist_count();
	std::vector<size_t> order;
	order.reserve(n);
	for (size_t k = 0; k < n; ++k) {
		if ((NSInteger)k == to) order.push_back((size_t)from);
		if ((NSInteger)k != from) order.push_back(k);
	}
	if (to >= (NSInteger)n) order.push_back((size_t)from);
	if (order.size() == n) pm->reorder(order.data(), n);
}

// --- Drag & drop: drop tracks/files onto a tab to add them to that playlist ---

- (NSInteger)tabAtPoint:(NSPoint)p {
	if (p.x >= self.visibleWidth) return -1;
	p.x += _scroll;
	for (NSUInteger i = 0; i < _rects.count; ++i)
		if (NSPointInRect(p, _rects[i].rectValue)) return (NSInteger)i;
	return -1;
}

static NSPasteboardType const kFb2kViewDrag = @"com.foobar2000.viewinstance";

static NSArray<NSURL *> * droppedURLs(id<NSDraggingInfo> info) {
	return [info.draggingPasteboard readObjectsForClasses:@[NSURL.class]
												  options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
}

// A drag from foobar2000's own playlist view. Its file URLs can't be read from inside the
// sandbox, so the dragged tracks are taken from the source playlist's selection instead.
static BOOL isPlaylistDrag(id<NSDraggingInfo> info) {
	NSArray * t = info.draggingPasteboard.types;
	return [t containsObject:kFb2kViewDrag] || [t containsObject:kClassicRowsType];
}
static BOOL isFileDrag(id<NSDraggingInfo> info) {
	return [info.draggingPasteboard.types containsObject:NSPasteboardTypeFileURL];
}

- (void)setDropIndex:(NSInteger)i {
	if (i == _dropIndex) return;
	_dropIndex = i;
	[_hoverTimer invalidate];
	_hoverTimer = nil;
	if (i >= 0 && i != _active) {
		_hoverTimer = [NSTimer scheduledTimerWithTimeInterval:0.7 repeats:NO block:^(NSTimer *) {
			if (self->_dropIndex == i) {
				playlist_manager::get()->set_active_playlist((size_t)i);
			}
		}];
	}
	[self setNeedsDisplay:YES];
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info {
	const BOOL ok = isPlaylistDrag(info) ? _dragItems.get_count() > 0 : isFileDrag(info);
	if (!ok) { self.dropIndex = -2; return NSDragOperationNone; }
	const NSPoint dp = [self convertPoint:info.draggingLocation fromView:nil];
	self.dropIndex = [self tabAtPoint:dp];
	// Answer with an operation the source allows; foobar2000's playlist view may offer only Move.
	const NSDragOperation mask = info.draggingSourceOperationMask;
	if (mask & NSDragOperationCopy) return NSDragOperationCopy;
	if (mask & NSDragOperationGeneric) return NSDragOperationGeneric;
	if (mask & NSDragOperationMove) return NSDragOperationMove;
	return NSDragOperationEvery & mask;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info {
	_dragItems.remove_all();
	if (isPlaylistDrag(info)) {
		// Snapshot now: hovering a tab switches the active playlist, which changes the selection.
		auto pm = playlist_manager::get();
		const size_t pl = pm->get_active_playlist();
		if (g_drag.active) _dragItems = g_drag.items;
		else if (pl != SIZE_MAX) pm->playlist_get_selected_items(pl, _dragItems);
	}
	return [self draggingUpdated:info];
}
- (void)draggingExited:(id<NSDraggingInfo>)info {
	self.dropIndex = -2;
}
- (void)draggingEnded:(id<NSDraggingInfo>)info {
	self.dropIndex = -2;
}
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info {
	return YES;
}

static void addToPlaylist(size_t pl, metadb_handle_list_cref items) {
	auto pm = playlist_manager::get();
	if (pl == SIZE_MAX || pl >= pm->get_playlist_count()) {
		pl = pm->create_playlist("New Playlist", SIZE_MAX, SIZE_MAX);
		if (pl == SIZE_MAX) return;
		pm->set_active_playlist(pl);
	}
	pm->playlist_add_items(pl, items, pfc::bit_array_false());
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
	const NSInteger target = [self tabAtPoint:[self convertPoint:info.draggingLocation fromView:nil]];
	self.dropIndex = -2;
	const size_t count = playlist_manager::get()->get_playlist_count();
	const size_t targetIdx = target >= 0 && (size_t)target < count ? (size_t)target : SIZE_MAX;

	if (isPlaylistDrag(info)) {
		if (_dragItems.get_count() == 0) return NO;
		addToPlaylist(targetIdx, _dragItems);
		_dragItems.remove_all();
		return YES;
	}

	NSArray<NSURL *> * urls = droppedURLs(info);
	if (urls.count == 0) return NO;

	pfc::list_t<pfc::string8> paths;
	for (NSURL * u in urls) paths.add_item(u.path.UTF8String);
	pfc::list_t<const char *> ptrs;
	for (size_t i = 0; i < paths.get_count(); ++i) ptrs.add_item(paths[i].c_str());

	// Dropping on empty space makes a new playlist.
	auto notify = process_locations_notify::create([targetIdx](metadb_handle_list_cref items) {
		addToPlaylist(targetIdx, items);
	});
	playlist_incoming_item_filter_v2::get()->process_locations_async(
		ptrs, playlist_incoming_item_filter_v2::op_flag_background | playlist_incoming_item_filter_v2::op_flag_delay_ui,
		nullptr, nullptr, nullptr, notify);
	return YES;
}

- (NSMenu *)menuForEvent:(NSEvent *)e {
	_menuIndex = [self tabAt:e];
	if ([self convertPoint:e.locationInWindow fromView:nil].x >= self.visibleWidth) return nil;
	NSMenu * m = [NSMenu new];
	[m addItemWithTitle:@"New Playlist" action:@selector(newPlaylist:) keyEquivalent:@""].target = self;
	if (_menuIndex >= 0) {
		[m addItemWithTitle:@"Rename…" action:@selector(renamePlaylist:) keyEquivalent:@""].target = self;
		const BOOL locked = [self isLocked:(NSUInteger)_menuIndex];
		NSMenuItem * rm = [m addItemWithTitle:@"Remove" action:locked ? nil : @selector(removePlaylist:) keyEquivalent:@""];
		rm.target = self;
		[m addItem:NSMenuItem.separatorItem];
		[m addItemWithTitle:locked ? @"Unlock Playlist" : @"Lock Playlist" action:@selector(toggleLock:) keyEquivalent:@""].target = self;
	}
	[m addItem:NSMenuItem.separatorItem];
	NSMenu * closed = [NSMenu new];
	for (size_t k = g_closed.size(); k-- > 0;) {
		NSString * title = [NSString stringWithFormat:@"%s  (%zu)", g_closed[k].name.c_str(), g_closed[k].items.get_count()];
		NSMenuItem * it = [closed addItemWithTitle:title action:@selector(restoreClosedItem:) keyEquivalent:@""];
		it.target = self;
		it.tag = (NSInteger)k;
	}
	NSMenuItem * rc = [m addItemWithTitle:@"Recently Closed" action:nil keyEquivalent:@""];
	if (closed.numberOfItems) rc.submenu = closed; else rc.enabled = NO;
	return m;
}

- (void)toggleLock:(id)s {
	if (_menuIndex < 0) return;
	setPlaylistLocked((size_t)_menuIndex, ![self isLocked:(NSUInteger)_menuIndex]);
}
- (void)restoreClosedItem:(NSMenuItem *)item { restoreClosed((size_t)item.tag); }

- (void)newPlaylist:(id)s {
	auto pm = playlist_manager::get();
	size_t idx = pm->create_playlist("New Playlist", SIZE_MAX, SIZE_MAX);
	if (idx != SIZE_MAX) pm->set_active_playlist(idx);
}

- (void)removePlaylist:(id)s {
	if (_menuIndex >= 0) playlist_manager::get()->remove_playlist_switch((size_t)_menuIndex);
}

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
	if (self.window) [a beginSheetModalForWindow:self.window completionHandler:done];
	else done([a runModal]);
}
@end

@interface FooClassicTabs : NSViewController
@end

@implementation FooClassicTabs {
	FooClassicTabsView * _tabs;
	NSTimer * _timer;
	id _keyMonitor;
}

- (void)loadView {
	_tabs = [[FooClassicTabsView alloc] initWithFrame:NSMakeRect(0, 0, 400, 24)];
	_tabs.dropIndex = -2;
	[_tabs registerForDraggedTypes:@[NSPasteboardTypeFileURL, @"com.foobar2000.viewinstance", kClassicRowsType]];
	[_tabs.heightAnchor constraintEqualToConstant:24].active = YES;
	self.view = _tabs;
	[self refresh];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	__weak FooClassicTabs * weakSelf = self;
	_timer = [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *) { [weakSelf refresh]; }];

	[NSNotificationCenter.defaultCenter addObserverForName:kClassicPrefsChanged object:nil queue:nil usingBlock:^(NSNotification *) {
		FooClassicTabs * s = weakSelf;
		if (s) [s->_tabs setNeedsDisplay:YES];
	}];

	// Left/right arrows switch playlists, unless a text field is being edited.
	_keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent * e) {
		FooClassicTabs * s = weakSelf;
		if (!s || e.window != s.view.window) return e;
		if ([e.window.firstResponder isKindOfClass:NSText.class]) return e;
		const NSEventModifierFlags mods = e.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl | NSEventModifierFlagShift);
		if (mods && [s handleShortcut:e.keyCode mods:mods]) return nil;
		if (mods) return e;
		int dir = e.keyCode == 123 ? -1 : e.keyCode == 124 ? 1 : 0;
		if (dir == 0) return e;
		auto pm = playlist_manager::get();
		const size_t n = pm->get_playlist_count(), cur = pm->get_active_playlist();
		if (n == 0) return nil;
		size_t next = cur == SIZE_MAX ? 0 : (cur + n + dir) % n;
		pm->set_active_playlist(next);
		[s refresh];
		return nil;
	}];
}

- (void)dealloc {
	[_timer invalidate];
	if (_keyMonitor) [NSEvent removeMonitor:_keyMonitor];
}

// Physical keys, so shortcuts work with any keyboard layout.
// ⌘1…⌘8 playlist N, ⌘9 last playlist, ⌘T new, ⇧⌘T reopen closed, ⌥⌘W close, ⌘J jump to playing.
- (BOOL)handleShortcut:(unsigned short)key mods:(NSEventModifierFlags)mods {
	auto pm = playlist_manager::get();
	const size_t n = pm->get_playlist_count();
	if (mods == NSEventModifierFlagCommand) {
		static const unsigned short digits[] = { 18, 19, 20, 21, 23, 22, 26, 28, 25 }; // 1…9
		for (size_t d = 0; d < 9; ++d) if (key == digits[d]) {
			if (n == 0) return YES;
			pm->set_active_playlist(d == 8 ? n - 1 : std::min(d, n - 1));
			[self refresh];
			return YES;
		}
		if (key == 17) { // T
			const size_t pl = pm->create_playlist("New Playlist", SIZE_MAX, SIZE_MAX);
			if (pl != SIZE_MAX) pm->set_active_playlist(pl);
			return YES;
		}
		if (key == 38) { goToPlaying(); return YES; } // J
	}
	if (mods == (NSEventModifierFlagCommand | NSEventModifierFlagShift) && key == 17) { restoreClosed(); return YES; }
	if (mods == (NSEventModifierFlagCommand | NSEventModifierFlagOption) && key == 13) { // W
		const size_t cur = pm->get_active_playlist();
		if (cur != SIZE_MAX && !pm->remove_playlist_switch(cur)) NSBeep(); // locked playlists refuse
		return YES;
	}
	return NO;
}

- (void)refresh {
	auto pm = playlist_manager::get();
	NSMutableArray * names = [NSMutableArray array];
	NSMutableArray * locked = [NSMutableArray array];
	for (size_t i = 0, n = pm->get_playlist_count(); i < n; ++i) {
		pfc::string8 name;
		pm->playlist_get_name(i, name);
		[names addObject:[NSString stringWithUTF8String:name.c_str()] ?: @""];
		[locked addObject:@(pm->playlist_lock_is_present(i))];
	}
	if (![locked isEqualToArray:_tabs.locked]) _tabs.locked = locked;
	const size_t act = pm->get_active_playlist();
	NSInteger active = act == SIZE_MAX ? -1 : (NSInteger)act;
	if (![names isEqualToArray:_tabs.names]) _tabs.names = names;
	if (active != _tabs.active) _tabs.active = active;
}
@end

// ---------------------------------------------------------------------------
// Playlist with configurable columns (Windows-style)
// ---------------------------------------------------------------------------

struct ColumnDef { const char * key; const char * title; const char * format; bool right; CGFloat width; };

// Built-in columns, matching foobar2000's own column menu.
static const ColumnDef kColumns[] = {
	{ "index",       "Item index",           nullptr,                                            true,  50 },
	{ "artist",      "Artist",               "[%artist%]",                                       false, 180 },
	{ "album",       "Album",                "[%album%]",                                        false, 180 },
	{ "artistalbum", "Artist/album",         "$if2(%album artist%,?) – $if2(%album%,?)",         false, 250 },
	{ "trackno",     "Track no",             "[%tracknumber%]",                                  true,  60 },
	{ "title",       "Title",                "%title%",                                          false, 250 },
	{ "titleartist", "Title / track artist", "%title%[ // %track artist%]",                      false, 400 },
	{ "date",        "Date",                 "[%date%]",                                         true,  70 },
	{ "duration",    "Duration",             "[%length%]",                                       true,  60 },
	{ "codec",       "Codec",                "[%codec%]",                                        false, 70 },
	{ "bitrate",     "Bitrate",              "[%bitrate% kbps]",                                 true,  80 },
	{ "playing",     "Playing",              nullptr,                                            false, 60 },
	{ "filename",    "File name",            "%filename_ext%",                                   false, 250 },
	{ "ext",         "File extension",       "$ext(%path%)",                                     false, 70 },
	{ "path",        "File path",            "%path%",                                           false, 450 },
	{ "size",        "File size",            "[%filesize_natural%]",                             true,  80 },
	{ "playcount",   "Play Count",           "[%play_count%]",                                   true,  70 },
	{ "firstplayed", "First Played",         "[%first_played%]",                                 false, 140 },
	{ "lastplayed",  "Last Played",          "[%last_played%]",                                  false, 140 },
	{ "added",       "Date Added",           "[%added%]",                                        false, 140 },
	{ "rating",      "Rating",               "[%rating%]",                                       true,  60 },
};
static const int kColumnSeparatorAfter = 15; // menu separator after "File size"

static const ColumnDef * findColumn(NSString * key) {
	for (auto & c : kColumns) if ([key isEqualToString:@(c.key)]) return &c;
	return nullptr;
}

// Saved as lines: "key\twidth" for built-ins, "custom\twidth\tname\tformat" for custom columns.
static cfg_string cfg_columns(GUID { 0x0c7d3e51, 0x6b2a, 0x4f9e, { 0x83, 0x1c, 0xa4, 0x59, 0x2e, 0xd7, 0x06, 0xbb } },
	"playing\t60\nartistalbum\t250\ntitleartist\t400\nduration\t60\nplaycount\t70\npath\t450");

// Group headers, like Windows DUI. Key -> title formatting of the group header.
struct GroupDef { const char * key; const char * title; const char * format; };
static const GroupDef kGroups[] = {
	{ "none",   "None",            nullptr },
	{ "album",  "Artist / Album",  "$if2(%album artist%,?) – $if2(%album%,?)[ '('%date%')']" },
	{ "artist", "Artist",          "$if2(%album artist%,?)" },
	{ "folder", "Folder",          "$directory_path(%path%)" },
};
static cfg_string cfg_groupBy(GUID { 0x77a2c3e9, 0x1b05, 0x4d6f, { 0x9c, 0x24, 0xe1, 0x5a, 0x80, 0x3d, 0x6b, 0x12 } }, "none");

static NSColor * playingColor() { return accentColor(); }

@interface FooClassicPlaylist : NSViewController <NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate>
- (void)scheduleRebuild;
- (void)syncSelection;
- (void)revealItem:(size_t)idx;
- (void)playingChanged;
- (void)removeSelection;
- (void)playClicked;
- (NSMenu *)contextMenu;
- (void)showSearch;
- (BOOL)canEdit:(SEL)action;
- (NSInteger)playingRow;
- (BOOL)isHeaderRow:(NSInteger)row;
- (void)doCopy:(BOOL)cut;
- (void)doPaste;
- (void)doUndo:(BOOL)redo;
@end

@interface FooClassicTableView : NSTableView
@property (nonatomic, weak) FooClassicPlaylist * owner;
@end

@implementation FooClassicTableView
// Shortcuts by physical key, so they work with any keyboard layout (e.g. Russian ⌘Ф = ⌘A).
- (BOOL)performKeyEquivalent:(NSEvent *)e {
	if (self.window.firstResponder == self && e.type == NSEventTypeKeyDown) {
		const NSEventModifierFlags mods = e.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption | NSEventModifierFlagControl);
		if (mods == NSEventModifierFlagCommand) {
			if (e.keyCode == 0) { [self selectAll:nil]; return YES; }              // A
			if (e.keyCode == 3) { [self.owner showSearch]; return YES; }           // F
		}
		// Non-Latin layout: run the main menu command bound to the same physical key (⌘C, ⌘V, ⌘X, ⌘Z…).
		NSString * typed = e.charactersIgnoringModifiers;
		if ((mods & NSEventModifierFlagCommand) && typed.length && [typed characterAtIndex:0] > 0x7F) {
			NSString * latin = latinForKeyCode(e.keyCode);
			if (latin && performMenuShortcut(NSApp.mainMenu, latin, mods)) return YES;
		}
	}
	return [super performKeyEquivalent:e];
}

static NSString * latinForKeyCode(unsigned short code) {
	static const char * map[] = {
		"a","s","d","f","h","g","z","x","c","v",nullptr,"b","q","w","e","r","y","t",
		nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,
		"o","u",nullptr,"i","p",nullptr,"l","j",nullptr,"k",nullptr,nullptr,nullptr,nullptr,"n","m" };
	if (code >= sizeof(map) / sizeof(map[0]) || !map[code]) return nil;
	return @(map[code]);
}

static BOOL performMenuShortcut(NSMenu * menu, NSString * key, NSEventModifierFlags mods) {
	[menu update];
	for (NSInteger i = 0; i < menu.numberOfItems; ++i) {
		NSMenuItem * it = [menu itemAtIndex:i];
		if (it.submenu) {
			if (performMenuShortcut(it.submenu, key, mods)) return YES;
			continue;
		}
		NSEventModifierFlags itemMods = it.keyEquivalentModifierMask;
		NSString * ke = it.keyEquivalent;
		// Upper-case key equivalents imply Shift.
		if (ke.length == 1 && [ke characterAtIndex:0] >= 'A' && [ke characterAtIndex:0] <= 'Z') {
			itemMods |= NSEventModifierFlagShift;
			ke = ke.lowercaseString;
		}
		if (it.enabled && [ke isEqualToString:key] && itemMods == mods) {
			[menu performActionForItemAtIndex:i];
			return YES;
		}
	}
	return NO;
}
// Edit menu commands (the built-in playlist handles these itself).
- (void)copy:(id)s { [self.owner doCopy:NO]; }
- (void)cut:(id)s { [self.owner doCopy:YES]; }
- (void)paste:(id)s { [self.owner doPaste]; }
- (void)delete:(id)s { [self.owner removeSelection]; }
- (void)undo:(id)s { [self.owner doUndo:NO]; }
- (void)redo:(id)s { [self.owner doUndo:YES]; }
- (BOOL)validateMenuItem:(NSMenuItem *)item {
	SEL a = item.action;
	if (a == @selector(copy:) || a == @selector(cut:) || a == @selector(paste:) || a == @selector(delete:)
		|| a == @selector(undo:) || a == @selector(redo:)) return [self.owner canEdit:a];
	return [super validateMenuItem:item];
}

- (void)highlightSelectionInClipRect:(NSRect)clip {
	NSColor * sel = selectionColor();
	if (!sel) { [super highlightSelectionInClipRect:clip]; return; }
	[sel setFill];
	NSIndexSet * rows = self.selectedRowIndexes;
	for (NSUInteger r = rows.firstIndex; r != NSNotFound; r = [rows indexGreaterThanIndex:r]) {
		NSRect rr = [self rectOfRow:(NSInteger)r];
		if (NSIntersectsRect(rr, clip)) NSRectFill(rr);
	}
}

- (void)drawRow:(NSInteger)row clipRect:(NSRect)clip {
	if (row == [self.owner playingRow] && ![self isRowSelected:row]) {
		[[playingColor() colorWithAlphaComponent:0.22] setFill];
		NSRectFill([self rectOfRow:row]);
	}
	[super drawRow:row clipRect:clip];
}

- (NSMenu *)menuForEvent:(NSEvent *)e {
	NSInteger row = [self rowAtPoint:[self convertPoint:e.locationInWindow fromView:nil]];
	if (row < 0 || [self.owner isHeaderRow:row]) return nil;
	if (![self isRowSelected:row]) [self selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
	return [self.owner contextMenu];
}
- (void)keyDown:(NSEvent *)e {
	unichar c = e.charactersIgnoringModifiers.length ? [e.charactersIgnoringModifiers characterAtIndex:0] : 0;
	if (c == NSDeleteCharacter || c == NSDeleteFunctionKey) { [self.owner removeSelection]; return; }
	if (c == NSCarriageReturnCharacter || c == NSEnterCharacter) { [self.owner playClicked]; return; }
	[super keyDown:e];
}
@end

namespace {
	class ClassicPlaylistCallback : public playlist_callback_impl_base {
	public:
		ClassicPlaylistCallback(FooClassicPlaylist * o) : playlist_callback_impl_base(flag_all), m_owner(o) {}
		void on_items_added(t_size, t_size, metadb_handle_list_cref, const bit_array &) override { [m_owner scheduleRebuild]; }
		void on_items_reordered(t_size, const t_size *, t_size) override { [m_owner scheduleRebuild]; }
		void on_items_removed(t_size, const bit_array &, t_size, t_size) override { [m_owner scheduleRebuild]; }
		void on_items_modified(t_size, const bit_array &) override { [m_owner scheduleRebuild]; }
		void on_items_modified_fromplayback(t_size, const bit_array &, play_control::t_display_level) override { [m_owner scheduleRebuild]; }
		void on_items_replaced(t_size, const bit_array &, const pfc::list_base_const_t<t_on_items_replaced_entry> &) override { [m_owner scheduleRebuild]; }
		void on_playlist_activate(t_size, t_size) override { [m_owner scheduleRebuild]; }
		void on_items_selection_change(t_size, const bit_array &, const bit_array &) override { [m_owner syncSelection]; }
		void on_item_ensure_visible(t_size p, t_size idx) override {
			if (p == playlist_manager::get()->get_active_playlist()) [m_owner revealItem:idx];
		}
	private:
		__weak FooClassicPlaylist * m_owner;
	};
	class ClassicPlayCallback : public play_callback_impl_base {
	public:
		ClassicPlayCallback(FooClassicPlaylist * o) : play_callback_impl_base(flag_on_playback_new_track | flag_on_playback_stop | flag_on_playback_pause), m_owner(o) {}
		void on_playback_new_track(metadb_handle_ptr) override { [m_owner playingChanged]; }
		void on_playback_stop(play_control::t_stop_reason) override { [m_owner playingChanged]; }
		void on_playback_pause(bool) override { [m_owner playingChanged]; }
	private:
		__weak FooClassicPlaylist * m_owner;
	};
}

@implementation FooClassicPlaylist {
	FooClassicTableView * _table;
	std::unique_ptr<ClassicPlaylistCallback> _plcb;
	std::unique_ptr<ClassicPlayCallback> _pbcb;
	metadb_handle_list _items;
	size_t _playlist;
	NSMutableDictionary<NSString *, NSValue *> * _scripts; // column identifier -> titleformat_object*
	std::vector<titleformat_object::ptr> _scriptStore;
	NSCache<NSString *, NSString *> * _cache;
	BOOL _syncing, _rebuildPending, _loadingColumns;
	NSString * _home;
	NSString * _sortColumn; // last column sorted by, for toggling direction
	BOOL _sortDescending;
	contextmenu_manager::ptr _menuManager; // keeps context menu nodes alive while the menu is open
	std::vector<ptrdiff_t> _rowItem;      // table row -> playlist item, -1 = group header
	std::vector<size_t> _itemRow;         // playlist item -> table row
	NSMutableDictionary<NSNumber *, NSString *> * _headers; // header row -> text
	NSTextFieldCell * _headerCell;
	NSMutableDictionary<NSNumber *, NSString *> * _queueLabels; // item -> "1" / "2, 5"
	NSView * _searchBar;
	NSSearchField * _search;
	NSTextField * _searchInfo;
	std::vector<size_t> _matches;
	size_t _matchPos;
}

- (void)loadView {
	NSScrollView * sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
	sv.hasVerticalScroller = YES;
	sv.hasHorizontalScroller = YES;
	sv.autohidesScrollers = YES;

	_table = [[FooClassicTableView alloc] initWithFrame:sv.bounds];
	_table.owner = self;
	_table.allowsMultipleSelection = YES;
	_table.allowsColumnReordering = YES;
	_table.allowsColumnResizing = YES;
	_table.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
	_table.style = NSTableViewStylePlain;
	_table.rowHeight = playlistRowHeight();
	_table.intercellSpacing = NSMakeSize(6, 0);
	_table.dataSource = self;
	_table.delegate = self;
	_table.target = self;
	_table.doubleAction = @selector(playClicked);
	[_table registerForDraggedTypes:@[kClassicRowsType, NSPasteboardTypeFileURL]];
	[_table setDraggingSourceOperationMask:NSDragOperationMove | NSDragOperationCopy forLocal:YES];
	[_table setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO]; // Finder & other apps get copies
	_table.draggingDestinationFeedbackStyle = NSTableViewDraggingDestinationFeedbackStyleGap;

	NSMenu * headerMenu = [NSMenu new];
	headerMenu.delegate = self;
	_table.headerView.menu = headerMenu;

	sv.documentView = _table;

	_search = [NSSearchField new];
	_search.placeholderString = @"Search playlist";
	_search.controlSize = NSControlSizeSmall;
	_search.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
	_search.sendsSearchStringImmediately = YES;
	_search.target = self;
	_search.action = @selector(onSearch:);
	_search.delegate = (id<NSSearchFieldDelegate>)self;
	[_search.widthAnchor constraintEqualToConstant:260].active = YES;
	_searchInfo = [NSTextField labelWithString:@""];
	_searchInfo.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
	_searchInfo.textColor = NSColor.secondaryLabelColor;
	NSButton * close = [NSButton buttonWithTitle:@"Done" target:self action:@selector(hideSearch)];
	close.controlSize = NSControlSizeSmall;
	close.bezelStyle = NSBezelStyleRounded;
	NSStackView * bar = [NSStackView stackViewWithViews:@[_search, _searchInfo, [NSView new], close]];
	bar.edgeInsets = NSEdgeInsetsMake(4, 8, 4, 8);
	bar.hidden = YES;
	_searchBar = bar;

	NSStackView * root = [NSStackView stackViewWithViews:@[bar, sv]];
	root.orientation = NSUserInterfaceLayoutOrientationVertical;
	root.spacing = 0;
	root.alignment = NSLayoutAttributeWidth;
	root.detachesHiddenViews = YES;
	self.view = root;

	_cache = [NSCache new];
	_cache.countLimit = 20000;
	_home = NSHomeDirectory();
	[self loadColumns];

	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(columnsChanged:) name:NSTableViewColumnDidMoveNotification object:_table];
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(columnsChanged:) name:NSTableViewColumnDidResizeNotification object:_table];
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(prefsChanged:) name:kClassicPrefsChanged object:nil];
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(queueChanged:) name:kClassicQueueChanged object:nil];
	[self rebuild];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	_plcb = std::make_unique<ClassicPlaylistCallback>(self);
	_pbcb = std::make_unique<ClassicPlayCallback>(self);
}

- (void)dealloc {
	[NSNotificationCenter.defaultCenter removeObserver:self];
	_plcb.reset(); _pbcb.reset();
}

// --- Columns -----------------------------------------------------------------

- (NSTableColumn *)makeColumn:(NSString *)ident title:(NSString *)title width:(CGFloat)w right:(BOOL)right {
	NSTableColumn * col = [[NSTableColumn alloc] initWithIdentifier:ident];
	col.title = title;
	col.width = w;
	col.minWidth = 20;
	col.resizingMask = NSTableColumnUserResizingMask;
	NSTextFieldCell * cell = [NSTextFieldCell new];
	cell.font = playlistFont(NO);
	cell.lineBreakMode = NSLineBreakByTruncatingTail;
	cell.alignment = right ? NSTextAlignmentRight : NSTextAlignmentLeft;
	col.dataCell = cell;
	col.headerCell.alignment = cell.alignment;
	return col;
}

- (void)compileColumn:(NSString *)ident format:(const char *)fmt {
	if (!fmt) return;
	titleformat_object::ptr obj;
	titleformat_compiler::get()->compile_safe(obj, fmt);
	_scriptStore.push_back(obj);
	_scripts[ident] = [NSValue valueWithPointer:obj.get_ptr()];
}

- (void)loadColumns {
	_loadingColumns = YES;
	while (_table.tableColumns.count) [_table removeTableColumn:_table.tableColumns.lastObject];
	_scripts = [NSMutableDictionary dictionary];
	_scriptStore.clear();

	NSString * saved = [NSString stringWithUTF8String:cfg_columns.get().c_str()];
	int customN = 0;
	for (NSString * line in [saved componentsSeparatedByString:@"\n"]) {
		NSArray * f = [line componentsSeparatedByString:@"\t"];
		if (f.count < 2) continue;
		CGFloat w = [f[1] doubleValue];
		if ([f[0] isEqualToString:@"custom"] && f.count >= 4) {
			NSString * ident = [NSString stringWithFormat:@"custom%d\t%@\t%@", customN++, f[2], f[3]];
			[_table addTableColumn:[self makeColumn:ident title:f[2] width:w right:NO]];
			[self compileColumn:ident format:[f[3] UTF8String]];
		} else if (auto def = findColumn(f[0])) {
			[_table addTableColumn:[self makeColumn:f[0] title:@(def->title) width:w right:def->right]];
			[self compileColumn:f[0] format:def->format];
		}
	}
	_loadingColumns = NO;
	[_cache removeAllObjects];
	[_table reloadData];
}

- (void)saveColumns {
	NSMutableArray * lines = [NSMutableArray array];
	for (NSTableColumn * c in _table.tableColumns) {
		if ([c.identifier hasPrefix:@"custom"]) {
			NSArray * f = [c.identifier componentsSeparatedByString:@"\t"];
			[lines addObject:[NSString stringWithFormat:@"custom\t%d\t%@\t%@", (int)c.width, f[1], f[2]]];
		} else {
			[lines addObject:[NSString stringWithFormat:@"%@\t%d", c.identifier, (int)c.width]];
		}
	}
	cfg_columns = [[lines componentsJoinedByString:@"\n"] UTF8String];
}

- (void)rebuildQueue {
	_queueLabels = [NSMutableDictionary dictionary];
	pfc::list_t<t_playback_queue_item> q;
	playlist_manager::get()->queue_get_contents(q);
	for (size_t k = 0; k < q.get_count(); ++k) {
		if (q[k].m_playlist != _playlist) continue;
		NSNumber * key = @(q[k].m_item);
		NSString * pos = [NSString stringWithFormat:@"%zu", k + 1];
		_queueLabels[key] = _queueLabels[key] ? [NSString stringWithFormat:@"%@, %@", _queueLabels[key], pos] : pos;
	}
}
- (void)queueChanged:(NSNotification *)n { [self rebuildQueue]; [_table reloadData]; }

- (void)prefsChanged:(NSNotification *)n {
	_table.rowHeight = playlistRowHeight();
	for (NSTableColumn * c in _table.tableColumns) ((NSTextFieldCell *)c.dataCell).font = playlistFont(NO);
	_headerCell.font = playlistFont(YES);
	[_table noteHeightOfRowsWithIndexesChanged:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, (NSUInteger)_table.numberOfRows)]];
	[_table reloadData];
}

- (void)columnsChanged:(NSNotification *)n { if (!_loadingColumns) [self saveColumns]; }

- (void)menuNeedsUpdate:(NSMenu *)menu {
	[menu removeAllItems];
	int i = 0;
	for (auto & c : kColumns) {
		NSMenuItem * it = [menu addItemWithTitle:@(c.title) action:@selector(toggleColumn:) keyEquivalent:@""];
		it.target = self;
		it.representedObject = @(c.key);
		it.state = [_table tableColumnWithIdentifier:@(c.key)] ? NSControlStateValueOn : NSControlStateValueOff;
		if (i++ == kColumnSeparatorAfter) [menu addItem:NSMenuItem.separatorItem];
	}
	NSMutableArray * customs = [NSMutableArray array];
	for (NSTableColumn * c in _table.tableColumns) if ([c.identifier hasPrefix:@"custom"]) [customs addObject:c];
	if (customs.count) {
		[menu addItem:NSMenuItem.separatorItem];
		for (NSTableColumn * c in customs) {
			NSMenuItem * it = [menu addItemWithTitle:[NSString stringWithFormat:@"Remove “%@”", c.title] action:@selector(removeCustom:) keyEquivalent:@""];
			it.target = self;
			it.representedObject = c.identifier;
		}
	}
	[menu addItem:NSMenuItem.separatorItem];
	[menu addItemWithTitle:@"More…" action:@selector(addCustom:) keyEquivalent:@""].target = self;

	[menu addItem:NSMenuItem.separatorItem];
	NSMenu * groups = [NSMenu new];
	const pfc::string8 current = cfg_groupBy.get();
	for (auto & g : kGroups) {
		NSMenuItem * it = [groups addItemWithTitle:@(g.title) action:@selector(setGrouping:) keyEquivalent:@""];
		it.target = self;
		it.representedObject = @(g.key);
		it.state = current == g.key ? NSControlStateValueOn : NSControlStateValueOff;
	}
	[menu addItemWithTitle:@"Group by" action:nil keyEquivalent:@""].submenu = groups;
}

- (void)setGrouping:(NSMenuItem *)item {
	cfg_groupBy = [item.representedObject UTF8String];
	[self rebuild];
}

- (void)toggleColumn:(NSMenuItem *)item {
	NSString * key = item.representedObject;
	if (NSTableColumn * c = [_table tableColumnWithIdentifier:key]) {
		[_table removeTableColumn:c];
	} else if (auto def = findColumn(key)) {
		[_table addTableColumn:[self makeColumn:key title:@(def->title) width:def->width right:def->right]];
		[self compileColumn:key format:def->format];
	}
	[self saveColumns];
	[_table reloadData];
}

- (void)removeCustom:(NSMenuItem *)item {
	if (NSTableColumn * c = [_table tableColumnWithIdentifier:item.representedObject]) [_table removeTableColumn:c];
	[self saveColumns];
}

- (void)addCustom:(id)s {
	NSAlert * a = [NSAlert new];
	a.messageText = @"Add column";
	a.informativeText = @"Name and title formatting pattern, e.g. %genre%";
	[a addButtonWithTitle:@"Add"];
	[a addButtonWithTitle:@"Cancel"];
	NSTextField * name = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 30, 300, 22)];
	name.placeholderString = @"Name";
	NSTextField * fmt = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 22)];
	fmt.placeholderString = @"Pattern";
	NSView * box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 52)];
	[box addSubview:name];
	[box addSubview:fmt];
	a.accessoryView = box;
	a.window.initialFirstResponder = name;
	void (^done)(NSModalResponse) = ^(NSModalResponse r) {
		NSString * n = [name.stringValue stringByReplacingOccurrencesOfString:@"\t" withString:@" "];
		NSString * f = [fmt.stringValue stringByReplacingOccurrencesOfString:@"\t" withString:@" "];
		if (r != NSAlertFirstButtonReturn || n.length == 0 || f.length == 0) return;
		cfg_columns = [[NSString stringWithFormat:@"%s\ncustom\t150\t%@\t%@", cfg_columns.get().c_str(), n, f] UTF8String];
		[self loadColumns];
	};
	if (self.view.window) [a beginSheetModalForWindow:self.view.window completionHandler:done]; else done([a runModal]);
}

// --- Data ----------------------------------------------------------------------

- (void)scheduleRebuild {
	if (_rebuildPending) return;
	_rebuildPending = YES;
	dispatch_async(dispatch_get_main_queue(), ^{ self->_rebuildPending = NO; [self rebuild]; });
}

- (void)rebuild {
	auto pm = playlist_manager::get();
	const size_t pl = pm->get_active_playlist();
	const BOOL switched = pl != _playlist;
	_playlist = pl;
	_items.remove_all();
	if (pl != SIZE_MAX) pm->playlist_get_all_items(pl, _items);
	[self buildRows];
	[self rebuildQueue];
	[_cache removeAllObjects];
	[_table reloadData];
	if (switched) {
		[_table scrollRowToVisible:0];
		_sortColumn = nil;
		for (NSTableColumn * c in _table.tableColumns) [_table setIndicatorImage:nil inTableColumn:c];
	}
	[self syncSelection];
}

- (void)buildRows {
	_rowItem.clear();
	_itemRow.assign(_items.get_count(), 0);
	_headers = [NSMutableDictionary dictionary];
	const char * fmt = nullptr;
	const pfc::string8 key = cfg_groupBy.get();
	for (auto & g : kGroups) if (key == g.key) fmt = g.format;
	titleformat_object::ptr script;
	if (fmt) titleformat_compiler::get()->compile_safe(script, fmt);
	pfc::string8 group, prev;
	for (size_t i = 0; i < _items.get_count(); ++i) {
		if (script.is_valid()) {
			_items[i]->format_title(nullptr, group, script, nullptr);
			if (i == 0 || strcmp(group, prev) != 0) {
				NSString * text = [NSString stringWithUTF8String:group.c_str()] ?: @"";
				if ([text hasPrefix:@"file://"]) text = [text substringFromIndex:7];
				if ([text hasPrefix:_home]) text = [@"~" stringByAppendingString:[text substringFromIndex:_home.length]];
				_headers[@(_rowItem.size())] = text;
				_rowItem.push_back(-1);
				prev = group;
			}
		}
		_itemRow[i] = _rowItem.size();
		_rowItem.push_back((ptrdiff_t)i);
	}
}

- (BOOL)isHeaderRow:(NSInteger)row { return row >= 0 && (size_t)row < _rowItem.size() && _rowItem[(size_t)row] < 0; }
- (ptrdiff_t)itemForRow:(NSInteger)row { return row >= 0 && (size_t)row < _rowItem.size() ? _rowItem[(size_t)row] : -1; }
- (NSInteger)rowForItem:(size_t)i { return i < _itemRow.size() ? (NSInteger)_itemRow[i] : -1; }
// Playlist index a drop above `row` inserts at.
- (size_t)insertIndexForRow:(NSInteger)row {
	for (size_t r = (size_t)std::max<NSInteger>(row, 0); r < _rowItem.size(); ++r)
		if (_rowItem[r] >= 0) return (size_t)_rowItem[r];
	return _items.get_count();
}

- (NSInteger)playingRow {
	size_t pl, item;
	if (playlist_manager::get()->get_playing_item_location(&pl, &item) && pl == _playlist) return [self rowForItem:item];
	return -1;
}

- (void)playingChanged {
	[_table reloadData];
	// On a new track foobar2000 reports the playing playlist position a moment later.
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self->_table reloadData]; });
}

- (BOOL)tableView:(NSTableView *)tv isGroupRow:(NSInteger)row { return [self isHeaderRow:row]; }
- (BOOL)tableView:(NSTableView *)tv shouldSelectRow:(NSInteger)row { return ![self isHeaderRow:row]; }
- (CGFloat)tableView:(NSTableView *)tv heightOfRow:(NSInteger)row {
	return [self isHeaderRow:row] ? playlistRowHeight() + 6 : playlistRowHeight();
}

- (NSCell *)tableView:(NSTableView *)tv dataCellForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
	if (col == nil) {
		if (![self isHeaderRow:row]) return nil;
		if (!_headerCell) {
			_headerCell = [NSTextFieldCell new];
			_headerCell.font = playlistFont(YES);
			_headerCell.lineBreakMode = NSLineBreakByTruncatingTail;
		}
		return _headerCell;
	}
	return [col dataCellForRow:row];
}

- (void)tableView:(NSTableView *)tv willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)col row:(NSInteger)row {
	if (![cell isKindOfClass:NSTextFieldCell.class]) return;
	NSTextFieldCell * c = cell;
	if ([self isHeaderRow:row]) { c.textColor = playingColor(); return; }
	const BOOL playing = row == [self playingRow];
	c.textColor = playing && ![tv isRowSelected:row] ? playingColor() : NSColor.labelColor;
	c.font = playlistFont(playing);
}

- (void)syncSelection {
	if (_playlist == SIZE_MAX || _syncing) return;
	auto pm = playlist_manager::get();
	pfc::bit_array_bittable mask(_items.get_count());
	pm->playlist_get_selection_mask(_playlist, mask);
	NSMutableIndexSet * set = [NSMutableIndexSet indexSet];
	for (size_t i = 0; i < _items.get_count(); ++i) if (mask.get(i)) [set addIndex:(NSUInteger)[self rowForItem:i]];
	_syncing = YES;
	[_table selectRowIndexes:set byExtendingSelection:NO];
	_syncing = NO;
}

- (void)revealItem:(size_t)idx { if (idx < _items.get_count()) [_table scrollRowToVisible:[self rowForItem:idx]]; }

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)_rowItem.size(); }

- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
	if ([self isHeaderRow:row]) return _headers[@(row)] ?: @"";
	const ptrdiff_t itemIdx = [self itemForRow:row];
	if (itemIdx < 0) return @"";
	const size_t item = (size_t)itemIdx;
	NSString * ident = col.identifier;
	if ([ident isEqualToString:@"index"]) return [NSString stringWithFormat:@"%zu", item + 1];
	if ([ident isEqualToString:@"playing"]) {
		if (row == [self playingRow]) return playback_control::get()->is_paused() ? @"  ❚❚" : @"  ▶";
		if (NSString * q = _queueLabels[@(item)]) return [NSString stringWithFormat:@"  [%@]", q];
		return @"";
	}
	NSString * key = [NSString stringWithFormat:@"%zu|%@", item, ident];
	if (NSString * hit = [_cache objectForKey:key]) return hit;
	auto obj = (titleformat_object *)[_scripts[ident] pointerValue];
	if (!obj) return @"";
	pfc::string8 out;
	_items[item]->format_title(nullptr, out, titleformat_object::ptr(obj), nullptr);
	NSString * v = [NSString stringWithUTF8String:out.c_str()] ?: @"";
	if ([ident isEqualToString:@"path"]) {
		if ([v hasPrefix:@"file://"]) v = [v substringFromIndex:7];
		if ([v hasPrefix:_home]) v = [@"~" stringByAppendingString:[v substringFromIndex:_home.length]];
	}
	[_cache setObject:v forKey:key];
	return v;
}

- (void)tableViewSelectionDidChange:(NSNotification *)n {
	if (_syncing || _playlist == SIZE_MAX) return;
	auto pm = playlist_manager::get();
	pfc::bit_array_bittable mask(_items.get_count());
	NSIndexSet * sel = _table.selectedRowIndexes;
	for (NSUInteger r = sel.firstIndex; r != NSNotFound; r = [sel indexGreaterThanIndex:r]) {
		const ptrdiff_t i = [self itemForRow:(NSInteger)r];
		if (i >= 0) mask.set((size_t)i, true);
	}
	_syncing = YES;
	pm->playlist_set_selection(_playlist, pfc::bit_array_true(), mask);
	const ptrdiff_t focus = [self itemForRow:_table.selectedRow];
	if (focus >= 0) pm->playlist_set_focus_item(_playlist, (size_t)focus);
	_syncing = NO;
}

// --- Context menu: foobar2000's own track menu for the selection ---

static void buildMenu(NSMenu * menu, contextmenu_node * parent, id target) {
	for (size_t i = 0, n = parent->get_num_children(); i < n; ++i) {
		contextmenu_node * node = parent->get_child(i);
		if (!node) continue;
		const auto type = node->get_type();
		if (type == contextmenu_item_node::TYPE_SEPARATOR) {
			if (menu.numberOfItems && !menu.itemArray.lastObject.isSeparatorItem) [menu addItem:NSMenuItem.separatorItem];
			continue;
		}
		NSString * title = [NSString stringWithUTF8String:node->get_name() ?: ""] ?: @"";
		title = [title stringByReplacingOccurrencesOfString:@"&" withString:@""];
		const unsigned flags = node->get_display_flags();
		NSMenuItem * item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
		if (type == contextmenu_item_node::TYPE_POPUP) {
			NSMenu * sub = [[NSMenu alloc] initWithTitle:title];
			buildMenu(sub, node, target);
			item.submenu = sub;
		} else {
			item.target = target;
			item.action = @selector(runContextNode:);
			item.representedObject = [NSValue valueWithPointer:node];
		}
		if (flags & (contextmenu_item_node::FLAG_CHECKED | contextmenu_item_node::FLAG_RADIOCHECKED)) item.state = NSControlStateValueOn;
		if (flags & (contextmenu_item_node::FLAG_DISABLED | contextmenu_item_node::FLAG_GRAYED)) { item.enabled = NO; item.action = nil; }
		[menu addItem:item];
	}
	while (menu.numberOfItems && menu.itemArray.lastObject.isSeparatorItem) [menu removeItem:menu.itemArray.lastObject];
}

- (NSMenu *)contextMenu {
	if (_playlist == SIZE_MAX) return nil;
	NSMenu * menu = [NSMenu new];
	menu.autoenablesItems = NO;
	[menu addItemWithTitle:@"Play" action:@selector(playClicked) keyEquivalent:@""].target = self;
	[menu addItemWithTitle:@"Remove" action:@selector(removeSelection) keyEquivalent:@""].target = self;
	[menu addItem:NSMenuItem.separatorItem];

	NSMenu * fb2k = [NSMenu new];
	_menuManager = contextmenu_manager::get();
	_menuManager->init_context_playlist(contextmenu_manager::flag_view_full);
	if (contextmenu_node * root = _menuManager->get_root()) buildMenu(fb2k, root, self);

	BOOL hasQueue = NO;
	for (NSMenuItem * it in fb2k.itemArray) if ([it.title rangeOfString:@"queue" options:NSCaseInsensitiveSearch].location != NSNotFound) hasQueue = YES;
	if (!hasQueue) {
		[menu addItemWithTitle:@"Add to Playback Queue" action:@selector(queueAdd:) keyEquivalent:@""].target = self;
		BOOL anyQueued = NO;
		for (NSUInteger r = _table.selectedRowIndexes.firstIndex; r != NSNotFound; r = [_table.selectedRowIndexes indexGreaterThanIndex:r]) {
			const ptrdiff_t i = [self itemForRow:(NSInteger)r];
			if (i >= 0 && _queueLabels[@(i)]) anyQueued = YES;
		}
		if (anyQueued) [menu addItemWithTitle:@"Remove from Playback Queue" action:@selector(queueRemove:) keyEquivalent:@""].target = self;
		if (playlist_manager::get()->queue_get_count() > 0)
			[menu addItemWithTitle:@"Flush Playback Queue" action:@selector(queueFlush:) keyEquivalent:@""].target = self;
		[menu addItem:NSMenuItem.separatorItem];
	}
	for (NSMenuItem * it in fb2k.itemArray.copy) { [fb2k removeItem:it]; [menu addItem:it]; }
	return menu;
}

- (void)queueAdd:(id)s {
	auto pm = playlist_manager::get();
	for (NSUInteger r = _table.selectedRowIndexes.firstIndex; r != NSNotFound; r = [_table.selectedRowIndexes indexGreaterThanIndex:r]) {
		const ptrdiff_t i = [self itemForRow:(NSInteger)r];
		if (i >= 0) pm->queue_add_item_playlist(_playlist, (size_t)i);
	}
}
- (void)queueRemove:(id)s {
	auto pm = playlist_manager::get();
	pfc::list_t<t_playback_queue_item> q;
	pm->queue_get_contents(q);
	pfc::bit_array_bittable mask(q.get_count());
	NSIndexSet * sel = _table.selectedRowIndexes;
	for (size_t k = 0; k < q.get_count(); ++k)
		if (q[k].m_playlist == _playlist && [sel containsIndex:(NSUInteger)[self rowForItem:q[k].m_item]]) mask.set(k, true);
	pm->queue_remove_mask(mask);
}
- (void)queueFlush:(id)s { playlist_manager::get()->queue_flush(); }

- (void)runContextNode:(NSMenuItem *)item {
	auto node = (contextmenu_node *)[item.representedObject pointerValue];
	if (node && _menuManager.is_valid()) node->execute();
}

// --- Search: Cmd+F; selects all matches, Enter jumps to the next one ---

- (void)showSearch {
	_searchBar.hidden = NO;
	[self.view.window makeFirstResponder:_search];
	[self onSearch:nil];
}

- (void)hideSearch {
	_searchBar.hidden = YES;
	_matches.clear();
	[self.view.window makeFirstResponder:_table];
}

- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)cmd {
	if (cmd == @selector(cancelOperation:)) { [self hideSearch]; return YES; }
	if (cmd == @selector(insertNewline:)) { [self nextMatch]; return YES; }
	return NO;
}

- (void)onSearch:(id)s {
	_matches.clear();
	_matchPos = 0;
	NSString * q = _search.stringValue;
	if (q.length == 0 || _playlist == SIZE_MAX) { _searchInfo.stringValue = @""; return; }
	titleformat_object::ptr script;
	titleformat_compiler::get()->compile_safe(script, "%artist% %title% %album% %album artist% %genre% %date% %filename%");
	pfc::string8 text;
	NSArray<NSString *> * words = [q componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
	for (size_t i = 0; i < _items.get_count(); ++i) {
		_items[i]->format_title(nullptr, text, script, nullptr);
		NSString * t = [NSString stringWithUTF8String:text.c_str()] ?: @"";
		BOOL all = YES;
		for (NSString * w in words)
			if (w.length && [t rangeOfString:w options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location == NSNotFound) { all = NO; break; }
		if (all) _matches.push_back(i);
	}
	_searchInfo.stringValue = _matches.empty() ? @"Not found" : [NSString stringWithFormat:@"%zu found", _matches.size()];

	auto pm = playlist_manager::get();
	pfc::bit_array_bittable mask(_items.get_count());
	for (size_t i : _matches) mask.set(i, true);
	pm->playlist_set_selection(_playlist, pfc::bit_array_true(), mask);
	if (!_matches.empty()) {
		pm->playlist_set_focus_item(_playlist, _matches[0]);
		[_table scrollRowToVisible:[self rowForItem:_matches[0]]];
	}
}

- (void)nextMatch {
	if (_matches.empty()) return;
	_matchPos = (_matchPos + 1) % _matches.size();
	const size_t i = _matches[_matchPos];
	playlist_manager::get()->playlist_set_focus_item(_playlist, i);
	[_table scrollRowToVisible:[self rowForItem:i]];
	_searchInfo.stringValue = [NSString stringWithFormat:@"%zu of %zu", _matchPos + 1, _matches.size()];
}

// --- Clipboard & undo -----------------------------------------------------------

static metadb_handle_list g_clipboard;    // tracks copied from a classic-playlist
static NSInteger g_clipboardChange = -1;  // pasteboard changeCount when we copied

- (BOOL)canEdit:(SEL)a {
	if (_playlist == SIZE_MAX) return NO;
	auto pm = playlist_manager::get();
	if (a == @selector(undo:)) return pm->playlist_is_undo_available(_playlist);
	if (a == @selector(redo:)) return pm->playlist_is_redo_available(_playlist);
	if (a == @selector(paste:)) return YES;
	return _table.numberOfSelectedRows > 0;
}

- (void)doCopy:(BOOL)cut {
	if (_playlist == SIZE_MAX) return;
	auto pm = playlist_manager::get();
	g_clipboard.remove_all();
	pm->playlist_get_selected_items(_playlist, g_clipboard);
	if (g_clipboard.get_count() == 0) return;

	// Also publish file URLs, so the tracks can be pasted into Finder or other apps.
	NSMutableArray<NSURL *> * urls = [NSMutableArray array];
	for (size_t i = 0; i < g_clipboard.get_count(); ++i) {
		const char * path = g_clipboard[i]->get_path();
		if (pfc::strcmp_partial(path, "file://") == 0)
			if (NSString * p = [NSString stringWithUTF8String:path + 7]) [urls addObject:[NSURL fileURLWithPath:p]];
	}
	NSPasteboard * pb = NSPasteboard.generalPasteboard;
	[pb clearContents];
	if (urls.count) [pb writeObjects:urls];
	g_clipboardChange = pb.changeCount;

	if (cut) { pm->playlist_undo_backup(_playlist); pm->playlist_remove_selection(_playlist); }
}

- (void)doPaste {
	if (_playlist == SIZE_MAX) return;
	auto pm = playlist_manager::get();
	size_t at = pm->playlist_get_focus_item(_playlist);
	at = at == SIZE_MAX ? pm->playlist_get_item_count(_playlist) : at + 1;
	NSPasteboard * pb = NSPasteboard.generalPasteboard;

	if (pb.changeCount == g_clipboardChange && g_clipboard.get_count()) {
		pm->playlist_undo_backup(_playlist);
		pm->playlist_clear_selection(_playlist);
		pm->playlist_insert_items(_playlist, at, g_clipboard, pfc::bit_array_true());
		return;
	}
	// Files copied in Finder.
	NSArray<NSURL *> * urls = [pb readObjectsForClasses:@[NSURL.class] options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
	if (urls.count == 0) return;
	pfc::list_t<pfc::string8> paths;
	for (NSURL * u in urls) paths.add_item(u.path.UTF8String);
	pfc::list_t<const char *> ptrs;
	for (size_t i = 0; i < paths.get_count(); ++i) ptrs.add_item(paths[i].c_str());
	const size_t pl = _playlist;
	auto notify = process_locations_notify::create([pl, at](metadb_handle_list_cref items) {
		auto pm = playlist_manager::get();
		if (pl >= pm->get_playlist_count()) return;
		pm->playlist_undo_backup(pl);
		pm->playlist_clear_selection(pl);
		pm->playlist_insert_items(pl, std::min(at, pm->playlist_get_item_count(pl)), items, pfc::bit_array_true());
	});
	playlist_incoming_item_filter_v2::get()->process_locations_async(
		ptrs, playlist_incoming_item_filter_v2::op_flag_background | playlist_incoming_item_filter_v2::op_flag_delay_ui,
		nullptr, nullptr, nullptr, notify);
}

- (void)doUndo:(BOOL)redo {
	if (_playlist == SIZE_MAX) return;
	auto pm = playlist_manager::get();
	if (redo) pm->playlist_redo_restore(_playlist); else pm->playlist_undo_restore(_playlist);
}

// --- Sorting: clicking a header sorts the playlist itself, again reverses ---

- (void)tableView:(NSTableView *)tv didClickTableColumn:(NSTableColumn *)col {
	if (_playlist == SIZE_MAX) return;
	NSString * ident = col.identifier;
	if ([ident isEqualToString:@"playing"]) return;

	_sortDescending = [ident isEqualToString:_sortColumn] ? !_sortDescending : NO;
	_sortColumn = ident;
	for (NSTableColumn * c in tv.tableColumns) [tv setIndicatorImage:nil inTableColumn:c];
	[tv setIndicatorImage:[NSImage imageNamed:_sortDescending ? @"NSDescendingSortIndicator" : @"NSAscendingSortIndicator"] inTableColumn:col];

	const size_t n = _items.get_count();
	std::vector<size_t> order(n);
	for (size_t i = 0; i < n; ++i) order[i] = i;
	const BOOL desc = _sortDescending;

	if ([ident isEqualToString:@"index"]) {
		if (desc) std::reverse(order.begin(), order.end());
	} else {
		// Sort keys: file size by bytes; everything else by its displayed text, compared naturally (2 < 10).
		titleformat_object::ptr script;
		if ([ident isEqualToString:@"size"]) titleformat_compiler::get()->compile_safe(script, "$num(%filesize%,20)");
		else script = titleformat_object::ptr((titleformat_object *)[_scripts[ident] pointerValue]);
		if (script.is_empty()) return;
		NSMutableArray<NSString *> * keys = [NSMutableArray arrayWithCapacity:n];
		pfc::string8 out;
		for (size_t i = 0; i < n; ++i) {
			_items[i]->format_title(nullptr, out, script, nullptr);
			[keys addObject:[NSString stringWithUTF8String:out.c_str()] ?: @""];
		}
		std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) {
			NSComparisonResult r = [keys[a] localizedStandardCompare:keys[b]];
			return desc ? r == NSOrderedDescending : r == NSOrderedAscending;
		});
	}
	playlist_manager::get()->playlist_undo_backup(_playlist);
	playlist_manager::get()->playlist_reorder_items(_playlist, order.data(), n);
}

- (void)playClicked {
	NSInteger row = _table.clickedRow >= 0 ? _table.clickedRow : _table.selectedRow;
	const ptrdiff_t item = [self itemForRow:row];
	if (item >= 0 && _playlist != SIZE_MAX) playlist_manager::get()->playlist_execute_default_action(_playlist, (size_t)item);
}

- (void)removeSelection {
	if (_playlist == SIZE_MAX) return;
	playlist_manager::get()->playlist_undo_backup(_playlist);
	playlist_manager::get()->playlist_remove_selection(_playlist);
}

// --- Drag & drop -------------------------------------------------------------------

- (id<NSPasteboardWriting>)tableView:(NSTableView *)tv pasteboardWriterForRow:(NSInteger)row {
	const ptrdiff_t item = [self itemForRow:row];
	if (item < 0) return nil;
	NSPasteboardItem * it = [NSPasteboardItem new];
	[it setString:[NSString stringWithFormat:@"%td", item] forType:kClassicRowsType];
	// Real files also go out as file URLs, so they can be dropped into Finder or other apps.
	{
		const char * path = _items[(size_t)item]->get_path();
		if (pfc::strcmp_partial(path, "file://") == 0) {
			NSString * p = [NSString stringWithUTF8String:path + 7];
			if (p) [it setString:[NSURL fileURLWithPath:p].absoluteString forType:NSPasteboardTypeFileURL];
		}
	}
	return it;
}

- (void)tableView:(NSTableView *)tv draggingSession:(NSDraggingSession *)session willBeginAtPoint:(NSPoint)p forRowIndexes:(NSIndexSet *)rows {
	g_drag = ClassicDrag();
	g_drag.active = true;
	g_drag.playlist = _playlist;
	for (NSUInteger r = rows.firstIndex; r != NSNotFound; r = [rows indexGreaterThanIndex:r]) {
		const ptrdiff_t i = [self itemForRow:(NSInteger)r];
		if (i < 0) continue;
		g_drag.indices.push_back((size_t)i);
		g_drag.items.add_item(_items[(size_t)i]);
	}
}

- (void)tableView:(NSTableView *)tv draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)p operation:(NSDragOperation)op {
	g_drag = ClassicDrag();
}

- (NSDragOperation)tableView:(NSTableView *)tv validateDrop:(id<NSDraggingInfo>)info proposedRow:(NSInteger)row
	   proposedDropOperation:(NSTableViewDropOperation)op {
	if (_playlist == SIZE_MAX) return NSDragOperationNone;
	if (op == NSTableViewDropOn) [tv setDropRow:row dropOperation:NSTableViewDropAbove];
	if (g_drag.active && [info.draggingPasteboard.types containsObject:kClassicRowsType])
		return g_drag.playlist == _playlist ? NSDragOperationMove : NSDragOperationCopy;
	if ([info.draggingPasteboard.types containsObject:NSPasteboardTypeFileURL]) return NSDragOperationCopy;
	return NSDragOperationNone;
}

- (BOOL)tableView:(NSTableView *)tv acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)op {
	if (_playlist == SIZE_MAX) return NO;
	auto pm = playlist_manager::get();
	const size_t n = pm->playlist_get_item_count(_playlist);
	const size_t target = std::min([self insertIndexForRow:row], n);

	if (g_drag.active && [info.draggingPasteboard.types containsObject:kClassicRowsType]) {
		if (g_drag.playlist == _playlist) {
			// Reorder: dragged items land at `target`, keeping their relative order.
			std::vector<bool> moving(n, false);
			for (size_t i : g_drag.indices) if (i < n) moving[i] = true;
			std::vector<size_t> order;
			order.reserve(n);
			for (size_t i = 0; i < target; ++i) if (!moving[i]) order.push_back(i);
			for (size_t i = 0; i < n; ++i) if (moving[i]) order.push_back(i);
			for (size_t i = target; i < n; ++i) if (!moving[i]) order.push_back(i);
			if (order.size() != n) return NO;
			pm->playlist_undo_backup(_playlist);
			pm->playlist_reorder_items(_playlist, order.data(), n);
		} else {
			pm->playlist_undo_backup(_playlist);
			pm->playlist_clear_selection(_playlist);
			pm->playlist_insert_items(_playlist, target, g_drag.items, pfc::bit_array_true());
		}
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
		pm->playlist_undo_backup(pl);
		pm->playlist_clear_selection(pl);
		pm->playlist_insert_items(pl, std::min(target, pm->playlist_get_item_count(pl)), items, pfc::bit_array_true());
	});
	playlist_incoming_item_filter_v2::get()->process_locations_async(
		ptrs, playlist_incoming_item_filter_v2::op_flag_background | playlist_incoming_item_filter_v2::op_flag_delay_ui,
		nullptr, nullptr, nullptr, notify);
	return YES;
}
@end

// ---------------------------------------------------------------------------
// Preferences page
// ---------------------------------------------------------------------------

@interface FooClassicPrefs : NSViewController
@end

@implementation FooClassicPrefs {
	NSPopUpButton * _font, * _theme;
	NSButton * _useAccent, * _tabClose;
	NSColorWell * _accent;
	NSTextField * _size, * _height, * _left, * _right, * _winTitle;
	NSStepper * _sizeStep, * _heightStep;
}

- (NSTextField *)numberField:(NSStepper **)stepper min:(double)lo max:(double)hi {
	NSTextField * f = [NSTextField textFieldWithString:@""];
	f.target = self; f.action = @selector(changed:);
	[f.widthAnchor constraintEqualToConstant:50].active = YES;
	NSStepper * st = [NSStepper new];
	st.minValue = lo; st.maxValue = hi; st.increment = 1;
	st.target = self; st.action = @selector(stepped:);
	*stepper = st;
	return f;
}

- (void)loadView {
	_font = [NSPopUpButton new];
	[_font addItemWithTitle:@"System"];
	[_font.menu addItem:NSMenuItem.separatorItem];
	for (NSString * fam in [NSFontManager.sharedFontManager.availableFontFamilies sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)])
		[_font addItemWithTitle:fam];
	_font.target = self; _font.action = @selector(changed:);

	NSStepper * s1, * s2;
	_size = [self numberField:&s1 min:8 max:32]; _sizeStep = s1;
	_height = [self numberField:&s2 min:12 max:48]; _heightStep = s2;

	_left = [NSTextField textFieldWithString:@""];
	_right = [NSTextField textFieldWithString:@""];
	_winTitle = [NSTextField textFieldWithString:@""];
	_winTitle.placeholderString = @"Empty: don't change the window title";
	for (NSTextField * f in @[_left, _right, _winTitle]) { f.target = self; f.action = @selector(changed:); [f.widthAnchor constraintGreaterThanOrEqualToConstant:420].active = YES; }

	_theme = [NSPopUpButton new];
	[_theme addItemsWithTitles:@[@"Follow macOS", @"Light", @"Dark", @"Dark Monochrome (Windows-like)"]];
	_theme.target = self; _theme.action = @selector(changed:);
	_useAccent = [NSButton checkboxWithTitle:@"Custom accent color" target:self action:@selector(changed:)];
	_accent = [NSColorWell colorWellWithStyle:NSColorWellStyleDefault];
	_accent.target = self; _accent.action = @selector(changed:);

	_tabClose = [NSButton checkboxWithTitle:@"Show close button on tabs" target:self action:@selector(changed:)];

	NSButton * reset = [NSButton buttonWithTitle:@"Reset to Defaults" target:self action:@selector(reset:)];
	NSTextField * hint = [NSTextField wrappingLabelWithString:@"Status bar uses title formatting; %volume% shows the volume. Press Return to apply text fields."];
	hint.textColor = NSColor.secondaryLabelColor;
	hint.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];

	NSGridView * grid = [NSGridView gridViewWithViews:@[
		@[[NSTextField labelWithString:@"Theme:"], _theme],
		@[[NSTextField labelWithString:@"Accent:"], [NSStackView stackViewWithViews:@[_useAccent, _accent]]],
		@[[NSTextField labelWithString:@"Tabs:"], _tabClose],
		@[[NSTextField labelWithString:@"Playlist font:"], _font],
		@[[NSTextField labelWithString:@"Font size:"], [NSStackView stackViewWithViews:@[_size, _sizeStep]]],
		@[[NSTextField labelWithString:@"Row height:"], [NSStackView stackViewWithViews:@[_height, _heightStep]]],
		@[[NSTextField labelWithString:@"Status bar left:"], _left],
		@[[NSTextField labelWithString:@"Status bar right:"], _right],
		@[[NSTextField labelWithString:@"Window title:"], _winTitle],
		@[NSGridCell.emptyContentView, hint],
		@[NSGridCell.emptyContentView, reset],
	]];
	grid.rowSpacing = 10;
	grid.columnSpacing = 8;
	[grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
	grid.translatesAutoresizingMaskIntoConstraints = NO;

	NSView * v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 600, 300)];
	[v addSubview:grid];
	[NSLayoutConstraint activateConstraints:@[
		[grid.topAnchor constraintEqualToAnchor:v.topAnchor constant:20],
		[grid.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:20],
		[grid.trailingAnchor constraintLessThanOrEqualToAnchor:v.trailingAnchor constant:-20],
		[grid.bottomAnchor constraintLessThanOrEqualToAnchor:v.bottomAnchor constant:-20],
	]];
	self.view = v;
	[self load];
}

- (void)load {
	NSString * fam = [NSString stringWithUTF8String:cfg_fontName.get().c_str()];
	if (fam.length && [_font itemWithTitle:fam]) [_font selectItemWithTitle:fam]; else [_font selectItemAtIndex:0];
	_size.integerValue = (NSInteger)cfg_fontSize.get(); _sizeStep.integerValue = _size.integerValue;
	_height.integerValue = (NSInteger)cfg_rowHeight.get(); _heightStep.integerValue = _height.integerValue;
	_left.stringValue = [NSString stringWithUTF8String:cfg_statusLeft.get().c_str()];
	_right.stringValue = [NSString stringWithUTF8String:cfg_statusRight.get().c_str()];
	_winTitle.stringValue = [NSString stringWithUTF8String:cfg_windowTitle.get().c_str()];
	[_theme selectItemAtIndex:(NSInteger)std::clamp<int64_t>(cfg_theme.get(), 0, 3)];
	_tabClose.state = cfg_tabClose.get() ? NSControlStateValueOn : NSControlStateValueOff;
	NSColor * custom = customAccent();
	_useAccent.state = custom ? NSControlStateValueOn : NSControlStateValueOff;
	_accent.enabled = custom != nil;
	_accent.color = custom ?: NSColor.controlAccentColor;
}

- (void)stepped:(NSStepper *)st {
	(st == _sizeStep ? _size : _height).integerValue = st.integerValue;
	[self changed:nil];
}

- (void)changed:(id)s {
	cfg_fontName = _font.indexOfSelectedItem == 0 ? "" : _font.titleOfSelectedItem.UTF8String;
	cfg_fontSize = std::clamp<NSInteger>(_size.integerValue, 8, 32);
	cfg_rowHeight = std::clamp<NSInteger>(_height.integerValue, 12, 48);
	cfg_statusLeft = _left.stringValue.UTF8String;
	cfg_statusRight = _right.stringValue.UTF8String;
	cfg_theme = _theme.indexOfSelectedItem;
	cfg_windowTitle = _winTitle.stringValue.UTF8String;
	cfg_tabClose = _tabClose.state == NSControlStateValueOn ? 1 : 0;
	if (_useAccent.state == NSControlStateValueOn) {
		NSColor * c = [_accent.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
		cfg_accent = [NSString stringWithFormat:@"%02X%02X%02X", (int)lround(c.redComponent * 255), (int)lround(c.greenComponent * 255), (int)lround(c.blueComponent * 255)].UTF8String;
	} else cfg_accent = "";
	applyTheme();
	[NSNotificationCenter.defaultCenter postNotificationName:kClassicPrefsChanged object:nil];
	[self load];
}

- (void)reset:(id)s {
	cfg_fontName = ""; cfg_fontSize = 12; cfg_rowHeight = 18;
	cfg_statusLeft = kStatusLeftDefault; cfg_statusRight = kStatusRightDefault;
	cfg_theme = 0; cfg_accent = ""; cfg_tabClose = 0; cfg_windowTitle = kWindowTitleDefault; applyTheme();
	[NSNotificationCenter.defaultCenter postNotificationName:kClassicPrefsChanged object:nil];
	[self load];
}
@end

namespace {
	class preferences_page_classic : public preferences_page {
	public:
		service_ptr instantiate() override { return fb2k::wrapNSObject([FooClassicPrefs new]); }
		const char * get_name() override { return "Classic UI"; }
		GUID get_guid() override { return GUID { 0x3c95e8a1, 0x7f24, 0x4d0b, { 0xa6, 0x5d, 0x18, 0xb2, 0x9e, 0x40, 0xc7, 0x83 } }; }
		GUID get_parent_guid() override { return guid_display; }
	};
	FB2K_SERVICE_FACTORY(preferences_page_classic);
}

// ---------------------------------------------------------------------------
// Library search window (Library > Search Library…)
// ---------------------------------------------------------------------------

@interface FooClassicLibrarySearch : NSWindowController <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate>
+ (void)show;
@end

@implementation FooClassicLibrarySearch {
	NSSearchField * _search;
	NSTableView * _table;
	NSTextField * _count;
	metadb_handle_list _all;
	std::vector<NSString *> _haystack;   // lower-cased search text per library item
	std::vector<size_t> _results;        // indexes into _all
	titleformat_object::ptr _tfArtist, _tfTitle, _tfAlbum, _tfLength;
	NSCache<NSString *, NSString *> * _cache;
}

static FooClassicLibrarySearch * g_librarySearch;

+ (void)show {
	if (!g_librarySearch) g_librarySearch = [FooClassicLibrarySearch new];
	[g_librarySearch reload];
	[g_librarySearch showWindow:nil];
	[g_librarySearch.window makeKeyAndOrderFront:nil];
	[g_librarySearch.window makeFirstResponder:g_librarySearch->_search];
}

- (instancetype)init {
	NSWindow * w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 820, 520)
											   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
												 backing:NSBackingStoreBuffered defer:YES];
	w.title = @"Search Library";
	w.releasedWhenClosed = NO;
	[w center];
	w.frameAutosaveName = @"FooClassicLibrarySearch";
	if (!(self = [super initWithWindow:w])) return nil;

	_search = [NSSearchField new];
	_search.placeholderString = @"Artist, title, album, genre, year…";
	_search.sendsSearchStringImmediately = YES;
	_search.target = self; _search.action = @selector(filter:);
	_search.delegate = self;

	_table = [[NSTableView alloc] initWithFrame:NSZeroRect];
	_table.allowsMultipleSelection = YES;
	_table.style = NSTableViewStylePlain;
	_table.usesAlternatingRowBackgroundColors = YES;
	_table.dataSource = self; _table.delegate = self;
	_table.target = self; _table.doubleAction = @selector(addToCurrent:);
	[_table setDraggingSourceOperationMask:NSDragOperationCopy forLocal:YES];
	[_table setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
	for (NSArray * c in @[@[@"artist", @"Artist", @200], @[@"title", @"Title", @260], @[@"album", @"Album", @220], @[@"length", @"Duration", @70]]) {
		NSTableColumn * col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
		col.title = c[1]; col.width = [c[2] doubleValue];
		[_table addTableColumn:col];
	}
	NSScrollView * sv = [NSScrollView new];
	sv.documentView = _table; sv.hasVerticalScroller = YES;

	_count = [NSTextField labelWithString:@""];
	_count.textColor = NSColor.secondaryLabelColor;
	NSButton * add = [NSButton buttonWithTitle:@"Add to Current Playlist" target:self action:@selector(addToCurrent:)];
	NSButton * send = [NSButton buttonWithTitle:@"Send to New Playlist" target:self action:@selector(sendToNew:)];
	add.keyEquivalent = @"\r";
	NSStackView * bottom = [NSStackView stackViewWithViews:@[_count, [NSView new], send, add]];

	NSStackView * root = [NSStackView stackViewWithViews:@[_search, sv, bottom]];
	root.orientation = NSUserInterfaceLayoutOrientationVertical;
	root.alignment = NSLayoutAttributeWidth;
	root.edgeInsets = NSEdgeInsetsMake(12, 12, 12, 12);
	root.spacing = 8;
	[sv setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
	w.contentView = root;

	_tfArtist = [self compile:"[%artist%]"];
	_tfTitle = [self compile:"%title%"];
	_tfAlbum = [self compile:"[%album%]"];
	_tfLength = [self compile:"[%length%]"];
	_cache = [NSCache new];
	return self;
}

- (titleformat_object::ptr)compile:(const char *)f {
	titleformat_object::ptr p;
	titleformat_compiler::get()->compile_safe(p, f);
	return p;
}

- (void)reload {
	_all.remove_all();
	_haystack.clear();
	[_cache removeAllObjects];
	auto lib = library_manager::get();
	if (lib->is_library_enabled()) lib->get_all_items(_all);
	titleformat_object::ptr tf = [self compile:"%artist% %album artist% %title% %album% %genre% %date% %filename%"];
	pfc::string8 out;
	_haystack.reserve(_all.get_count());
	for (size_t i = 0; i < _all.get_count(); ++i) {
		_all[i]->format_title(nullptr, out, tf, nullptr);
		_haystack.push_back([NSString stringWithUTF8String:out.c_str()] ?: @"");
	}
	[self filter:nil];
}

- (void)filter:(id)s {
	_results.clear();
	NSArray<NSString *> * words = [_search.stringValue componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
	words = [words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
	if (words.count) {
		for (size_t i = 0; i < _haystack.size(); ++i) {
			BOOL all = YES;
			for (NSString * w in words)
				if ([_haystack[i] rangeOfString:w options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location == NSNotFound) { all = NO; break; }
			if (all) _results.push_back(i);
		}
	}
	if (!library_manager::get()->is_library_enabled()) _count.stringValue = @"Media Library is not configured (Preferences > Media Library).";
	else _count.stringValue = words.count ? [NSString stringWithFormat:@"%zu of %zu tracks", _results.size(), _all.get_count()]
										  : [NSString stringWithFormat:@"%zu tracks in library", _all.get_count()];
	[_table reloadData];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)_results.size(); }

- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
	if ((size_t)row >= _results.size()) return @"";
	const size_t i = _results[(size_t)row];
	NSString * key = [NSString stringWithFormat:@"%zu|%@", i, col.identifier];
	if (NSString * hit = [_cache objectForKey:key]) return hit;
	titleformat_object::ptr tf = [col.identifier isEqualToString:@"artist"] ? _tfArtist : [col.identifier isEqualToString:@"title"] ? _tfTitle
							   : [col.identifier isEqualToString:@"album"] ? _tfAlbum : _tfLength;
	pfc::string8 out;
	_all[i]->format_title(nullptr, out, tf, nullptr);
	NSString * v = [NSString stringWithUTF8String:out.c_str()] ?: @"";
	[_cache setObject:v forKey:key];
	return v;
}

- (metadb_handle_list)chosen {
	metadb_handle_list out;
	NSIndexSet * sel = _table.selectedRowIndexes;
	if (sel.count == 0) for (size_t i : _results) out.add_item(_all[i]); // nothing selected: everything found
	for (NSUInteger r = sel.firstIndex; r != NSNotFound; r = [sel indexGreaterThanIndex:r])
		if (r < _results.size()) out.add_item(_all[_results[r]]);
	return out;
}

- (void)addToCurrent:(id)s {
	metadb_handle_list items = [self chosen];
	if (items.get_count() == 0) return;
	auto pm = playlist_manager::get();
	size_t pl = pm->get_active_playlist();
	if (pl == SIZE_MAX) { pl = pm->create_playlist("New Playlist", SIZE_MAX, SIZE_MAX); pm->set_active_playlist(pl); }
	pm->playlist_undo_backup(pl);
	pm->playlist_add_items(pl, items, pfc::bit_array_false());
}

- (void)sendToNew:(id)s {
	metadb_handle_list items = [self chosen];
	if (items.get_count() == 0) return;
	auto pm = playlist_manager::get();
	pfc::string8 name = _search.stringValue.length ? _search.stringValue.UTF8String : "Search results";
	const size_t pl = pm->create_playlist(name, SIZE_MAX, SIZE_MAX);
	if (pl == SIZE_MAX) return;
	pm->playlist_add_items(pl, items, pfc::bit_array_false());
	pm->set_active_playlist(pl);
}

// Drag results onto classic-tabs / classic-playlist (and Finder).
- (id<NSPasteboardWriting>)tableView:(NSTableView *)tv pasteboardWriterForRow:(NSInteger)row {
	if ((size_t)row >= _results.size()) return nil;
	NSPasteboardItem * it = [NSPasteboardItem new];
	[it setString:@"library" forType:kClassicRowsType];
	const char * path = _all[_results[(size_t)row]]->get_path();
	if (pfc::strcmp_partial(path, "file://") == 0)
		if (NSString * p = [NSString stringWithUTF8String:path + 7])
			[it setString:[NSURL fileURLWithPath:p].absoluteString forType:NSPasteboardTypeFileURL];
	return it;
}
- (void)tableView:(NSTableView *)tv draggingSession:(NSDraggingSession *)session willBeginAtPoint:(NSPoint)p forRowIndexes:(NSIndexSet *)rows {
	g_drag = ClassicDrag();
	g_drag.active = true;  // playlist stays SIZE_MAX: drops always copy
	for (NSUInteger r = rows.firstIndex; r != NSNotFound; r = [rows indexGreaterThanIndex:r])
		if (r < _results.size()) g_drag.items.add_item(_all[_results[r]]);
}
- (void)tableView:(NSTableView *)tv draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)p operation:(NSDragOperation)op {
	g_drag = ClassicDrag();
}
@end

namespace {
	static const GUID guid_library_search = { 0x5ea7c2f1, 0x8d36, 0x4b90, { 0xa4, 0x1f, 0x73, 0xc8, 0x0e, 0x95, 0x2b, 0xd6 } };
	class mainmenu_classic_library : public mainmenu_commands {
	public:
		t_uint32 get_command_count() override { return 1; }
		GUID get_command(t_uint32) override { return guid_library_search; }
		void get_name(t_uint32, pfc::string_base & out) override { out = "Search Library..."; }
		bool get_description(t_uint32, pfc::string_base & out) override { out = "Search the media library and add tracks to a playlist."; return true; }
		GUID get_parent() override { return mainmenu_groups::library; }
		void execute(t_uint32, ctx_t) override { [FooClassicLibrarySearch show]; }
	};
	static mainmenu_commands_factory_t<mainmenu_classic_library> g_mainmenu_classic_library;
}

// ---------------------------------------------------------------------------
// File > Check for Plugin Updates… (all nanor.ru components that are installed)
// ---------------------------------------------------------------------------

static void checkAllPluginsNow() {
	// Installed components: file name -> (title, version).
	NSMutableDictionary<NSString *, NSArray *> * installed = [NSMutableDictionary dictionary];
	for (auto e = service_enum_t<componentversion>(); !e.finished(); ++e) {
		pfc::string8 file, name, ver;
		(*e)->get_file_name(file); (*e)->get_component_name(name); (*e)->get_component_version(ver);
		NSString * key = [[NSString stringWithUTF8String:file.c_str()] stringByDeletingPathExtension];
		if (key.length) installed[key] = @[[NSString stringWithUTF8String:name.c_str()] ?: key, [NSString stringWithUTF8String:ver.c_str()] ?: @""];
	}
	nanor_update::fetchManifest(^(NSDictionary * manifest, NSError * err) {
		if (!manifest) {
			NSAlert * a = [NSAlert new];
			a.messageText = @"Could not check for updates";
			a.informativeText = err.localizedDescription ?: @"nanor.ru did not return update information.";
			[a runModal];
			return;
		}
		NSMutableArray<NSArray *> * updates = [NSMutableArray array];
		for (NSString * key in manifest) {
			NSArray * inst = installed[key];
			if (!inst) continue;
			if (NSDictionary * e = nanor_update::newerEntry(manifest, key, inst[1])) [updates addObject:@[key, inst[0], inst[1], e]];
		}
		if (updates.count == 1) nanor_update::showUpdate(updates[0][0], updates[0][1], updates[0][2], updates[0][3], YES);
		else if (updates.count > 1) nanor_update::offerMany(updates);
		else {
			NSAlert * a = [NSAlert new];
			a.messageText = @"All plugins are up to date";
			NSMutableArray * lines = [NSMutableArray array];
			for (NSString * key in manifest) if (NSArray * inst = installed[key]) [lines addObject:[NSString stringWithFormat:@"%@ %@", inst[0], inst[1]]];
			a.informativeText = [lines componentsJoinedByString:@"\n"];
			[a runModal];
		}
	});
}

namespace {
	static const GUID guid_check_updates = { 0x2d9f6b14, 0xa3e8, 0x4c71, { 0x85, 0x0b, 0x1e, 0x6a, 0xd4, 0x93, 0x7c, 0x05 } };
	class mainmenu_classic_updates : public mainmenu_commands {
	public:
		t_uint32 get_command_count() override { return 1; }
		GUID get_command(t_uint32) override { return guid_check_updates; }
		void get_name(t_uint32, pfc::string_base & out) override { out = "Check for Plugin Updates..."; }
		bool get_description(t_uint32, pfc::string_base & out) override { out = "Check nanor.ru for newer versions of installed plugins."; return true; }
		GUID get_parent() override { return mainmenu_groups::file_etc; } // Help isn't extensible on Mac
		void execute(t_uint32, ctx_t) override { checkAllPluginsNow(); }
	};
	static mainmenu_commands_factory_t<mainmenu_classic_updates> g_mainmenu_classic_updates;
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

namespace {
	class ui_element_classic_toolbar : public ui_element_mac {
	public:
		service_ptr instantiate(service_ptr) override { return fb2k::wrapNSObject([FooClassicToolbar new]); }
		bool match_name(const char * name) override { return strcmp(name, "classic-toolbar") == 0; }
		fb2k::stringRef get_name() override { return fb2k::makeString("Classic Toolbar"); }
		GUID get_guid() override {
			return GUID { 0x3e7a1f52, 0x9c04, 0x4b8d, { 0xa1, 0x6f, 0x52, 0x0e, 0x9d, 0x37, 0xc4, 0x18 } };
		}
	};
	class ui_element_classic_statusbar : public ui_element_mac {
	public:
		service_ptr instantiate(service_ptr) override { return fb2k::wrapNSObject([FooClassicStatusbar new]); }
		bool match_name(const char * name) override { return strcmp(name, "classic-statusbar") == 0; }
		fb2k::stringRef get_name() override { return fb2k::makeString("Classic Status Bar"); }
		GUID get_guid() override {
			return GUID { 0x8d21c6b4, 0x2f73, 0x4e0a, { 0xb5, 0x9c, 0x0d, 0x61, 0xe8, 0x4a, 0x27, 0xf3 } };
		}
	};
	class ui_element_classic_tabs : public ui_element_mac {
	public:
		service_ptr instantiate(service_ptr) override { return fb2k::wrapNSObject([FooClassicTabs new]); }
		bool match_name(const char * name) override { return strcmp(name, "classic-tabs") == 0; }
		fb2k::stringRef get_name() override { return fb2k::makeString("Classic Playlist Tabs"); }
		GUID get_guid() override {
			return GUID { 0x61c9e2d7, 0x4a18, 0x4f3b, { 0x8e, 0x02, 0x7b, 0xd5, 0x13, 0x9f, 0x60, 0xa4 } };
		}
	};
	class ui_element_classic_playlist : public ui_element_mac {
	public:
		service_ptr instantiate(service_ptr) override { return fb2k::wrapNSObject([FooClassicPlaylist new]); }
		bool match_name(const char * name) override { return strcmp(name, "classic-playlist") == 0; }
		fb2k::stringRef get_name() override { return fb2k::makeString("Classic Playlist"); }
		GUID get_guid() override {
			return GUID { 0x9e47b2c1, 0x3d58, 0x4a06, { 0xb1, 0x7e, 0x64, 0x0f, 0xa9, 0x2d, 0x18, 0xc5 } };
		}
	};
	FB2K_SERVICE_FACTORY(ui_element_classic_playlist);
	FB2K_SERVICE_FACTORY(ui_element_classic_toolbar);
	FB2K_SERVICE_FACTORY(ui_element_classic_tabs);
	FB2K_SERVICE_FACTORY(ui_element_classic_statusbar);
}

NANOR_UPDATE_COMPONENT("foo_classic_ui", "Classic UI", COMPONENT_VERSION)
