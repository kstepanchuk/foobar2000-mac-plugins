#include "stdafx.h"
#include "version.h"

DECLARE_COMPONENT_VERSION("Waveform Seekbar", COMPONENT_VERSION,
	"Waveform seekbar UI element for foobar2000 for Mac.\n"
	"Add to layout as: waveform-seekbar (option: time=sides)");

VALIDATE_COMPONENT_FILENAME("foo_wave_seekbar.dll");

FOOBAR2000_IMPLEMENT_CFG_VAR_DOWNGRADE;
