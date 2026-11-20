#include "predef.h"
#include "version.h"

DECLARE_COMPONENT_VERSION("Behringer Multichannel Output", COMPONENT_VERSION,
    "CoreAudio output for multichannel mixers. Select a device and stereo output pair "
    "in foobar2000's Output Device menu.\n"
    "Source: https://github.com/kstepanchuk/foobar2000-mac-plugins");

VALIDATE_COMPONENT_FILENAME("foo_behringer_output.fb2k-component");
FOOBAR2000_IMPLEMENT_CFG_VAR_DOWNGRADE;
