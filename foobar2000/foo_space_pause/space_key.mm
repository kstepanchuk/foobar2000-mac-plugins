#import <Cocoa/Cocoa.h>
#include "foobar2000/SDK/foobar2000.h"

namespace {
id g_spaceKeyMonitor = nil;

class space_pause_lifecycle : public initquit {
public:
	void on_init() override {
		g_spaceKeyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
			handler:^NSEvent *(NSEvent *event) {
				if (event.keyCode != 49 || event.isARepeat) return event;
				if (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption |
					NSEventModifierFlagControl | NSEventModifierFlagShift)) return event;

				NSWindow *window = event.window;
				if (window == nil || !window.isKeyWindow) return event;
				NSResponder *responder = window.firstResponder;
				// Keep Space available for text entry and controls that consume it themselves.
				if ([responder isKindOfClass:NSTextView.class] ||
					[responder isKindOfClass:NSTextField.class] ||
					[responder isKindOfClass:NSButton.class]) return event;

				playback_control::get()->play_or_pause();
				return nil;
			}];
	}

	void on_quit() override {
		if (g_spaceKeyMonitor != nil) {
			[NSEvent removeMonitor:g_spaceKeyMonitor];
			g_spaceKeyMonitor = nil;
		}
	}
};

FB2K_SERVICE_FACTORY(space_pause_lifecycle);
}
