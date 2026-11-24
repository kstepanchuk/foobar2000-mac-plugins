#include "foobar2000/SDK/foobar2000.h"

DECLARE_COMPONENT_VERSION("Space Pause", "1.1.0",
    "Press Space in the foobar2000 window to toggle playback pause.\n"
    "Source: https://github.com/kstepanchuk/foobar2000-mac-plugins");

VALIDATE_COMPONENT_FILENAME("foo_space_pause.fb2k-component");
FOOBAR2000_IMPLEMENT_CFG_VAR_DOWNGRADE;

namespace {
const GUID guid_pause_resume = { 0x246135a4, 0x8d17, 0x4f42, { 0xa7, 0x2c, 0x31, 0x90, 0x55, 0x8e, 0x04, 0x63 } };

class pause_resume_command : public mainmenu_commands {
public:
	 t_uint32 get_command_count() override { return 1; }
	 GUID get_command(t_uint32 index) override {
		if (index != 0) uBugCheck();
		return guid_pause_resume;
	}
	 void get_name(t_uint32 index, pfc::string_base & out) override {
		if (index != 0) uBugCheck();
		out = "Space Pause: Pause / Resume (manual command)";
	}
	 bool get_description(t_uint32 index, pfc::string_base & out) override {
		if (index != 0) return false;
		out = "Toggles playback pause. Space is handled automatically while foobar2000 is active.";
		return true;
	}
	 GUID get_parent() override { return mainmenu_groups::playback_controls; }
	 void execute(t_uint32 index, service_ptr_t<service_base>) override {
		if (index == 0) playback_control::get()->play_or_pause();
	}
};

mainmenu_commands_factory_t<pause_resume_command> g_pause_resume_factory;
}
