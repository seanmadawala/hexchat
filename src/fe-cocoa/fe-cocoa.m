/* HexChat — Cocoa Frontend
 * Copyright (C) 2026 Sean Madawala.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 */

/*
 * ==========================================================================
 *  OBJECTIVE-C CRASH COURSE FOR C PROGRAMMERS
 * ==========================================================================
 *
 *  Objective-C is C with objects bolted on. Everything you know about C
 *  still works — pointers, malloc, structs, #include, etc.
 *
 *  The new stuff:
 *
 *  1. IMPORTING (instead of #include):
 *       #import <AppKit/AppKit.h>
 *     Like #include but automatically prevents double-inclusion (no need
 *     for #ifndef guards). AppKit.h pulls in ALL of macOS's UI classes.
 *
 *  2. SENDING MESSAGES (instead of calling functions):
 *       C:     strlen(myString)
 *       ObjC:  [myString length]
 *
 *     The square brackets mean "send the message 'length' to myString".
 *     Think of it as calling a method on an object.
 *
 *  3. CREATING OBJECTS:
 *       NSWindow *win = [[NSWindow alloc] initWithContentRect:...];
 *
 *     [[ClassName alloc] initWith...] is like malloc + constructor.
 *     "alloc" allocates memory, "init..." initializes it.
 *
 *  4. STRINGS:
 *       @"Hello"    — an NSString (Objective-C string object)
 *       "Hello"     — a plain C string (char *)
 *
 *     To convert: [NSString stringWithUTF8String: myCString]
 *
 *  5. CLASSES:
 *       @interface MyClass : NSObject   — declare a class (like a struct + methods)
 *       @end
 *
 *       @implementation MyClass         — define the methods
 *       - (void)doSomething { ... }     — instance method (dash = instance)
 *       + (void)doSomething { ... }     — class method (plus = static/class)
 *       @end
 *
 *  6. PROPERTIES:
 *       @property (strong) NSString *name;
 *     Automatically creates a getter and setter. Access with dot syntax:
 *       self.name = @"HexChat";
 *
 *  7. PROTOCOLS (like interfaces in other languages):
 *       @interface MyClass : NSObject <NSTextFieldDelegate>
 *     Means "MyClass promises to implement the NSTextFieldDelegate methods".
 *
 *  8. MEMORY:
 *     We use ARC (Automatic Reference Counting) — the compiler inserts
 *     retain/release for us. But when storing ObjC objects in C structs
 *     (like session_gui), we use __bridge casts to cross the C/ObjC boundary:
 *
 *       void *cptr = (__bridge_retained void *)objcObject;  // C now "owns" it
 *       NSWindow *w = (__bridge_transfer NSWindow *)cptr;   // ObjC takes it back
 *
 *     For simplicity in this skeleton, we use CFBridgingRetain/CFBridgingRelease.
 *
 *  9. nil vs NULL:
 *       nil  = a null Objective-C object pointer (like NULL but for objects)
 *       NULL = a null C pointer (same as always)
 *     Sending a message to nil is safe — it just returns 0/nil/NO.
 *     This is DIFFERENT from C where dereferencing NULL crashes!
 *
 *  That's it! The rest is just learning which classes to use:
 *    NSWindow     = a window on screen
 *    NSTextView   = multi-line editable text area (like a rich textarea)
 *    NSScrollView = makes any view scrollable
 *    NSTextField   = single-line text input OR a label
 *    NSTableView  = a table/list (for the user list)
 *    NSApplication = THE app — manages event loop, menus, dock icon
 *    NSTimer      = calls your function after a delay (like setTimeout)
 * ==========================================================================
 */

#import <Cocoa/Cocoa.h>   /* Imports ALL of AppKit + Foundation. */

/* Pull in the Meson-generated config (HAS_OPENSSL, PACKAGE_VERSION, etc.) */
#include "config.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>

/* GLib — we still use this for the event loop (timers, socket I/O).
 * HexChat's backend relies heavily on GLib types (gboolean, gchar, etc.)
 * and on GLib's socket monitoring. Replacing GLib entirely would mean
 * rewriting a lot of backend code. So we keep it and integrate it
 * with Cocoa's run loop. */
#include <glib.h>

/* HexChat backend headers */
#include "../common/hexchat.h"
#include "../common/hexchatc.h"
#include "../common/cfgfiles.h"
#include "../common/outbound.h"
#include "../common/util.h"
#include "../common/fe.h"

/* Our own header (the session_gui / server_gui structs) */
#include "fe-cocoa.h"


/* ==========================================================================
 *  OBJECTIVE-C LESSON: @interface / @implementation
 * ==========================================================================
 *
 *  Below we define a "delegate" class. In Cocoa, a delegate is an object
 *  that handles events on behalf of another object.
 *
 *  NSApplicationDelegate — handles app-level events (launch, quit, etc.)
 *  NSTextFieldDelegate   — handles text field events (user pressed Enter)
 *
 *  Think of it like registering callback functions, but object-oriented.
 * ==========================================================================
 */

/*
 * HCAppDelegate — our main application delegate.
 *
 * @interface declares what methods and properties the class has.
 * The part in angle brackets <NSApplicationDelegate> means
 * "this class implements the NSApplicationDelegate protocol".
 */
@interface HCAppDelegate : NSObject <NSApplicationDelegate>

/*
 * @property declares instance variables with automatic getters/setters.
 *
 * (strong) means "this object owns the timer and keeps it alive".
 *   In C terms: it's like the struct holding a reference that prevents
 *   the object from being freed.
 *
 * (nonatomic) means "not thread-safe" — fine for UI code which is
 *   always on the main thread.
 */
@property (strong, nonatomic) NSTimer *glibTimer;

@end

/*
 * HCInputDelegate — handles events from the text input field.
 *
 * When the user presses Enter in the input box, Cocoa calls our
 * controlTextDidEndEditing: method. We then send the text to HexChat's
 * backend via handle_multiline().
 */
@interface HCInputDelegate : NSObject <NSTextFieldDelegate>
@end


/* ==========================================================================
 *  GLOBAL STATE
 * ==========================================================================
 *
 *  These globals are similar to what fe-text.c uses.
 *  "static" means file-scope only (not visible to other .c/.m files).
 * ==========================================================================
 */

static int done = FALSE;           /* Has the user quit?                     */
static int done_intro = 0;         /* Have we shown the welcome message?     */
static HCAppDelegate *appDelegate; /* Our app delegate (prevent dealloc)     */
static HCInputDelegate *inputDel;  /* Our input field delegate               */


/* ==========================================================================
 *  HELPER: Store and retrieve Cocoa objects from session_gui void* fields
 * ==========================================================================
 *
 *  OBJECTIVE-C LESSON: Bridging between C and Objective-C memory
 *
 *  When we store an NSWindow* in a void* field of a C struct, we need to
 *  tell the compiler "I'm taking ownership of this object in C land".
 *
 *  CFBridgingRetain(obj)  — increments the reference count, returns void*
 *                           (the object won't be freed while we hold it)
 *
 *  CFBridgingRelease(ptr) — decrements the reference count, returns id
 *                           (if count reaches 0, the object is freed)
 *
 *  (__bridge Type)ptr     — just casts, no ownership change
 *                           (use for temporary access, not storage)
 *
 *  Simple rule:
 *    Storing into void*  -> use CFBridgingRetain
 *    Reading from void*  -> use (__bridge Type)
 *    Freeing from void*  -> use CFBridgingRelease
 * ==========================================================================
 */

/* Safely get the NSWindow from a session, or nil if not set up yet. */
static inline NSWindow *
get_window (struct session *sess)
{
	if (!sess || !sess->gui || !sess->gui->window)
		return nil;
	return (__bridge NSWindow *)sess->gui->window;
}

/* Safely get the NSTextView from a session. */
static inline NSTextView *
get_text_view (struct session *sess)
{
	if (!sess || !sess->gui || !sess->gui->text_view)
		return nil;
	return (__bridge NSTextView *)sess->gui->text_view;
}

/* Safely get the input NSTextField from a session. */
static inline NSTextField *
get_input_field (struct session *sess)
{
	if (!sess || !sess->gui || !sess->gui->input_field)
		return nil;
	return (__bridge NSTextField *)sess->gui->input_field;
}


/* ==========================================================================
 *  HCAppDelegate IMPLEMENTATION
 * ==========================================================================
 *
 *  OBJECTIVE-C LESSON: @implementation
 *
 *  This is where we write the actual code for HCAppDelegate's methods.
 *
 *  Methods that start with "-" are instance methods (called on an object).
 *  Methods that start with "+" are class methods (called on the class itself).
 *
 *  The method signature syntax is:
 *    - (ReturnType)methodName:(ParamType)param1 secondPart:(ParamType)param2
 *
 *  In C this would be:
 *    ReturnType methodName(ParamType param1, ParamType param2)
 *
 *  Why the weird syntax? Each "part" of the name describes the parameter:
 *    [window initWithContentRect:rect styleMask:style ...]
 *  reads like English: "init with content rect ___ style mask ___"
 * ==========================================================================
 */
@implementation HCAppDelegate

/*
 * applicationDidFinishLaunching: is called by macOS after NSApplication
 * has finished starting up. This is similar to GTK's "realize" signal.
 *
 * The (NSNotification *) parameter contains info about the event.
 * We don't need it here, so we ignore it.
 */
- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
	/*
	 * Activate our app (bring it to the front).
	 *
	 * NSApplicationActivationPolicyRegular means "this app appears in the
	 * Dock and has a menu bar" (as opposed to a background daemon).
	 */
	[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

	/*
	 * OBJECTIVE-C LESSON: preprocessor check
	 *
	 * NSApp is a global variable that points to the shared NSApplication
	 * instance. It's set up by [NSApplication sharedApplication].
	 */
	[NSApp activateIgnoringOtherApps:YES];
}

/*
 * applicationShouldTerminateAfterLastWindowClosed: — macOS asks us:
 * "should the app quit when the last window is closed?"
 * We say NO because HexChat can reconnect and reopen windows.
 */
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
	return NO;
}

/*
 * applicationShouldTerminate: — macOS asks us: "is it OK to quit?"
 * We call hexchat_exit() which does graceful cleanup (disconnect from
 * servers, save config, etc.) and then returns. We allow the quit.
 */
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
	hexchat_exit();
	return NSTerminateNow;
}

/*
 * pumpGLib: — called periodically by our NSTimer.
 *
 * This is how we integrate GLib with Cocoa's event loop:
 *
 * - Cocoa has its OWN event loop (NSApplication's run loop)
 * - GLib has its OWN event loop (GMainLoop / GMainContext)
 * - HexChat's backend uses GLib for socket I/O and timers
 *
 * Solution: we let Cocoa's run loop be the "boss", and use an NSTimer
 * to periodically "pump" (check) GLib's pending events.
 *
 * g_main_context_iteration(NULL, FALSE) means:
 *   NULL  = use the default GLib context
 *   FALSE = don't block (return immediately if nothing to do)
 *
 * We call this ~100 times per second (every 10ms) so GLib events
 * get processed promptly without noticeable lag.
 */
- (void)pumpGLib:(NSTimer *)timer
{
	/* Process all pending GLib events without blocking. */
	while (g_main_context_iteration(NULL, FALSE))
		;  /* empty body — just keep pumping until there's nothing left */

	if (done)
	{
		[NSApp terminate:nil];
	}
}

@end  /* HCAppDelegate */


/* ==========================================================================
 *  HCInputDelegate IMPLEMENTATION — handles the input text field
 * ==========================================================================
 */
@implementation HCInputDelegate

/*
 * control:textView:doCommandBySelector: is called when the user presses
 * a special key (Enter, Tab, Escape, etc.) in an NSTextField.
 *
 * OBJECTIVE-C LESSON: @selector
 *   @selector(insertNewline:) is a way to refer to a method by name.
 *   It's like a function pointer, but for Objective-C methods.
 *   insertNewline: is the method that fires when the user hits Enter.
 *
 * We check: "did the user press Enter?" If yes, we grab the text and
 * send it to HexChat's command handler.
 *
 * Return YES means "we handled it, don't do the default action".
 * Return NO means "we didn't handle it, do the default action".
 */
- (BOOL)control:(NSControl *)control
	   textView:(NSTextView *)textView
doCommandBySelector:(SEL)commandSelector
{
	if (commandSelector == @selector(insertNewline:))
	{
		/* Get the text from the input field as a C string. */
		NSTextField *field = (NSTextField *)control;
		const char *text = [[field stringValue] UTF8String];

		if (text && text[0] != '\0' && current_sess)
		{
			/*
			 * handle_multiline() is HexChat's backend function that
			 * processes user input. It handles:
			 *   - Regular messages (sent to the channel)
			 *   - Commands starting with / (like /join, /quit, /msg)
			 *   - Multi-line pastes
			 *
			 * Parameters:
			 *   current_sess = the currently active chat session
			 *   (char *)text = the text to process (cast away const)
			 *   TRUE         = allow commands (process /slash commands)
			 *   FALSE        = don't add to command history (we could change this)
			 */
			handle_multiline (current_sess, (char *)text, TRUE, FALSE);

			/* Clear the input field after sending. */
			[field setStringValue:@""];
		}

		return YES;  /* We handled the Enter key. */
	}

	return NO;  /* Let Cocoa handle other keys normally. */
}

@end  /* HCInputDelegate */


/* ==========================================================================
 *  MENU BAR SETUP
 * ==========================================================================
 *
 *  Every macOS app needs a menu bar. Without one, you can't even Cmd+Q
 *  to quit! This function creates a minimal menu with:
 *    - Application menu (with Quit)
 *
 *  OBJECTIVE-C LESSON: Nested message sends
 *    [[NSMenuItem alloc] initWithTitle:...]
 *  is the same as:
 *    NSMenuItem *item = [NSMenuItem alloc];  // step 1: allocate
 *    item = [item initWithTitle:...];        // step 2: initialize
 *  Just combined into one line.
 * ==========================================================================
 */
static void
create_menu_bar (void)
{
	/*
	 * macOS menu structure:
	 *   NSMenu (main menu bar)
	 *     -> NSMenuItem (one per dropdown)
	 *         -> NSMenu (the dropdown menu)
	 *             -> NSMenuItem (individual items like "Quit")
	 */

	/* Create the main menu bar. */
	NSMenu *menuBar = [[NSMenu alloc] init];

	/* Create the "HexChat" application menu (first dropdown). */
	NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
	[menuBar addItem:appMenuItem];

	/* Create the dropdown menu for the app menu item. */
	NSMenu *appMenu = [[NSMenu alloc] init];

	/*
	 * Add "Quit HexChat" with Cmd+Q shortcut.
	 *
	 * @selector(terminate:) tells macOS "when clicked, call the
	 * terminate: method on the target" — NSApp's terminate: will
	 * trigger applicationShouldTerminate: on our delegate.
	 *
	 * keyEquivalent:@"q" with the default modifier (Cmd) = Cmd+Q.
	 */
	NSMenuItem *quitItem = [[NSMenuItem alloc]
		initWithTitle:@"Quit HexChat"
		action:@selector(terminate:)
		keyEquivalent:@"q"];
	[appMenu addItem:quitItem];

	/* Wire it all together. */
	[appMenuItem setSubmenu:appMenu];
	[NSApp setMainMenu:menuBar];
}


/* ==========================================================================
 *
 *                  THE fe_* FUNCTIONS — HexChat's Frontend API
 *
 *  Everything below implements the functions declared in src/common/fe.h.
 *  The backend calls these to interact with the UI.
 *
 *  We implement the critical ones fully, and stub out the rest.
 *  A "stub" is an empty function that satisfies the linker — the app
 *  won't crash, it just won't do anything for that feature yet.
 *
 * ==========================================================================
 */


/* --------------------------------------------------------------------------
 *  fe_args — Parse command-line arguments.
 *
 *  Called at the very start, before any UI is set up.
 *  Return -1 to continue startup, 0 or 1 to exit immediately.
 *
 *  This is identical to fe-text.c's version — command-line parsing
 *  is the same regardless of which UI we use.
 * -------------------------------------------------------------------------- */

static char *arg_cfgdir = NULL;
static gint arg_show_autoload = 0;
static gint arg_show_config = 0;
static gint arg_show_version = 0;

static const GOptionEntry gopt_entries[] =
{
	{"no-auto",    'a', 0, G_OPTION_ARG_NONE,   &arg_dont_autoconnect, N_("Don't auto connect to servers"), NULL},
	{"cfgdir",     'd', 0, G_OPTION_ARG_STRING,  &arg_cfgdir, N_("Use a different config directory"), "PATH"},
	{"no-plugins", 'n', 0, G_OPTION_ARG_NONE,   &arg_skip_plugins, N_("Don't auto load any plugins"), NULL},
	{"plugindir",  'p', 0, G_OPTION_ARG_NONE,   &arg_show_autoload, N_("Show plugin/script auto-load directory"), NULL},
	{"configdir",  'u', 0, G_OPTION_ARG_NONE,   &arg_show_config, N_("Show user config directory"), NULL},
	{"url",         0, G_OPTION_FLAG_HIDDEN, G_OPTION_ARG_STRING, &arg_url, N_("Open an irc://server:port/channel URL"), "URL"},
	{"version",    'v', 0, G_OPTION_ARG_NONE,   &arg_show_version, N_("Show version information"), NULL},
	{G_OPTION_REMAINING, '\0', 0, G_OPTION_ARG_STRING_ARRAY, &arg_urls, N_("Open an irc://server:port/channel?key URL"), "URL"},
	{NULL}
};

int
fe_args (int argc, char *argv[])
{
	GError *error = NULL;
	GOptionContext *context;

#ifdef ENABLE_NLS
	bindtextdomain (GETTEXT_PACKAGE, LOCALEDIR);
	bind_textdomain_codeset (GETTEXT_PACKAGE, "UTF-8");
	textdomain (GETTEXT_PACKAGE);
#endif

	context = g_option_context_new (NULL);
	g_option_context_add_main_entries (context, gopt_entries, GETTEXT_PACKAGE);
	g_option_context_parse (context, &argc, &argv, &error);

	if (error)
	{
		if (error->message)
			printf ("%s\n", error->message);
		return 1;
	}

	g_option_context_free (context);

	if (arg_show_version)
	{
		printf (PACKAGE_NAME " " PACKAGE_VERSION "\n");
		return 0;
	}

	if (arg_show_autoload)
	{
#ifdef USE_PLUGIN
		printf ("%s\n", HEXCHATLIBDIR);
#else
		printf (PACKAGE_NAME " was built without plugin support\n");
#endif
		return 0;
	}

	if (arg_show_config)
	{
		printf ("%s\n", get_xdir ());
		return 0;
	}

	if (arg_cfgdir)
	{
		g_free (xdir);
		xdir = strdup (arg_cfgdir);
		if (xdir[strlen (xdir) - 1] == '/')
			xdir[strlen (xdir) - 1] = 0;
		g_free (arg_cfgdir);
	}

	return -1;  /* -1 = continue with normal startup */
}


/* --------------------------------------------------------------------------
 *  fe_init — Called once after fe_args. Set up default preferences.
 *
 *  We disable some GUI features that don't exist yet in our frontend,
 *  and disable the server list dialog (we'll auto-connect or use commands).
 * -------------------------------------------------------------------------- */
void
fe_init (void)
{
	/* Disable features we haven't built yet. */
	prefs.hex_gui_tab_server = 0;      /* no server tabs yet              */
	prefs.hex_gui_autoopen_dialog = 0; /* no auto-open dialog             */
	prefs.hex_gui_lagometer = 0;       /* no lag meter widget yet         */
	prefs.hex_gui_slist_skip = 1;      /* skip the server list on startup */
}


/* --------------------------------------------------------------------------
 *  fe_main — THE MAIN EVENT LOOP. This is the heart of the frontend.
 *
 *  In a Cocoa app, [NSApp run] is the main event loop — it processes
 *  mouse clicks, keyboard input, window events, timers, etc.
 *
 *  But HexChat's backend uses GLib for socket I/O (reading from IRC)
 *  and timers (reconnect delays, etc.). We need BOTH loops running.
 *
 *  Solution: we run Cocoa's loop (it's the boss) and use an NSTimer
 *  to periodically "pump" GLib's pending events. This is set up in
 *  applicationDidFinishLaunching: but we kick it off here too.
 *
 *  This function does NOT return until the app quits.
 * -------------------------------------------------------------------------- */
void
fe_main (void)
{
	/*
	 * OBJECTIVE-C LESSON: @autoreleasepool
	 *
	 * In Objective-C, objects can be "autoreleased" — marked for later
	 * cleanup. The @autoreleasepool block defines a scope: when the
	 * block exits, all autoreleased objects inside it are freed.
	 *
	 * Every thread that uses Objective-C objects needs at least one
	 * autorelease pool. For the main thread, we wrap our app startup.
	 */
	@autoreleasepool
	{
		/*
		 * [NSApplication sharedApplication] creates the singleton NSApp.
		 * Every macOS app has exactly ONE NSApplication instance.
		 * This call also sets the global NSApp variable.
		 */
		[NSApplication sharedApplication];

		/* Create our app delegate and assign it to NSApp. */
		appDelegate = [[HCAppDelegate alloc] init];
		[NSApp setDelegate:appDelegate];

		/* Create the menu bar (Cmd+Q needs this to work). */
		create_menu_bar ();

		/*
		 * Create the NSTimer that pumps GLib events.
		 *
		 * scheduledTimerWithTimeInterval: creates a timer that fires
		 * repeatedly every 0.01 seconds (100 Hz).
		 *
		 * target:   = the object whose method to call
		 * selector: = which method to call  (pumpGLib:)
		 * userInfo: = extra data to pass (nil = none)
		 * repeats:  = YES means it fires repeatedly (not just once)
		 */
		appDelegate.glibTimer = [NSTimer
			scheduledTimerWithTimeInterval:0.01
			target:appDelegate
			selector:@selector(pumpGLib:)
			userInfo:nil
			repeats:YES];

		/*
		 * Also create the shared input delegate for text fields.
		 * We create it once and reuse it for all input fields.
		 */
		inputDel = [[HCInputDelegate alloc] init];

		/*
		 * [NSApp run] — start the Cocoa event loop.
		 * This call BLOCKS until the app quits (NSApp terminate: is called).
		 * All UI events, timer firings, etc. happen inside here.
		 */
		[NSApp run];
	}
}


/* --------------------------------------------------------------------------
 *  fe_cleanup — Called during shutdown. Free resources.
 * -------------------------------------------------------------------------- */
void
fe_cleanup (void)
{
	/* Stop the GLib pump timer. */
	if (appDelegate.glibTimer)
	{
		[appDelegate.glibTimer invalidate];
		appDelegate.glibTimer = nil;
	}
}


/* --------------------------------------------------------------------------
 *  fe_exit — The backend wants us to quit.
 *
 *  We set the "done" flag. The next time pumpGLib: fires, it will see
 *  this flag and call [NSApp terminate:nil] to cleanly exit.
 * -------------------------------------------------------------------------- */
void
fe_exit (void)
{
	done = TRUE;
}


/* --------------------------------------------------------------------------
 *  TIMERS AND I/O — Delegated to GLib
 *
 *  For Phase 1, we use GLib's timer and I/O functions, exactly like
 *  fe-text.c does. This is the path of least resistance — it works
 *  because our NSTimer pumps GLib's main context.
 *
 *  Later, we could replace these with NSTimer and dispatch_source_t
 *  for a "purer" Cocoa experience, but GLib works fine.
 * -------------------------------------------------------------------------- */

int
fe_timeout_add (int interval, void *callback, void *userdata)
{
	return g_timeout_add (interval, (GSourceFunc) callback, userdata);
}

int
fe_timeout_add_seconds (int interval, void *callback, void *userdata)
{
	return g_timeout_add_seconds (interval, (GSourceFunc) callback, userdata);
}

void
fe_timeout_remove (int tag)
{
	g_source_remove (tag);
}

int
fe_input_add (int sok, int flags, void *func, void *data)
{
	int tag, type = 0;
	GIOChannel *channel;

	channel = g_io_channel_unix_new (sok);

	if (flags & FIA_READ)
		type |= G_IO_IN | G_IO_HUP | G_IO_ERR;
	if (flags & FIA_WRITE)
		type |= G_IO_OUT | G_IO_ERR;
	if (flags & FIA_EX)
		type |= G_IO_PRI;

	tag = g_io_add_watch (channel, type, (GIOFunc) func, data);
	g_io_channel_unref (channel);

	return tag;
}

void
fe_input_remove (int tag)
{
	g_source_remove (tag);
}

void
fe_idle_add (void *func, void *data)
{
	g_idle_add (func, data);
}


/* --------------------------------------------------------------------------
 *  fe_new_window — Create a new chat window/tab.
 *
 *  This is called by the backend whenever a new session is created
 *  (joining a channel, opening a query, connecting to a server).
 *
 *  For Phase 1: one NSWindow per session, with a simple layout:
 *    +-----------------------------------------+
 *    | Topic bar (future)                      |
 *    +-----------------------------------------+
 *    |                              | User     |
 *    |  Chat text area              | List     |
 *    |  (NSTextView in              | (future) |
 *    |   NSScrollView)              |          |
 *    |                              |          |
 *    +-----------------------------------------+
 *    | [nick] [input field                   ] |
 *    +-----------------------------------------+
 *
 *  Later we'll add tabs (NSTabView or custom tab bar) so multiple
 *  sessions can share one window, like the GTK frontend does.
 * -------------------------------------------------------------------------- */
void
fe_new_window (struct session *sess, int focus)
{
	/*
	 * STEP 1: Allocate the session_gui struct.
	 * g_new0 is GLib's "allocate and zero-fill" — like calloc.
	 */
	session_gui *gui = g_new0 (session_gui, 1);
	sess->gui = gui;

	/* Set up session pointers (same as fe-text.c). */
	if (!sess->server->front_session)
		sess->server->front_session = sess;
	if (!sess->server->server_session)
		sess->server->server_session = sess;
	if (!current_tab || focus)
		current_tab = sess;

	current_sess = sess;

	@autoreleasepool
	{
		/*
		 * STEP 2: Create the window.
		 *
		 * NSMakeRect(x, y, width, height) defines the window's position
		 * and size. In macOS, (0,0) is the BOTTOM-LEFT of the screen
		 * (unlike most other systems where it's top-left).
		 *
		 * NSWindowStyleMask flags:
		 *   Titled     = has a title bar
		 *   Closable   = has a close button (red circle)
		 *   Resizable  = can be resized by dragging edges
		 *   Miniaturizable = has a minimize button (yellow circle)
		 *
		 * NSBackingStoreBuffered = double-buffered drawing (standard).
		 */
		NSRect frame = NSMakeRect (200, 200, 800, 600);
		NSUInteger style = NSWindowStyleMaskTitled
		                 | NSWindowStyleMaskClosable
		                 | NSWindowStyleMaskResizable
		                 | NSWindowStyleMaskMiniaturizable;

		NSWindow *window = [[NSWindow alloc]
			initWithContentRect:frame
			styleMask:style
			backing:NSBackingStoreBuffered
			defer:NO];

		/*
		 * Set the window title to the session's channel name,
		 * or "HexChat" if there's no channel yet.
		 */
		if (sess->channel[0])
			[window setTitle:[NSString stringWithUTF8String:sess->channel]];
		else
			[window setTitle:@"HexChat"];

		/*
		 * STEP 3: Create the text view (where IRC messages appear).
		 *
		 * NSTextView needs to be inside an NSScrollView to be scrollable.
		 * The scroll view handles scrollbars and clipping automatically.
		 */
		NSRect contentFrame = [[window contentView] bounds];

		/* Reserve 30px at the bottom for the input field. */
		NSRect scrollFrame = contentFrame;
		scrollFrame.size.height -= 30;
		scrollFrame.origin.y = 30;

		NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:scrollFrame];
		[scrollView setHasVerticalScroller:YES];
		[scrollView setHasHorizontalScroller:NO];

		/*
		 * Enable autoresizing so the scroll view grows/shrinks with
		 * the window. This is the "springs and struts" model:
		 *   NSViewWidthSizable  = stretch horizontally
		 *   NSViewHeightSizable = stretch vertically
		 */
		[scrollView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

		/*
		 * Create the text view that goes inside the scroll view.
		 * We make it non-editable (it's for display only — the user
		 * types in the input field below, not in the chat area).
		 */
		NSTextView *textView = [[NSTextView alloc]
			initWithFrame:[[scrollView contentView] bounds]];
		[textView setEditable:NO];       /* Can't type in the chat area.       */
		[textView setSelectable:YES];    /* Can select and copy text.          */
		[textView setRichText:NO];       /* Plain text only (for now).         */

		/*
		 * Use a nice monospace font for IRC text.
		 * systemFontOfSize:0 means "use the system default size".
		 * We use monospacedSystemFontOfSize for a fixed-width font,
		 * which makes IRC art and alignment look correct.
		 */
		[textView setFont:[NSFont monospacedSystemFontOfSize:12
										  weight:NSFontWeightRegular]];

		/* Dark background, light text — classic IRC look. */
		[textView setBackgroundColor:[NSColor colorWithWhite:0.1 alpha:1.0]];
		[textView setTextColor:[NSColor colorWithWhite:0.9 alpha:1.0]];

		/*
		 * Allow the text view to resize horizontally with the scroll view.
		 * Without this, long lines would extend beyond the visible area.
		 */
		[textView setMaxSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
		[textView setMinSize:NSMakeSize(0, scrollFrame.size.height)];
		[textView setAutoresizingMask:NSViewWidthSizable];
		[[textView textContainer] setWidthTracksTextView:YES];

		/* Put the text view inside the scroll view. */
		[scrollView setDocumentView:textView];

		/*
		 * STEP 4: Create the input field (where user types messages).
		 *
		 * NSTextField can be a label OR an input box. By default it's
		 * an input box. We place it at the bottom of the window.
		 */
		NSRect inputFrame = NSMakeRect (0, 0, contentFrame.size.width, 28);
		NSTextField *inputField = [[NSTextField alloc] initWithFrame:inputFrame];

		/*
		 * setPlaceholderString — ghost text shown when the field is empty.
		 * Like HTML's <input placeholder="...">.
		 */
		[inputField setPlaceholderString:@"Type a message or /command..."];
		[inputField setFont:[NSFont monospacedSystemFontOfSize:12
											 weight:NSFontWeightRegular]];

		/* Make the input field stretch horizontally with the window. */
		[inputField setAutoresizingMask:NSViewWidthSizable];

		/* Connect our delegate so we get notified when Enter is pressed. */
		[inputField setDelegate:(id<NSTextFieldDelegate>)inputDel];

		/*
		 * STEP 5: Add everything to the window.
		 *
		 * [window contentView] is the "content area" of the window
		 * (everything below the title bar).
		 */
		[[window contentView] addSubview:scrollView];
		[[window contentView] addSubview:inputField];

		/*
		 * STEP 6: Store Cocoa objects in the session_gui struct.
		 *
		 * CFBridgingRetain — tells ARC "I'm storing this in a void* field,
		 * so keep it alive (don't free it)".
		 */
		gui->window      = (void *)CFBridgingRetain (window);
		gui->text_view   = (void *)CFBridgingRetain (textView);
		gui->scroll_view = (void *)CFBridgingRetain (scrollView);
		gui->input_field = (void *)CFBridgingRetain (inputField);

		/*
		 * STEP 7: Show the window.
		 *
		 * makeKeyAndOrderFront: makes the window:
		 *   "key" = receives keyboard input
		 *   "order front" = visible and in front of other windows
		 *
		 * makeFirstResponder: sets keyboard focus to the input field
		 * so the user can start typing immediately.
		 */
		if (focus)
		{
			[window makeKeyAndOrderFront:nil];
			[window makeFirstResponder:inputField];
		}
		else
		{
			[window orderFront:nil];
		}
	}

	/* Show the intro banner (once). */
	if (!done_intro)
	{
		done_intro = 1;

		char buf[512];
		g_snprintf (buf, sizeof (buf),
			"\n"
			" \017HexChat-Cocoa \00310" PACKAGE_VERSION "\n"
			" \017Running on \00310%s\n",
			get_sys_str (1));
		fe_print_text (sess, buf, 0, FALSE);
	}
}


/* --------------------------------------------------------------------------
 *  fe_new_server — Allocate server_gui for a new server connection.
 * -------------------------------------------------------------------------- */
void
fe_new_server (struct server *serv)
{
	serv->gui = g_new0 (server_gui, 1);
}


/* --------------------------------------------------------------------------
 *  fe_print_text — Display text in the chat area.
 *
 *  This is THE most important display function. The backend calls this
 *  every time there's a message to show (chat messages, joins, parts,
 *  status messages, etc.).
 *
 *  The text contains mIRC color codes (^C, ^B, ^O, etc.) that we need
 *  to either render or strip. For Phase 1, we strip them and just show
 *  plain text. Color support comes later!
 * -------------------------------------------------------------------------- */
void
fe_print_text (struct session *sess, char *text, time_t stamp,
               gboolean no_activity)
{
	NSTextView *textView = get_text_view (sess);
	if (!textView)
		return;

	@autoreleasepool
	{
		/*
		 * Strip mIRC formatting codes.
		 *
		 * mIRC uses control characters for formatting:
		 *   \003 (^C) = color code, followed by digits
		 *   \002 (^B) = bold toggle
		 *   \017 (^O) = reset all formatting
		 *   \026 (^V) = reverse/italic toggle
		 *   \037 (^_) = underline toggle
		 *   \010 (^H) = hidden text
		 *
		 * For now, we just strip them all out.
		 * In a future phase, we'll convert them to NSAttributedString
		 * attributes (bold, colored text, etc.).
		 */
		int len = strlen (text);
		char *clean = g_malloc (len + 1);
		int i = 0, j = 0;

		while (i < len)
		{
			switch (text[i])
			{
			case '\003':  /* color code */
				i++;
				/* Skip up to 2 digits (foreground color). */
				if (i < len && text[i] >= '0' && text[i] <= '9') i++;
				if (i < len && text[i] >= '0' && text[i] <= '9') i++;
				/* Skip comma and up to 2 digits (background color). */
				if (i < len && text[i] == ',')
				{
					i++;
					if (i < len && text[i] >= '0' && text[i] <= '9') i++;
					if (i < len && text[i] >= '0' && text[i] <= '9') i++;
				}
				continue;  /* Don't increment i at the end of the loop. */
			case '\002':  /* bold */
			case '\017':  /* reset */
			case '\026':  /* reverse */
			case '\037':  /* underline */
			case '\010':  /* hidden */
				break;    /* Skip this character. */
			default:
				clean[j++] = text[i];
				break;
			}
			i++;
		}
		clean[j] = '\0';

		/*
		 * Append the cleaned text to the text view.
		 *
		 * OBJECTIVE-C LESSON: NSTextStorage
		 *
		 * NSTextView uses a "model-view" architecture:
		 *   - NSTextStorage holds the text data (the model)
		 *   - NSTextView renders it on screen (the view)
		 *
		 * To modify text, we go through the textStorage:
		 *   1. Get the storage: [textView textStorage]
		 *   2. Begin editing:   [storage beginEditing]
		 *   3. Append text:     [storage appendAttributedString:...]
		 *   4. End editing:     [storage endEditing]
		 *
		 * NSAttributedString = text + formatting attributes (font, color, etc.)
		 * NSString           = just text
		 *
		 * We create an NSAttributedString with our font/color settings.
		 */
		NSString *nsText = [NSString stringWithUTF8String:clean];
		if (!nsText)
		{
			/* If the text isn't valid UTF-8, try Latin-1 as fallback. */
			nsText = [[NSString alloc]
				initWithBytes:clean
				length:j
				encoding:NSISOLatin1StringEncoding];
		}
		g_free (clean);

		if (!nsText)
			return;

		/*
		 * NSDictionary — a key-value container (like Python's dict).
		 * Here we use it to specify text attributes:
		 *   NSForegroundColorAttributeName = text color
		 *   NSFontAttributeName = font
		 *
		 * The @{ key: value, ... } syntax is an Objective-C literal
		 * for creating an NSDictionary.
		 */
		NSDictionary *attrs = @{
			NSForegroundColorAttributeName:
				[NSColor colorWithWhite:0.9 alpha:1.0],
			NSFontAttributeName:
				[NSFont monospacedSystemFontOfSize:12
					weight:NSFontWeightRegular],
		};

		NSAttributedString *attrText = [[NSAttributedString alloc]
			initWithString:nsText attributes:attrs];

		/*
		 * OBJECTIVE-C LESSON: dispatch_async to main thread
		 *
		 * UI updates in macOS MUST happen on the main thread.
		 * The backend might call fe_print_text from a callback running
		 * on a GLib thread. To be safe, we dispatch to the main queue.
		 *
		 * dispatch_get_main_queue() = the main thread's dispatch queue
		 * dispatch_async = "run this block later on that queue"
		 *
		 * The ^{ ... } syntax is a "block" — like a lambda/closure.
		 * It captures variables from the surrounding scope.
		 */
		dispatch_async (dispatch_get_main_queue (), ^{
			NSTextStorage *storage = [textView textStorage];
			[storage beginEditing];
			[storage appendAttributedString:attrText];
			[storage endEditing];

			/*
			 * Scroll to the bottom so the newest text is visible.
			 * [textView scrollRangeToVisible:...] scrolls to show the
			 * given range. We use the very end of the text.
			 */
			NSRange endRange = NSMakeRange ([[storage string] length], 0);
			[textView scrollRangeToVisible:endRange];
		});
	}
}


/* --------------------------------------------------------------------------
 *  fe_close_window — Close a session's window and free its GUI resources.
 * -------------------------------------------------------------------------- */
void
fe_close_window (struct session *sess)
{
	if (sess->gui)
	{
		@autoreleasepool
		{
			/*
			 * Close the NSWindow. orderOut removes it from screen.
			 * CFBridgingRelease transfers ownership back to ARC,
			 * which will free the object when its reference count
			 * hits zero.
			 */
			NSWindow *window = get_window (sess);
			if (window)
				[window orderOut:nil];

			/* Release all retained Cocoa objects. */
			if (sess->gui->window)
				CFBridgingRelease (sess->gui->window);
			if (sess->gui->text_view)
				CFBridgingRelease (sess->gui->text_view);
			if (sess->gui->scroll_view)
				CFBridgingRelease (sess->gui->scroll_view);
			if (sess->gui->input_field)
				CFBridgingRelease (sess->gui->input_field);
		}

		/* Free the C struct itself. */
		g_free (sess->gui->input_text);
		g_free (sess->gui->topic_text);
		g_free (sess->gui);
		sess->gui = NULL;
	}

	session_free (sess);
}


/* --------------------------------------------------------------------------
 *  fe_message — Show a simple message (info, warning, error).
 *
 *  For now, just print to stdout. Later, this could be an NSAlert dialog.
 * -------------------------------------------------------------------------- */
void
fe_message (char *msg, int flags)
{
	puts (msg);
}


/* --------------------------------------------------------------------------
 *  fe_set_topic — The backend tells us the channel topic changed.
 * -------------------------------------------------------------------------- */
void
fe_set_topic (struct session *sess, char *topic, char *stripped_topic)
{
	/* Future: update the topic bar in the window. */
	NSWindow *window = get_window (sess);
	if (window && stripped_topic)
	{
		/* For now, append the topic to the window title. */
		dispatch_async (dispatch_get_main_queue (), ^{
			NSString *title;
			if (sess->channel[0])
				title = [NSString stringWithFormat:@"%s — %s",
					sess->channel, stripped_topic];
			else
				title = [NSString stringWithUTF8String:stripped_topic];
			[window setTitle:title];
		});
	}
}


/* --------------------------------------------------------------------------
 *  fe_set_title — Update the window title.
 * -------------------------------------------------------------------------- */
void
fe_set_title (struct session *sess)
{
	NSWindow *window = get_window (sess);
	if (window)
	{
		dispatch_async (dispatch_get_main_queue (), ^{
			NSString *title;
			if (sess->channel[0])
				title = [NSString stringWithUTF8String:sess->channel];
			else
				title = @"HexChat";
			[window setTitle:title];
		});
	}
}


/* --------------------------------------------------------------------------
 *  fe_set_channel — The session's channel name changed.
 * -------------------------------------------------------------------------- */
void
fe_set_channel (struct session *sess)
{
	fe_set_title (sess);
}


/* --------------------------------------------------------------------------
 *  fe_set_nick — Your nickname changed on this server.
 * -------------------------------------------------------------------------- */
void
fe_set_nick (struct server *serv, char *newnick)
{
	/* Future: update the nick label in all sessions for this server. */
}


/* --------------------------------------------------------------------------
 *  fe_beep — Play a beep sound.
 * -------------------------------------------------------------------------- */
void
fe_beep (session *sess)
{
	NSBeep ();   /* macOS system beep */
}


/* --------------------------------------------------------------------------
 *  fe_open_url — Open a URL in the user's default browser.
 * -------------------------------------------------------------------------- */
void
fe_open_url (const char *url)
{
	if (!url)
		return;

	@autoreleasepool
	{
		/*
		 * NSURL + NSWorkspace: the standard way to open URLs on macOS.
		 *
		 * NSWorkspace is a singleton that talks to the macOS Finder/system.
		 * openURL: launches the default browser with the given URL.
		 */
		NSString *urlStr = [NSString stringWithUTF8String:url];
		NSURL *nsurl = [NSURL URLWithString:urlStr];
		if (nsurl)
			[[NSWorkspace sharedWorkspace] openURL:nsurl];
	}
}


/* --------------------------------------------------------------------------
 *  fe_ctrl_gui — Control the GUI (show, hide, focus, iconify, etc.).
 * -------------------------------------------------------------------------- */
void
fe_ctrl_gui (session *sess, fe_gui_action action, int arg)
{
	NSWindow *window = get_window (sess);

	switch (action)
	{
	case FE_GUI_HIDE:
		if (window)
			dispatch_async (dispatch_get_main_queue (), ^{
				[window orderOut:nil];
			});
		break;

	case FE_GUI_SHOW:
		if (window)
			dispatch_async (dispatch_get_main_queue (), ^{
				[window makeKeyAndOrderFront:nil];
			});
		break;

	case FE_GUI_FOCUS:
		current_sess = sess;
		current_tab = sess;
		if (sess->server)
			sess->server->front_session = sess;
		if (window)
			dispatch_async (dispatch_get_main_queue (), ^{
				[window makeKeyAndOrderFront:nil];
			});
		break;

	case FE_GUI_ICONIFY:
		if (window)
			dispatch_async (dispatch_get_main_queue (), ^{
				[window miniaturize:nil];
			});
		break;

	default:
		break;
	}
}


/* --------------------------------------------------------------------------
 *  fe_gui_info — Return information about the GUI state.
 * -------------------------------------------------------------------------- */
int
fe_gui_info (session *sess, int info_type)
{
	return -1;  /* -1 = unknown/not implemented */
}


void *
fe_gui_info_ptr (session *sess, int info_type)
{
	return NULL;
}


/* --------------------------------------------------------------------------
 *  fe_get_inputbox_contents / fe_set_inputbox_contents
 *
 *  The backend sometimes needs to read or modify the input field
 *  (e.g., for tab completion, command history).
 * -------------------------------------------------------------------------- */
char *
fe_get_inputbox_contents (struct session *sess)
{
	NSTextField *field = get_input_field (sess);
	if (!field)
		return g_strdup ("");

	__block char *result = NULL;

	/*
	 * OBJECTIVE-C LESSON: dispatch_sync
	 *
	 * Like dispatch_async, but WAITS for the block to finish.
	 * We need this because the caller expects a return value.
	 * Must be careful: calling dispatch_sync on the main thread
	 * FROM the main thread would deadlock!
	 */
	if ([NSThread isMainThread])
	{
		const char *text = [[field stringValue] UTF8String];
		result = g_strdup (text ? text : "");
	}
	else
	{
		dispatch_sync (dispatch_get_main_queue (), ^{
			const char *text = [[field stringValue] UTF8String];
			result = g_strdup (text ? text : "");
		});
	}

	return result;
}

int
fe_get_inputbox_cursor (struct session *sess)
{
	/* Future: return the cursor position in the input field. */
	return 0;
}

void
fe_set_inputbox_contents (struct session *sess, char *text)
{
	NSTextField *field = get_input_field (sess);
	if (!field || !text)
		return;

	dispatch_async (dispatch_get_main_queue (), ^{
		[field setStringValue:[NSString stringWithUTF8String:text]];
	});
}

void
fe_set_inputbox_cursor (struct session *sess, int delta, int pos)
{
	/* Future: move the cursor in the input field. */
}


/* --------------------------------------------------------------------------
 *  fe_flash_window — Flash the Dock icon to get the user's attention.
 * -------------------------------------------------------------------------- */
void
fe_flash_window (struct session *sess)
{
	/*
	 * requestUserAttention: makes the Dock icon bounce.
	 * NSInformationalRequest = bounce once (vs. NSCriticalRequest = keep bouncing)
	 */
	dispatch_async (dispatch_get_main_queue (), ^{
		[NSApp requestUserAttention:NSInformationalRequest];
	});
}


/* --------------------------------------------------------------------------
 *  fe_text_clear — Clear the chat text area.
 * -------------------------------------------------------------------------- */
void
fe_text_clear (struct session *sess, int lines)
{
	NSTextView *textView = get_text_view (sess);
	if (!textView)
		return;

	dispatch_async (dispatch_get_main_queue (), ^{
		if (lines == 0)
		{
			/* Clear all text. */
			[[textView textStorage] setAttributedString:
				[[NSAttributedString alloc] initWithString:@""]];
		}
		/* Future: if lines > 0, remove only that many lines from the top. */
	});
}


/* --------------------------------------------------------------------------
 *  fe_confirm — Ask user a yes/no question.
 *
 *  Shows a macOS alert dialog.
 * -------------------------------------------------------------------------- */
void
fe_confirm (const char *message, void (*yesproc)(void *),
            void (*noproc)(void *), void *ud)
{
	if (!message)
		return;

	dispatch_async (dispatch_get_main_queue (), ^{
		@autoreleasepool
		{
			/*
			 * NSAlert — a standard macOS dialog box.
			 *
			 * setMessageText:    — the main question (big text)
			 * addButtonWithTitle: — add buttons (first one is default)
			 *
			 * runModal returns which button was clicked.
			 * NSAlertFirstButtonReturn = the first button we added ("Yes").
			 */
			NSAlert *alert = [[NSAlert alloc] init];
			[alert setMessageText:[NSString stringWithUTF8String:message]];
			[alert addButtonWithTitle:@"Yes"];
			[alert addButtonWithTitle:@"No"];

			NSModalResponse response = [alert runModal];
			if (response == NSAlertFirstButtonReturn)
			{
				if (yesproc)
					yesproc (ud);
			}
			else
			{
				if (noproc)
					noproc (ud);
			}
		}
	});
}


/* --------------------------------------------------------------------------
 *  fe_get_file — Open a file picker dialog.
 * -------------------------------------------------------------------------- */
void
fe_get_file (const char *title, char *initial,
             void (*callback)(void *userdata, char *file), void *userdata,
             int flags)
{
	dispatch_async (dispatch_get_main_queue (), ^{
		@autoreleasepool
		{
			if (flags & FRF_WRITE)
			{
				/* Save dialog. */
				NSSavePanel *panel = [NSSavePanel savePanel];
				if (title)
					[panel setTitle:[NSString stringWithUTF8String:title]];

				if ([panel runModal] == NSModalResponseOK)
				{
					const char *path = [[[panel URL] path] UTF8String];
					if (path && callback)
						callback (userdata, (char *)path);
				}
			}
			else
			{
				/* Open dialog. */
				NSOpenPanel *panel = [NSOpenPanel openPanel];
				if (title)
					[panel setTitle:[NSString stringWithUTF8String:title]];

				[panel setAllowsMultipleSelection:
					(flags & FRF_MULTIPLE) ? YES : NO];
				[panel setCanChooseDirectories:
					(flags & FRF_CHOOSEFOLDER) ? YES : NO];
				[panel setCanChooseFiles:
					(flags & FRF_CHOOSEFOLDER) ? NO : YES];

				if ([panel runModal] == NSModalResponseOK)
				{
					for (NSURL *url in [panel URLs])
					{
						const char *path = [[url path] UTF8String];
						if (path && callback)
							callback (userdata, (char *)path);
					}
				}
			}
		}
	});
}


/* --------------------------------------------------------------------------
 *  fe_get_default_font — Return the default font name for IRC text.
 * -------------------------------------------------------------------------- */
const char *
fe_get_default_font (void)
{
	return "Menlo 12";  /* macOS's default monospace font */
}


/* --------------------------------------------------------------------------
 *  fe_server_event — Server connection state changed.
 * -------------------------------------------------------------------------- */
void
fe_server_event (server *serv, int type, int arg)
{
	/* Future: update status bar or connection indicator. */
}


/* --------------------------------------------------------------------------
 *  fe_get_bool / fe_get_str / fe_get_int — Prompt dialogs.
 * -------------------------------------------------------------------------- */
void
fe_get_bool (char *title, char *prompt, void *callback, void *userdata)
{
	/* Future: show an NSAlert with Yes/No buttons. */
}

void
fe_get_str (char *prompt, char *def, void *callback, void *ud)
{
	/* Future: show an NSAlert with a text input field. */
}

void
fe_get_int (char *prompt, int def, void *callback, void *ud)
{
	/* Future: show an NSAlert with a number input field. */
}


/* ==========================================================================
 *  STUBS — Functions that do nothing yet.
 *
 *  These satisfy the linker so the app compiles and runs.
 *  Each one represents a feature we'll implement in a future phase:
 *
 *  Phase 2: User list (fe_userlist_*)
 *  Phase 3: Channel list (fe_add_chan_list, fe_chan_list_end)
 *  Phase 4: DCC file transfer UI (fe_dcc_*)
 *  Phase 5: Ban list, ignore list
 *  Phase 6: Menus, tray icon, notifications
 * ==========================================================================
 */

/* --- User list (Phase 2) --- */
void fe_userlist_insert (struct session *sess, struct User *newuser, gboolean sel) {}
int  fe_userlist_remove (struct session *sess, struct User *user) { return 0; }
void fe_userlist_rehash (struct session *sess, struct User *user) {}
void fe_userlist_update (session *sess, struct User *user) {}
void fe_userlist_numbers (struct session *sess) {}
void fe_userlist_clear (struct session *sess) {}
void fe_userlist_set_selected (struct session *sess) {}
void fe_uselect (struct session *sess, char *word[], int do_clear, int scroll_to) {}

/* --- Channel list (Phase 3) --- */
int  fe_is_chanwindow (struct server *serv) { return 0; }
void fe_add_chan_list (struct server *serv, char *chan, char *users, char *topic) {}
void fe_chan_list_end (struct server *serv) {}
void fe_open_chan_list (server *serv, char *filter, int do_refresh)
{
	serv->p_list_channels (serv, filter, 1);
}

/* --- Ban list --- */
gboolean fe_add_ban_list (struct session *sess, char *mask, char *who,
                          char *when, int rplcode) { return 0; }
gboolean fe_ban_list_end (struct session *sess, int rplcode) { return 0; }

/* --- DCC (Phase 4) --- */
void fe_dcc_add (struct DCC *dcc) {}
void fe_dcc_update (struct DCC *dcc) {}
void fe_dcc_remove (struct DCC *dcc) {}
int  fe_dcc_open_recv_win (int passive) { return FALSE; }
int  fe_dcc_open_send_win (int passive) { return FALSE; }
int  fe_dcc_open_chat_win (int passive) { return FALSE; }
void fe_dcc_send_filereq (struct session *sess, char *nick, int maxcps,
                          int passive) {}

/* --- Notifications / buddy list --- */
void fe_notify_update (char *name) {}
void fe_notify_ask (char *name, char *networks) {}

/* --- Various UI updates --- */
void fe_set_tab_color (struct session *sess, tabcolor col) {}
void fe_update_mode_buttons (struct session *sess, char mode, char sign) {}
void fe_update_channel_key (struct session *sess) {}
void fe_update_channel_limit (struct session *sess) {}
void fe_set_nonchannel (struct session *sess, int state) {}
void fe_ignore_update (int level) {}
void fe_clear_channel (struct session *sess) {}
void fe_progressbar_start (struct session *sess) {}
void fe_progressbar_end (struct server *serv) {}
void fe_set_lag (server *serv, long lag) {}
void fe_set_throttle (server *serv) {}
void fe_set_away (server *serv) {}
void fe_serverlist_open (session *sess) {}
void fe_add_rawlog (struct server *serv, char *text, int len, int outbound) {}

/* --- Session/server lifecycle callbacks --- */
void fe_session_callback (struct session *sess) {}
void fe_server_callback (struct server *serv) {}

/* --- URL grabber --- */
void fe_url_add (const char *text) {}

/* --- Plugin/button updates --- */
void fe_pluginlist_update (void) {}
void fe_buttons_update (struct session *sess) {}
void fe_dlgbuttons_update (struct session *sess) {}

/* --- Log search --- */
void fe_lastlog (session *sess, session *lastlog_sess, char *sstr,
                 gtk_xtext_search_flags flags) {}

/* --- Menus (Phase 6) --- */
char *fe_menu_add (menu_entry *me) { return NULL; }
void  fe_menu_del (menu_entry *me) {}
void  fe_menu_update (menu_entry *me) {}

/* --- System tray (Phase 6) --- */
void fe_tray_set_flash (const char *filename1, const char *filename2,
                        int timeout) {}
void fe_tray_set_file (const char *filename) {}
void fe_tray_set_icon (feicon icon) {}
void fe_tray_set_tooltip (const char *text) {}

/* --- Nick change (not in fe.h but needed by the linker) --- */
void fe_change_nick (struct server *serv, char *nick, char *newnick) {}

/* --- Userlist hide (not in fe.h but needed by the linker) --- */
void fe_userlist_hide (session *sess) {}
