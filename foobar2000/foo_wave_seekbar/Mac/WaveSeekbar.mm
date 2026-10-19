#import "stdafx.h"
#include "../version.h"
#include "../../nanor_shared/NanorUpdate.h"
#include <SDK/ui_element_mac.h>
#include <SDK/commonObjects-Apple.h>
#include <atomic>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>
#include <cmath>

// ---------------------------------------------------------------------------
// Waveform data and background scanner
// ---------------------------------------------------------------------------

namespace wave {
	static constexpr size_t kBuckets = 2048;

	struct Waveform {
		std::vector<float> peak = std::vector<float>(kBuckets, 0.f);
		std::vector<float> rms = std::vector<float>(kBuckets, 0.f);
		bool complete = false;
	};
	typedef std::shared_ptr<const Waveform> WaveformRef;

	// Small in-memory cache of finished waveforms, main thread only.
	static std::map<std::string, WaveformRef> g_cache;
	static std::vector<std::string> g_cacheOrder;
	static constexpr size_t kCacheMax = 64;

	static std::string keyFor(metadb_handle_ptr const & track) {
		auto & loc = track->get_location();
		pfc::string8 k; k << loc.get_path() << "|" << loc.get_subsong();
		return k.c_str();
	}

	static void cachePut(std::string const & key, WaveformRef wf) {
		if (g_cache.count(key) == 0) {
			g_cacheOrder.push_back(key);
			if (g_cacheOrder.size() > kCacheMax) {
				g_cache.erase(g_cacheOrder.front());
				g_cacheOrder.erase(g_cacheOrder.begin());
			}
		}
		g_cache[key] = wf;
	}

	// One scan of one track. The worker owns a reference; the UI drops its
	// reference (and aborts) when the track changes.
	struct ScanJob {
		abort_callback_impl abort;
		std::string key;
	};

	// Decodes the track and reports progress via `onUpdate` (called on main thread).
	static void startScan(std::shared_ptr<ScanJob> job, metadb_handle_ptr track,
						  std::function<void(WaveformRef)> onUpdate) {
		std::thread([job, track, onUpdate] {
			try {
				const double length = track->get_length();
				if (length <= 0) return;

				input_helper in;
				in.open(nullptr, track, input_flag_simpledecode, job->abort);

				auto wf = std::make_shared<Waveform>();
				std::vector<double> sumSq(kBuckets, 0.0);
				std::vector<uint64_t> count(kBuckets, 0);

				audio_chunk_impl chunk;
				uint64_t pos = 0; // in samples (frames)
				double totalFrames = 0;
				auto lastPost = std::chrono::steady_clock::now();

				auto snapshot = [&](bool done) {
					auto out = std::make_shared<Waveform>(*wf);
					for (size_t i = 0; i < kBuckets; ++i)
						out->rms[i] = count[i] ? (float)std::sqrt(sumSq[i] / count[i]) : 0.f;
					out->complete = done;
					fb2k::inMainThread([onUpdate, out] { onUpdate(out); });
				};

				while (in.run(chunk, job->abort)) {
					const unsigned ch = chunk.get_channel_count();
					const size_t frames = chunk.get_sample_count();
					if (totalFrames == 0) totalFrames = length * chunk.get_sample_rate();
					const audio_sample * data = chunk.get_data();
					for (size_t f = 0; f < frames; ++f, ++pos) {
						size_t b = (size_t)((double)pos / totalFrames * kBuckets);
						if (b >= kBuckets) b = kBuckets - 1;
						float m = 0; double sq = 0;
						for (unsigned c = 0; c < ch; ++c) {
							float v = std::fabs((float)data[f * ch + c]);
							if (v > m) m = v;
							sq += (double)v * v;
						}
						if (m > wf->peak[b]) wf->peak[b] = m;
						sumSq[b] += sq / ch;
						count[b]++;
					}
					auto now = std::chrono::steady_clock::now();
					if (now - lastPost > std::chrono::milliseconds(250)) {
						lastPost = now;
						snapshot(false);
					}
				}
				snapshot(true);
			} catch (exception_aborted const &) {
			} catch (std::exception const & e) {
				FB2K_console_formatter() << "Waveform Seekbar: scan failed: " << e.what();
			}
		}).detach();
	}
}

// ---------------------------------------------------------------------------
// Colors (Preferences > Display > Waveform Seekbar); empty = system colors
// ---------------------------------------------------------------------------

static cfg_string cfg_colorPlayed(GUID { 0x6d2a91c4, 0x38e7, 0x4f10, { 0xb5, 0x6c, 0x0a, 0x93, 0xd1, 0x47, 0xe2, 0x58 } }, "");
static cfg_string cfg_colorRest(GUID { 0xa47f0e3b, 0x91c2, 0x4d65, { 0x8e, 0x09, 0x5b, 0x2c, 0x76, 0xf1, 0x30, 0xad } }, "");
static NSNotificationName const kWavePrefsChanged = @"FooWaveSeekbarPrefsChanged";

static NSColor * colorFromCfg(cfg_string & c) {
	NSString * hex = [NSString stringWithUTF8String:c.get().c_str()];
	unsigned v = 0;
	if (hex.length != 6 || ![[NSScanner scannerWithString:hex] scanHexInt:&v]) return nil;
	return [NSColor colorWithSRGBRed:((v >> 16) & 0xFF) / 255.0 green:((v >> 8) & 0xFF) / 255.0 blue:(v & 0xFF) / 255.0 alpha:1];
}
static void colorToCfg(cfg_string & c, NSColor * color) {
	NSColor * rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
	if (!rgb) { c = ""; return; }
	c = [NSString stringWithFormat:@"%02X%02X%02X", (int)lround(rgb.redComponent * 255), (int)lround(rgb.greenComponent * 255), (int)lround(rgb.blueComponent * 255)].UTF8String;
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

@interface FooWaveSeekbarView : NSView
@property (nonatomic) wave::WaveformRef waveform;
@property (nonatomic) double position;   // seconds
@property (nonatomic) double length;     // seconds, 0 = nothing playing / not seekable
@property (nonatomic) BOOL seekable;
@property (nonatomic) BOOL sideTimes;    // elapsed / total drawn left and right of the wave
@end

@implementation FooWaveSeekbarView {
	BOOL _dragging;
	double _dragPos;
	CGFloat _hoverX; // < 0 = not hovering
	NSTrackingArea * _tracking;
}

- (instancetype)initWithFrame:(NSRect)r {
	if ((self = [super initWithFrame:r])) {
		_hoverX = -1;
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(prefsChanged:) name:kWavePrefsChanged object:nil];
	}
	return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)prefsChanged:(NSNotification *)n { [self setNeedsDisplay:YES]; }

- (void)updateTrackingAreas {
	[super updateTrackingAreas];
	if (_tracking) [self removeTrackingArea:_tracking];
	_tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
		options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingActiveAlways | NSTrackingInVisibleRect
		owner:self userInfo:nil];
	[self addTrackingArea:_tracking];
}

- (void)mouseMoved:(NSEvent *)e {
	_hoverX = [self convertPoint:e.locationInWindow fromView:nil].x;
	[self setNeedsDisplay:YES];
}
- (void)mouseExited:(NSEvent *)e {
	_hoverX = -1;
	[self setNeedsDisplay:YES];
}

static NSString * formatTime(double t) {
	long s = (long)t;
	if (s >= 3600) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", s / 3600, s / 60 % 60, s % 60];
	return [NSString stringWithFormat:@"%ld:%02ld", s / 60, s % 60];
}

- (void)drawTimeLabelAt:(CGFloat)x time:(double)t {
	NSRect b = self.bounds;
	NSDictionary * attrs = @{
		NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium],
		NSForegroundColorAttributeName: [NSColor textBackgroundColor],
	};
	NSString * str = formatTime(t);
	NSSize sz = [str sizeWithAttributes:attrs];
	NSRect box = NSMakeRect(x + 6, NSMidY(b) - sz.height / 2 - 2, sz.width + 10, sz.height + 4);
	if (NSMaxX(box) > NSMaxX(b)) box.origin.x = x - 6 - box.size.width;
	[[[NSColor labelColor] colorWithAlphaComponent:0.85] setFill];
	[[NSBezierPath bezierPathWithRoundedRect:box xRadius:4 yRadius:4] fill];
	[str drawAtPoint:NSMakePoint(box.origin.x + 5, box.origin.y + 2) withAttributes:attrs];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

// Horizontal extent of the waveform itself.
- (CGFloat)waveX { return self.sideTimes ? 54 : 0; }
- (CGFloat)waveW { return std::max<CGFloat>(1, self.bounds.size.width - 2 * self.waveX); }

- (void)drawSideTimes:(double)pos length:(double)len {
	NSRect b = self.bounds;
	NSDictionary * a = @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular],
						  NSForegroundColorAttributeName: NSColor.secondaryLabelColor };
	NSString * l = len > 0 ? formatTime(pos) : @"";
	NSString * r = len > 0 ? formatTime(len) : @"";
	NSSize sl = [l sizeWithAttributes:a], sr = [r sizeWithAttributes:a];
	[l drawAtPoint:NSMakePoint(self.waveX - 8 - sl.width, NSMidY(b) - sl.height / 2) withAttributes:a];
	[r drawAtPoint:NSMakePoint(NSMaxX(b) - self.waveX + 8, NSMidY(b) - sr.height / 2) withAttributes:a];
}

- (void)setWaveform:(wave::WaveformRef)w { _waveform = w; [self setNeedsDisplay:YES]; }
- (void)setPosition:(double)p {
	if (p != _position) { _position = p; if (!_dragging) [self setNeedsDisplay:YES]; }
}
- (void)setLength:(double)l { _length = l; [self setNeedsDisplay:YES]; }

- (void)drawRect:(NSRect)dirty {
	NSRect b = self.bounds;
	[[NSColor controlBackgroundColor] setFill];
	NSRectFill(b);

	const double len = self.length;
	const double pos = _dragging ? _dragPos : self.position;
	const CGFloat x0 = self.waveX, ww = self.waveW;
	const CGFloat progressX = x0 + (len > 0 ? (CGFloat)(pos / len) * ww : 0);
	if (self.sideTimes) [self drawSideTimes:pos length:len];

	NSColor * accent = colorFromCfg(cfg_colorPlayed) ?: [NSColor controlAccentColor];
	NSColor * rest = colorFromCfg(cfg_colorRest);
	NSColor * idle = rest ? [rest colorWithAlphaComponent:0.45] : [NSColor tertiaryLabelColor];
	NSColor * idleRms = rest ?: [NSColor secondaryLabelColor];

	const CGFloat midY = NSMidY(b);
	const CGFloat half = b.size.height / 2 - 2;

	auto wf = self.waveform;
	if (wf) {
		const int w = (int)ceil(ww);
		CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
		for (int pass = 0; pass < 2; ++pass) { // 0 = peak, 1 = rms
			auto const & arr = pass == 0 ? wf->peak : wf->rms;
			for (int x = 0; x < w; ++x) {
				size_t i0 = (size_t)((double)x / w * wave::kBuckets);
				size_t i1 = std::max(i0 + 1, (size_t)((double)(x + 1) / w * wave::kBuckets));
				float v = 0;
				for (size_t i = i0; i < i1 && i < wave::kBuckets; ++i) v = std::max(v, arr[i]);
				if (v > 1) v = 1;
				CGFloat h = std::max<CGFloat>(0.5, v * half);
				NSColor * c;
				if (x0 + x < progressX) c = pass == 0 ? [accent colorWithAlphaComponent:0.55] : accent;
				else c = pass == 0 ? idle : idleRms;
				CGContextSetFillColorWithColor(ctx, c.CGColor);
				CGContextFillRect(ctx, CGRectMake(x0 + x, midY - h, 1, h * 2));
			}
		}
	} else {
		[idle setFill];
		NSRectFill(NSMakeRect(x0, midY - 0.5, ww, 1));
	}

	if (len > 0) {
		[[NSColor labelColor] setFill];
		NSRectFill(NSMakeRect(floor(progressX), 0, 1, b.size.height));

		const CGFloat hx = _dragging ? progressX : _hoverX;
		if (hx >= x0 && hx <= x0 + ww) {
			if (!_dragging) {
				[[[NSColor labelColor] colorWithAlphaComponent:0.4] setFill];
				NSRectFill(NSMakeRect(floor(hx), 0, 1, b.size.height));
			}
			[self drawTimeLabelAt:hx time:(hx - x0) / ww * len];
		}
	}
}

- (double)timeForEvent:(NSEvent *)e {
	NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
	double f = (p.x - self.waveX) / self.waveW;
	f = std::clamp(f, 0.0, 1.0);
	return f * self.length;
}

- (void)mouseDown:(NSEvent *)e {
	if (self.length <= 0 || !self.seekable) return;
	_dragging = YES;
	_dragPos = [self timeForEvent:e];
	[self setNeedsDisplay:YES];
}
- (void)mouseDragged:(NSEvent *)e {
	if (!_dragging) return;
	_dragPos = [self timeForEvent:e];
	_hoverX = [self convertPoint:e.locationInWindow fromView:nil].x;
	[self setNeedsDisplay:YES];
}
- (void)mouseUp:(NSEvent *)e {
	if (!_dragging) return;
	_dragging = NO;
	_dragPos = [self timeForEvent:e];
	playback_control::get()->playback_seek(_dragPos);
	self.position = _dragPos;
	[self setNeedsDisplay:YES];
}
@end

// ---------------------------------------------------------------------------
// Controller: hooks playback events to the view
// ---------------------------------------------------------------------------

@interface FooWaveSeekbarController : NSViewController
@property (nonatomic) BOOL sideTimes;
- (void)trackChanged:(metadb_handle_ptr)track;
- (void)stopped;
@end

namespace {
	class PlayCallback : public play_callback_impl_base {
	public:
		PlayCallback(FooWaveSeekbarController * owner)
			: play_callback_impl_base(flag_on_playback_new_track | flag_on_playback_stop), m_owner(owner) {}
		void on_playback_new_track(metadb_handle_ptr track) override { [m_owner trackChanged:track]; }
		void on_playback_stop(play_control::t_stop_reason reason) override {
			if (reason != play_control::stop_reason_starting_another) [m_owner stopped];
		}
	private:
		__weak FooWaveSeekbarController * m_owner;
	};
}

@implementation FooWaveSeekbarController {
	std::unique_ptr<PlayCallback> _cb;
	std::shared_ptr<wave::ScanJob> _job;
	NSTimer * _timer;
	FooWaveSeekbarView * _wave;
}

- (void)loadView {
	_wave = [[FooWaveSeekbarView alloc] initWithFrame:NSMakeRect(0, 0, 400, 40)];
	_wave.sideTimes = self.sideTimes;
	self.view = _wave;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	_cb = std::make_unique<PlayCallback>(self);

	metadb_handle_ptr now;
	if (playback_control::get()->get_now_playing(now)) [self trackChanged:now];

	__weak FooWaveSeekbarController * weakSelf = self;
	_timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *) {
		[weakSelf tick];
	}];
	[[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)dealloc {
	[_timer invalidate];
	if (_job) _job->abort.abort();
	_cb.reset();
}

- (void)tick {
	if (!self.viewLoaded || _wave.window == nil) return;
	auto pc = playback_control::get();
	if (pc->is_playing()) {
		_wave.position = pc->playback_get_position();
		_wave.seekable = pc->playback_can_seek();
	}
}

- (void)trackChanged:(metadb_handle_ptr)track {
	if (_job) { _job->abort.abort(); _job.reset(); }
	_wave.length = track->get_length();
	_wave.position = 0;

	const std::string key = wave::keyFor(track);
	auto it = wave::g_cache.find(key);
	if (it != wave::g_cache.end()) { _wave.waveform = it->second; return; }

	_wave.waveform = nullptr;
	auto job = std::make_shared<wave::ScanJob>();
	job->key = key;
	_job = job;

	__weak FooWaveSeekbarController * weakSelf = self;
	std::weak_ptr<wave::ScanJob> weakJob = job;
	wave::startScan(job, track, [weakSelf, weakJob, key](wave::WaveformRef wf) {
		if (wf->complete) wave::cachePut(key, wf);
		FooWaveSeekbarController * s = weakSelf;
		auto j = weakJob.lock();
		if (s && j && s->_job == j) {
			s->_wave.waveform = wf;
			if (wf->complete) s->_job.reset();
		}
	});
}

- (void)stopped {
	if (_job) { _job->abort.abort(); _job.reset(); }
	_wave.waveform = nullptr;
	_wave.length = 0;
	_wave.position = 0;
}
@end

// ---------------------------------------------------------------------------
// Preferences page
// ---------------------------------------------------------------------------

@interface FooWaveSeekbarPrefs : NSViewController
@end

@implementation FooWaveSeekbarPrefs {
	NSColorWell * _played, * _rest;
}
- (NSColorWell *)well {
	NSColorWell * w = [NSColorWell colorWellWithStyle:NSColorWellStyleDefault];
	w.target = self; w.action = @selector(changed:);
	return w;
}
- (void)loadView {
	_played = [self well];
	_rest = [self well];
	NSButton * reset = [NSButton buttonWithTitle:@"Use System Colors" target:self action:@selector(reset:)];
	NSGridView * grid = [NSGridView gridViewWithViews:@[
		@[[NSTextField labelWithString:@"Played part:"], _played],
		@[[NSTextField labelWithString:@"Rest of the track:"], _rest],
		@[NSGridCell.emptyContentView, reset],
	]];
	grid.rowSpacing = 10; grid.columnSpacing = 8;
	[grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
	grid.translatesAutoresizingMaskIntoConstraints = NO;
	NSView * v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, 200)];
	[v addSubview:grid];
	[NSLayoutConstraint activateConstraints:@[
		[grid.topAnchor constraintEqualToAnchor:v.topAnchor constant:20],
		[grid.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:20],
	]];
	self.view = v;
	[self load];
}
- (void)load {
	_played.color = colorFromCfg(cfg_colorPlayed) ?: NSColor.controlAccentColor;
	_rest.color = colorFromCfg(cfg_colorRest) ?: NSColor.secondaryLabelColor;
}
- (void)changed:(NSColorWell *)w {
	colorToCfg(w == _played ? cfg_colorPlayed : cfg_colorRest, w.color);
	[NSNotificationCenter.defaultCenter postNotificationName:kWavePrefsChanged object:nil];
}
- (void)reset:(id)s {
	cfg_colorPlayed = ""; cfg_colorRest = "";
	[NSNotificationCenter.defaultCenter postNotificationName:kWavePrefsChanged object:nil];
	[self load];
}
@end

namespace {
	class preferences_page_wave : public preferences_page {
	public:
		service_ptr instantiate() override { return fb2k::wrapNSObject([FooWaveSeekbarPrefs new]); }
		const char * get_name() override { return "Waveform Seekbar"; }
		GUID get_guid() override { return GUID { 0x0b8e47d2, 0xc561, 0x4a3f, { 0x92, 0x7d, 0xe4, 0x05, 0x6a, 0xb8, 0x13, 0xc9 } }; }
		GUID get_parent_guid() override { return guid_display; }
	};
	FB2K_SERVICE_FACTORY(preferences_page_wave);
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

namespace {
	class ui_element_wave_seekbar : public ui_element_mac {
	public:
		service_ptr instantiate(service_ptr arg) override {
			FooWaveSeekbarController * c = [FooWaveSeekbarController new];
			// Layout options, e.g. "waveform-seekbar time=sides"
			NSDictionary * opts = arg.is_valid() ? fb2k::unwrapNSObject(arg) : nil;
			if ([opts isKindOfClass:NSDictionary.class]) {
				id t = opts[@"time"];
				c.sideTimes = [t isKindOfClass:NSString.class] && [t isEqualToString:@"sides"];
			}
			return fb2k::wrapNSObject(c);
		}
		bool match_name(const char * name) override {
			return strcmp(name, "waveform-seekbar") == 0 || strcmp(name, "Waveform Seekbar") == 0;
		}
		fb2k::stringRef get_name() override { return fb2k::makeString("Waveform Seekbar"); }
		GUID get_guid() override {
			return GUID { 0x5b1e8c3a, 0x7d42, 0x4f19, { 0x9a, 0x6e, 0x21, 0xc4, 0x8b, 0x03, 0xd7, 0x5f } };
		}
	};
	FB2K_SERVICE_FACTORY(ui_element_wave_seekbar);
}

NANOR_UPDATE_COMPONENT("foo_wave_seekbar", "Waveform Seekbar", COMPONENT_VERSION)
