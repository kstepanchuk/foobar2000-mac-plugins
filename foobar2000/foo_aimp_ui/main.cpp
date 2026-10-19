#include "stdafx.h"
#include "version.h"

DECLARE_COMPONENT_VERSION("AIMP UI", COMPONENT_VERSION,
	"AIMP-style UI elements for foobar2000 for Mac.\n"
	"Add to layout as: aimp-header, aimp-tabs, aimp-playlist, aimp-footer");

VALIDATE_COMPONENT_FILENAME("foo_aimp_ui.dll");

FOOBAR2000_IMPLEMENT_CFG_VAR_DOWNGRADE;
