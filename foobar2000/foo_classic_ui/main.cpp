#include "stdafx.h"
#include "version.h"

DECLARE_COMPONENT_VERSION("Classic UI", COMPONENT_VERSION,
	"Windows-style toolbar and status bar UI elements for foobar2000 for Mac.\n"
	"Add to layout as: classic-toolbar, classic-tabs, classic-playlist, classic-statusbar");

VALIDATE_COMPONENT_FILENAME("foo_classic_ui.dll");

FOOBAR2000_IMPLEMENT_CFG_VAR_DOWNGRADE;
