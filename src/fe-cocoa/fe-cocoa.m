/* HexChat — Cocoa Frontend (Phase 3)
 * Copyright (C) 2026 Sean Madawala.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

/*
 * ==========================================================================
 *  PHASE 3: Six Feature Sprint
 *
 *  Feature 1 — mIRC Color Rendering
 *    Parse \003NN,NN color codes, \002 bold, \035 italic, \037 underline,
 *    \036 strikethrough, \026 reverse, \017 reset. Renders colored text
 *    using NSAttributedString with a 16-color mIRC palette.
 *
 *  Feature 2 — User Mode Badges + User Count Label
 *    Colored circles (Unicode ●) next to nicks based on prefix:
 *      ~ owner=purple, & admin=red, @ op=green, % hop=blue, + voice=yellow.
 *    Summary label above user list: "7 ops, 531 total".
 *
 *  Feature 3 — Topic Bar
 *    Read-only text field above the chat area showing channel topic.
 *
 *  Feature 4 — Nick Tab-Completion
 *    Press Tab to complete nicknames. Subsequent Tab presses cycle matches.
 *
 *  Feature 5 — Server List Dialog
 *    Window listing saved networks from HexChat's servlist. Connect button.
 *
 *  Feature 6 — DCC Transfers Panel
 *    Window with table showing file transfers: nick, file, size, progress,
 *    speed, status.
 * ==========================================================================
 */

#import <Cocoa/Cocoa.h>

#include "config.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>

#include <glib.h>

#include "../common/hexchat.h"
#include "../common/hexchatc.h"
#include "../common/cfgfiles.h"
#include "../common/outbound.h"
#include "../common/util.h"
#include "../common/fe.h"
#include "../common/servlist.h"
#include "../common/userlist.h"
#include "../common/text.h"

#include "fe-cocoa.h"


/* ==========================================================================
 *  FORWARD DECLARATIONS
 * ==========================================================================
 */

static void create_main_window (void);
static void create_menu_bar (void);
static void switch_to_session (struct session *sess);
static void refresh_channel_tree (void);
static void update_user_count_label (void);
static void init_mirc_colors (void);
static void show_server_list (void);
static void show_edit_network (ircnet *net);
static void show_dcc_panel (void);
static void show_preferences (void);

/* Helper: get the NSTextStorage for a session. */
static inline NSTextStorage *
get_text_storage (struct session *sess)
{
	if (!sess || !sess->gui || !sess->gui->text_storage)
		return nil;
	return (__bridge NSTextStorage *)sess->gui->text_storage;
}

/* Helper: get the user list array for a session. */
static inline NSMutableArray *
get_user_list_data (struct session *sess)
{
	if (!sess || !sess->gui || !sess->gui->user_list_data)
		return nil;
	return (__bridge NSMutableArray *)sess->gui->user_list_data;
}


/* ==========================================================================
 *  DATA MODEL — Wrapper objects for the channel tree
 * ==========================================================================
 */

@interface HCServerNode : NSObject
@property (assign, nonatomic) struct server *server;
@property (strong, nonatomic) NSString *name;
@property (strong, nonatomic) NSMutableArray *children;
@end

@implementation HCServerNode
- (instancetype)initWithServer:(struct server *)serv
{
	self = [super init];
	if (self)
	{
		_server = serv;
		_name = serv->servername[0]
			? [NSString stringWithUTF8String:serv->servername]
			: @"(connecting...)";
		_children = [[NSMutableArray alloc] init];
	}
	return self;
}
@end

@interface HCSessionNode : NSObject
@property (assign, nonatomic) struct session *session;
@property (strong, nonatomic) NSString *name;
@end

@implementation HCSessionNode
- (instancetype)initWithSession:(struct session *)sess
{
	self = [super init];
	if (self)
	{
		_session = sess;
		_name = sess->channel[0]
			? [NSString stringWithUTF8String:sess->channel]
			: @"(server)";
	}
	return self;
}
@end


/* ==========================================================================
 *  GLOBAL STATE
 * ==========================================================================
 */

static int done = FALSE;
static int done_intro = 0;

/* --- Main window and components --- */
static NSWindow      *mainWindow;
static NSSplitView   *splitView;
static NSOutlineView *channelTree;
static NSScrollView  *channelTreeScroll;
static NSTextView    *chatTextView;
static NSScrollView  *chatScrollView;
static NSTableView   *userListTable;
static NSScrollView  *userListScroll;
static NSTextField   *inputField;

/* --- Phase 3 new widgets --- */
static NSTextField   *topicBar;           /* Feature 3: topic display          */
static NSTextField   *userCountLabel;     /* Feature 2: "7 ops, 531 total"    */
static NSView        *centerWrapper;      /* Holds topic bar + chat scroll     */
static NSView        *rightWrapper;       /* Holds user count + user scroll    */

/* --- Data model for channel tree --- */
static NSMutableArray *serverNodes;

/* --- Delegates (prevent deallocation) --- */
static id appDelegate;
static id inputDelegate;
static id treeDataSource;
static id userListDataSource;

/* --- Feature 1: mIRC color palette (16 colors) --- */
static NSColor *mircColors[16];

/*
 * COCOA LESSON: NSColor
 *
 * NSColor represents a color in Cocoa. We create colors from
 * RGB float values (0.0 to 1.0). The mIRC protocol defines 16
 * standard colors indexed 0-15. When text contains \003NN, we
 * look up mircColors[NN] to get the corresponding NSColor.
 */

/* --- Feature 4: Tab-completion state --- */
static NSMutableArray *completionMatches;  /* Current list of matching nicks  */
static NSString       *completionPrefix;   /* The partial word being completed */
static NSInteger       completionIndex;    /* Which match we're showing       */
static NSInteger       completionStart;    /* Character position of the word  */

/* --- Feature 5: Server List panel --- */
static NSWindow      *serverListWindow;
static NSTableView   *serverListTable;
static NSMutableArray *serverListNets;     /* Array of NSValue<ircnet *>      */
static id             serverListDataSource;
static NSTextField   *slNickField1;        /* Server list nick/user fields    */
static NSTextField   *slNickField2;
static NSTextField   *slNickField3;
static NSTextField   *slUserField;

/* --- Feature 5b: Edit Network dialog --- */
static NSWindow      *editNetWindow;
static ircnet        *editNet;             /* network being edited            */
static NSTabView     *editTabView;
static NSTableView   *editServerTable;
static NSTableView   *editChanTable;
static NSTableView   *editCmdTable;
static NSTextField   *editNickField;
static NSTextField   *editNick2Field;
static NSTextField   *editNick3Field;      /* Third choice (global only)      */
static NSTextField   *editUserField;
static NSSecureTextField *editPassField;
static NSPopUpButton *editLoginPopup;
static NSComboBox    *editCharsetCombo;
static NSButton      *editChkGlobal;       /* "Use global user information"   */
/* Fields that get toggled when "Use global" is checked. */
static NSTextField   *editFieldsToToggle[4]; /* nick, nick2, nick3, user      */

/* Login type mapping — must match the popup item order. */
static const int cocoa_login_types_conf[] = {
	0,   /* LOGIN_DEFAULT */
	6,   /* LOGIN_SASL */
	10,  /* LOGIN_SASLEXTERNAL */
	11,  /* LOGIN_SASL_SCRAM_SHA_1 */
	12,  /* LOGIN_SASL_SCRAM_SHA_256 */
	13,  /* LOGIN_SASL_SCRAM_SHA_512 */
	7,   /* LOGIN_PASS */
	1,   /* LOGIN_MSG_NICKSERV */
	2,   /* LOGIN_NICKSERV */
	8,   /* LOGIN_CHALLENGEAUTH */
	9,   /* LOGIN_CUSTOM */
};
static const int cocoa_login_types_count = 11;

/* Character set list. */
static const char *cocoa_charsets[] = {
	"UTF-8 (Unicode)",
	"CP1252 (Windows-1252)",
	"ISO-8859-15 (Western Europe)",
	"ISO-8859-2 (Central Europe)",
	"ISO-8859-7 (Greek)",
	"ISO-8859-8 (Hebrew)",
	"ISO-8859-9 (Turkish)",
	"ISO-2022-JP (Japanese)",
	"SJIS (Japanese)",
	"CP949 (Korean)",
	"KOI8-R (Cyrillic)",
	"CP1251 (Cyrillic)",
	"CP1256 (Arabic)",
	"CP1257 (Baltic)",
	"GB18030 (Chinese)",
	"TIS-620 (Thai)",
	NULL
};

/* --- Feature 6: DCC panel --- */
static NSWindow      *dccWindow;
static NSTableView   *dccTable;
static NSMutableArray *dccTransfers;       /* Array of struct DCC * (wrapped) */
static id             dccDataSource;

/* --- Find bar (Edit > Find) --- */
static NSView        *findBar;
static NSTextField   *findField;
static BOOL           findBarVisible;
static NSRange        lastFindRange;

/* --- Preferences dialog --- */
static NSWindow      *prefsWindow;
static NSTabView     *prefsTabView;
/* Text fields that must be read back on close: */
static NSTextField   *prefsFontLabel;
static NSTextField   *prefsStampFmt;
static NSTextField   *prefsSpellLangs;
static NSTextField   *prefsCompSuffix;
static NSTextField   *prefsQuitMsg;
static NSTextField   *prefsPartMsg;
static NSTextField   *prefsAwayMsg;
static NSTextField   *prefsRealName;
static NSTextField   *prefsUlistDblClick;
static NSTextField   *prefsHilightExtra;
static NSTextField   *prefsHilightNoNick;
static NSTextField   *prefsHilightNick;
static NSTextField   *prefsLogMask;
static NSTextField   *prefsLogStampFmt;
static NSTextField   *prefsProxyHost;
static NSTextField   *prefsProxyUser;
static NSSecureTextField *prefsProxyPass;
static NSTextField   *prefsDccIp;
/* New fields for expanded preferences tabs: */
static NSTextField   *prefsBgImage;
static NSTextField   *prefsBindHost;
static NSTextField   *prefsDccDir;
static NSTextField   *prefsDccCompletedDir;
/* Sounds tab state: */
static NSTableView   *soundsTable;
static NSTextField   *soundsFileField;
static int            soundsSelectedRow = -1;

/* --- Menu items needing runtime state updates --- */
static NSMenuItem    *topicBarMenuItem;
static NSMenuItem    *userListMenuItem;
static NSMenuItem    *awayMenuItem;


/* ==========================================================================
 *  FEATURE 1 — mIRC Color Palette Initialization
 * ==========================================================================
 *
 *  These 16 colors match the GTK frontend's palette.c values.
 *  GdkColor uses 16-bit values (0x0000–0xFFFF). We convert to
 *  NSColor floats (0.0–1.0) by dividing by 65535.0.
 */

static void
init_mirc_colors (void)
{
	mircColors[ 0] = [NSColor colorWithSRGBRed:0.827 green:0.843 blue:0.812 alpha:1.0]; /* white    */
	mircColors[ 1] = [NSColor colorWithSRGBRed:0.180 green:0.204 blue:0.212 alpha:1.0]; /* black    */
	mircColors[ 2] = [NSColor colorWithSRGBRed:0.204 green:0.396 blue:0.643 alpha:1.0]; /* blue     */
	mircColors[ 3] = [NSColor colorWithSRGBRed:0.306 green:0.604 blue:0.024 alpha:1.0]; /* green    */
	mircColors[ 4] = [NSColor colorWithSRGBRed:0.800 green:0.000 blue:0.000 alpha:1.0]; /* red      */
	mircColors[ 5] = [NSColor colorWithSRGBRed:0.561 green:0.224 blue:0.008 alpha:1.0]; /* lt red   */
	mircColors[ 6] = [NSColor colorWithSRGBRed:0.361 green:0.208 blue:0.400 alpha:1.0]; /* purple   */
	mircColors[ 7] = [NSColor colorWithSRGBRed:0.808 green:0.361 blue:0.000 alpha:1.0]; /* orange   */
	mircColors[ 8] = [NSColor colorWithSRGBRed:0.769 green:0.627 blue:0.000 alpha:1.0]; /* yellow   */
	mircColors[ 9] = [NSColor colorWithSRGBRed:0.451 green:0.824 blue:0.086 alpha:1.0]; /* lt green */
	mircColors[10] = [NSColor colorWithSRGBRed:0.067 green:0.659 blue:0.475 alpha:1.0]; /* aqua     */
	mircColors[11] = [NSColor colorWithSRGBRed:0.345 green:0.631 blue:0.616 alpha:1.0]; /* lt aqua  */
	mircColors[12] = [NSColor colorWithSRGBRed:0.341 green:0.475 blue:0.620 alpha:1.0]; /* lt blue  */
	mircColors[13] = [NSColor colorWithSRGBRed:0.629 green:0.824 blue:0.396 alpha:1.0]; /* lt purple*/
	mircColors[14] = [NSColor colorWithSRGBRed:0.333 green:0.341 blue:0.325 alpha:1.0]; /* grey     */
	mircColors[15] = [NSColor colorWithSRGBRed:0.533 green:0.541 blue:0.522 alpha:1.0]; /* lt grey  */
}


/* ==========================================================================
 *  FEATURE 2 — Badge Color for User Prefixes
 * ==========================================================================
 *
 *  Maps an IRC user prefix character to a colored circle indicator.
 *  Returns nil for users with no prefix (regular users).
 */

static NSColor *
badge_color_for_prefix (char prefix)
{
	switch (prefix)
	{
	case '~': return [NSColor purpleColor];                                   /* owner   */
	case '&': return [NSColor redColor];                                      /* admin   */
	case '@': return [NSColor colorWithSRGBRed:0.2 green:0.8 blue:0.2 alpha:1.0]; /* op */
	case '%': return [NSColor colorWithSRGBRed:0.3 green:0.5 blue:1.0 alpha:1.0]; /* hop */
	case '+': return [NSColor colorWithSRGBRed:0.9 green:0.7 blue:0.0 alpha:1.0]; /* voice */
	default:  return nil;
	}
}

/*
 * Build an NSAttributedString for a user list entry.
 * If the user has a prefix (@ + % etc.), prepend a colored ● circle.
 */
static NSAttributedString *
make_user_list_entry (char prefix, const char *nick)
{
	@autoreleasepool
	{
		NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
		NSFont *font = [NSFont systemFontOfSize:12];

		NSColor *badgeColor = badge_color_for_prefix (prefix);
		if (badgeColor)
		{
			/* Colored circle ● followed by a space. */
			NSDictionary *badgeAttrs = @{
				NSForegroundColorAttributeName: badgeColor,
				NSFontAttributeName: font,
			};
			[result appendAttributedString:
				[[NSAttributedString alloc]
					initWithString:@"\xE2\x97\x8F " attributes:badgeAttrs]];
		}
		else
		{
			/* No prefix — add spacing to align with badged nicks. */
			NSDictionary *spaceAttrs = @{
				NSForegroundColorAttributeName: [NSColor clearColor],
				NSFontAttributeName: font,
			};
			[result appendAttributedString:
				[[NSAttributedString alloc]
					initWithString:@"\xE2\x97\x8F " attributes:spaceAttrs]];
		}

		/* The nick itself. */
		NSString *nsNick = [NSString stringWithUTF8String:nick];
		if (!nsNick) nsNick = @"???";
		NSDictionary *nickAttrs = @{
			NSForegroundColorAttributeName:
				[NSColor labelColor],
			NSFontAttributeName: font,
		};
		[result appendAttributedString:
			[[NSAttributedString alloc]
				initWithString:nsNick attributes:nickAttrs]];

		return result;
	}
}

/* Update the "7 ops, 531 total" label above the user list. */
static void
update_user_count_label (void)
{
	if (!userCountLabel || !current_sess)
		return;

	NSMutableArray *users = get_user_list_data (current_sess);
	NSInteger total = users ? (NSInteger)[users count] : 0;

	/* Count ops by walking the session's actual user tree. */
	NSInteger ops = 0;
	if (current_sess->usertree)
	{
		GList *list = userlist_double_list (current_sess);
		for (GList *iter = list; iter; iter = iter->next)
		{
			struct User *u = iter->data;
			if (u && u->op)
				ops++;
		}
		g_list_free (list);
	}

	NSString *text = [NSString stringWithFormat:@"%ld ops, %ld total",
		(long)ops, (long)total];
	[userCountLabel setStringValue:text];
}


/* ==========================================================================
 *  HCAppDelegate — Application lifecycle
 * ==========================================================================
 */

@interface HCAppDelegate : NSObject <NSApplicationDelegate>
@property (strong, nonatomic) NSTimer *glibTimer;
@end

@implementation HCAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
	[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
	[NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
	return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
	hexchat_exit();
	return NSTerminateNow;
}

- (void)pumpGLib:(NSTimer *)timer
{
	while (g_main_context_iteration (NULL, FALSE))
		;
	if (done)
		[NSApp terminate:nil];
}

@end


/* ==========================================================================
 *  HCInputDelegate — Handles Enter and Tab in the input field
 * ==========================================================================
 */

@interface HCInputDelegate : NSObject <NSTextFieldDelegate>
@end

@implementation HCInputDelegate

- (BOOL)control:(NSControl *)control
	   textView:(NSTextView *)textView
doCommandBySelector:(SEL)commandSelector
{
	/* --- Enter key: send message --- */
	if (commandSelector == @selector(insertNewline:))
	{
		NSTextField *field = (NSTextField *)control;
		const char *text = [[field stringValue] UTF8String];

		if (text && text[0] != '\0' && current_sess)
		{
			handle_multiline (current_sess, (char *)text, TRUE, FALSE);
			[field setStringValue:@""];
		}

		/* Reset tab-completion state on Enter. */
		completionMatches = nil;
		completionPrefix = nil;
		completionIndex = 0;

		return YES;
	}

	/*
	 * FEATURE 4 — Tab key: nick completion.
	 *
	 * COCOA LESSON: insertTab:
	 *
	 * When the user presses Tab in an NSTextField, Cocoa sends
	 * insertTab: which normally moves focus to the next field.
	 * We intercept it here to do IRC nick completion instead.
	 *
	 * Algorithm:
	 * 1. If we have existing matches, cycle to the next one
	 * 2. Otherwise, find the partial word before the cursor
	 * 3. Walk the channel's user list for matching nicks
	 * 4. Replace the partial word with the first match
	 * 5. If at start of line, append ": " (IRC convention)
	 */
	if (commandSelector == @selector(insertTab:))
	{
		if (!current_sess) return YES;

		NSTextField *field = (NSTextField *)control;
		NSString *fullText = [field stringValue];

		/* If we already have matches, cycle through them. */
		if (completionMatches && [completionMatches count] > 0)
		{
			completionIndex = (completionIndex + 1) % [completionMatches count];
			NSString *match = completionMatches[completionIndex];

			/* Build the replacement string. */
			NSString *suffix = (completionStart == 0) ? @": " : @" ";
			NSString *before = [fullText substringToIndex:completionStart];

			/* Find end of previous completion to replace it. */
			NSString *newText = [NSString stringWithFormat:@"%@%@%@",
				before, match, suffix];
			[field setStringValue:newText];
			return YES;
		}

		/* No existing matches — start a new completion. */
		NSInteger cursorPos = (NSInteger)[fullText length];

		/* Find the start of the word being completed. */
		NSInteger wordStart = cursorPos;
		while (wordStart > 0 &&
			[fullText characterAtIndex:wordStart - 1] != ' ')
		{
			wordStart--;
		}

		if (wordStart == cursorPos)
			return YES;  /* Nothing to complete. */

		NSString *partial = [fullText substringWithRange:
			NSMakeRange (wordStart, cursorPos - wordStart)];

		/* Walk the user list for matches. */
		NSMutableArray *matches = [[NSMutableArray alloc] init];
		GList *list = userlist_double_list (current_sess);
		for (GList *iter = list; iter; iter = iter->next)
		{
			struct User *u = iter->data;
			if (!u) continue;
			NSString *nick = [NSString stringWithUTF8String:u->nick];
			if ([nick length] >= [partial length] &&
				[[nick substringToIndex:[partial length]]
					caseInsensitiveCompare:partial] == NSOrderedSame)
			{
				[matches addObject:nick];
			}
		}
		g_list_free (list);

		if ([matches count] == 0)
			return YES;  /* No matches. */

		/* Save completion state for cycling. */
		completionMatches = matches;
		completionPrefix = partial;
		completionIndex = 0;
		completionStart = wordStart;

		/* Insert the first match. */
		NSString *match = matches[0];
		NSString *suffix = (wordStart == 0) ? @": " : @" ";
		NSString *before = [fullText substringToIndex:wordStart];
		NSString *newText = [NSString stringWithFormat:@"%@%@%@",
			before, match, suffix];
		[field setStringValue:newText];

		return YES;
	}

	/* Any other key resets completion state. */
	completionMatches = nil;
	completionPrefix = nil;
	completionIndex = 0;

	return NO;
}

/*
 * Reset tab completion when the user types anything new.
 */
- (void)controlTextDidChange:(NSNotification *)notification
{
	completionMatches = nil;
	completionPrefix = nil;
	completionIndex = 0;
}

@end


/* ==========================================================================
 *  HCChannelTreeDataSource — Data source + delegate for the left sidebar
 * ==========================================================================
 */

@interface HCChannelTreeDataSource : NSObject
	<NSOutlineViewDataSource, NSOutlineViewDelegate>
@end

@implementation HCChannelTreeDataSource

- (NSInteger)outlineView:(NSOutlineView *)outlineView
	numberOfChildrenOfItem:(id)item
{
	if (item == nil)
		return (NSInteger)[serverNodes count];
	if ([item isKindOfClass:[HCServerNode class]])
		return (NSInteger)[((HCServerNode *)item).children count];
	return 0;
}

- (id)outlineView:(NSOutlineView *)outlineView
	child:(NSInteger)index
	ofItem:(id)item
{
	if (item == nil)
		return serverNodes[index];
	if ([item isKindOfClass:[HCServerNode class]])
		return ((HCServerNode *)item).children[index];
	return nil;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView
	isItemExpandable:(id)item
{
	return [item isKindOfClass:[HCServerNode class]];
}

- (id)outlineView:(NSOutlineView *)outlineView
	objectValueForTableColumn:(NSTableColumn *)tableColumn
	byItem:(id)item
{
	if ([item isKindOfClass:[HCServerNode class]])
		return ((HCServerNode *)item).name;
	if ([item isKindOfClass:[HCSessionNode class]])
		return ((HCSessionNode *)item).name;
	return @"???";
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification
{
	NSInteger row = [channelTree selectedRow];
	if (row < 0) return;

	id item = [channelTree itemAtRow:row];

	if ([item isKindOfClass:[HCSessionNode class]])
	{
		struct session *sess = ((HCSessionNode *)item).session;
		if (sess) switch_to_session (sess);
	}
	else if ([item isKindOfClass:[HCServerNode class]])
	{
		struct server *serv = ((HCServerNode *)item).server;
		if (serv && serv->server_session)
			switch_to_session (serv->server_session);
	}
}

@end


/* ==========================================================================
 *  HCUserListDataSource — Feature 2: returns attributed strings with badges
 * ==========================================================================
 */

@interface HCUserListDataSource : NSObject
	<NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation HCUserListDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	NSMutableArray *users = get_user_list_data (current_sess);
	return users ? (NSInteger)[users count] : 0;
}

- (id)tableView:(NSTableView *)tableView
	objectValueForTableColumn:(NSTableColumn *)tableColumn
	row:(NSInteger)row
{
	NSMutableArray *users = get_user_list_data (current_sess);
	if (!users || row < 0 || row >= (NSInteger)[users count])
		return @"";

	/*
	 * Each entry is an NSAttributedString with a colored ● badge.
	 * Cell-based NSTableView renders attributed strings natively.
	 */
	return users[row];
}

@end


/* ==========================================================================
 *  FEATURE 5 — HCServerListDataSource (view-based for bold favorites)
 * ==========================================================================
 */

@interface HCServerListDataSource : NSObject
	<NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation HCServerListDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	return serverListNets ? (NSInteger)[serverListNets count] : 0;
}

- (NSView *)tableView:(NSTableView *)tableView
	viewForTableColumn:(NSTableColumn *)tableColumn
	row:(NSInteger)row
{
	NSTableCellView *cell =
		[tableView makeViewWithIdentifier:@"NetworkCell" owner:self];
	if (!cell)
	{
		cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
		NSTextField *tf = [NSTextField labelWithString:@""];
		[tf setIdentifier:@"label"];
		[tf setFrame:[cell bounds]];
		[tf setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
		[cell addSubview:tf];
		[cell setTextField:tf];
		[cell setIdentifier:@"NetworkCell"];
	}

	if (!serverListNets || row < 0 || row >= (NSInteger)[serverListNets count])
	{
		[[cell textField] setStringValue:@""];
		return cell;
	}

	ircnet *net = [serverListNets[row] pointerValue];
	NSString *name = (net && net->name)
		? [NSString stringWithUTF8String:net->name] : @"???";
	if (!name) name = @"???";

	/* Bold for favorites. */
	NSFont *font = (net && (net->flags & FLAG_FAVORITE))
		? [NSFont boldSystemFontOfSize:13]
		: [NSFont systemFontOfSize:13];
	NSDictionary *attrs = @{ NSFontAttributeName : font };
	[[cell textField] setAttributedStringValue:
		[[NSAttributedString alloc] initWithString:name attributes:attrs]];

	return cell;
}

@end


/* ==========================================================================
 *  FEATURE 6 — HCDCCDataSource
 * ==========================================================================
 */

@interface HCDCCDataSource : NSObject
	<NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation HCDCCDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	return dccTransfers ? (NSInteger)[dccTransfers count] : 0;
}

- (id)tableView:(NSTableView *)tableView
	objectValueForTableColumn:(NSTableColumn *)tableColumn
	row:(NSInteger)row
{
	if (!dccTransfers || row < 0 || row >= (NSInteger)[dccTransfers count])
		return @"";

	struct DCC *dcc = [dccTransfers[row] pointerValue];
	if (!dcc) return @"";

	NSString *ident = [tableColumn identifier];

	if ([ident isEqualToString:@"nick"])
		return dcc->nick ? [NSString stringWithUTF8String:dcc->nick] : @"";

	if ([ident isEqualToString:@"file"])
		return dcc->file ? [NSString stringWithUTF8String:dcc->file] : @"";

	if ([ident isEqualToString:@"size"])
	{
		if (dcc->size < 1024)
			return [NSString stringWithFormat:@"%llu B", dcc->size];
		else if (dcc->size < 1048576)
			return [NSString stringWithFormat:@"%.1f KB", dcc->size / 1024.0];
		else
			return [NSString stringWithFormat:@"%.1f MB", dcc->size / 1048576.0];
	}

	if ([ident isEqualToString:@"progress"])
	{
		if (dcc->size == 0) return @"0%";
		double pct = (double)dcc->pos / (double)dcc->size * 100.0;
		return [NSString stringWithFormat:@"%.1f%%", pct];
	}

	if ([ident isEqualToString:@"speed"])
	{
		if (dcc->cps < 1024)
			return [NSString stringWithFormat:@"%lld B/s", (long long)dcc->cps];
		else
			return [NSString stringWithFormat:@"%.1f KB/s", dcc->cps / 1024.0];
	}

	if ([ident isEqualToString:@"status"])
	{
		const char *names[] = {"Queued","Active","Failed","Done","Connecting","Aborted"};
		int idx = (int)dcc->dccstat;
		if (idx >= 0 && idx <= 5)
			return [NSString stringWithUTF8String:names[idx]];
		return @"?";
	}

	return @"";
}

@end


/* ==========================================================================
 *  WINDOW CREATION — Build the entire single-window UI
 * ==========================================================================
 */

static void
create_main_window (void)
{
	NSRect frame = NSMakeRect (100, 100, 1000, 650);
	NSUInteger style = NSWindowStyleMaskTitled
	                 | NSWindowStyleMaskClosable
	                 | NSWindowStyleMaskResizable
	                 | NSWindowStyleMaskMiniaturizable;

	mainWindow = [[NSWindow alloc]
		initWithContentRect:frame
		styleMask:style
		backing:NSBackingStoreBuffered
		defer:NO];
	[mainWindow setTitle:@"MacChat"];
	[mainWindow setMinSize:NSMakeSize(600, 400)];

	NSView *content = [mainWindow contentView];
	NSRect bounds = [content bounds];

	/*
	 * LAYOUT (Phase 3):
	 *
	 *   +------+------------------+-----------+
	 *   | tree | [topic bar     ] | N ops, M  |
	 *   |      |                  | total     |
	 *   |      | chat scroll view |-----------|
	 *   |      |                  | user list |
	 *   +------+------------------+-----------+
	 *   | [input field                       ] |
	 *   +--------------------------------------+
	 */

	/* --- Input field (bottom, 28px tall) --- */
	NSRect inputFrame = NSMakeRect (0, 0, bounds.size.width, 28);
	inputField = [[NSTextField alloc] initWithFrame:inputFrame];
	[inputField setPlaceholderString:@"Type a message or /command..."];
	[inputField setFont:[NSFont monospacedSystemFontOfSize:12
		weight:NSFontWeightRegular]];
	[inputField setAutoresizingMask:NSViewWidthSizable];
	[inputField setDelegate:(id<NSTextFieldDelegate>)inputDelegate];
	[content addSubview:inputField];

	/* --- Split view (fills everything above input) --- */
	NSRect splitFrame = NSMakeRect (0, 28, bounds.size.width,
		bounds.size.height - 28);
	splitView = [[NSSplitView alloc] initWithFrame:splitFrame];
	[splitView setVertical:YES];
	[splitView setDividerStyle:NSSplitViewDividerStyleThin];
	[splitView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

	/* --- LEFT PANE: Channel tree --- */
	NSRect treeFrame = NSMakeRect (0, 0, 180, splitFrame.size.height);
	channelTreeScroll = [[NSScrollView alloc] initWithFrame:treeFrame];
	[channelTreeScroll setHasVerticalScroller:YES];
	[channelTreeScroll setHasHorizontalScroller:NO];
	[channelTreeScroll setAutoresizingMask:
		(NSViewWidthSizable | NSViewHeightSizable)];

	channelTree = [[NSOutlineView alloc] initWithFrame:
		[[channelTreeScroll contentView] bounds]];
	NSTableColumn *treeCol = [[NSTableColumn alloc]
		initWithIdentifier:@"channels"];
	[treeCol setWidth:170];
	[treeCol setTitle:@"Channels"];
	[channelTree addTableColumn:treeCol];
	[channelTree setOutlineTableColumn:treeCol];
	[channelTree setHeaderView:nil];
	[channelTree setDataSource:(id<NSOutlineViewDataSource>)treeDataSource];
	[channelTree setDelegate:(id<NSOutlineViewDelegate>)treeDataSource];
	[channelTreeScroll setDocumentView:channelTree];

	/*
	 * --- CENTER PANE: Topic bar + Chat text view ---
	 *
	 * FEATURE 3: We wrap the topic bar and chat scroll view
	 * in an NSView so they appear as one pane in the split view.
	 */
	NSRect centerFrame = NSMakeRect (0, 0, 580, splitFrame.size.height);
	centerWrapper = [[NSView alloc] initWithFrame:centerFrame];
	[centerWrapper setAutoresizingMask:
		(NSViewWidthSizable | NSViewHeightSizable)];

	/* Topic bar (24px tall, at the top of the center pane). */
	NSRect topicFrame = NSMakeRect (0, centerFrame.size.height - 24,
		centerFrame.size.width, 24);
	topicBar = [NSTextField labelWithString:@""];
	[topicBar setFrame:topicFrame];
	[topicBar setFont:[NSFont systemFontOfSize:11]];
	[topicBar setTextColor:[NSColor secondaryLabelColor]];
	[topicBar setBackgroundColor:[NSColor colorWithWhite:0.15 alpha:1.0]];
	[topicBar setDrawsBackground:YES];
	[topicBar setLineBreakMode:NSLineBreakByTruncatingTail];
	[topicBar setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
	[centerWrapper addSubview:topicBar];

	/* Find bar (28px tall, below topic bar, initially hidden). */
	NSRect findFrame = NSMakeRect (0, centerFrame.size.height - 24 - 28,
		centerFrame.size.width, 28);
	findBar = [[NSView alloc] initWithFrame:findFrame];
	[findBar setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
	[findBar setHidden:YES];
	findBarVisible = NO;
	lastFindRange = NSMakeRange (0, 0);

	NSTextField *findLabel = [NSTextField labelWithString:@"Find:"];
	[findLabel setFrame:NSMakeRect (4, 4, 36, 20)];
	[findLabel setFont:[NSFont systemFontOfSize:11]];
	[findLabel setTextColor:[NSColor secondaryLabelColor]];
	[findBar addSubview:findLabel];

	findField = [[NSTextField alloc]
		initWithFrame:NSMakeRect (42, 4, findFrame.size.width - 50, 20)];
	[findField setFont:[NSFont systemFontOfSize:12]];
	[findField setAutoresizingMask:NSViewWidthSizable];
	[findField setPlaceholderString:@"Search text\xE2\x80\xA6"];
	[findBar addSubview:findField];

	[centerWrapper addSubview:findBar];

	/* Chat scroll view (fills below topic bar). */
	NSRect chatFrame = NSMakeRect (0, 0, centerFrame.size.width,
		centerFrame.size.height - 24);
	chatScrollView = [[NSScrollView alloc] initWithFrame:chatFrame];
	[chatScrollView setHasVerticalScroller:YES];
	[chatScrollView setHasHorizontalScroller:NO];
	[chatScrollView setAutoresizingMask:
		(NSViewWidthSizable | NSViewHeightSizable)];

	chatTextView = [[NSTextView alloc] initWithFrame:
		[[chatScrollView contentView] bounds]];
	[chatTextView setEditable:NO];
	[chatTextView setSelectable:YES];
	[chatTextView setRichText:YES];
	[chatTextView setFont:[NSFont monospacedSystemFontOfSize:12
		weight:NSFontWeightRegular]];
	[chatTextView setBackgroundColor:
		[NSColor colorWithWhite:0.1 alpha:1.0]];
	[chatTextView setTextColor:
		[NSColor colorWithWhite:0.9 alpha:1.0]];
	[chatTextView setMaxSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
	[chatTextView setMinSize:NSMakeSize(0, chatFrame.size.height)];
	[chatTextView setAutoresizingMask:NSViewWidthSizable];
	[[chatTextView textContainer] setWidthTracksTextView:YES];
	[chatScrollView setDocumentView:chatTextView];

	[centerWrapper addSubview:chatScrollView];

	/*
	 * --- RIGHT PANE: User count label + User list ---
	 *
	 * FEATURE 2: Wrapper holds the count label at top and
	 * the user list scroll view below it.
	 */
	NSRect rightFrame = NSMakeRect (0, 0, 150, splitFrame.size.height);
	rightWrapper = [[NSView alloc] initWithFrame:rightFrame];
	[rightWrapper setAutoresizingMask:
		(NSViewWidthSizable | NSViewHeightSizable)];

	/* User count label (20px tall, at top). */
	NSRect countFrame = NSMakeRect (0, rightFrame.size.height - 20,
		rightFrame.size.width, 20);
	userCountLabel = [NSTextField labelWithString:@"0 ops, 0 total"];
	[userCountLabel setFrame:countFrame];
	[userCountLabel setFont:[NSFont systemFontOfSize:10]];
	[userCountLabel setTextColor:[NSColor secondaryLabelColor]];
	[userCountLabel setAlignment:NSTextAlignmentCenter];
	[userCountLabel setAutoresizingMask:
		(NSViewWidthSizable | NSViewMinYMargin)];
	[rightWrapper addSubview:userCountLabel];

	/* User list scroll view (below the count label). */
	NSRect userFrame = NSMakeRect (0, 0, rightFrame.size.width,
		rightFrame.size.height - 20);
	userListScroll = [[NSScrollView alloc] initWithFrame:userFrame];
	[userListScroll setHasVerticalScroller:YES];
	[userListScroll setHasHorizontalScroller:NO];
	[userListScroll setAutoresizingMask:
		(NSViewWidthSizable | NSViewHeightSizable)];

	userListTable = [[NSTableView alloc] initWithFrame:
		[[userListScroll contentView] bounds]];
	NSTableColumn *userCol = [[NSTableColumn alloc]
		initWithIdentifier:@"nicks"];
	[userCol setWidth:140];
	[userCol setTitle:@"Users"];
	[userListTable addTableColumn:userCol];
	[userListTable setHeaderView:nil];
	[userListTable setDataSource:
		(id<NSTableViewDataSource>)userListDataSource];
	[userListTable setDelegate:
		(id<NSTableViewDelegate>)userListDataSource];
	[userListScroll setDocumentView:userListTable];

	[rightWrapper addSubview:userListScroll];

	/* --- Assemble the split view --- */
	[splitView addSubview:channelTreeScroll];
	[splitView addSubview:centerWrapper];
	[splitView addSubview:rightWrapper];

	[content addSubview:splitView];

	[splitView adjustSubviews];
	[splitView setPosition:180 ofDividerAtIndex:0];
	[splitView setPosition:(bounds.size.width - 160) ofDividerAtIndex:1];

	/* Don't show the main window yet — the Network List is shown first.
	   The main window becomes visible once the user connects to a server
	   (via fe_ctrl_gui FE_GUI_SHOW / FE_GUI_FOCUS). */
	[mainWindow orderOut:nil];
	[mainWindow makeFirstResponder:inputField];
}


/* ==========================================================================
 *  MENU BAR — Full native macOS menu bar
 * ==========================================================================
 */

static void show_stub_alert (NSString *feature)
{
	NSAlert *alert = [[NSAlert alloc] init];
	[alert setMessageText:[NSString stringWithFormat:@"%@ is not yet implemented.",
		feature]];
	[alert setInformativeText:@"This feature will be added in a future update."];
	[alert addButtonWithTitle:@"OK"];
	[alert runModal];
}

/* Menu action targets — we need a class to receive selectors. */
@interface HCMenuTarget : NSObject

/* File menu */
- (void)openServerList:(id)sender;
- (void)menuNewServerTab:(id)sender;
- (void)menuNewChannelTab:(id)sender;
- (void)menuNewServerWindow:(id)sender;
- (void)menuNewChannelWindow:(id)sender;
- (void)menuLoadPlugin:(id)sender;
- (void)menuCloseTab:(id)sender;

/* Edit menu */
- (void)menuCopySelection:(id)sender;
- (void)menuFind:(id)sender;
- (void)menuFindNext:(id)sender;
- (void)menuFindPrev:(id)sender;
- (void)menuClearText:(id)sender;

/* View menu */
- (void)menuToggleTopicBar:(id)sender;
- (void)menuToggleUserList:(id)sender;
- (void)menuFullscreen:(id)sender;

/* Server menu */
- (void)menuDisconnect:(id)sender;
- (void)menuReconnect:(id)sender;
- (void)menuJoinChannel:(id)sender;
- (void)menuChannelList:(id)sender;
- (void)menuAway:(id)sender;

/* Settings menu */
- (void)menuStub:(id)sender;
- (void)menuPreferences:(id)sender;

/* Window menu */
- (void)openDCCPanel:(id)sender;
- (void)menuResetMarker:(id)sender;
- (void)menuMoveToMarker:(id)sender;
- (void)menuSaveText:(id)sender;

/* Help menu */
- (void)menuAbout:(id)sender;
- (void)menuDocs:(id)sender;

@end

@implementation HCMenuTarget

/* --- File menu --- */

- (void)openServerList:(id)sender { show_server_list (); }

- (void)menuNewServerTab:(id)sender
{
	new_ircwindow (current_sess->server, NULL, SESS_SERVER, 0);
}

- (void)menuNewChannelTab:(id)sender
{
	new_ircwindow (current_sess->server, NULL, SESS_CHANNEL, 0);
}

- (void)menuNewServerWindow:(id)sender
{
	new_ircwindow (NULL, NULL, SESS_SERVER, 0);
}

- (void)menuNewChannelWindow:(id)sender
{
	new_ircwindow (current_sess->server, NULL, SESS_CHANNEL, 0);
}

- (void)menuLoadPlugin:(id)sender
{
	show_stub_alert (@"Load Plugin or Script");
}

- (void)menuCloseTab:(id)sender
{
	handle_command (current_sess, "CLOSE", FALSE);
}

/* --- Edit menu --- */

- (void)menuCopySelection:(id)sender
{
	[chatTextView copy:nil];
}

- (void)menuFind:(id)sender
{
	if (!findBar || !centerWrapper)
		return;

	findBarVisible = !findBarVisible;
	[findBar setHidden:!findBarVisible];

	/* Recalculate chat scroll frame. */
	CGFloat topicH = [topicBar isHidden] ? 0 : 24;
	CGFloat findH = findBarVisible ? 28 : 0;
	CGFloat wrapH = [centerWrapper frame].size.height;
	CGFloat wrapW = [centerWrapper frame].size.width;

	[chatScrollView setFrame:NSMakeRect (0, 0, wrapW,
		wrapH - topicH - findH)];
	[findBar setFrame:NSMakeRect (0, wrapH - topicH - findH,
		wrapW, 28)];

	if (findBarVisible)
		[[findField window] makeFirstResponder:findField];
}

- (void)menuFindNext:(id)sender
{
	if (!findField || !chatTextView)
		return;
	NSString *needle = [findField stringValue];
	if ([needle length] == 0)
	{
		/* If no search term yet, open the find bar. */
		if (!findBarVisible)
			[self menuFind:sender];
		return;
	}

	NSString *haystack = [[chatTextView textStorage] string];
	NSUInteger start = lastFindRange.location + lastFindRange.length;
	if (start >= [haystack length])
		start = 0;
	NSRange searchRange = NSMakeRange (start,
		[haystack length] - start);
	NSRange found = [haystack rangeOfString:needle
		options:NSCaseInsensitiveSearch range:searchRange];
	if (found.location == NSNotFound && start > 0)
	{
		/* Wrap around. */
		found = [haystack rangeOfString:needle
			options:NSCaseInsensitiveSearch
			range:NSMakeRange (0, [haystack length])];
	}
	if (found.location != NSNotFound)
	{
		lastFindRange = found;
		[chatTextView setSelectedRange:found];
		[chatTextView scrollRangeToVisible:found];
	}
	else
	{
		NSBeep ();
	}
}

- (void)menuFindPrev:(id)sender
{
	if (!findField || !chatTextView)
		return;
	NSString *needle = [findField stringValue];
	if ([needle length] == 0)
		return;

	NSString *haystack = [[chatTextView textStorage] string];
	NSUInteger end = lastFindRange.location;
	if (end == 0)
		end = [haystack length];
	NSRange searchRange = NSMakeRange (0, end);
	NSRange found = [haystack rangeOfString:needle
		options:(NSCaseInsensitiveSearch | NSBackwardsSearch)
		range:searchRange];
	if (found.location == NSNotFound)
	{
		/* Wrap around. */
		found = [haystack rangeOfString:needle
			options:(NSCaseInsensitiveSearch | NSBackwardsSearch)
			range:NSMakeRange (0, [haystack length])];
	}
	if (found.location != NSNotFound)
	{
		lastFindRange = found;
		[chatTextView setSelectedRange:found];
		[chatTextView scrollRangeToVisible:found];
	}
	else
	{
		NSBeep ();
	}
}

- (void)menuClearText:(id)sender
{
	fe_text_clear (current_sess, 0);
}

/* --- View menu --- */

- (void)menuToggleTopicBar:(id)sender
{
	BOOL nowHidden = ![topicBar isHidden];
	[topicBar setHidden:nowHidden];

	/* Update checkmark. */
	[topicBarMenuItem setState:nowHidden ? NSControlStateValueOff
		: NSControlStateValueOn];

	/* Resize chat to fill. */
	CGFloat topicH = nowHidden ? 0 : 24;
	CGFloat findH = findBarVisible ? 28 : 0;
	CGFloat wrapH = [centerWrapper frame].size.height;
	CGFloat wrapW = [centerWrapper frame].size.width;
	[chatScrollView setFrame:NSMakeRect (0, 0, wrapW,
		wrapH - topicH - findH)];
}

- (void)menuToggleUserList:(id)sender
{
	BOOL nowHidden = ![userListScroll isHidden];
	[userListScroll setHidden:nowHidden];
	[userCountLabel setHidden:nowHidden];
	[rightWrapper setHidden:nowHidden];

	/* Update checkmark. */
	[userListMenuItem setState:nowHidden ? NSControlStateValueOff
		: NSControlStateValueOn];
}

- (void)menuFullscreen:(id)sender
{
	[mainWindow toggleFullScreen:nil];
}

/* --- Server menu --- */

- (void)menuDisconnect:(id)sender
{
	if (!current_sess || !current_sess->server)
		return;
	handle_command (current_sess, "DISCON", FALSE);
}

- (void)menuReconnect:(id)sender
{
	if (!current_sess || !current_sess->server)
		return;
	handle_command (current_sess, "RECONNECT", FALSE);
}

- (void)menuJoinChannel:(id)sender
{
	NSAlert *alert = [[NSAlert alloc] init];
	[alert setMessageText:@"Join a Channel"];
	[alert setInformativeText:@"Enter channel name:"];
	[alert addButtonWithTitle:@"Join"];
	[alert addButtonWithTitle:@"Cancel"];

	NSTextField *chanField = [[NSTextField alloc]
		initWithFrame:NSMakeRect (0, 0, 220, 24)];
	[chanField setStringValue:@"#"];
	[alert setAccessoryView:chanField];

	/* Make text field first responder. */
	[[alert window] setInitialFirstResponder:chanField];

	if ([alert runModal] == NSAlertFirstButtonReturn)
	{
		NSString *chan = [chanField stringValue];
		if ([chan length] > 0)
		{
			char cmd[512];
			snprintf (cmd, sizeof (cmd), "join %s",
				[chan UTF8String]);
			handle_command (current_sess, cmd, FALSE);
		}
	}
}

- (void)menuChannelList:(id)sender
{
	show_stub_alert (@"Channel List");
}

- (void)menuAway:(id)sender
{
	if (!current_sess || !current_sess->server)
		return;
	if (current_sess->server->is_away)
		handle_command (current_sess, "back", FALSE);
	else
		handle_command (current_sess, "away", FALSE);
}

/* --- Settings menu (all stubs) --- */

- (void)menuStub:(id)sender
{
	NSMenuItem *mi = (NSMenuItem *)sender;
	show_stub_alert ([mi title]);
}

/* --- Window menu --- */

- (void)openDCCPanel:(id)sender { show_dcc_panel (); }

- (void)menuResetMarker:(id)sender
{
	if (!current_sess || !current_sess->gui)
		return;
	NSTextStorage *storage = get_text_storage (current_sess);
	if (storage)
		current_sess->gui->marker_pos =
			(unsigned long)[[storage string] length];
}

- (void)menuMoveToMarker:(id)sender
{
	if (!current_sess || !current_sess->gui)
		return;
	NSUInteger pos = (NSUInteger)current_sess->gui->marker_pos;
	NSTextStorage *storage = get_text_storage (current_sess);
	if (!storage)
		return;
	if (pos > [[storage string] length])
		pos = [[storage string] length];
	[chatTextView scrollRangeToVisible:NSMakeRange (pos, 0)];
}

- (void)menuSaveText:(id)sender
{
	show_stub_alert (@"Save Text");
}

/* --- Help menu --- */

- (void)menuAbout:(id)sender
{
	NSAlert *alert = [[NSAlert alloc] init];
	[alert setMessageText:@"MacChat " PACKAGE_VERSION];
	[alert setInformativeText:
		@"An IRC client for macOS.\n\n"
		"Copyright \xC2\xA9 2026 Sean Madawala.\n"
		"Based on HexChat by the HexChat team.\n\n"
		"https://github.com/seanmadawala/hexchat\n"
		""];
	[alert setAlertStyle:NSAlertStyleInformational];
	[alert addButtonWithTitle:@"OK"];
	[alert runModal];
}

- (void)menuDocs:(id)sender
{
	fe_open_url ("https://hexchat.readthedocs.org");
}

@end

static id menuTarget;

/* Helper: create a menu item targeting menuTarget. */
static NSMenuItem *
menu_item (NSString *title, SEL action, NSString *key)
{
	NSMenuItem *item = [[NSMenuItem alloc]
		initWithTitle:title action:action keyEquivalent:key];
	[item setTarget:menuTarget];
	return item;
}

/* Helper: create a menu item with modifier mask. */
static NSMenuItem *
menu_item_mod (NSString *title, SEL action, NSString *key,
	NSEventModifierFlags mask)
{
	NSMenuItem *item = menu_item (title, action, key);
	[item setKeyEquivalentModifierMask:mask];
	return item;
}

static void
create_menu_bar (void)
{
	menuTarget = [[HCMenuTarget alloc] init];

	NSMenu *menuBar = [[NSMenu alloc] init];

	/* =================================================================
	 *  APP MENU (HexChat)
	 * ================================================================= */
	NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
	[menuBar addItem:appMenuItem];
	NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"MacChat"];

	[appMenu addItem:menu_item (@"About MacChat",
		@selector(menuAbout:), @"")];
	[appMenu addItem:[NSMenuItem separatorItem]];

	[appMenu addItem:menu_item (@"Preferences\xE2\x80\xA6",
		@selector(menuPreferences:), @",")];
	[appMenu addItem:[NSMenuItem separatorItem]];

	/* Services submenu. */
	NSMenu *servicesMenu = [[NSMenu alloc] initWithTitle:@"Services"];
	NSMenuItem *servicesItem = [[NSMenuItem alloc]
		initWithTitle:@"Services" action:nil keyEquivalent:@""];
	[servicesItem setSubmenu:servicesMenu];
	[appMenu addItem:servicesItem];
	[NSApp setServicesMenu:servicesMenu];

	[appMenu addItem:[NSMenuItem separatorItem]];

	[appMenu addItemWithTitle:@"Hide MacChat"
		action:@selector(hide:) keyEquivalent:@"h"];

	NSMenuItem *hideOthers = [appMenu addItemWithTitle:@"Hide Others"
		action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
	[hideOthers setKeyEquivalentModifierMask:
		(NSEventModifierFlagCommand | NSEventModifierFlagOption)];

	[appMenu addItemWithTitle:@"Show All"
		action:@selector(unhideAllApplications:) keyEquivalent:@""];

	[appMenu addItem:[NSMenuItem separatorItem]];

	[appMenu addItemWithTitle:@"Quit MacChat"
		action:@selector(terminate:) keyEquivalent:@"q"];

	[appMenuItem setSubmenu:appMenu];

	/* =================================================================
	 *  FILE MENU
	 * ================================================================= */
	NSMenuItem *fileMenuItem = [[NSMenuItem alloc] init];
	[menuBar addItem:fileMenuItem];
	NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];

	[fileMenu addItem:menu_item (@"Network List\xE2\x80\xA6",
		@selector(openServerList:), @"s")];
	[fileMenu addItem:[NSMenuItem separatorItem]];

	/* New submenu. */
	NSMenu *newSub = [[NSMenu alloc] initWithTitle:@"New"];
	[newSub addItem:menu_item (@"Server Tab",
		@selector(menuNewServerTab:), @"t")];
	[newSub addItem:menu_item (@"Channel Tab",
		@selector(menuNewChannelTab:), @"")];
	[newSub addItem:menu_item (@"Server Window",
		@selector(menuNewServerWindow:), @"n")];
	[newSub addItem:menu_item (@"Channel Window",
		@selector(menuNewChannelWindow:), @"")];

	NSMenuItem *newSubItem = [[NSMenuItem alloc]
		initWithTitle:@"New" action:nil keyEquivalent:@""];
	[newSubItem setSubmenu:newSub];
	[fileMenu addItem:newSubItem];

	[fileMenu addItem:[NSMenuItem separatorItem]];
	[fileMenu addItem:menu_item (@"Load Plugin or Script\xE2\x80\xA6",
		@selector(menuLoadPlugin:), @"")];
	[fileMenu addItem:[NSMenuItem separatorItem]];
	[fileMenu addItem:menu_item (@"Close Tab",
		@selector(menuCloseTab:), @"w")];

	[fileMenuItem setSubmenu:fileMenu];

	/* =================================================================
	 *  EDIT MENU
	 * ================================================================= */
	NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
	[menuBar addItem:editMenuItem];
	NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];

	[editMenu addItem:menu_item_mod (@"Copy Selection",
		@selector(menuCopySelection:), @"C",
		(NSEventModifierFlagCommand | NSEventModifierFlagShift))];
	[editMenu addItem:[NSMenuItem separatorItem]];
	[editMenu addItem:menu_item (@"Find\xE2\x80\xA6",
		@selector(menuFind:), @"f")];
	[editMenu addItem:menu_item (@"Find Next",
		@selector(menuFindNext:), @"g")];
	[editMenu addItem:menu_item_mod (@"Find Previous",
		@selector(menuFindPrev:), @"G",
		(NSEventModifierFlagCommand | NSEventModifierFlagShift))];
	[editMenu addItem:[NSMenuItem separatorItem]];
	[editMenu addItem:menu_item (@"Clear Text",
		@selector(menuClearText:), @"")];

	[editMenuItem setSubmenu:editMenu];

	/* =================================================================
	 *  VIEW MENU
	 * ================================================================= */
	NSMenuItem *viewMenuItem = [[NSMenuItem alloc] init];
	[menuBar addItem:viewMenuItem];
	NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];

	topicBarMenuItem = menu_item (@"Topic Bar",
		@selector(menuToggleTopicBar:), @"");
	[topicBarMenuItem setState:NSControlStateValueOn];
	[viewMenu addItem:topicBarMenuItem];

	userListMenuItem = menu_item (@"User List",
		@selector(menuToggleUserList:), @"");
	[userListMenuItem setState:NSControlStateValueOn];
	[viewMenu addItem:userListMenuItem];

	[viewMenu addItem:[NSMenuItem separatorItem]];

	[viewMenu addItem:menu_item_mod (@"Fullscreen",
		@selector(menuFullscreen:), @"f",
		(NSEventModifierFlagCommand | NSEventModifierFlagControl))];

	[viewMenuItem setSubmenu:viewMenu];

	/* =================================================================
	 *  SERVER MENU
	 * ================================================================= */
	NSMenuItem *serverMenuItem = [[NSMenuItem alloc] init];
	[menuBar addItem:serverMenuItem];
	NSMenu *serverMenu = [[NSMenu alloc] initWithTitle:@"Server"];

	[serverMenu addItem:menu_item (@"Disconnect",
		@selector(menuDisconnect:), @"")];
	[serverMenu addItem:menu_item (@"Reconnect",
		@selector(menuReconnect:), @"")];
	[serverMenu addItem:[NSMenuItem separatorItem]];
	[serverMenu addItem:menu_item (@"Join a Channel\xE2\x80\xA6",
		@selector(menuJoinChannel:), @"")];
	[serverMenu addItem:menu_item (@"Channel List\xE2\x80\xA6",
		@selector(menuChannelList:), @"")];
	[serverMenu addItem:[NSMenuItem separatorItem]];

	awayMenuItem = menu_item (@"Marked Away",
		@selector(menuAway:), @"");
	[serverMenu addItem:awayMenuItem];

	[serverMenuItem setSubmenu:serverMenu];

	/* =================================================================
	 *  SETTINGS MENU
	 * ================================================================= */
	NSMenuItem *settingsMenuItem = [[NSMenuItem alloc] init];
	[menuBar addItem:settingsMenuItem];
	NSMenu *settingsMenu = [[NSMenu alloc] initWithTitle:@"Settings"];

	NSString *settingsItems[] = {
		@"Auto Replace", @"CTCP Replies", @"Dialog Buttons",
		@"Keyboard Shortcuts", @"Text Events", @"URL Handlers",
		@"User Commands", @"User List Buttons", @"User List Popup",
		nil
	};
	for (int i = 0; settingsItems[i]; i++)
		[settingsMenu addItem:menu_item (settingsItems[i],
			@selector(menuStub:), @"")];

	[settingsMenuItem setSubmenu:settingsMenu];

	/* =================================================================
	 *  WINDOW MENU
	 * ================================================================= */
	NSMenuItem *windowMenuItem = [[NSMenuItem alloc] init];
	[menuBar addItem:windowMenuItem];
	NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];

	[windowMenu addItemWithTitle:@"Minimize"
		action:@selector(miniaturize:) keyEquivalent:@"m"];
	[windowMenu addItemWithTitle:@"Zoom"
		action:@selector(performZoom:) keyEquivalent:@""];

	[windowMenu addItem:[NSMenuItem separatorItem]];

	NSString *windowStubs[] = {
		@"Ban List", @"Character Chart", @"Direct Chat",
		nil
	};
	for (int i = 0; windowStubs[i]; i++)
		[windowMenu addItem:menu_item (windowStubs[i],
			@selector(menuStub:), @"")];

	[windowMenu addItem:menu_item (@"File Transfers",
		@selector(openDCCPanel:), @"")];

	NSString *windowStubs2[] = {
		@"Friends List", @"Ignore List",
		@"Plugins and Scripts", @"Raw Log", @"URL Grabber",
		nil
	};
	for (int i = 0; windowStubs2[i]; i++)
		[windowMenu addItem:menu_item (windowStubs2[i],
			@selector(menuStub:), @"")];

	[windowMenu addItem:[NSMenuItem separatorItem]];
	[windowMenu addItem:menu_item (@"Reset Marker Line",
		@selector(menuResetMarker:), @"")];
	[windowMenu addItem:menu_item (@"Move to Marker Line",
		@selector(menuMoveToMarker:), @"")];
	[windowMenu addItem:[NSMenuItem separatorItem]];
	[windowMenu addItem:menu_item (@"Save Text\xE2\x80\xA6",
		@selector(menuSaveText:), @"")];

	[windowMenuItem setSubmenu:windowMenu];
	[NSApp setWindowsMenu:windowMenu];

	/* =================================================================
	 *  HELP MENU
	 * ================================================================= */
	NSMenuItem *helpMenuItem = [[NSMenuItem alloc] init];
	[menuBar addItem:helpMenuItem];
	NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];

	[helpMenu addItem:menu_item (@"MacChat Documentation",
		@selector(menuDocs:), @"")];

	[helpMenuItem setSubmenu:helpMenu];
	[NSApp setHelpMenu:helpMenu];

	/* --- Set the menu bar --- */
	[NSApp setMainMenu:menuBar];
}


/* ==========================================================================
 *  SESSION SWITCHING
 * ==========================================================================
 */

static void
switch_to_session (struct session *sess)
{
	if (!sess || !sess->gui || sess == current_sess)
		return;

	@autoreleasepool
	{
		/* Save current session's input text. */
		if (current_sess && current_sess->gui)
		{
			const char *curText = [[inputField stringValue] UTF8String];
			g_free (current_sess->gui->input_text);
			current_sess->gui->input_text = g_strdup (curText ? curText : "");
		}

		/* Update HexChat's session pointers. */
		current_sess = sess;
		current_tab = sess;
		if (sess->server)
			sess->server->front_session = sess;

		/* Swap the text storage. */
		NSTextStorage *storage = get_text_storage (sess);
		if (storage && chatTextView)
		{
			[[chatTextView layoutManager] replaceTextStorage:storage];
			NSRange endRange = NSMakeRange ([[storage string] length], 0);
			[chatTextView scrollRangeToVisible:endRange];
		}

		/* Reload the user list. */
		[userListTable reloadData];

		/* Update window title. */
		NSString *title = sess->channel[0]
			? [NSString stringWithUTF8String:sess->channel]
			: @"MacChat";
		[mainWindow setTitle:title];

		/* Feature 3: Update topic bar. */
		if (sess->topic && sess->topic[0])
			[topicBar setStringValue:
				[NSString stringWithUTF8String:sess->topic]];
		else
			[topicBar setStringValue:@""];

		/* Feature 2: Update user count. */
		update_user_count_label ();

		/* Restore input text. */
		if (sess->gui->input_text)
			[inputField setStringValue:
				[NSString stringWithUTF8String:sess->gui->input_text]];
		else
			[inputField setStringValue:@""];

		/* Reset tab completion on session switch. */
		completionMatches = nil;
		completionPrefix = nil;
		completionIndex = 0;
	}
}


/* ==========================================================================
 *  CHANNEL TREE REFRESH
 * ==========================================================================
 */

static void
refresh_channel_tree (void)
{
	@autoreleasepool
	{
		[serverNodes removeAllObjects];

		GSList *slist;
		for (slist = sess_list; slist; slist = slist->next)
		{
			struct session *sess = slist->data;
			if (!sess || !sess->server)
				continue;

			HCServerNode *srvNode = nil;
			for (HCServerNode *existing in serverNodes)
			{
				if (existing.server == sess->server)
				{
					srvNode = existing;
					break;
				}
			}
			if (!srvNode)
			{
				srvNode = [[HCServerNode alloc]
					initWithServer:sess->server];
				[serverNodes addObject:srvNode];
			}

			HCSessionNode *sessNode = [[HCSessionNode alloc]
				initWithSession:sess];
			[srvNode.children addObject:sessNode];
		}

		[channelTree reloadData];
		[channelTree expandItem:nil expandChildren:YES];

		if (current_sess)
		{
			for (NSInteger i = 0; i < [channelTree numberOfRows]; i++)
			{
				id item = [channelTree itemAtRow:i];
				if ([item isKindOfClass:[HCSessionNode class]] &&
					((HCSessionNode *)item).session == current_sess)
				{
					[channelTree selectRowIndexes:
						[NSIndexSet indexSetWithIndex:i]
						byExtendingSelection:NO];
					break;
				}
			}
		}
	}
}


/* ==========================================================================
 *  USER LIST REBUILD — Now creates attributed strings with badges
 * ==========================================================================
 */

static void
rebuild_user_list_data (struct session *sess)
{
	if (!sess || !sess->gui)
		return;

	NSMutableArray *users = get_user_list_data (sess);
	if (!users)
		return;

	@autoreleasepool
	{
		[users removeAllObjects];

		tree *ut = sess->usertree;
		if (ut)
		{
			GList *list = userlist_double_list (sess);
			for (GList *iter = list; iter; iter = iter->next)
			{
				struct User *user = iter->data;
				if (user)
				{
					NSAttributedString *entry =
						make_user_list_entry (user->prefix[0], user->nick);
					if (entry)
						[users addObject:entry];
				}
			}
			g_list_free (list);
		}
	}
}


/* ==========================================================================
 *  FEATURE 5 — Server List Dialog
 * ==========================================================================
 */

/* Helper: rebuild serverListNets from network_list, respecting favorites. */
static void
populate_server_list_nets (void)
{
	[serverListNets removeAllObjects];
	GSList *sl;
	int i = 0;
	for (sl = network_list; sl; sl = sl->next, i++)
	{
		ircnet *net = sl->data;
		if (!net) continue;
		if (prefs.hex_gui_slist_fav && !(net->flags & FLAG_FAVORITE))
			continue;
		[serverListNets addObject:[NSValue valueWithPointer:net]];
	}
}

/* Helper: save nick/user fields from the server list dialog to prefs. */
static int
servlist_save_fields (void)
{
	if (!slNickField1) return 0;

	const char *user = [[slUserField stringValue] UTF8String];
	if (!user || user[0] == 0)
		return 1;   /* blank username not allowed */

	const char *n1 = [[slNickField1 stringValue] UTF8String];
	const char *n2 = [[slNickField2 stringValue] UTF8String];
	const char *n3 = [[slNickField3 stringValue] UTF8String];

	if (n1) safe_strcpy (prefs.hex_irc_nick1, n1, sizeof (prefs.hex_irc_nick1));
	if (n2) safe_strcpy (prefs.hex_irc_nick2, n2, sizeof (prefs.hex_irc_nick2));
	if (n3) safe_strcpy (prefs.hex_irc_nick3, n3, sizeof (prefs.hex_irc_nick3));
	if (user)
	{
		safe_strcpy (prefs.hex_irc_user_name, user,
			sizeof (prefs.hex_irc_user_name));
		/* Strip spaces — they break IRC login. */
		char *sp = strchr (prefs.hex_irc_user_name, ' ');
		if (sp) *sp = 0;
	}

	servlist_save ();
	save_config ();
	return 0;
}

/* Helper: compare function for sorting networks. */
static gint
cocoa_servlist_compare (ircnet *a, ircnet *b)
{
	gchar *af = g_utf8_casefold (a->name, -1);
	gchar *bf = g_utf8_casefold (b->name, -1);
	int r = g_utf8_collate (af, bf);
	g_free (af);
	g_free (bf);
	return r;
}

static void
show_server_list (void)
{
	@autoreleasepool
	{
		if (serverListWindow)
		{
			[serverListWindow makeKeyAndOrderFront:nil];
			return;
		}

		/* Build the network array. */
		serverListNets = [[NSMutableArray alloc] init];
		populate_server_list_nets ();

		/* --- Window --- */
		NSRect frame = NSMakeRect (0, 0, 410, 530);
		serverListWindow = [[NSWindow alloc]
			initWithContentRect:frame
			styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
				| NSWindowStyleMaskResizable)
			backing:NSBackingStoreBuffered
			defer:NO];
		[serverListWindow center];
		[serverListWindow setTitle:@"Network List - MacChat"];
		[serverListWindow setMinSize:NSMakeSize (380, 420)];

		NSView *content = [serverListWindow contentView];
		CGFloat W = [content bounds].size.width;
		CGFloat y = [content bounds].size.height;   /* build top-down */

		/* ============================================================
		 *  User Information section
		 * ============================================================ */
		y -= 24;
		NSTextField *userInfoLabel = [NSTextField labelWithString:
			@"User Information"];
		[userInfoLabel setFont:[NSFont boldSystemFontOfSize:12]];
		[userInfoLabel setFrame:NSMakeRect (14, y, 200, 18)];
		[userInfoLabel setAutoresizingMask:NSViewMinYMargin];
		[content addSubview:userInfoLabel];

		/* Nick / user name fields — 4 rows. */
		NSArray *labels = @[ @"Nick name:", @"Second choice:",
							 @"Third choice:", @"User name:" ];
		const char *vals[] = {
			prefs.hex_irc_nick1, prefs.hex_irc_nick2,
			prefs.hex_irc_nick3, prefs.hex_irc_user_name
		};
		NSTextField *fields[4];

		for (int i = 0; i < 4; i++)
		{
			y -= 28;
			NSTextField *lbl = [NSTextField labelWithString:labels[i]];
			[lbl setFrame:NSMakeRect (20, y + 2, 110, 18)];
			[lbl setAlignment:NSTextAlignmentRight];
			[lbl setFont:[NSFont systemFontOfSize:12]];
			[lbl setAutoresizingMask:NSViewMinYMargin];
			[content addSubview:lbl];

			NSTextField *tf = [[NSTextField alloc]
				initWithFrame:NSMakeRect (136, y, W - 156, 22)];
			NSString *v = vals[i]
				? [NSString stringWithUTF8String:vals[i]] : @"";
			[tf setStringValue:v ?: @""];
			[tf setFont:[NSFont systemFontOfSize:12]];
			[tf setAutoresizingMask:
				(NSViewWidthSizable | NSViewMinYMargin)];
			[content addSubview:tf];
			fields[i] = tf;
		}

		slNickField1 = fields[0];
		slNickField2 = fields[1];
		slNickField3 = fields[2];
		slUserField  = fields[3];

		/* ============================================================
		 *  Networks section
		 * ============================================================ */
		y -= 30;
		NSTextField *netsLabel = [NSTextField labelWithString:@"Networks"];
		[netsLabel setFont:[NSFont boldSystemFontOfSize:12]];
		[netsLabel setFrame:NSMakeRect (14, y, 200, 18)];
		[netsLabel setAutoresizingMask:NSViewMinYMargin];
		[content addSubview:netsLabel];

		/* Network table and buttons layout. */
		CGFloat btnW = 80, btnH = 28, btnX = W - btnW - 14;
		CGFloat tableTop = y - 6;
		CGFloat tableH = 5 * (btnH + 4) + 20;  /* tall enough for buttons */
		CGFloat tableBot = tableTop - tableH;

		/* Buttons on the right, anchored to the bottom of the table area. */
		NSArray *btnTitles = @[ @"Add", @"Remove", @"Edit\xE2\x80\xA6",
								@"Sort", @"Favor" ];
		SEL btnActions[] = {
			@selector(slAdd:), @selector(slRemove:),
			@selector(slEdit:), @selector(slSort:),
			@selector(slFavor:)
		};
		for (int i = 0; i < 5; i++)
		{
			/* Stack upward from the bottom: Favor at bottom, Add at top. */
			NSButton *btn = [[NSButton alloc]
				initWithFrame:NSMakeRect (btnX,
					tableBot + (4 - i) * (btnH + 4),
					btnW, btnH)];
			[btn setTitle:btnTitles[i]];
			[btn setBezelStyle:NSBezelStyleRounded];
			[btn setTarget:menuTarget];
			[btn setAction:btnActions[i]];
			[btn setAutoresizingMask:
				(NSViewMinXMargin | NSViewMinYMargin)];
			[content addSubview:btn];
		}

		/* Network table (left of buttons). */
		CGFloat tableW = btnX - 24;
		NSScrollView *scroll = [[NSScrollView alloc]
			initWithFrame:NSMakeRect (14, tableTop - tableH, tableW, tableH)];
		[scroll setHasVerticalScroller:YES];
		[scroll setBorderType:NSBezelBorder];
		[scroll setAutoresizingMask:
			(NSViewWidthSizable | NSViewHeightSizable)];

		serverListTable = [[NSTableView alloc]
			initWithFrame:[[scroll contentView] bounds]];
		NSTableColumn *col = [[NSTableColumn alloc]
			initWithIdentifier:@"network"];
		[col setWidth:tableW - 20];
		[serverListTable addTableColumn:col];
		[serverListTable setHeaderView:nil];
		[serverListTable setRowHeight:20];

		serverListDataSource = [[HCServerListDataSource alloc] init];
		[serverListTable setDataSource:
			(id<NSTableViewDataSource>)serverListDataSource];
		[serverListTable setDelegate:
			(id<NSTableViewDelegate>)serverListDataSource];
		[serverListTable setDoubleAction:@selector(connectFromServerList:)];
		[serverListTable setTarget:menuTarget];

		[scroll setDocumentView:serverListTable];
		[content addSubview:scroll];

		y = tableTop - tableH;

		/* ============================================================
		 *  Checkboxes
		 * ============================================================ */
		y -= 6;
		NSButton *skipChk = [NSButton checkboxWithTitle:
			@"Skip network list on startup"
			target:menuTarget action:@selector(slSkipToggled:)];
		[skipChk setFrame:NSMakeRect (14, y - 20, 220, 18)];
		[skipChk setState:prefs.hex_gui_slist_skip
			? NSControlStateValueOn : NSControlStateValueOff];
		[skipChk setAutoresizingMask:NSViewMaxXMargin];
		[content addSubview:skipChk];

		NSButton *favChk = [NSButton checkboxWithTitle:
			@"Show favorites only"
			target:menuTarget action:@selector(slFavToggled:)];
		[favChk setFrame:NSMakeRect (242, y - 20, 160, 18)];
		[favChk setState:prefs.hex_gui_slist_fav
			? NSControlStateValueOn : NSControlStateValueOff];
		[favChk setAutoresizingMask:NSViewMaxXMargin];
		[content addSubview:favChk];

		y -= 26;

		/* ============================================================
		 *  Close / Connect buttons (bottom)
		 * ============================================================ */
		NSButton *closeBtn = [[NSButton alloc]
			initWithFrame:NSMakeRect (14, 10, 80, 32)];
		[closeBtn setTitle:@"Close"];
		[closeBtn setBezelStyle:NSBezelStyleRounded];
		[closeBtn setTarget:menuTarget];
		[closeBtn setAction:@selector(slClose:)];
		[closeBtn setAutoresizingMask:
			(NSViewMaxXMargin | NSViewMaxYMargin)];
		[content addSubview:closeBtn];

		NSButton *connectBtn = [[NSButton alloc]
			initWithFrame:NSMakeRect (W - 94, 10, 80, 32)];
		[connectBtn setTitle:@"Connect"];
		[connectBtn setBezelStyle:NSBezelStyleRounded];
		[connectBtn setTarget:menuTarget];
		[connectBtn setAction:@selector(connectFromServerList:)];
		[connectBtn setAutoresizingMask:
			(NSViewMinXMargin | NSViewMaxYMargin)];
		[connectBtn setKeyEquivalent:@"\r"];  /* default button */
		[content addSubview:connectBtn];

		/* Restore previous selection. */
		if (prefs.hex_gui_slist_select >= 0 &&
			prefs.hex_gui_slist_select < (int)[serverListNets count])
		{
			NSIndexSet *idx = [NSIndexSet
				indexSetWithIndex:prefs.hex_gui_slist_select];
			[serverListTable selectRowIndexes:idx byExtendingSelection:NO];
			[serverListTable scrollRowToVisible:prefs.hex_gui_slist_select];
		}

		[serverListWindow makeKeyAndOrderFront:nil];
	}
}

/* Server list button actions. */
@implementation HCMenuTarget (ServerList)

- (void)connectFromServerList:(id)sender
{
	NSInteger row = [serverListTable selectedRow];
	if (row < 0 || !serverListNets ||
		row >= (NSInteger)[serverListNets count])
		return;

	ircnet *net = [serverListNets[row] pointerValue];
	if (!net) return;

	/* Save nick/user fields to prefs before connecting. */
	if (servlist_save_fields () == 1)
	{
		NSAlert *a = [[NSAlert alloc] init];
		[a setMessageText:@"User name cannot be left blank."];
		[a runModal];
		return;
	}

	/* Remember selection. */
	prefs.hex_gui_slist_select = (int)row;

	/* Close the dialog. */
	[serverListWindow orderOut:nil];
	serverListWindow = nil;
	slNickField1 = slNickField2 = slNickField3 = slUserField = nil;

	/*
	 * Match GTK frontend logic:
	 * - Look for an existing session already on this network
	 * - If that session's server is already connected, pass NULL
	 *   so servlist_connect() creates a new window
	 * - Otherwise reuse an idle/unconnected session
	 */
	struct session *chosen = current_sess;
	struct session *use_sess = NULL;

	GSList *list;
	for (list = sess_list; list; list = list->next)
	{
		struct session *s = list->data;
		if (s->server->network == net)
		{
			use_sess = s;
			if (s->server->connected)
				use_sess = NULL;
			break;
		}
	}

	if (!use_sess && chosen &&
		!chosen->server->connected &&
		chosen->server->server_session->channel[0] == 0)
	{
		use_sess = chosen;
	}

	servlist_connect (use_sess, net, TRUE);

	/* Show the main window now that we're connecting. */
	[mainWindow makeKeyAndOrderFront:nil];
}

- (void)slClose:(id)sender
{
	servlist_save_fields ();

	/* Remember selection. */
	NSInteger row = [serverListTable selectedRow];
	if (row >= 0)
		prefs.hex_gui_slist_select = (int)row;

	[serverListWindow orderOut:nil];
	serverListWindow = nil;
	slNickField1 = slNickField2 = slNickField3 = slUserField = nil;

	/* If no server is connected (fresh launch, user closed dialog),
	   quit the application just like the GTK frontend. */
	{
		int any_connected = 0;
		GSList *sl;
		for (sl = sess_list; sl; sl = sl->next)
		{
			struct session *s = sl->data;
			if (s->server && (s->server->connected ||
				s->server->connecting))
			{
				any_connected = 1;
				break;
			}
		}
		if (!any_connected)
			[NSApp terminate:nil];
	}
}

- (void)slAdd:(id)sender
{
	ircnet *net = servlist_net_add ("New Network", "", TRUE);
	if (!net) return;
	net->encoding = g_strdup ("UTF-8 (Unicode)");
	servlist_server_add (net, "newserver/6667");

	populate_server_list_nets ();
	[serverListTable reloadData];

	/* Select the new network (it was prepended). */
	if ([serverListNets count] > 0)
	{
		[serverListTable selectRowIndexes:
			[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
		[serverListTable scrollRowToVisible:0];
	}
}

- (void)slRemove:(id)sender
{
	NSInteger row = [serverListTable selectedRow];
	if (row < 0 || !serverListNets ||
		row >= (NSInteger)[serverListNets count])
		return;

	ircnet *net = [serverListNets[row] pointerValue];
	if (!net) return;

	NSString *name = net->name
		? [NSString stringWithUTF8String:net->name] : @"network";
	NSAlert *alert = [[NSAlert alloc] init];
	[alert setMessageText:
		[NSString stringWithFormat:@"Remove network \"%@\"?", name]];
	[alert addButtonWithTitle:@"Remove"];
	[alert addButtonWithTitle:@"Cancel"];
	if ([alert runModal] != NSAlertFirstButtonReturn)
		return;

	servlist_net_remove (net);
	populate_server_list_nets ();
	[serverListTable reloadData];

	/* Select something nearby. */
	NSInteger newCount = (NSInteger)[serverListNets count];
	if (newCount > 0)
	{
		NSInteger sel = (row < newCount) ? row : newCount - 1;
		[serverListTable selectRowIndexes:
			[NSIndexSet indexSetWithIndex:sel] byExtendingSelection:NO];
	}
}

- (void)slEdit:(id)sender
{
	NSInteger row = [serverListTable selectedRow];
	if (row < 0 || !serverListNets ||
		row >= (NSInteger)[serverListNets count])
		return;

	ircnet *net = [serverListNets[row] pointerValue];
	if (!net) return;

	show_edit_network (net);
}

- (void)slSort:(id)sender
{
	network_list = g_slist_sort (network_list,
		(GCompareFunc)cocoa_servlist_compare);
	populate_server_list_nets ();
	[serverListTable reloadData];
}

- (void)slFavor:(id)sender
{
	NSInteger row = [serverListTable selectedRow];
	if (row < 0 || !serverListNets ||
		row >= (NSInteger)[serverListNets count])
		return;

	ircnet *net = [serverListNets[row] pointerValue];
	if (!net) return;

	net->flags ^= FLAG_FAVORITE;   /* toggle */

	/* If "Show favorites only" is on and we just unfavorited,
	   the row will vanish — repopulate. */
	if (prefs.hex_gui_slist_fav)
	{
		populate_server_list_nets ();
		[serverListTable reloadData];
	}
	else
	{
		/* Just refresh the single row for bold toggle. */
		[serverListTable reloadDataForRowIndexes:
			[NSIndexSet indexSetWithIndex:row]
			columnIndexes:[NSIndexSet indexSetWithIndex:0]];
	}
}

- (void)slSkipToggled:(id)sender
{
	prefs.hex_gui_slist_skip =
		([sender state] == NSControlStateValueOn) ? 1 : 0;
}

- (void)slFavToggled:(id)sender
{
	prefs.hex_gui_slist_fav =
		([sender state] == NSControlStateValueOn) ? 1 : 0;
	populate_server_list_nets ();
	[serverListTable reloadData];
}

@end


/* ==========================================================================
 *  FEATURE 5b — Edit Network Dialog
 * ==========================================================================
 */

/* Forward declarations. */
static void show_edit_network (ircnet *net);
static void edit_toggle_global_fields (void);

/* ---------- helper: get popup index for a logintype conf value ---------- */
static int
login_conf_to_popup_index (int conf_value)
{
	for (int i = 0; i < cocoa_login_types_count; i++)
		if (cocoa_login_types_conf[i] == conf_value)
			return i;
	return 0;
}

/* ---------- Servers data source ---------- */
@interface HCEditServerDS : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@end
@implementation HCEditServerDS
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv
{
	return editNet ? (NSInteger)g_slist_length (editNet->servlist) : 0;
}
- (id)tableView:(NSTableView *)tv
	objectValueForTableColumn:(NSTableColumn *)col
	row:(NSInteger)row
{
	if (!editNet) return @"";
	ircserver *s = g_slist_nth_data (editNet->servlist, (guint)row);
	if (!s || !s->hostname) return @"";
	NSString *r = [NSString stringWithUTF8String:s->hostname];
	return r ?: @"";
}
- (void)tableView:(NSTableView *)tv
	setObjectValue:(id)obj
	forTableColumn:(NSTableColumn *)col
	row:(NSInteger)row
{
	if (!editNet) return;
	ircserver *s = g_slist_nth_data (editNet->servlist, (guint)row);
	if (!s) return;
	const char *newval = [obj UTF8String];
	if (!newval || newval[0] == 0)
	{
		/* Empty string = delete the server, but keep at least one. */
		if (g_slist_length (editNet->servlist) > 1)
		{
			servlist_server_remove (editNet, s);
			[tv reloadData];
		}
		return;
	}
	g_free (s->hostname);
	/* Convert "host:port" to "host/port". */
	char *dup = g_strdup (newval);
	char *colon = strchr (dup, ':');
	if (colon && strchr (colon + 1, ':') == NULL)  /* single colon only */
		*colon = '/';
	s->hostname = dup;
}
@end

/* ---------- Channels data source ---------- */
@interface HCEditChanDS : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@end
@implementation HCEditChanDS
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv
{
	return editNet ? (NSInteger)g_slist_length (editNet->favchanlist) : 0;
}
- (id)tableView:(NSTableView *)tv
	objectValueForTableColumn:(NSTableColumn *)col
	row:(NSInteger)row
{
	if (!editNet) return @"";
	favchannel *fc = g_slist_nth_data (editNet->favchanlist, (guint)row);
	if (!fc) return @"";
	if ([[col identifier] isEqualToString:@"key"])
	{
		if (!fc->key) return @"";
		NSString *r = [NSString stringWithUTF8String:fc->key];
		return r ?: @"";
	}
	if (!fc->name) return @"";
	NSString *r = [NSString stringWithUTF8String:fc->name];
	return r ?: @"";
}
- (void)tableView:(NSTableView *)tv
	setObjectValue:(id)obj
	forTableColumn:(NSTableColumn *)col
	row:(NSInteger)row
{
	if (!editNet) return;
	favchannel *fc = g_slist_nth_data (editNet->favchanlist, (guint)row);
	if (!fc) return;
	const char *newval = [obj UTF8String];
	if ([[col identifier] isEqualToString:@"key"])
	{
		g_free (fc->key);
		fc->key = (newval && newval[0]) ? g_strdup (newval) : NULL;
		return;
	}
	/* Channel name column. */
	if (!newval || newval[0] == 0)
	{
		servlist_favchan_remove (editNet, fc);
		[tv reloadData];
		return;
	}
	g_free (fc->name);
	fc->name = g_strdup (newval);
}
@end

/* ---------- Commands data source ---------- */
@interface HCEditCmdDS : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@end
@implementation HCEditCmdDS
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv
{
	return editNet ? (NSInteger)g_slist_length (editNet->commandlist) : 0;
}
- (id)tableView:(NSTableView *)tv
	objectValueForTableColumn:(NSTableColumn *)col
	row:(NSInteger)row
{
	if (!editNet) return @"";
	commandentry *e = g_slist_nth_data (editNet->commandlist, (guint)row);
	if (!e || !e->command) return @"";
	NSString *r = [NSString stringWithUTF8String:e->command];
	return r ?: @"";
}
- (void)tableView:(NSTableView *)tv
	setObjectValue:(id)obj
	forTableColumn:(NSTableColumn *)col
	row:(NSInteger)row
{
	if (!editNet) return;
	commandentry *e = g_slist_nth_data (editNet->commandlist, (guint)row);
	if (!e) return;
	const char *newval = [obj UTF8String];
	if (!newval || newval[0] == 0)
	{
		servlist_command_remove (editNet, e);
		[tv reloadData];
		return;
	}
	g_free (e->command);
	/* Strip leading slash. */
	if (newval[0] == '/') newval++;
	e->command = g_strdup (newval);
}
@end

/* ----------- Keep strong references to data sources alive ----------- */
static id editServerDS;
static id editChanDS;
static id editCmdDS;

/* -------------------------------------------------------------------- */
static void
show_edit_network (ircnet *net)
{
	@autoreleasepool
	{
		if (!net) return;

		/* If already open, bring to front. */
		if (editNetWindow)
		{
			[editNetWindow makeKeyAndOrderFront:nil];
			return;
		}

		editNet = net;

		/* --- Window --- */
		NSString *title = [NSString stringWithFormat:@"Edit %s - MacChat",
			net->name ? net->name : "network"];
		NSRect frame = NSMakeRect (250, 120, 480, 620);
		editNetWindow = [[NSWindow alloc]
			initWithContentRect:frame
			styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
				| NSWindowStyleMaskResizable)
			backing:NSBackingStoreBuffered
			defer:NO];
		[editNetWindow setTitle:title];
		[editNetWindow setMinSize:NSMakeSize (440, 520)];

		NSView *content = [editNetWindow contentView];
		CGFloat W = [content bounds].size.width;
		CGFloat y = [content bounds].size.height;

		/* ==============================================================
		 *  Tab View (Servers / Autojoin channels / Connect commands)
		 * ============================================================== */
		CGFloat tabH = 180;
		y -= (tabH + 10);
		editTabView = [[NSTabView alloc]
			initWithFrame:NSMakeRect (10, y, W - 20, tabH)];
		[editTabView setAutoresizingMask:
			(NSViewWidthSizable | NSViewMinYMargin)];

		/* --- Helper block to create a tab with table + Add/Remove --- */
		NSTableView *(^makeTab)(NSString *, NSString *, NSArray *,
			id, SEL, SEL) =
		^NSTableView *(NSString *label, NSString *ident,
			NSArray *colDefs, id ds, SEL addSel, SEL rmSel)
		{
			NSTabViewItem *item = [[NSTabViewItem alloc]
				initWithIdentifier:ident];
			[item setLabel:label];
			NSView *v = [[NSView alloc]
				initWithFrame:NSMakeRect (0, 0, W - 34, tabH - 30)];

			CGFloat vW = [v bounds].size.width;
			CGFloat vH = [v bounds].size.height;

			/* Buttons on right, anchored near bottom. */
			CGFloat bW = 70, bH = 26, bX = vW - bW - 4;
			NSButton *rmBtn = [[NSButton alloc]
				initWithFrame:NSMakeRect (bX, 4, bW, bH)];
			[rmBtn setTitle:@"Remove"];
			[rmBtn setBezelStyle:NSBezelStyleRounded];
			[rmBtn setTarget:menuTarget];
			[rmBtn setAction:rmSel];
			[rmBtn setAutoresizingMask:NSViewMinXMargin];
			[v addSubview:rmBtn];

			NSButton *addBtn = [[NSButton alloc]
				initWithFrame:NSMakeRect (bX, 4 + bH + 4, bW, bH)];
			[addBtn setTitle:@"Add"];
			[addBtn setBezelStyle:NSBezelStyleRounded];
			[addBtn setTarget:menuTarget];
			[addBtn setAction:addSel];
			[addBtn setAutoresizingMask:NSViewMinXMargin];
			[v addSubview:addBtn];

			/* Table. */
			NSScrollView *sc = [[NSScrollView alloc]
				initWithFrame:NSMakeRect (0, 0, bX - 6, vH)];
			[sc setHasVerticalScroller:YES];
			[sc setBorderType:NSBezelBorder];
			[sc setAutoresizingMask:
				(NSViewWidthSizable | NSViewHeightSizable)];

			NSTableView *tv = [[NSTableView alloc]
				initWithFrame:[[sc contentView] bounds]];
			for (NSDictionary *cd in colDefs)
			{
				NSTableColumn *tc = [[NSTableColumn alloc]
					initWithIdentifier:cd[@"id"]];
				[tc setTitle:cd[@"title"]];
				[tc setEditable:YES];
				[tc setWidth:[cd[@"w"] floatValue]];
				[tv addTableColumn:tc];
			}
			[tv setHeaderView:([colDefs count] > 1) ? [tv headerView] : nil];
			[tv setRowHeight:18];
			[tv setDataSource:(id<NSTableViewDataSource>)ds];
			[tv setDelegate:(id<NSTableViewDelegate>)ds];

			[sc setDocumentView:tv];
			[v addSubview:sc];

			[item setView:v];
			[editTabView addTabViewItem:item];
			return tv;
		};

		/* Create data sources. */
		editServerDS = [[HCEditServerDS alloc] init];
		editChanDS   = [[HCEditChanDS alloc] init];
		editCmdDS    = [[HCEditCmdDS alloc] init];

		/* Servers tab. */
		editServerTable = makeTab (@"Servers", @"servers",
			@[ @{ @"id": @"server", @"title": @"Server",
				  @"w": @(300) } ],
			editServerDS,
			@selector(editAddServer:), @selector(editRemoveServer:));

		/* Autojoin channels tab. */
		editChanTable = makeTab (@"Autojoin channels", @"channels",
			@[ @{ @"id": @"chan", @"title": @"Channel", @"w": @(180) },
			   @{ @"id": @"key",  @"title": @"Key (Password)",
				  @"w": @(100) } ],
			editChanDS,
			@selector(editAddChannel:), @selector(editRemoveChannel:));

		/* Connect commands tab. */
		editCmdTable = makeTab (@"Connect commands", @"commands",
			@[ @{ @"id": @"cmd", @"title": @"Command",
				  @"w": @(300) } ],
			editCmdDS,
			@selector(editAddCommand:), @selector(editRemoveCommand:));

		[content addSubview:editTabView];

		/* ==============================================================
		 *  Checkboxes
		 * ============================================================== */
		struct {
			const char *label;
			int flag;
			int reversed;  /* 1 = checked means flag is OFF */
		} chks[] = {
			{ "Connect to selected server only",             1,  1 },
			{ "Connect to this network automatically",       8,  0 },
			{ "Bypass proxy server",                         16, 1 },
			{ "Use SSL for all the servers on this network", 4,  0 },
			{ "Accept invalid SSL certificates",             32, 0 },
			{ "Use global user information",                 2,  0 },
		};

		y -= 10;
		for (int i = 0; i < 6; i++)
		{
			y -= 22;
			NSString *lbl = [NSString stringWithUTF8String:chks[i].label];
			NSButton *chk = [NSButton checkboxWithTitle:lbl
				target:menuTarget action:@selector(editCheckboxToggled:)];
			[chk setFrame:NSMakeRect (14, y, W - 28, 18)];
			[chk setTag:(chks[i].flag | (chks[i].reversed ? 0x10000 : 0))];
			[chk setAutoresizingMask:NSViewMaxXMargin];

			/* Compute initial state. */
			BOOL on;
			if (chks[i].reversed)
				on = !(net->flags & chks[i].flag);
			else
				on = !!(net->flags & chks[i].flag);
			[chk setState:on ? NSControlStateValueOn : NSControlStateValueOff];

			[content addSubview:chk];

			if (chks[i].flag == 2)  /* FLAG_USE_GLOBAL */
				editChkGlobal = chk;
		}

		/* ==============================================================
		 *  Text fields: nick, nick2, real, user, login, pass, charset
		 * ============================================================== */
		/*
		 * When "Use global user information" is ON, show the global
		 * prefs values (linked to the Network List fields).
		 * When OFF, show per-network overrides.
		 */
		BOOL useGlobal = !!(net->flags & FLAG_USE_GLOBAL);
		struct {
			const char *label;
			const char *value;
			int secure;     /* 1 = password field */
		} fields[] = {
			{ "Nick name:",     useGlobal ? prefs.hex_irc_nick1     : net->nick,  0 },
			{ "Second choice:", useGlobal ? prefs.hex_irc_nick2     : net->nick2, 0 },
			{ "Third choice:",  useGlobal ? prefs.hex_irc_nick3     : NULL,       0 },
			{ "User name:",     useGlobal ? prefs.hex_irc_user_name : net->user,  0 },
		};

		y -= 8;
		NSTextField *textFields[4];
		for (int i = 0; i < 4; i++)
		{
			y -= 26;
			NSTextField *lbl = [NSTextField labelWithString:
				[NSString stringWithUTF8String:fields[i].label]];
			[lbl setFrame:NSMakeRect (14, y + 2, 110, 18)];
			[lbl setAlignment:NSTextAlignmentRight];
			[lbl setFont:[NSFont systemFontOfSize:12]];
			[lbl setAutoresizingMask:NSViewMinYMargin];
			[content addSubview:lbl];

			NSTextField *tf = [[NSTextField alloc]
				initWithFrame:NSMakeRect (130, y, W - 150, 22)];
			NSString *val = fields[i].value
				? [NSString stringWithUTF8String:fields[i].value] : @"";
			[tf setStringValue:val ?: @""];
			[tf setFont:[NSFont systemFontOfSize:12]];
			[tf setAutoresizingMask:
				(NSViewWidthSizable | NSViewMinYMargin)];
			[content addSubview:tf];
			textFields[i] = tf;
		}
		editNickField  = textFields[0];
		editNick2Field = textFields[1];
		editNick3Field = textFields[2];
		editUserField  = textFields[3];
		editFieldsToToggle[0] = editNickField;
		editFieldsToToggle[1] = editNick2Field;
		editFieldsToToggle[2] = editNick3Field;
		editFieldsToToggle[3] = editUserField;

		/* Login method popup. */
		y -= 26;
		{
			NSTextField *lbl = [NSTextField labelWithString:@"Login method:"];
			[lbl setFrame:NSMakeRect (14, y + 2, 110, 18)];
			[lbl setAlignment:NSTextAlignmentRight];
			[lbl setFont:[NSFont systemFontOfSize:12]];
			[lbl setAutoresizingMask:NSViewMinYMargin];
			[content addSubview:lbl];

			editLoginPopup = [[NSPopUpButton alloc]
				initWithFrame:NSMakeRect (130, y - 2, W - 150, 26)
				pullsDown:NO];
			NSArray *loginNames = @[
				@"Default",
				@"SASL PLAIN (username + password)",
				@"SASL EXTERNAL (cert)",
				@"SASL SCRAM-SHA-1",
				@"SASL SCRAM-SHA-256",
				@"SASL SCRAM-SHA-512",
				@"Server password (/PASS password)",
				@"NickServ (/MSG NickServ + password)",
				@"NickServ (/NICKSERV + password)",
				@"Challenge Auth (username + password)",
				@"Custom... (connect commands)",
			];
			for (NSString *n in loginNames)
				[editLoginPopup addItemWithTitle:n];
			[editLoginPopup selectItemAtIndex:
				login_conf_to_popup_index (net->logintype)];
			[editLoginPopup setFont:[NSFont systemFontOfSize:12]];
			[editLoginPopup setAutoresizingMask:
				(NSViewWidthSizable | NSViewMinYMargin)];
			[content addSubview:editLoginPopup];
		}

		/* Password. */
		y -= 26;
		{
			NSTextField *lbl = [NSTextField labelWithString:@"Password:"];
			[lbl setFrame:NSMakeRect (14, y + 2, 110, 18)];
			[lbl setAlignment:NSTextAlignmentRight];
			[lbl setFont:[NSFont systemFontOfSize:12]];
			[lbl setAutoresizingMask:NSViewMinYMargin];
			[content addSubview:lbl];

			editPassField = [[NSSecureTextField alloc]
				initWithFrame:NSMakeRect (130, y, W - 150, 22)];
			NSString *pw = net->pass
				? [NSString stringWithUTF8String:net->pass] : @"";
			[editPassField setStringValue:pw ?: @""];
			[editPassField setFont:[NSFont systemFontOfSize:12]];
			[editPassField setAutoresizingMask:
				(NSViewWidthSizable | NSViewMinYMargin)];
			[content addSubview:editPassField];
		}

		/* Character set combo. */
		y -= 28;
		{
			NSTextField *lbl = [NSTextField labelWithString:@"Character set:"];
			[lbl setFrame:NSMakeRect (14, y + 2, 110, 18)];
			[lbl setAlignment:NSTextAlignmentRight];
			[lbl setFont:[NSFont systemFontOfSize:12]];
			[lbl setAutoresizingMask:NSViewMinYMargin];
			[content addSubview:lbl];

			editCharsetCombo = [[NSComboBox alloc]
				initWithFrame:NSMakeRect (130, y, W - 150, 24)];
			for (int i = 0; cocoa_charsets[i]; i++)
				[editCharsetCombo addItemWithObjectValue:
					[NSString stringWithUTF8String:cocoa_charsets[i]]];
			NSString *enc = (net->encoding && net->encoding[0])
				? [NSString stringWithUTF8String:net->encoding]
				: @"UTF-8 (Unicode)";
			[editCharsetCombo setStringValue:enc ?: @"UTF-8 (Unicode)"];
			[editCharsetCombo setEditable:YES];
			[editCharsetCombo setFont:[NSFont systemFontOfSize:12]];
			[editCharsetCombo setAutoresizingMask:
				(NSViewWidthSizable | NSViewMinYMargin)];
			[content addSubview:editCharsetCombo];
		}

		/* ==============================================================
		 *  Close button
		 * ============================================================== */
		NSButton *closeBtn = [[NSButton alloc]
			initWithFrame:NSMakeRect (W - 94, 10, 80, 32)];
		[closeBtn setTitle:@"Close"];
		[closeBtn setBezelStyle:NSBezelStyleRounded];
		[closeBtn setTarget:menuTarget];
		[closeBtn setAction:@selector(editClose:)];
		[closeBtn setKeyEquivalent:@"\r"];
		[closeBtn setAutoresizingMask:
			(NSViewMinXMargin | NSViewMaxYMargin)];
		[content addSubview:closeBtn];

		/* Apply "Use global" state to fields. */
		edit_toggle_global_fields ();

		[editNetWindow makeKeyAndOrderFront:nil];
	}
}

/* ---------- Toggle nick/user field enabled state ---------- */
static void
edit_toggle_global_fields (void)
{
	if (!editChkGlobal || !editNet) return;
	BOOL global = ([editChkGlobal state] == NSControlStateValueOn);

	/*
	 * Swap displayed values: when global is ON, show prefs values
	 * (linked to Network List); when OFF, show per-network values.
	 * Also read the Network List text fields if they're open, since
	 * the user may have edited them without saving yet.
	 */
	if (global)
	{
		/* Read from NL fields if open, otherwise from prefs. */
		NSString *n1 = slNickField1
			? [slNickField1 stringValue]
			: [NSString stringWithUTF8String:prefs.hex_irc_nick1];
		NSString *n2 = slNickField2
			? [slNickField2 stringValue]
			: [NSString stringWithUTF8String:prefs.hex_irc_nick2];
		NSString *n3 = slNickField3
			? [slNickField3 stringValue]
			: [NSString stringWithUTF8String:prefs.hex_irc_nick3];
		NSString *u  = slUserField
			? [slUserField stringValue]
			: [NSString stringWithUTF8String:prefs.hex_irc_user_name];
		[editNickField  setStringValue:n1 ?: @""];
		[editNick2Field setStringValue:n2 ?: @""];
		[editNick3Field setStringValue:n3 ?: @""];
		[editUserField  setStringValue:u  ?: @""];
	}
	else
	{
		/* Show per-network values. */
		NSString *n = editNet->nick
			? [NSString stringWithUTF8String:editNet->nick] : @"";
		NSString *n2 = editNet->nick2
			? [NSString stringWithUTF8String:editNet->nick2] : @"";
		NSString *u = editNet->user
			? [NSString stringWithUTF8String:editNet->user] : @"";
		[editNickField  setStringValue:n  ?: @""];
		[editNick2Field setStringValue:n2 ?: @""];
		[editNick3Field setStringValue:@""];  /* no per-network 3rd nick */
		[editUserField  setStringValue:u  ?: @""];
	}

	/* The "Third choice" field only makes sense in global mode. */
	[editNick3Field setEditable:global];
	[editNick3Field setEnabled:global];

	/* The other fields are only editable in per-network mode. */
	[editNickField  setEditable:!global];
	[editNickField  setEnabled:!global || YES];  /* visible but read-only when global */
	[editNick2Field setEditable:!global];
	[editUserField  setEditable:!global];

	/* Actually: when global is ON, make all 4 fields editable so the
	   user can change the global values from here too. */
	/* All fields always enabled, just reflect the right source. */
	[editNickField  setEditable:YES];
	[editNickField  setEnabled:YES];
	[editNick2Field setEditable:YES];
	[editNick2Field setEnabled:YES];
	[editNick3Field setEditable:global];
	[editNick3Field setEnabled:global];
	[editUserField  setEditable:YES];
	[editUserField  setEnabled:YES];
}

/* ---------- Save fields back to ircnet / prefs ---------- */
static void
edit_save_fields (void)
{
	if (!editNet) return;

	BOOL global = editChkGlobal &&
		([editChkGlobal state] == NSControlStateValueOn);

	if (global)
	{
		/* Save nick/user back to global prefs AND sync to NL fields. */
		const char *v;

		v = [[editNickField stringValue] UTF8String];
		if (v) safe_strcpy (prefs.hex_irc_nick1, v,
			sizeof (prefs.hex_irc_nick1));
		if (slNickField1) [slNickField1 setStringValue:
			[editNickField stringValue]];

		v = [[editNick2Field stringValue] UTF8String];
		if (v) safe_strcpy (prefs.hex_irc_nick2, v,
			sizeof (prefs.hex_irc_nick2));
		if (slNickField2) [slNickField2 setStringValue:
			[editNick2Field stringValue]];

		v = [[editNick3Field stringValue] UTF8String];
		if (v) safe_strcpy (prefs.hex_irc_nick3, v,
			sizeof (prefs.hex_irc_nick3));
		if (slNickField3) [slNickField3 setStringValue:
			[editNick3Field stringValue]];

		v = [[editUserField stringValue] UTF8String];
		if (v) safe_strcpy (prefs.hex_irc_user_name, v,
			sizeof (prefs.hex_irc_user_name));
		if (slUserField) [slUserField setStringValue:
			[editUserField stringValue]];
	}
	else
	{
		/* Save to per-network fields. */
		const char *v;

		v = [[editNickField stringValue] UTF8String];
		g_free (editNet->nick);
		editNet->nick = (v && v[0]) ? g_strdup (v) : NULL;

		v = [[editNick2Field stringValue] UTF8String];
		g_free (editNet->nick2);
		editNet->nick2 = (v && v[0]) ? g_strdup (v) : NULL;

		/* Third choice not used in per-network mode. */

		v = [[editUserField stringValue] UTF8String];
		g_free (editNet->user);
		editNet->user = (v && v[0]) ? g_strdup (v) : NULL;
	}

	/* Password (always save). */
	const char *pw = [[editPassField stringValue] UTF8String];
	g_free (editNet->pass);
	editNet->pass = (pw && pw[0]) ? g_strdup (pw) : NULL;

	/* Login type. */
	NSInteger idx = [editLoginPopup indexOfSelectedItem];
	if (idx >= 0 && idx < cocoa_login_types_count)
		editNet->logintype = cocoa_login_types_conf[idx];

	/* Charset. */
	const char *cs = [[editCharsetCombo stringValue] UTF8String];
	g_free (editNet->encoding);
	editNet->encoding = (cs && cs[0]) ? g_strdup (cs) : NULL;
}

/* ---------- Edit dialog button actions ---------- */
@implementation HCMenuTarget (EditNetwork)

- (void)editClose:(id)sender
{
	edit_save_fields ();
	[editNetWindow orderOut:nil];
	editNetWindow = nil;
	editNet = nil;
	editServerTable = editChanTable = editCmdTable = nil;
	editNickField = editNick2Field = editNick3Field = editUserField = nil;
	editPassField = nil;
	editLoginPopup = nil;
	editCharsetCombo = nil;
	editChkGlobal = nil;
	editServerDS = editChanDS = editCmdDS = nil;

	/* Refresh server list table in case the name changed. */
	if (serverListTable)
		[serverListTable reloadData];
}

- (void)editCheckboxToggled:(id)sender
{
	if (!editNet) return;
	NSInteger tag = [sender tag];
	int flag = (int)(tag & 0xFFFF);
	int reversed = (tag & 0x10000) ? 1 : 0;
	BOOL checked = ([sender state] == NSControlStateValueOn);

	if (reversed)
		checked = !checked;

	if (checked)
		editNet->flags |= flag;
	else
		editNet->flags &= ~flag;

	/* If FLAG_USE_GLOBAL toggled, enable/disable fields. */
	if (flag == 2)
		edit_toggle_global_fields ();
}

/* --- Servers tab --- */
- (void)editAddServer:(id)sender
{
	if (!editNet) return;
	servlist_server_add (editNet, "newserver/6667");
	[editServerTable reloadData];
	/* Select & edit the new row. */
	NSInteger row = (NSInteger)g_slist_length (editNet->servlist) - 1;
	if (row >= 0)
	{
		[editServerTable selectRowIndexes:
			[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
		[editServerTable editColumn:0 row:row withEvent:nil select:YES];
	}
}

- (void)editRemoveServer:(id)sender
{
	if (!editNet) return;
	NSInteger row = [editServerTable selectedRow];
	if (row < 0) return;
	/* Keep at least one server. */
	if (g_slist_length (editNet->servlist) < 2) return;
	ircserver *s = g_slist_nth_data (editNet->servlist, (guint)row);
	if (s) servlist_server_remove (editNet, s);
	[editServerTable reloadData];
}

/* --- Channels tab --- */
- (void)editAddChannel:(id)sender
{
	if (!editNet) return;
	servlist_favchan_add (editNet, "#channel");
	[editChanTable reloadData];
	NSInteger row = (NSInteger)g_slist_length (editNet->favchanlist) - 1;
	if (row >= 0)
	{
		[editChanTable selectRowIndexes:
			[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
		[editChanTable editColumn:0 row:row withEvent:nil select:YES];
	}
}

- (void)editRemoveChannel:(id)sender
{
	if (!editNet) return;
	NSInteger row = [editChanTable selectedRow];
	if (row < 0) return;
	favchannel *fc = g_slist_nth_data (editNet->favchanlist, (guint)row);
	if (fc) servlist_favchan_remove (editNet, fc);
	[editChanTable reloadData];
}

/* --- Commands tab --- */
- (void)editAddCommand:(id)sender
{
	if (!editNet) return;
	servlist_command_add (editNet, "ECHO hello");
	[editCmdTable reloadData];
	NSInteger row = (NSInteger)g_slist_length (editNet->commandlist) - 1;
	if (row >= 0)
	{
		[editCmdTable selectRowIndexes:
			[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
		[editCmdTable editColumn:0 row:row withEvent:nil select:YES];
	}
}

- (void)editRemoveCommand:(id)sender
{
	if (!editNet) return;
	NSInteger row = [editCmdTable selectedRow];
	if (row < 0) return;
	commandentry *e = g_slist_nth_data (editNet->commandlist, (guint)row);
	if (e) servlist_command_remove (editNet, e);
	[editCmdTable reloadData];
}

@end


/* ==========================================================================
 *  PREFERENCES DIALOG
 * ==========================================================================
 *
 *  Ports the GTK setup.c preferences to native Cocoa.
 *  7 tabs: Appearance, Input, Chatting, User List, Alerts, Logging, Network.
 *  Auto-apply with a single Close button (macOS-native style).
 *  Changes write directly to the global prefs struct; save_config() on close.
 */

/* --------------------------------------------------------------------------
 *  Reusable widget helpers
 * -------------------------------------------------------------------------- */

/*
 * Bold section header.
 */
static void
prefs_add_header (NSView *v, CGFloat *y, NSString *title)
{
	*y -= 8;
	if (*y < [v bounds].size.height - 10)
		*y -= 6;   /* extra gap between sections */
	NSTextField *lbl = [NSTextField labelWithString:title];
	[lbl setFrame:NSMakeRect (10, *y - 16, [v bounds].size.width - 20, 16)];
	[lbl setFont:[NSFont boldSystemFontOfSize:12]];
	[lbl setAutoresizingMask:NSViewWidthSizable];
	[v addSubview:lbl];
	*y -= 20;
}

/*
 * Italic helper label.
 */
static void
prefs_add_label (NSView *v, CGFloat *y, NSString *text)
{
	CGFloat W = [v bounds].size.width;
	NSTextField *lbl = [NSTextField labelWithString:text];
	[lbl setFrame:NSMakeRect (30, *y - 16, W - 40, 14)];
	[lbl setFont:[NSFont systemFontOfSize:10]];
	[lbl setTextColor:[NSColor secondaryLabelColor]];
	[lbl setAutoresizingMask:NSViewWidthSizable];
	[v addSubview:lbl];
	*y -= 18;
}

/*
 * Checkbox bound to an unsigned-int boolean pref.
 * Tag stores the byte offset of the pref field so the generic
 * prefsBoolToggled: action can write any boolean pref.
 */
static NSButton *
prefs_add_checkbox (NSView *v, CGFloat *y, NSString *label,
	unsigned int *prefPtr)
{
	CGFloat W = [v bounds].size.width;
	NSButton *chk = [NSButton checkboxWithTitle:label
		target:menuTarget action:@selector(prefsBoolToggled:)];
	[chk setFrame:NSMakeRect (30, *y - 18, W - 40, 18)];
	[chk setState:*prefPtr ? NSControlStateValueOn : NSControlStateValueOff];
	[chk setTag:(NSInteger)((char *)prefPtr - (char *)&prefs)];
	[chk setAutoresizingMask:NSViewWidthSizable];
	[v addSubview:chk];
	*y -= 22;
	return chk;
}

/*
 * Label + text field pair.  Returns the NSTextField.
 */
static NSTextField *
prefs_add_textfield (NSView *v, CGFloat *y, NSString *label,
	const char *value)
{
	CGFloat W = [v bounds].size.width;
	NSTextField *lbl = [NSTextField labelWithString:label];
	[lbl setFrame:NSMakeRect (14, *y - 16, 140, 16)];
	[lbl setAlignment:NSTextAlignmentRight];
	[lbl setFont:[NSFont systemFontOfSize:12]];
	[lbl setAutoresizingMask:NSViewMinYMargin];
	[v addSubview:lbl];

	NSTextField *tf = [[NSTextField alloc]
		initWithFrame:NSMakeRect (160, *y - 18, W - 174, 22)];
	NSString *val = (value && value[0])
		? [NSString stringWithUTF8String:value] : @"";
	[tf setStringValue:val ?: @""];
	[tf setFont:[NSFont systemFontOfSize:12]];
	[tf setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
	[v addSubview:tf];
	*y -= 26;
	return tf;
}

/*
 * Label + secure text field pair.  Returns the NSSecureTextField.
 */
static NSSecureTextField *
prefs_add_securefield (NSView *v, CGFloat *y, NSString *label,
	const char *value)
{
	CGFloat W = [v bounds].size.width;
	NSTextField *lbl = [NSTextField labelWithString:label];
	[lbl setFrame:NSMakeRect (14, *y - 16, 140, 16)];
	[lbl setAlignment:NSTextAlignmentRight];
	[lbl setFont:[NSFont systemFontOfSize:12]];
	[lbl setAutoresizingMask:NSViewMinYMargin];
	[v addSubview:lbl];

	NSSecureTextField *tf = [[NSSecureTextField alloc]
		initWithFrame:NSMakeRect (160, *y - 18, W - 174, 22)];
	NSString *val = (value && value[0])
		? [NSString stringWithUTF8String:value] : @"";
	[tf setStringValue:val ?: @""];
	[tf setFont:[NSFont systemFontOfSize:12]];
	[tf setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
	[v addSubview:tf];
	*y -= 26;
	return tf;
}

/*
 * Label + NSStepper + value field, bound to an int pref.
 * Tag stores the byte offset of the pref field.
 */
static void
prefs_add_stepper (NSView *v, CGFloat *y, NSString *label,
	int *prefPtr, int minVal, int maxVal, NSString *suffix)
{
	CGFloat W = [v bounds].size.width;
	int curVal = *prefPtr;
	NSInteger tag = (NSInteger)((char *)prefPtr - (char *)&prefs);

	NSTextField *lbl = [NSTextField labelWithString:label];
	[lbl setFrame:NSMakeRect (14, *y - 16, 140, 16)];
	[lbl setAlignment:NSTextAlignmentRight];
	[lbl setFont:[NSFont systemFontOfSize:12]];
	[v addSubview:lbl];

	NSTextField *valField = [[NSTextField alloc]
		initWithFrame:NSMakeRect (160, *y - 18, 70, 22)];
	[valField setIntValue:curVal];
	[valField setFont:[NSFont systemFontOfSize:12]];
	[valField setTag:tag];
	[valField setTarget:menuTarget];
	[valField setAction:@selector(prefsStepperFieldEdited:)];
	[v addSubview:valField];

	NSStepper *stepper = [[NSStepper alloc]
		initWithFrame:NSMakeRect (234, *y - 18, 19, 22)];
	[stepper setMinValue:minVal];
	[stepper setMaxValue:maxVal];
	[stepper setIntValue:curVal];
	[stepper setIncrement:1];
	[stepper setValueWraps:NO];
	[stepper setTag:tag];
	[stepper setTarget:menuTarget];
	[stepper setAction:@selector(prefsStepperChanged:)];
	/* Store a reference to the value field via identifier trick:
	   we use the Cocoa associated-objects pattern instead. For
	   simplicity, we connect them by matching tags. */
	[v addSubview:stepper];

	if (suffix)
	{
		NSTextField *suf = [NSTextField labelWithString:suffix];
		[suf setFrame:NSMakeRect (258, *y - 16, W - 268, 16)];
		[suf setFont:[NSFont systemFontOfSize:11]];
		[suf setTextColor:[NSColor secondaryLabelColor]];
		[v addSubview:suf];
	}

	*y -= 26;
}

/*
 * Label + NSPopUpButton, bound to an int pref.
 * Tag stores the byte offset of the pref field.
 */
static NSPopUpButton *
prefs_add_popup (NSView *v, CGFloat *y, NSString *label,
	int *prefPtr, NSArray *options)
{
	CGFloat W = [v bounds].size.width;
	NSInteger tag = (NSInteger)((char *)prefPtr - (char *)&prefs);

	NSTextField *lbl = [NSTextField labelWithString:label];
	[lbl setFrame:NSMakeRect (14, *y - 16, 140, 16)];
	[lbl setAlignment:NSTextAlignmentRight];
	[lbl setFont:[NSFont systemFontOfSize:12]];
	[v addSubview:lbl];

	NSPopUpButton *popup = [[NSPopUpButton alloc]
		initWithFrame:NSMakeRect (160, *y - 20, W - 174, 26)
		pullsDown:NO];
	for (NSString *opt in options)
		[popup addItemWithTitle:opt];
	int cur = *prefPtr;
	if (cur >= 0 && cur < (int)[options count])
		[popup selectItemAtIndex:cur];
	[popup setFont:[NSFont systemFontOfSize:12]];
	[popup setTag:tag];
	[popup setTarget:menuTarget];
	[popup setAction:@selector(prefsMenuChanged:)];
	[popup setAutoresizingMask:(NSViewWidthSizable)];
	[v addSubview:popup];
	*y -= 28;
	return popup;
}

/* --------------------------------------------------------------------------
 *  Tab 1 — Appearance
 * -------------------------------------------------------------------------- */
static void
prefs_build_appearance_tab (NSView *v)
{
	CGFloat W = [v bounds].size.width;
	CGFloat y = [v bounds].size.height;

	prefs_add_header (v, &y, @"Font");

	/* Font display + Choose button. */
	{
		NSTextField *lbl = [NSTextField labelWithString:@"Main font:"];
		[lbl setFrame:NSMakeRect (14, y - 16, 140, 16)];
		[lbl setAlignment:NSTextAlignmentRight];
		[lbl setFont:[NSFont systemFontOfSize:12]];
		[v addSubview:lbl];

		prefsFontLabel = [NSTextField labelWithString:
			[NSString stringWithUTF8String:
				prefs.hex_text_font_main[0]
					? prefs.hex_text_font_main : "Menlo 12"]];
		[prefsFontLabel setFrame:NSMakeRect (160, y - 16, W - 254, 16)];
		[prefsFontLabel setFont:[NSFont systemFontOfSize:12]];
		[prefsFontLabel setAutoresizingMask:NSViewWidthSizable];
		[v addSubview:prefsFontLabel];

		NSButton *chooseBtn = [[NSButton alloc]
			initWithFrame:NSMakeRect (W - 90, y - 20, 80, 24)];
		[chooseBtn setTitle:@"Choose\xE2\x80\xA6"];
		[chooseBtn setBezelStyle:NSBezelStyleRounded];
		[chooseBtn setTarget:menuTarget];
		[chooseBtn setAction:@selector(prefsFontPicker:)];
		[chooseBtn setAutoresizingMask:NSViewMinXMargin];
		[v addSubview:chooseBtn];
		y -= 28;
	}

	prefs_add_header (v, &y, @"Text Box");
	prefs_add_checkbox (v, &y, @"Colored nick names",
		&prefs.hex_text_color_nicks);
	prefs_add_checkbox (v, &y, @"Indent nick names",
		&prefs.hex_text_indent);
	prefs_add_checkbox (v, &y, @"Show marker line",
		&prefs.hex_text_show_marker);

	prefs_add_header (v, &y, @"Timestamps");
	prefs_add_checkbox (v, &y, @"Enable timestamps",
		&prefs.hex_stamp_text);
	prefsStampFmt = prefs_add_textfield (v, &y, @"Timestamp format:",
		prefs.hex_stamp_text_format);
	prefs_add_label (v, &y,
		@"See strftime manpage for format codes.");

	prefs_add_header (v, &y, @"Title Bar");
	prefs_add_checkbox (v, &y, @"Show channel modes",
		&prefs.hex_gui_win_modes);
	prefs_add_checkbox (v, &y, @"Show number of users",
		&prefs.hex_gui_win_ucount);
	prefs_add_checkbox (v, &y, @"Show nickname",
		&prefs.hex_gui_win_nick);

	prefs_add_header (v, &y, @"Colors");
	prefs_add_checkbox (v, &y, @"Strip colors from messages",
		&prefs.hex_text_stripcolor_msg);
	prefs_add_checkbox (v, &y, @"Strip colors from scrollback",
		&prefs.hex_text_stripcolor_replay);
	prefs_add_checkbox (v, &y, @"Strip colors from topic",
		&prefs.hex_text_stripcolor_topic);

	prefs_add_header (v, &y, @"Display");
	prefs_add_stepper (v, &y, @"Transparency:",
		&prefs.hex_gui_transparency, 0, 255, @"(0=opaque)");
	prefsBgImage = prefs_add_textfield (v, &y, @"Background image:",
		prefs.hex_text_background);
}

/* --------------------------------------------------------------------------
 *  Tab 2 — Input
 * -------------------------------------------------------------------------- */
static void
prefs_build_input_tab (NSView *v)
{
	CGFloat y = [v bounds].size.height;

	prefs_add_header (v, &y, @"Input Box");
	prefs_add_checkbox (v, &y, @"Use the text box font and colors",
		&prefs.hex_gui_input_style);
	prefs_add_checkbox (v, &y, @"Render colors and attributes",
		&prefs.hex_gui_input_attr);
	prefs_add_checkbox (v, &y, @"Spell checking",
		&prefs.hex_gui_input_spell);
	prefsSpellLangs = prefs_add_textfield (v, &y, @"Dictionaries:",
		prefs.hex_text_spell_langs);
	prefs_add_label (v, &y,
		@"Separate multiple language codes with commas (e.g. en_US,fr).");

	prefs_add_header (v, &y, @"Nick Completion");
	prefsCompSuffix = prefs_add_textfield (v, &y,
		@"Completion suffix:", prefs.hex_completion_suffix);
	prefs_add_popup (v, &y, @"Completion sorted:",
		&prefs.hex_completion_sort,
		@[ @"A-Z", @"Last-spoke order" ]);
	prefs_add_stepper (v, &y, @"Completion amount:",
		&prefs.hex_completion_amount, 1, 1000, @"nicks");

	prefs_add_header (v, &y, @"Nick Box");
	prefs_add_checkbox (v, &y, @"Show nickname in input box",
		&prefs.hex_gui_input_nick);
	prefs_add_checkbox (v, &y, @"Show mode icon in nick box",
		&prefs.hex_gui_input_icon);
}

/* --------------------------------------------------------------------------
 *  Tab 3 — Chatting
 * -------------------------------------------------------------------------- */
static void
prefs_build_chatting_tab (NSView *v)
{
	CGFloat y = [v bounds].size.height;

	prefs_add_header (v, &y, @"Default Messages");
	prefsQuitMsg = prefs_add_textfield (v, &y, @"Quit:",
		prefs.hex_irc_quit_reason);
	prefsPartMsg = prefs_add_textfield (v, &y, @"Leave channel:",
		prefs.hex_irc_part_reason);
	prefsAwayMsg = prefs_add_textfield (v, &y, @"Away:",
		prefs.hex_away_reason);

	prefs_add_header (v, &y, @"Away");
	prefs_add_checkbox (v, &y, @"Show away once",
		&prefs.hex_away_show_once);
	prefs_add_checkbox (v, &y, @"Automatically unmark away",
		&prefs.hex_away_auto_unmark);

	prefs_add_header (v, &y, @"Miscellaneous");
	prefs_add_checkbox (v, &y, @"Display MODEs in raw form",
		&prefs.hex_irc_raw_modes);
	prefs_add_checkbox (v, &y, @"WHOIS on notify",
		&prefs.hex_notify_whois_online);
	prefs_add_checkbox (v, &y, @"Hide join and part messages",
		&prefs.hex_irc_conf_mode);
	prefs_add_checkbox (v, &y, @"Hide nick change messages",
		&prefs.hex_irc_hide_nickchange);
	prefsRealName = prefs_add_textfield (v, &y, @"Real name:",
		prefs.hex_irc_real_name);
	prefs_add_checkbox (v, &y, @"Display lists in compact mode",
		&prefs.hex_gui_compact);
	prefs_add_checkbox (v, &y, @"Use server time if supported",
		&prefs.hex_irc_cap_server_time);

	prefs_add_header (v, &y, @"Auto-copy");
	prefs_add_checkbox (v, &y, @"Automatically copy selected text",
		&prefs.hex_text_autocopy_text);
	prefs_add_checkbox (v, &y, @"Include timestamps when copying",
		&prefs.hex_text_autocopy_stamp);
	prefs_add_checkbox (v, &y, @"Include color codes when copying",
		&prefs.hex_text_autocopy_color);

	prefs_add_header (v, &y, @"IRC");
	prefs_add_popup (v, &y, @"Ban type:",
		&prefs.hex_irc_ban_type,
		@[ @"Host (nick!*@*.host)", @"Domain (*!*@domain.com)",
		   @"IP (*!*@1.2.3.*)", @"Full (nick!user@host)" ]);
}

/* --------------------------------------------------------------------------
 *  Tab 4 — User List
 * -------------------------------------------------------------------------- */
static void
prefs_build_userlist_tab (NSView *v)
{
	CGFloat y = [v bounds].size.height;

	prefs_add_header (v, &y, @"User List");
	prefs_add_checkbox (v, &y, @"Show hostnames in user list",
		&prefs.hex_gui_ulist_show_hosts);
	prefs_add_checkbox (v, &y, @"Use the text box font and colors",
		&prefs.hex_gui_ulist_style);
	prefs_add_checkbox (v, &y, @"Show icons for user modes",
		&prefs.hex_gui_ulist_icons);
	prefs_add_checkbox (v, &y, @"Color nicknames",
		&prefs.hex_gui_ulist_color);
	prefs_add_checkbox (v, &y, @"Show user count in channels",
		&prefs.hex_gui_ulist_count);
	prefs_add_popup (v, &y, @"Sorted by:",
		&prefs.hex_gui_ulist_sort,
		@[ @"A-Z, ops first", @"A-Z", @"Z-A, ops last",
		   @"Z-A", @"Unsorted" ]);

	prefs_add_header (v, &y, @"Away Tracking");
	prefs_add_checkbox (v, &y,
		@"Track away status of users",
		&prefs.hex_away_track);
	prefs_add_stepper (v, &y, @"On channels < :",
		&prefs.hex_away_size_max, 1, 10000, @"users");

	prefs_add_header (v, &y, @"Action Upon Double Click");
	prefsUlistDblClick = prefs_add_textfield (v, &y,
		@"Execute command:", prefs.hex_gui_ulist_doubleclick);

	prefs_add_header (v, &y, @"Position & Meters");
	prefs_add_popup (v, &y, @"User list position:",
		&prefs.hex_gui_ulist_pos,
		@[ @"Left", @"Right" ]);
	prefs_add_popup (v, &y, @"Lag meter:",
		&prefs.hex_gui_lagometer,
		@[ @"Off", @"Graphical", @"Text", @"Both" ]);
	prefs_add_popup (v, &y, @"Throttle meter:",
		&prefs.hex_gui_throttlemeter,
		@[ @"Off", @"Graphical", @"Text", @"Both" ]);
}

/* --------------------------------------------------------------------------
 *  Tab 5 — Alerts
 * -------------------------------------------------------------------------- */
static void
prefs_build_alerts_tab (NSView *v)
{
	CGFloat W = [v bounds].size.width;
	CGFloat y = [v bounds].size.height;

	prefs_add_header (v, &y, @"Alerts");

	/* Column headers for the 3-toggle rows. */
	{
		CGFloat colW = (W - 180) / 3;
		NSArray *titles = @[ @"Channel", @"Private", @"Highlight" ];
		for (int i = 0; i < 3; i++)
		{
			NSTextField *h = [NSTextField labelWithString:titles[i]];
			[h setFrame:NSMakeRect (180 + i * colW, y - 14,
				colW, 14)];
			[h setAlignment:NSTextAlignmentCenter];
			[h setFont:[NSFont boldSystemFontOfSize:10]];
			[v addSubview:h];
		}
		y -= 18;
	}

	/* 3-toggle row helper macro. */
	#define PREFS_3TOGGLE(LABEL, F1, F2, F3) \
	do { \
		CGFloat colW = (W - 180) / 3; \
		NSTextField *lbl = [NSTextField labelWithString:LABEL]; \
		[lbl setFrame:NSMakeRect (30, y - 16, 146, 16)]; \
		[lbl setFont:[NSFont systemFontOfSize:12]]; \
		[v addSubview:lbl]; \
		unsigned int *ptrs[3] = { &prefs.F1, &prefs.F2, &prefs.F3 }; \
		for (int _i = 0; _i < 3; _i++) \
		{ \
			NSButton *chk = [[NSButton alloc] \
				initWithFrame:NSMakeRect ( \
					180 + _i * colW + colW / 2 - 8, y - 16, 18, 18)]; \
			[chk setButtonType:NSButtonTypeSwitch]; \
			[chk setTitle:@""]; \
			[chk setState:*ptrs[_i] \
				? NSControlStateValueOn : NSControlStateValueOff]; \
			[chk setTag:(NSInteger)((char *)ptrs[_i] - (char *)&prefs)]; \
			[chk setTarget:menuTarget]; \
			[chk setAction:@selector(prefsBoolToggled:)]; \
			[v addSubview:chk]; \
		} \
		y -= 22; \
	} while (0)

	PREFS_3TOGGLE (@"Bounce dock icon:",
		hex_input_flash_chans, hex_input_flash_priv,
		hex_input_flash_hilight);

	PREFS_3TOGGLE (@"Make a beep sound:",
		hex_input_beep_chans, hex_input_beep_priv,
		hex_input_beep_hilight);

	#undef PREFS_3TOGGLE

	y -= 4;
	prefs_add_checkbox (v, &y,
		@"Omit alerts when marked as being away",
		&prefs.hex_away_omit_alerts);
	prefs_add_checkbox (v, &y,
		@"Omit alerts while the window is focused",
		&prefs.hex_gui_focus_omitalerts);

	prefs_add_header (v, &y, @"Highlighted Messages");
	prefs_add_label (v, &y,
		@"Highlighted messages are ones where your nickname is "
		"mentioned, but also:");
	prefsHilightExtra = prefs_add_textfield (v, &y,
		@"Extra words:", prefs.hex_irc_extra_hilight);
	prefsHilightNoNick = prefs_add_textfield (v, &y,
		@"Nicks not to hilight:", prefs.hex_irc_no_hilight);
	prefsHilightNick = prefs_add_textfield (v, &y,
		@"Nicks to always hilight:", prefs.hex_irc_nick_hilight);
	prefs_add_label (v, &y,
		@"Separate multiple words with commas. Wildcards accepted.");

	prefs_add_header (v, &y, @"Notifications");
	prefs_add_label (v, &y,
		@"Send macOS notifications for:");

	/* 3-toggle row header for notifications. */
	{
		CGFloat colW = (W - 180) / 3;
		NSArray *titles = @[ @"Channel", @"Private", @"Highlight" ];
		for (int i = 0; i < 3; i++)
		{
			NSTextField *h = [NSTextField labelWithString:titles[i]];
			[h setFrame:NSMakeRect (180 + i * colW, y - 14,
				colW, 14)];
			[h setAlignment:NSTextAlignmentCenter];
			[h setFont:[NSFont boldSystemFontOfSize:10]];
			[v addSubview:h];
		}
		y -= 18;
	}

	#define PREFS_3TOGGLE_NOTIF(LABEL, F1, F2, F3) \
	do { \
		CGFloat colW = (W - 180) / 3; \
		NSTextField *lbl = [NSTextField labelWithString:LABEL]; \
		[lbl setFrame:NSMakeRect (30, y - 16, 146, 16)]; \
		[lbl setFont:[NSFont systemFontOfSize:12]]; \
		[v addSubview:lbl]; \
		unsigned int *ptrs[3] = { &prefs.F1, &prefs.F2, &prefs.F3 }; \
		for (int _i = 0; _i < 3; _i++) \
		{ \
			NSButton *chk = [[NSButton alloc] \
				initWithFrame:NSMakeRect ( \
					180 + _i * colW + colW / 2 - 8, y - 16, 18, 18)]; \
			[chk setButtonType:NSButtonTypeSwitch]; \
			[chk setTitle:@""]; \
			[chk setState:*ptrs[_i] \
				? NSControlStateValueOn : NSControlStateValueOff]; \
			[chk setTag:(NSInteger)((char *)ptrs[_i] - (char *)&prefs)]; \
			[chk setTarget:menuTarget]; \
			[chk setAction:@selector(prefsBoolToggled:)]; \
			[v addSubview:chk]; \
		} \
		y -= 22; \
	} while (0)

	PREFS_3TOGGLE_NOTIF (@"Send notification:",
		hex_input_balloon_chans, hex_input_balloon_priv,
		hex_input_balloon_hilight);

	#undef PREFS_3TOGGLE_NOTIF
}

/* --------------------------------------------------------------------------
 *  Tab 6 — Sounds
 * -------------------------------------------------------------------------- */

extern struct text_event te[];  /* text.c */
extern char *sound_files[];     /* text.c */

static void
prefs_build_sounds_tab (NSView *v)
{
	CGFloat W = [v bounds].size.width;
	CGFloat H = [v bounds].size.height;

	/* Two buttons at the bottom. */
	CGFloat btnY = 8;
	NSButton *playBtn = [[NSButton alloc]
		initWithFrame:NSMakeRect (W - 90, btnY, 80, 28)];
	[playBtn setTitle:@"Play"];
	[playBtn setBezelStyle:NSBezelStyleRounded];
	[playBtn setTarget:menuTarget];
	[playBtn setAction:@selector(soundsPlay:)];
	[playBtn setAutoresizingMask:(NSViewMinXMargin | NSViewMaxYMargin)];
	[v addSubview:playBtn];

	NSButton *browseBtn = [[NSButton alloc]
		initWithFrame:NSMakeRect (W - 180, btnY, 82, 28)];
	[browseBtn setTitle:@"Browse\xE2\x80\xA6"];
	[browseBtn setBezelStyle:NSBezelStyleRounded];
	[browseBtn setTarget:menuTarget];
	[browseBtn setAction:@selector(soundsBrowse:)];
	[browseBtn setAutoresizingMask:(NSViewMinXMargin | NSViewMaxYMargin)];
	[v addSubview:browseBtn];

	/* File path field above buttons. */
	soundsFileField = [[NSTextField alloc]
		initWithFrame:NSMakeRect (10, btnY + 34, W - 20, 22)];
	[soundsFileField setPlaceholderString:@"(no sound file)"];
	[soundsFileField setFont:[NSFont systemFontOfSize:12]];
	[soundsFileField setAutoresizingMask:
		(NSViewWidthSizable | NSViewMaxYMargin)];
	[v addSubview:soundsFileField];

	/* Table view. */
	NSScrollView *sv = [[NSScrollView alloc]
		initWithFrame:NSMakeRect (0, btnY + 62, W, H - (btnY + 62))];
	[sv setHasVerticalScroller:YES];
	[sv setHasHorizontalScroller:NO];
	[sv setBorderType:NSBezelBorder];
	[sv setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

	soundsTable = [[NSTableView alloc]
		initWithFrame:[[sv contentView] bounds]];
	[soundsTable setDataSource:(id<NSTableViewDataSource>)menuTarget];
	[soundsTable setDelegate:(id<NSTableViewDelegate>)menuTarget];
	[soundsTable setUsesAlternatingRowBackgroundColors:YES];

	NSTableColumn *colEvent = [[NSTableColumn alloc]
		initWithIdentifier:@"event"];
	[[colEvent headerCell] setStringValue:@"Event"];
	[colEvent setWidth:240];
	[colEvent setEditable:NO];
	[soundsTable addTableColumn:colEvent];

	NSTableColumn *colFile = [[NSTableColumn alloc]
		initWithIdentifier:@"file"];
	[[colFile headerCell] setStringValue:@"Sound File"];
	[colFile setEditable:YES];
	[soundsTable addTableColumn:colFile];

	[sv setDocumentView:soundsTable];
	[v addSubview:sv];
}

/* --------------------------------------------------------------------------
 *  Tab 7 — Logging
 * -------------------------------------------------------------------------- */
static void
prefs_build_logging_tab (NSView *v)
{
	CGFloat y = [v bounds].size.height;

	prefs_add_header (v, &y, @"Logging");
	prefs_add_checkbox (v, &y,
		@"Display scrollback from previous session",
		&prefs.hex_text_replay);
	prefs_add_stepper (v, &y, @"Scrollback lines:",
		&prefs.hex_text_max_lines, 0, 100000, nil);
	prefs_add_checkbox (v, &y,
		@"Enable logging of conversations to disk",
		&prefs.hex_irc_logging);
	prefsLogMask = prefs_add_textfield (v, &y, @"Log filename:",
		prefs.hex_irc_logmask);
	prefs_add_label (v, &y,
		@"%%s=Server  %%c=Channel  %%n=Network.");

	prefs_add_header (v, &y, @"Timestamps");
	prefs_add_checkbox (v, &y, @"Insert timestamps in logs",
		&prefs.hex_stamp_log);
	prefsLogStampFmt = prefs_add_textfield (v, &y,
		@"Log timestamp format:", prefs.hex_stamp_log_format);

	prefs_add_header (v, &y, @"URLs");
	prefs_add_checkbox (v, &y, @"Enable logging of URLs to disk",
		&prefs.hex_url_logging);
	prefs_add_checkbox (v, &y, @"Enable URL grabber",
		&prefs.hex_url_grabber);
	prefs_add_stepper (v, &y, @"Max URLs to grab:",
		&prefs.hex_url_grabber_limit, 0, 9999, nil);
}

/* --------------------------------------------------------------------------
 *  Tab 8 — Channel Switcher (new)
 * -------------------------------------------------------------------------- */
static void
prefs_build_switcher_tab (NSView *v)
{
	CGFloat y = [v bounds].size.height;

	prefs_add_header (v, &y, @"Tab Bar");
	prefs_add_checkbox (v, &y, @"Open server messages in separate tab",
		&prefs.hex_gui_tab_server);
	prefs_add_checkbox (v, &y, @"Sort tabs alphabetically",
		&prefs.hex_gui_tab_sort);
	prefs_add_checkbox (v, &y, @"Show icons in tab bar",
		&prefs.hex_gui_tab_icons);
	prefs_add_checkbox (v, &y, @"Show activity dots on tabs",
		&prefs.hex_gui_tab_dots);
	prefs_add_checkbox (v, &y, @"Scroll mouse wheel to change tabs",
		&prefs.hex_gui_tab_scrollchans);
	prefs_add_checkbox (v, &y, @"Show channels in tab bar",
		&prefs.hex_gui_tab_chans);
	prefs_add_checkbox (v, &y, @"Show dialogs in tab bar",
		&prefs.hex_gui_tab_dialogs);
	prefs_add_checkbox (v, &y, @"Show utility tabs",
		&prefs.hex_gui_tab_utils);
}

/* --------------------------------------------------------------------------
 *  Tab 9 — Network (expanded)
 * -------------------------------------------------------------------------- */
static void
prefs_build_network_tab (NSView *v)
{
	CGFloat y = [v bounds].size.height;

	prefs_add_header (v, &y, @"Connection");
	prefs_add_checkbox (v, &y,
		@"Automatically reconnect to servers on disconnect",
		&prefs.hex_net_auto_reconnect);
	prefs_add_stepper (v, &y, @"Reconnect delay:",
		&prefs.hex_net_reconnect_delay, 0, 9999, @"seconds");
	prefs_add_stepper (v, &y, @"Auto join delay:",
		&prefs.hex_irc_join_delay, 0, 9999, @"seconds");

	prefs_add_header (v, &y, @"Bind Address");
	prefsBindHost = prefs_add_textfield (v, &y,
		@"Outgoing IP / hostname:", prefs.hex_net_bind_host);
	prefs_add_label (v, &y,
		@"Leave blank to use default interface.");

	prefs_add_header (v, &y, @"Proxy Server");
	prefsProxyHost = prefs_add_textfield (v, &y, @"Hostname:",
		prefs.hex_net_proxy_host);
	prefs_add_stepper (v, &y, @"Port:",
		&prefs.hex_net_proxy_port, 0, 65535, nil);
	prefs_add_popup (v, &y, @"Type:",
		&prefs.hex_net_proxy_type,
		@[ @"(Disabled)", @"Wingate", @"SOCKS4",
		   @"SOCKS5", @"HTTP", @"Auto" ]);
	prefs_add_popup (v, &y, @"Use proxy for:",
		&prefs.hex_net_proxy_use,
		@[ @"All connections", @"IRC only", @"DCC only" ]);
	prefs_add_checkbox (v, &y,
		@"Use authentication (HTTP or SOCKS5 only)",
		&prefs.hex_net_proxy_auth);
	prefsProxyUser = prefs_add_textfield (v, &y, @"Username:",
		prefs.hex_net_proxy_user);
	prefsProxyPass = prefs_add_securefield (v, &y, @"Password:",
		prefs.hex_net_proxy_pass);

	prefs_add_header (v, &y, @"Identd");
	prefs_add_checkbox (v, &y, @"Enable Identd server",
		&prefs.hex_identd_server);
	prefs_add_stepper (v, &y, @"Identd port:",
		&prefs.hex_identd_port, 1, 65535, nil);
}

/* --------------------------------------------------------------------------
 *  Tab 10 — File Transfers (new, split from old Network tab)
 * -------------------------------------------------------------------------- */
static void
prefs_build_filetransfers_tab (NSView *v)
{
	CGFloat y = [v bounds].size.height;

	prefs_add_header (v, &y, @"Download");
	prefs_add_popup (v, &y, @"Auto-accept transfers:",
		&prefs.hex_dcc_auto_recv,
		@[ @"Ask", @"Ask to folder", @"Save automatically" ]);
	prefsDccDir = prefs_add_textfield (v, &y, @"Save files to:",
		prefs.hex_dcc_dir);
	prefsDccCompletedDir = prefs_add_textfield (v, &y,
		@"Move completed to:", prefs.hex_dcc_completed_dir);
	prefs_add_checkbox (v, &y, @"Include nick in filenames",
		&prefs.hex_dcc_save_nick);

	prefs_add_header (v, &y, @"Port Range");
	prefs_add_stepper (v, &y, @"First port:",
		&prefs.hex_dcc_port_first, 0, 65535, nil);
	prefs_add_stepper (v, &y, @"Last port:",
		&prefs.hex_dcc_port_last, 0, 65535, nil);

	prefs_add_header (v, &y, @"IP");
	prefs_add_checkbox (v, &y, @"Get IP from server",
		&prefs.hex_dcc_ip_from_server);
	prefsDccIp = prefs_add_textfield (v, &y, @"DCC IP address:",
		prefs.hex_dcc_ip);

	prefs_add_header (v, &y, @"Speed Limits");
	prefs_add_stepper (v, &y, @"Max upload (single):",
		&prefs.hex_dcc_max_send_cps, 0, 1000000, @"KB/s");
	prefs_add_stepper (v, &y, @"Max download (single):",
		&prefs.hex_dcc_max_get_cps, 0, 1000000, @"KB/s");
	prefs_add_stepper (v, &y, @"Max upload (all):",
		&prefs.hex_dcc_global_max_send_cps, 0, 1000000, @"KB/s");
	prefs_add_stepper (v, &y, @"Max download (all):",
		&prefs.hex_dcc_global_max_get_cps, 0, 1000000, @"KB/s");

	prefs_add_header (v, &y, @"Timeouts");
	prefs_add_stepper (v, &y, @"Stall timeout:",
		&prefs.hex_dcc_stall_timeout, 0, 9999, @"seconds");
	prefs_add_stepper (v, &y, @"DCC timeout:",
		&prefs.hex_dcc_timeout, 0, 9999, @"seconds");

	prefs_add_header (v, &y, @"Auto-open Windows");
	prefs_add_checkbox (v, &y, @"Open send window automatically",
		&prefs.hex_gui_autoopen_send);
	prefs_add_checkbox (v, &y, @"Open receive window automatically",
		&prefs.hex_gui_autoopen_recv);
	prefs_add_checkbox (v, &y, @"Open chat window automatically",
		&prefs.hex_gui_autoopen_chat);
}

/* --------------------------------------------------------------------------
 *  show_preferences — create / show the Preferences window
 * -------------------------------------------------------------------------- */
static void
show_preferences (void)
{
	@autoreleasepool
	{
		if (prefsWindow)
		{
			[prefsWindow makeKeyAndOrderFront:nil];
			return;
		}

		/* --- Window --- */
		NSRect frame = NSMakeRect (0, 0, 560, 480);
		prefsWindow = [[NSWindow alloc]
			initWithContentRect:frame
			styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
				| NSWindowStyleMaskResizable)
			backing:NSBackingStoreBuffered
			defer:NO];
		[prefsWindow center];
		[prefsWindow setTitle:@"Preferences - MacChat"];
		[prefsWindow setMinSize:NSMakeSize (480, 400)];

		NSView *content = [prefsWindow contentView];
		CGFloat W = [content bounds].size.width;
		CGFloat H = [content bounds].size.height;

		/* --- Tab view --- */
		prefsTabView = [[NSTabView alloc]
			initWithFrame:NSMakeRect (10, 44, W - 20, H - 54)];
		[prefsTabView setAutoresizingMask:
			(NSViewWidthSizable | NSViewHeightSizable)];

		struct {
			NSString *label;
			NSString *ident;
			void (*builder)(NSView *);
		} tabs[] = {
			{ @"Appearance",      @"appearance",   prefs_build_appearance_tab },
			{ @"Input",           @"input",        prefs_build_input_tab },
			{ @"Chatting",        @"chatting",     prefs_build_chatting_tab },
			{ @"User List",       @"userlist",     prefs_build_userlist_tab },
			{ @"Alerts",          @"alerts",       prefs_build_alerts_tab },
			{ @"Sounds",          @"sounds",       prefs_build_sounds_tab },
			{ @"Logging",         @"logging",      prefs_build_logging_tab },
			{ @"Chan Switcher",   @"switcher",     prefs_build_switcher_tab },
			{ @"Network",         @"network",      prefs_build_network_tab },
			{ @"File Transfers",  @"filetransfers",prefs_build_filetransfers_tab },
		};

		for (int i = 0; i < 10; i++)
		{
			NSTabViewItem *item = [[NSTabViewItem alloc]
				initWithIdentifier:tabs[i].ident];
			[item setLabel:tabs[i].label];

			/* Each tab gets a flipped-ish coordinate view.
			   We build top-down manually using y decrements. */
			NSRect tabRect = NSEqualRects ([prefsTabView contentRect], NSZeroRect)
				? NSMakeRect (0, 0, W - 34, H - 80)
				: [prefsTabView contentRect];
			NSView *tabView = [[NSView alloc]
				initWithFrame:NSMakeRect (0, 0,
					tabRect.size.width, tabRect.size.height)];

			/* Wrap in a scroll view so long tabs are scrollable. */
			NSScrollView *sv = [[NSScrollView alloc]
				initWithFrame:tabRect];
			[sv setHasVerticalScroller:YES];
			[sv setHasHorizontalScroller:NO];
			[sv setBorderType:NSNoBorder];
			[sv setAutoresizingMask:
				(NSViewWidthSizable | NSViewHeightSizable)];
			[sv setDocumentView:tabView];

			tabs[i].builder (tabView);
			[item setView:sv];
			[prefsTabView addTabViewItem:item];
		}

		[content addSubview:prefsTabView];

		/* --- Close button --- */
		NSButton *closeBtn = [[NSButton alloc]
			initWithFrame:NSMakeRect (W - 94, 8, 80, 32)];
		[closeBtn setTitle:@"Close"];
		[closeBtn setBezelStyle:NSBezelStyleRounded];
		[closeBtn setTarget:menuTarget];
		[closeBtn setAction:@selector(prefsClose:)];
		[closeBtn setKeyEquivalent:@"\033"];   /* Escape */
		[closeBtn setAutoresizingMask:
			(NSViewMinXMargin | NSViewMaxYMargin)];
		[content addSubview:closeBtn];

		[prefsWindow makeKeyAndOrderFront:nil];
	}
}

/* --------------------------------------------------------------------------
 *  Helper: read all text fields back into the prefs struct.
 * -------------------------------------------------------------------------- */
static void
prefs_save_fields (void)
{
	#define SAVE_STR(tf, dst) \
		do { \
			if (tf) { \
				const char *_s = [[tf stringValue] UTF8String]; \
				safe_strcpy (dst, _s ? _s : "", sizeof (dst)); \
			} \
		} while (0)

	SAVE_STR (prefsStampFmt,       prefs.hex_stamp_text_format);
	SAVE_STR (prefsSpellLangs,     prefs.hex_text_spell_langs);
	SAVE_STR (prefsCompSuffix,     prefs.hex_completion_suffix);
	SAVE_STR (prefsQuitMsg,        prefs.hex_irc_quit_reason);
	SAVE_STR (prefsPartMsg,        prefs.hex_irc_part_reason);
	SAVE_STR (prefsAwayMsg,        prefs.hex_away_reason);
	SAVE_STR (prefsRealName,       prefs.hex_irc_real_name);
	SAVE_STR (prefsUlistDblClick,  prefs.hex_gui_ulist_doubleclick);
	SAVE_STR (prefsHilightExtra,   prefs.hex_irc_extra_hilight);
	SAVE_STR (prefsHilightNoNick,  prefs.hex_irc_no_hilight);
	SAVE_STR (prefsHilightNick,    prefs.hex_irc_nick_hilight);
	SAVE_STR (prefsLogMask,        prefs.hex_irc_logmask);
	SAVE_STR (prefsLogStampFmt,    prefs.hex_stamp_log_format);
	SAVE_STR (prefsProxyHost,      prefs.hex_net_proxy_host);
	SAVE_STR (prefsProxyUser,      prefs.hex_net_proxy_user);
	SAVE_STR (prefsDccIp,          prefs.hex_dcc_ip);
	SAVE_STR (prefsBgImage,        prefs.hex_text_background);
	SAVE_STR (prefsBindHost,       prefs.hex_net_bind_host);
	SAVE_STR (prefsDccDir,         prefs.hex_dcc_dir);
	SAVE_STR (prefsDccCompletedDir,prefs.hex_dcc_completed_dir);

	/* Secure field (proxy password). */
	if (prefsProxyPass)
	{
		const char *pw = [[prefsProxyPass stringValue] UTF8String];
		safe_strcpy (prefs.hex_net_proxy_pass, pw ? pw : "",
			sizeof (prefs.hex_net_proxy_pass));
	}

	#undef SAVE_STR
}

/* --------------------------------------------------------------------------
 *  @implementation HCMenuTarget (Preferences)
 * -------------------------------------------------------------------------- */

@implementation HCMenuTarget (Preferences)

- (void)menuPreferences:(id)sender
{
	show_preferences ();
}

- (void)prefsClose:(id)sender
{
	prefs_save_fields ();
	save_config ();
	sound_save ();
	[prefsWindow orderOut:nil];
	prefsWindow = nil;
	prefsTabView = nil;
	prefsFontLabel = nil;
	prefsStampFmt = prefsSpellLangs = prefsCompSuffix = nil;
	prefsQuitMsg = prefsPartMsg = prefsAwayMsg = nil;
	prefsRealName = prefsUlistDblClick = nil;
	prefsHilightExtra = prefsHilightNoNick = prefsHilightNick = nil;
	prefsLogMask = prefsLogStampFmt = nil;
	prefsProxyHost = prefsProxyUser = nil;
	prefsProxyPass = nil;
	prefsDccIp = nil;
	prefsBgImage = nil;
	prefsBindHost = nil;
	prefsDccDir = prefsDccCompletedDir = nil;
	soundsTable = nil;
	soundsFileField = nil;
	soundsSelectedRow = -1;
}

/*
 * Generic boolean toggle handler.
 * Tag = byte offset of the unsigned int field within struct hexchatprefs.
 */
- (void)prefsBoolToggled:(id)sender
{
	NSInteger off = [sender tag];
	unsigned int *ptr = (unsigned int *)((char *)&prefs + off);
	*ptr = ([sender state] == NSControlStateValueOn) ? 1 : 0;
}

/*
 * Generic popup menu handler.
 * Tag = byte offset of the int field within struct hexchatprefs.
 */
- (void)prefsMenuChanged:(id)sender
{
	NSInteger off = [sender tag];
	int *ptr = (int *)((char *)&prefs + off);
	*ptr = (int)[sender indexOfSelectedItem];
}

/*
 * Generic stepper handler.
 * Tag = byte offset of the int field within struct hexchatprefs.
 * Also updates the companion text field (matched by tag).
 */
- (void)prefsStepperChanged:(id)sender
{
	NSInteger off = [sender tag];
	int val = [sender intValue];
	int *ptr = (int *)((char *)&prefs + off);
	*ptr = val;

	/* Find the companion text field with the same tag in the same superview. */
	NSView *parent = [sender superview];
	for (NSView *sibling in [parent subviews])
	{
		if (sibling != sender &&
			[sibling isKindOfClass:[NSTextField class]] &&
			[sibling tag] == off)
		{
			[(NSTextField *)sibling setIntValue:val];
			break;
		}
	}
}

/*
 * Text field next to a stepper was edited manually.
 */
- (void)prefsStepperFieldEdited:(id)sender
{
	NSInteger off = [sender tag];
	int val = [sender intValue];
	int *ptr = (int *)((char *)&prefs + off);
	*ptr = val;

	/* Sync companion stepper. */
	NSView *parent = [sender superview];
	for (NSView *sibling in [parent subviews])
	{
		if (sibling != sender &&
			[sibling isKindOfClass:[NSStepper class]] &&
			[sibling tag] == off)
		{
			[(NSStepper *)sibling setIntValue:val];
			break;
		}
	}
}

/*
 * Font picker — opens the macOS system font panel.
 */
- (void)prefsFontPicker:(id)sender
{
	/* Parse current font from prefs string ("FontName size"). */
	NSString *fontStr = [NSString stringWithUTF8String:
		prefs.hex_text_font_main[0]
			? prefs.hex_text_font_main : "Menlo 12"];
	NSFont *font = nil;

	/* Try to extract "Name Size" from the string. */
	NSRange lastSpace = [fontStr rangeOfString:@" "
		options:NSBackwardsSearch];
	if (lastSpace.location != NSNotFound)
	{
		NSString *name = [fontStr substringToIndex:lastSpace.location];
		CGFloat size = [[fontStr substringFromIndex:
			lastSpace.location + 1] doubleValue];
		if (size < 4) size = 12;
		font = [NSFont fontWithName:name size:size];
	}
	if (!font)
		font = [NSFont userFixedPitchFontOfSize:12];

	NSFontManager *fm = [NSFontManager sharedFontManager];
	[fm setSelectedFont:font isMultiple:NO];
	[fm orderFrontFontPanel:nil];

	/* We handle changeFont: via the app delegate's first-responder chain.
	   However, the simplest approach: set ourselves as the font target. */
	[fm setTarget:menuTarget];
	[fm setAction:@selector(prefsFontChanged:)];
}

/*
 * Sounds tab — NSTableViewDataSource
 */
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	if (tableView == soundsTable)
		return NUM_XP;
	/* Other tables (edit commands, etc.) handled by their own data source. */
	return 0;
}

- (id)tableView:(NSTableView *)tableView
	objectValueForTableColumn:(NSTableColumn *)tableColumn
	row:(NSInteger)row
{
	if (tableView != soundsTable)
		return nil;
	if ([[tableColumn identifier] isEqualToString:@"event"])
		return [NSString stringWithUTF8String:te[row].name];
	/* "file" column */
	if (sound_files[row] && sound_files[row][0])
		return [NSString stringWithUTF8String:sound_files[row]];
	return @"";
}

- (void)tableView:(NSTableView *)tableView
	setObjectValue:(id)object
	forTableColumn:(NSTableColumn *)tableColumn
	row:(NSInteger)row
{
	if (tableView != soundsTable)
		return;
	if (![[tableColumn identifier] isEqualToString:@"file"])
		return;
	const char *str = [object UTF8String];
	g_free (sound_files[row]);
	sound_files[row] = (str && str[0]) ? g_strdup (str) : NULL;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
	if ([notification object] != soundsTable)
		return;
	soundsSelectedRow = (int)[soundsTable selectedRow];
	if (soundsSelectedRow >= 0 && soundsSelectedRow < NUM_XP
		&& soundsFileField)
	{
		if (sound_files[soundsSelectedRow] && sound_files[soundsSelectedRow][0])
			[soundsFileField setStringValue:
				[NSString stringWithUTF8String:sound_files[soundsSelectedRow]]];
		else
			[soundsFileField setStringValue:@""];
	}
}

- (void)soundsBrowse:(id)sender
{
	if (soundsSelectedRow < 0 || soundsSelectedRow >= NUM_XP)
		return;

	NSOpenPanel *panel = [NSOpenPanel openPanel];
	[panel setTitle:@"Choose Sound File"];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	[panel setAllowedFileTypes:@[ @"aiff", @"aif", @"wav", @"mp3",
		@"m4a", @"caf", @"au" ]];
	[panel setAllowsOtherFileTypes:YES];
#pragma clang diagnostic pop

	[panel beginSheetModalForWindow:prefsWindow
		completionHandler:^(NSModalResponse result) {
		if (result == NSModalResponseOK)
		{
			NSString *path = [[panel URL] path];
			const char *cpath = [path UTF8String];
			g_free (sound_files[soundsSelectedRow]);
			sound_files[soundsSelectedRow] = cpath ? g_strdup (cpath) : NULL;
			if (soundsFileField)
				[soundsFileField setStringValue:path ?: @""];
			[soundsTable reloadData];
		}
	}];
}

- (void)soundsPlay:(id)sender
{
	if (soundsSelectedRow < 0 || soundsSelectedRow >= NUM_XP)
		return;
	if (sound_files[soundsSelectedRow] && sound_files[soundsSelectedRow][0])
		sound_play (sound_files[soundsSelectedRow], FALSE);
}

/*
 * Called by NSFontManager when user picks a font.
 */
- (void)prefsFontChanged:(id)sender
{
	NSFontManager *fm = (NSFontManager *)sender;
	NSFont *font = [fm convertFont:
		[NSFont userFixedPitchFontOfSize:12]];
	if (!font)
		return;

	NSString *desc = [NSString stringWithFormat:@"%@ %.0f",
		[font fontName], [font pointSize]];
	safe_strcpy (prefs.hex_text_font_main,
		[desc UTF8String],
		sizeof (prefs.hex_text_font_main));

	if (prefsFontLabel)
		[prefsFontLabel setStringValue:desc];
}

@end


/* ==========================================================================
 *  FEATURE 6 — DCC Transfers Panel
 * ==========================================================================
 */

static void
show_dcc_panel (void)
{
	@autoreleasepool
	{
		if (dccWindow)
		{
			[dccWindow makeKeyAndOrderFront:nil];
			return;
		}

		if (!dccTransfers)
			dccTransfers = [[NSMutableArray alloc] init];

		NSRect frame = NSMakeRect (250, 150, 700, 350);
		dccWindow = [[NSWindow alloc]
			initWithContentRect:frame
			styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
				| NSWindowStyleMaskResizable)
			backing:NSBackingStoreBuffered
			defer:NO];
		[dccWindow setTitle:@"DCC Transfers"];
		[dccWindow setMinSize:NSMakeSize(500, 200)];

		NSView *content = [dccWindow contentView];
		NSRect bounds = [content bounds];

		NSScrollView *scroll = [[NSScrollView alloc]
			initWithFrame:bounds];
		[scroll setHasVerticalScroller:YES];
		[scroll setAutoresizingMask:
			(NSViewWidthSizable | NSViewHeightSizable)];

		dccTable = [[NSTableView alloc]
			initWithFrame:[[scroll contentView] bounds]];

		/* Create columns: Nick, File, Size, Progress, Speed, Status */
		struct { const char *ident; const char *title; CGFloat w; }
		cols[] = {
			{"nick",     "Nick",     80},
			{"file",     "File",     200},
			{"size",     "Size",     80},
			{"progress", "Progress", 70},
			{"speed",    "Speed",    80},
			{"status",   "Status",   70},
		};
		for (int i = 0; i < 6; i++)
		{
			NSTableColumn *c = [[NSTableColumn alloc]
				initWithIdentifier:
					[NSString stringWithUTF8String:cols[i].ident]];
			[c setWidth:cols[i].w];
			[[c headerCell] setStringValue:
				[NSString stringWithUTF8String:cols[i].title]];
			[dccTable addTableColumn:c];
		}

		dccDataSource = [[HCDCCDataSource alloc] init];
		[dccTable setDataSource:(id<NSTableViewDataSource>)dccDataSource];
		[dccTable setDelegate:(id<NSTableViewDelegate>)dccDataSource];

		[scroll setDocumentView:dccTable];
		[content addSubview:scroll];

		[dccWindow makeKeyAndOrderFront:nil];
	}
}


/* ==========================================================================
 *
 *                  THE fe_* FUNCTIONS — HexChat Frontend API
 *
 * ==========================================================================
 */

/* --- Command-line arguments --- */

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
	return -1;
}


/* --------------------------------------------------------------------------
 *  fe_init — Bootstrap the Cocoa UI.
 * -------------------------------------------------------------------------- */
void
fe_init (void)
{
	prefs.hex_gui_tab_server = 0;
	prefs.hex_gui_autoopen_dialog = 0;
	prefs.hex_gui_lagometer = 0;
	prefs.hex_gui_slist_skip = 0;  /* Feature 5: Show server list on startup */

	@autoreleasepool
	{
		[NSApplication sharedApplication];

		/* Set process name so macOS shows "MacChat" in the app menu. */
		[[NSProcessInfo processInfo] setProcessName:@"MacChat"];

		appDelegate = [[HCAppDelegate alloc] init];
		[NSApp setDelegate:appDelegate];

		inputDelegate = [[HCInputDelegate alloc] init];
		treeDataSource = [[HCChannelTreeDataSource alloc] init];
		userListDataSource = [[HCUserListDataSource alloc] init];

		serverNodes = [[NSMutableArray alloc] init];

		/* Feature 1: Initialize mIRC color palette. */
		init_mirc_colors ();

		create_menu_bar ();
		create_main_window ();

		[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
	}
}


/* --------------------------------------------------------------------------
 *  fe_main — Start the event loop.
 * -------------------------------------------------------------------------- */
void
fe_main (void)
{
	@autoreleasepool
	{
		((HCAppDelegate *)appDelegate).glibTimer = [NSTimer
			scheduledTimerWithTimeInterval:0.01
			target:appDelegate
			selector:@selector(pumpGLib:)
			userInfo:nil
			repeats:YES];

		[NSApp activateIgnoringOtherApps:YES];
		[NSApp run];
	}
}


void
fe_cleanup (void)
{
	if (((HCAppDelegate *)appDelegate).glibTimer)
	{
		[((HCAppDelegate *)appDelegate).glibTimer invalidate];
		((HCAppDelegate *)appDelegate).glibTimer = nil;
	}
}

void
fe_exit (void)
{
	done = TRUE;
}


/* --- Timers and I/O --- */

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

void fe_timeout_remove (int tag) { g_source_remove (tag); }

int
fe_input_add (int sok, int flags, void *func, void *data)
{
	int tag, type = 0;
	GIOChannel *channel = g_io_channel_unix_new (sok);

	if (flags & FIA_READ)  type |= G_IO_IN | G_IO_HUP | G_IO_ERR;
	if (flags & FIA_WRITE) type |= G_IO_OUT | G_IO_ERR;
	if (flags & FIA_EX)    type |= G_IO_PRI;

	tag = g_io_add_watch (channel, type, (GIOFunc) func, data);
	g_io_channel_unref (channel);
	return tag;
}

void fe_input_remove (int tag) { g_source_remove (tag); }

void fe_idle_add (void *func, void *data) { g_idle_add (func, data); }


/* --------------------------------------------------------------------------
 *  fe_new_window — A new session was created.
 * -------------------------------------------------------------------------- */
void
fe_new_window (struct session *sess, int focus)
{
	session_gui *gui = g_new0 (session_gui, 1);
	sess->gui = gui;

	if (!sess->server->front_session)
		sess->server->front_session = sess;
	if (!sess->server->server_session)
		sess->server->server_session = sess;
	if (!current_tab || focus)
		current_tab = sess;

	@autoreleasepool
	{
		NSTextStorage *storage = [[NSTextStorage alloc] init];
		gui->text_storage = (void *)CFBridgingRetain (storage);

		NSMutableArray *users = [[NSMutableArray alloc] init];
		gui->user_list_data = (void *)CFBridgingRetain (users);

		refresh_channel_tree ();

		if (focus || !current_sess)
		{
			switch_to_session (sess);
		}
	}

	/* Show intro banner (once). */
	if (!done_intro)
	{
		done_intro = 1;
		char buf[512];
		g_snprintf (buf, sizeof (buf),
			"\n"
			" \017MacChat \00310" PACKAGE_VERSION "\n"
			" \017Running on \00310%s\n",
			get_sys_str (1));
		fe_print_text (sess, buf, 0, FALSE);
	}
}


void
fe_new_server (struct server *serv)
{
	serv->gui = g_new0 (server_gui, 1);
}


/* --------------------------------------------------------------------------
 *  FEATURE 1 — fe_print_text: mIRC color + formatting parser
 *
 *  This is the core of Feature 1. Instead of stripping formatting codes,
 *  we parse them into NSAttributedString spans with colors and styles.
 *
 *  mIRC formatting codes:
 *    \002       Toggle bold
 *    \003NN     Set foreground color to palette index NN
 *    \003NN,MM  Set foreground to NN, background to MM
 *    \003       Reset colors (no digits)
 *    \017       Reset ALL formatting (colors, bold, italic, etc.)
 *    \026       Toggle reverse (swap fg/bg)
 *    \035       Toggle italic
 *    \036       Toggle strikethrough
 *    \037       Toggle underline
 * -------------------------------------------------------------------------- */
void
fe_print_text (struct session *sess, char *text, time_t stamp,
               gboolean no_activity)
{
	NSTextStorage *storage = get_text_storage (sess);
	if (!storage || !text)
		return;

	@autoreleasepool
	{
		int len = strlen (text);
		NSMutableAttributedString *output =
			[[NSMutableAttributedString alloc] init];

		/* Current formatting state. */
		int fgColor = -1;       /* -1 = default (light grey)           */
		int bgColor = -1;       /* -1 = default (transparent)          */
		BOOL isBold = NO;
		BOOL isItalic = NO;
		BOOL isUnderline = NO;
		BOOL isStrikethrough = NO;
		BOOL isReverse = NO;

		/* Default colors for our dark background. */
		NSColor *defaultFg = [NSColor colorWithWhite:0.9 alpha:1.0];
		NSFont *regularFont = [NSFont monospacedSystemFontOfSize:12
			weight:NSFontWeightRegular];
		NSFont *boldFont = [NSFont monospacedSystemFontOfSize:12
			weight:NSFontWeightBold];

		/* Parse character by character. */
		char *clean = g_malloc (len + 1);  /* Buffer for current span text. */
		__block int cleanLen = 0;

		/* Helper: flush the current span with current formatting. */
		void (^flushSpan)(void) = ^{
			if (cleanLen == 0) return;
			clean[cleanLen] = '\0';

			NSString *nsStr = [NSString stringWithUTF8String:clean];
			if (!nsStr)
				nsStr = [[NSString alloc] initWithBytes:clean length:cleanLen
					encoding:NSISOLatin1StringEncoding];
			if (!nsStr) { cleanLen = 0; return; }

			/* Determine colors. */
			NSColor *fg, *bg;
			if (isReverse)
			{
				fg = (bgColor >= 0 && bgColor < 16)
					? mircColors[bgColor] : [NSColor colorWithWhite:0.1 alpha:1.0];
				bg = (fgColor >= 0 && fgColor < 16)
					? mircColors[fgColor] : defaultFg;
			}
			else
			{
				fg = (fgColor >= 0 && fgColor < 16)
					? mircColors[fgColor] : defaultFg;
				bg = (bgColor >= 0 && bgColor < 16)
					? mircColors[bgColor] : nil;
			}

			NSFont *font;
			if (isBold && isItalic)
			{
				/* Bold italic — get the bold font and apply italic trait. */
				NSFontDescriptor *desc = [boldFont fontDescriptor];
				desc = [desc fontDescriptorWithSymbolicTraits:
					NSFontDescriptorTraitBold | NSFontDescriptorTraitItalic];
				font = [NSFont fontWithDescriptor:desc size:12];
				if (!font) font = boldFont;
			}
			else if (isBold)
				font = boldFont;
			else if (isItalic)
			{
				NSFontDescriptor *desc = [regularFont fontDescriptor];
				desc = [desc fontDescriptorWithSymbolicTraits:
					NSFontDescriptorTraitItalic];
				font = [NSFont fontWithDescriptor:desc size:12];
				if (!font) font = regularFont;
			}
			else
				font = regularFont;

			NSMutableDictionary *attrs = [NSMutableDictionary dictionaryWithDictionary:@{
				NSForegroundColorAttributeName: fg,
				NSFontAttributeName: font,
			}];

			if (bg)
				attrs[NSBackgroundColorAttributeName] = bg;
			if (isUnderline)
				attrs[NSUnderlineStyleAttributeName] =
					@(NSUnderlineStyleSingle);
			if (isStrikethrough)
				attrs[NSStrikethroughStyleAttributeName] =
					@(NSUnderlineStyleSingle);

			NSAttributedString *span = [[NSAttributedString alloc]
				initWithString:nsStr attributes:attrs];
			[output appendAttributedString:span];

			cleanLen = 0;
		};

		int i = 0;
		while (i < len)
		{
			unsigned char ch = (unsigned char)text[i];
			switch (ch)
			{
			case '\002':  /* Bold toggle */
				flushSpan ();
				isBold = !isBold;
				i++;
				break;

			case '\003':  /* Color */
			{
				flushSpan ();
				i++;
				/* Parse optional foreground color (1-2 digits). */
				if (i < len && text[i] >= '0' && text[i] <= '9')
				{
					fgColor = text[i] - '0';
					i++;
					if (i < len && text[i] >= '0' && text[i] <= '9')
					{
						fgColor = fgColor * 10 + (text[i] - '0');
						i++;
					}
					fgColor %= 16;  /* Wrap to valid range. */

					/* Parse optional background color. */
					if (i < len && text[i] == ',')
					{
						i++;
						if (i < len && text[i] >= '0' && text[i] <= '9')
						{
							bgColor = text[i] - '0';
							i++;
							if (i < len && text[i] >= '0' && text[i] <= '9')
							{
								bgColor = bgColor * 10 + (text[i] - '0');
								i++;
							}
							bgColor %= 16;
						}
					}
				}
				else
				{
					/* \003 with no digits = reset colors. */
					fgColor = -1;
					bgColor = -1;
				}
				break;
			}

			case '\017':  /* Reset ALL formatting */
				flushSpan ();
				fgColor = -1;
				bgColor = -1;
				isBold = NO;
				isItalic = NO;
				isUnderline = NO;
				isStrikethrough = NO;
				isReverse = NO;
				i++;
				break;

			case '\026':  /* Reverse toggle */
				flushSpan ();
				isReverse = !isReverse;
				i++;
				break;

			case '\035':  /* Italic toggle */
				flushSpan ();
				isItalic = !isItalic;
				i++;
				break;

			case '\036':  /* Strikethrough toggle */
				flushSpan ();
				isStrikethrough = !isStrikethrough;
				i++;
				break;

			case '\037':  /* Underline toggle */
				flushSpan ();
				isUnderline = !isUnderline;
				i++;
				break;

			case '\010':  /* Backspace (legacy, skip) */
				i++;
				break;

			default:
				clean[cleanLen++] = text[i];
				i++;
				break;
			}
		}

		/* Flush any remaining text. */
		flushSpan ();
		g_free (clean);

		if ([output length] == 0)
			return;

		/* Append to the session's text storage (thread-safe). */
		dispatch_async (dispatch_get_main_queue (), ^{
			[storage beginEditing];
			[storage appendAttributedString:output];
			[storage endEditing];

			if (sess == current_sess && chatTextView)
			{
				NSRange endRange = NSMakeRange (
					[[storage string] length], 0);
				[chatTextView scrollRangeToVisible:endRange];
			}
		});
	}
}


/* --------------------------------------------------------------------------
 *  fe_close_window — Session closed.
 * -------------------------------------------------------------------------- */
void
fe_close_window (struct session *sess)
{
	if (sess->gui)
	{
		@autoreleasepool
		{
			if (sess->gui->text_storage)
				CFBridgingRelease (sess->gui->text_storage);
			if (sess->gui->user_list_data)
				CFBridgingRelease (sess->gui->user_list_data);
		}
		g_free (sess->gui->input_text);
		g_free (sess->gui->topic_text);
		g_free (sess->gui);
		sess->gui = NULL;
	}

	session_free (sess);

	dispatch_async (dispatch_get_main_queue (), ^{
		refresh_channel_tree ();
	});
}


/* --------------------------------------------------------------------------
 *  Feature 3: fe_set_topic — Update topic bar
 * -------------------------------------------------------------------------- */
void
fe_set_topic (struct session *sess, char *topic, char *stripped_topic)
{
	if (!stripped_topic) return;

	/* Save topic in session gui for later restore. */
	if (sess->gui)
	{
		g_free (sess->gui->topic_text);
		sess->gui->topic_text = g_strdup (stripped_topic);
	}

	if (sess == current_sess)
	{
		/* Copy strings before dispatching — originals may be freed. */
		NSString *topicStr = [NSString stringWithUTF8String:stripped_topic];
		if (!topicStr) topicStr = @"";
		NSString *chanStr = sess->channel[0]
			? [NSString stringWithUTF8String:sess->channel] : nil;

		dispatch_async (dispatch_get_main_queue (), ^{
			if (topicBar)
				[topicBar setStringValue:topicStr];

			/* Also update window title. */
			NSString *title;
			if (chanStr)
				title = [NSString stringWithFormat:@"%@ — %@",
					chanStr, topicStr];
			else
				title = topicStr;
			if (mainWindow)
				[mainWindow setTitle:title ?: @"MacChat"];
		});
	}
}


void
fe_set_title (struct session *sess)
{
	if (sess == current_sess && mainWindow)
	{
		NSString *t = sess->channel[0]
			? [NSString stringWithUTF8String:sess->channel]
			: @"MacChat";
		if (!t) t = @"MacChat";
		dispatch_async (dispatch_get_main_queue (), ^{
			[mainWindow setTitle:t];
		});
	}
}


void
fe_set_channel (struct session *sess)
{
	fe_set_title (sess);
	dispatch_async (dispatch_get_main_queue (), ^{
		refresh_channel_tree ();
	});
}


void fe_set_nick (struct server *serv, char *newnick) {}


void
fe_beep (session *sess)
{
	NSBeep ();
}


void
fe_open_url (const char *url)
{
	if (!url) return;
	@autoreleasepool
	{
		NSURL *nsurl = [NSURL URLWithString:
			[NSString stringWithUTF8String:url]];
		if (nsurl)
			[[NSWorkspace sharedWorkspace] openURL:nsurl];
	}
}


void
fe_ctrl_gui (session *sess, fe_gui_action action, int arg)
{
	switch (action)
	{
	case FE_GUI_FOCUS:
		switch_to_session (sess);
		if (mainWindow)
			dispatch_async (dispatch_get_main_queue (), ^{
				[mainWindow makeKeyAndOrderFront:nil];
			});
		break;
	case FE_GUI_HIDE:
		if (mainWindow)
			dispatch_async (dispatch_get_main_queue (), ^{
				[mainWindow orderOut:nil];
			});
		break;
	case FE_GUI_SHOW:
		if (mainWindow)
			dispatch_async (dispatch_get_main_queue (), ^{
				[mainWindow makeKeyAndOrderFront:nil];
			});
		break;
	case FE_GUI_ICONIFY:
		if (mainWindow)
			dispatch_async (dispatch_get_main_queue (), ^{
				[mainWindow miniaturize:nil];
			});
		break;
	default:
		break;
	}
}


int  fe_gui_info (session *sess, int info_type) { return -1; }
void *fe_gui_info_ptr (session *sess, int info_type) { return NULL; }

void fe_message (char *msg, int flags) { puts (msg); }


/* --- Input box --- */

char *
fe_get_inputbox_contents (struct session *sess)
{
	if (!inputField)
		return g_strdup ("");

	__block char *result = NULL;
	if ([NSThread isMainThread])
	{
		const char *t = [[inputField stringValue] UTF8String];
		result = g_strdup (t ? t : "");
	}
	else
	{
		dispatch_sync (dispatch_get_main_queue (), ^{
			const char *t = [[inputField stringValue] UTF8String];
			result = g_strdup (t ? t : "");
		});
	}
	return result;
}

int fe_get_inputbox_cursor (struct session *sess) { return 0; }

void
fe_set_inputbox_contents (struct session *sess, char *text)
{
	if (!inputField || !text) return;
	if (sess != current_sess) return;
	NSString *str = [NSString stringWithUTF8String:text];
	if (!str) str = @"";
	dispatch_async (dispatch_get_main_queue (), ^{
		[inputField setStringValue:str];
	});
}

void fe_set_inputbox_cursor (struct session *sess, int delta, int pos) {}


void
fe_flash_window (struct session *sess)
{
	dispatch_async (dispatch_get_main_queue (), ^{
		[NSApp requestUserAttention:NSInformationalRequest];
	});
}


void
fe_text_clear (struct session *sess, int lines)
{
	NSTextStorage *storage = get_text_storage (sess);
	if (!storage) return;
	dispatch_async (dispatch_get_main_queue (), ^{
		if (lines == 0)
			[storage setAttributedString:
				[[NSAttributedString alloc] initWithString:@""]];
	});
}


void
fe_confirm (const char *message, void (*yesproc)(void *),
            void (*noproc)(void *), void *ud)
{
	if (!message) return;
	NSString *msg = [NSString stringWithUTF8String:message];
	if (!msg) msg = @"Confirm?";
	dispatch_async (dispatch_get_main_queue (), ^{
		@autoreleasepool {
			NSAlert *alert = [[NSAlert alloc] init];
			[alert setMessageText:msg];
			[alert addButtonWithTitle:@"Yes"];
			[alert addButtonWithTitle:@"No"];
			if ([alert runModal] == NSAlertFirstButtonReturn)
			{
				if (yesproc) yesproc (ud);
			}
			else
			{
				if (noproc) noproc (ud);
			}
		}
	});
}


void
fe_get_file (const char *title, char *initial,
             void (*callback)(void *userdata, char *file), void *userdata,
             int flags)
{
	NSString *titleStr = title
		? [NSString stringWithUTF8String:title] : nil;
	dispatch_async (dispatch_get_main_queue (), ^{
		@autoreleasepool {
			if (flags & FRF_WRITE)
			{
				NSSavePanel *p = [NSSavePanel savePanel];
				if (titleStr) [p setTitle:titleStr];
				if ([p runModal] == NSModalResponseOK)
				{
					const char *path = [[[p URL] path] UTF8String];
					if (path && callback) callback (userdata, (char *)path);
				}
			}
			else
			{
				NSOpenPanel *p = [NSOpenPanel openPanel];
				if (titleStr) [p setTitle:titleStr];
				[p setAllowsMultipleSelection:(flags & FRF_MULTIPLE) ? YES : NO];
				[p setCanChooseDirectories:(flags & FRF_CHOOSEFOLDER) ? YES : NO];
				[p setCanChooseFiles:(flags & FRF_CHOOSEFOLDER) ? NO : YES];
				if ([p runModal] == NSModalResponseOK)
				{
					for (NSURL *url in [p URLs])
					{
						const char *path = [[url path] UTF8String];
						if (path && callback) callback (userdata, (char *)path);
					}
				}
			}
		}
	});
}


const char *fe_get_default_font (void) { return "Menlo 12"; }

void
fe_server_event (server *serv, int type, int arg)
{
	dispatch_async (dispatch_get_main_queue (), ^{
		refresh_channel_tree ();
	});
}

void fe_get_bool (char *title, char *prompt, void *callback, void *userdata) {}
void fe_get_str (char *prompt, char *def, void *callback, void *ud) {}
void fe_get_int (char *prompt, int def, void *callback, void *ud) {}


/* ==========================================================================
 *  USER LIST FUNCTIONS — Phase 3: badges + user count
 * ==========================================================================
 */

void
fe_userlist_insert (struct session *sess, struct User *newuser, gboolean sel)
{
	NSMutableArray *users = get_user_list_data (sess);
	if (!users || !newuser)
		return;

	@autoreleasepool
	{
		NSAttributedString *entry =
			make_user_list_entry (newuser->prefix[0], newuser->nick);
		if (entry)
			[users addObject:entry];

		if (sess == current_sess)
			dispatch_async (dispatch_get_main_queue (), ^{
				[userListTable reloadData];
				update_user_count_label ();
			});
	}
}


int
fe_userlist_remove (struct session *sess, struct User *user)
{
	NSMutableArray *users = get_user_list_data (sess);
	if (!users || !user)
		return 0;

	@autoreleasepool
	{
		NSString *target = [NSString stringWithUTF8String:user->nick];
		for (NSInteger i = (NSInteger)[users count] - 1; i >= 0; i--)
		{
			/* Each entry is an NSAttributedString. Check if it contains the nick. */
			NSAttributedString *entry = users[i];
			NSString *plainText = [entry string];
			/* The plain text is like "● nick" or "● nick" (invisible circle). */
			if ([plainText rangeOfString:target].location != NSNotFound)
			{
				[users removeObjectAtIndex:i];
				break;
			}
		}

		if (sess == current_sess)
			dispatch_async (dispatch_get_main_queue (), ^{
				[userListTable reloadData];
				update_user_count_label ();
			});
	}
	return 0;
}


void
fe_userlist_rehash (struct session *sess, struct User *user)
{
	rebuild_user_list_data (sess);
	if (sess == current_sess)
		dispatch_async (dispatch_get_main_queue (), ^{
			[userListTable reloadData];
			update_user_count_label ();
		});
}


void
fe_userlist_update (session *sess, struct User *user)
{
	fe_userlist_rehash (sess, user);
}


void
fe_userlist_numbers (struct session *sess)
{
	if (sess == current_sess)
		dispatch_async (dispatch_get_main_queue (), ^{
			[userListTable reloadData];
			update_user_count_label ();
		});
}


void
fe_userlist_clear (struct session *sess)
{
	NSMutableArray *users = get_user_list_data (sess);
	if (users)
		[users removeAllObjects];

	if (sess == current_sess)
		dispatch_async (dispatch_get_main_queue (), ^{
			[userListTable reloadData];
			update_user_count_label ();
		});
}


/* ==========================================================================
 *  DCC FUNCTIONS — Feature 6
 * ==========================================================================
 */

void
fe_dcc_add (struct DCC *dcc)
{
	if (!dcc) return;
	if (!dccTransfers)
		dccTransfers = [[NSMutableArray alloc] init];

	@autoreleasepool
	{
		[dccTransfers addObject:(__bridge id)(void *)dcc];
		if (dccTable)
			dispatch_async (dispatch_get_main_queue (), ^{
				[dccTable reloadData];
			});
	}
}

void
fe_dcc_update (struct DCC *dcc)
{
	if (dccTable)
		dispatch_async (dispatch_get_main_queue (), ^{
			[dccTable reloadData];
		});
}

void
fe_dcc_remove (struct DCC *dcc)
{
	if (!dcc || !dccTransfers) return;
	@autoreleasepool
	{
		/* Find and remove. */
		for (NSInteger i = (NSInteger)[dccTransfers count] - 1; i >= 0; i--)
		{
			struct DCC *d = (__bridge struct DCC *)(dccTransfers[i]);
			if (d == dcc)
			{
				[dccTransfers removeObjectAtIndex:i];
				break;
			}
		}
		if (dccTable)
			dispatch_async (dispatch_get_main_queue (), ^{
				[dccTable reloadData];
			});
	}
}

int
fe_dcc_open_recv_win (int passive)
{
	dispatch_async (dispatch_get_main_queue (), ^{
		show_dcc_panel ();
	});
	return TRUE;
}

int
fe_dcc_open_send_win (int passive)
{
	dispatch_async (dispatch_get_main_queue (), ^{
		show_dcc_panel ();
	});
	return TRUE;
}

int  fe_dcc_open_chat_win (int passive) { return FALSE; }

void
fe_dcc_send_filereq (struct session *sess, char *nick, int maxcps,
	int passive)
{
	if (!sess || !nick) return;
	dispatch_async (dispatch_get_main_queue (), ^{
		@autoreleasepool {
			NSOpenPanel *panel = [NSOpenPanel openPanel];
			[panel setTitle:@"Send File via DCC"];
			[panel setAllowsMultipleSelection:NO];
			if ([panel runModal] == NSModalResponseOK)
			{
				const char *path = [[[panel URL] path] UTF8String];
				if (path)
					dcc_send (sess, nick, (char *)path, maxcps, passive);
			}
		}
	});
}


/* ==========================================================================
 *  SERVER LIST FUNCTION — Feature 5
 * ==========================================================================
 */

void
fe_serverlist_open (session *sess)
{
	dispatch_async (dispatch_get_main_queue (), ^{
		show_server_list ();
	});
}


/* ==========================================================================
 *  REMAINING STUBS
 * ==========================================================================
 */

void fe_userlist_set_selected (struct session *sess) {}
void fe_uselect (struct session *sess, char *word[], int do_clear, int scroll_to) {}

int  fe_is_chanwindow (struct server *serv) { return 0; }
void fe_add_chan_list (struct server *serv, char *chan, char *users, char *topic) {}
void fe_chan_list_end (struct server *serv) {}
void fe_open_chan_list (server *serv, char *filter, int do_refresh)
	{ serv->p_list_channels (serv, filter, 1); }

gboolean fe_add_ban_list (struct session *sess, char *mask, char *who,
	char *when, int rplcode) { return 0; }
gboolean fe_ban_list_end (struct session *sess, int rplcode) { return 0; }

void fe_notify_update (char *name) {}
void fe_notify_ask (char *name, char *networks) {}

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
void fe_add_rawlog (struct server *serv, char *text, int len, int outbound) {}

void fe_session_callback (struct session *sess) {}
void fe_server_callback (struct server *serv) {}
void fe_url_add (const char *text) {}
void fe_pluginlist_update (void) {}
void fe_buttons_update (struct session *sess) {}
void fe_dlgbuttons_update (struct session *sess) {}
void fe_lastlog (session *sess, session *lastlog_sess, char *sstr,
	gtk_xtext_search_flags flags) {}
char *fe_menu_add (menu_entry *me) { return NULL; }
void  fe_menu_del (menu_entry *me) {}
void  fe_menu_update (menu_entry *me) {}
void fe_tray_set_flash (const char *filename1, const char *filename2,
	int timeout) {}
void fe_tray_set_file (const char *filename) {}
void fe_tray_set_icon (feicon icon) {}
void fe_tray_set_tooltip (const char *text) {}
void fe_change_nick (struct server *serv, char *nick, char *newnick) {}
void fe_userlist_hide (session *sess) {}
