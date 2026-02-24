# ==========================================================================
#  HexChat Cocoa Frontend — Build Configuration
# ==========================================================================
#
#  MESON LESSON: How this build file works
#
#  Meson is the build system. Think of it like a smarter Makefile.
#  This file tells Meson:
#    1. What source files to compile
#    2. What libraries to link against
#    3. What compiler flags to use
#    4. What the output executable should be called
#
#  Key Meson concepts:
#    dependency()      — find a system library (via pkg-config)
#    declare_dependency() — export settings for other Meson files to use
#    executable()      — build a program from source files
#    find_library()    — find a framework or library by name
#
#  For Objective-C (.m files), Meson uses the same C compiler (clang)
#  but with Objective-C mode enabled. We tell it to do this with
#  'objc_args' or by listing .m files as sources.
# ==========================================================================

# The one and only source file (for now).
# As we add more features, we'll split code into separate files:
#   - fe-cocoa.m        (main frontend, fe_* functions)
#   - userlistgui.m     (user list sidebar)
#   - servlistgui.m     (server list dialog)
#   - menu.m            (menu bar)
#   - etc.
hexchat_cocoa_sources = [
  'fe-cocoa.m',
]

# --------------------------------------------------------------------------
#  Find the AppKit framework (macOS's native UI framework).
#
#  On macOS, frameworks are found in /System/Library/Frameworks/.
#  AppKit.framework includes:
#    - NSWindow, NSView, NSButton, NSTextField (UI widgets)
#    - NSApplication (the app lifecycle manager)
#    - NSMenu (menu bar)
#    - ... everything you need for a macOS GUI
#
#  dependency('appleframeworks', ...) is Meson's way to link macOS
#  frameworks. It's equivalent to passing -framework AppKit to clang.
# --------------------------------------------------------------------------
appkit_dep = dependency('appleframeworks', modules: ['AppKit'])

# --------------------------------------------------------------------------
#  Dependencies list — everything we link against.
#
#  hexchat_common_dep — comes from src/common/meson.build
#    Provides: the hexchat backend library, GLib, OpenSSL, etc.
#    This is the "engine" — all the IRC protocol handling.
#
#  appkit_dep — macOS's UI framework (found above).
# --------------------------------------------------------------------------
hexchat_cocoa_deps = [
  hexchat_common_dep,
  appkit_dep,
]

# --------------------------------------------------------------------------
#  Compiler flags for Objective-C.
#
#  -fobjc-arc enables ARC (Automatic Reference Counting).
#  Without ARC, you'd have to manually call [obj retain] and [obj release]
#  to manage memory — very error-prone! ARC does it automatically.
#
#  Think of ARC like Python's reference counting garbage collector,
#  but done at compile time by inserting retain/release calls for you.
# --------------------------------------------------------------------------
hexchat_cocoa_cflags = [
  '-fobjc-arc',
]

# --------------------------------------------------------------------------
#  Build the executable.
#
#  executable() parameters:
#    'hexchat-cocoa'  — the output binary name
#    sources:         — list of source files to compile
#    dependencies:    — libraries to link against
#    c_args:          — extra compiler flags
#    install: true    — install the binary when running `ninja install`
#    gui_app: true    — on macOS, this creates a proper GUI app (not a
#                       command-line tool). It sets the Info.plist flag
#                       LSUIElement appropriately.
# --------------------------------------------------------------------------
# --------------------------------------------------------------------------
#  NOTE: Meson treats .m files as Objective-C, which uses 'objc_args'
#  instead of 'c_args'. We pass our ARC flag via objc_args.
#
#  We also need to pass the global C flags (warnings, etc.) to the
#  Objective-C compiler since they aren't inherited automatically.
# --------------------------------------------------------------------------
executable('MacChat',
  sources: hexchat_cocoa_sources,
  dependencies: hexchat_cocoa_deps,
  objc_args: hexchat_cocoa_cflags + global_cflags,
  install: true,
  gui_app: true,
)
