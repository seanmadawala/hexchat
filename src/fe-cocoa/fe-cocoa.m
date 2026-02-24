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
	[mainWindow setTitle:@"HexChat"];
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

	/* Show the window. */
	[mainWindow makeKeyAndOrderFront:nil];
	[mainWindow makeFirstResponder:inputField];
}


/* ==========================================================================
 *  MENU BAR — Now includes Server List and DCC items
 * ==========================================================================
 */

/* Menu action targets — we need a class to receive selectors. */
@interface HCMenuTarget : NSObject
- (void)openServerList:(id)sender;
- (void)openDCCPanel:(id)sender;
@end

@implementation HCMenuTarget
- (void)openServerList:(id)sender { show_server_list (); }
- (void)openDCCPanel:(id)sender   { show_dcc_panel (); }
@end

static id menuTarget;

static void
create_menu_bar (void)
{
	menuTarget = [[HCMenuTarget alloc] init];

	NSMenu *menuBar = [[NSMenu alloc] init];

	/* --- App menu --- */
	NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
	[menuBar addItem:appMenuItem];
	NSMenu *appMenu = [[NSMenu alloc] init];
	[appMenu addItemWithTitle:@"Quit HexChat"
		action:@selector(terminate:) keyEquivalent:@"q"];
	[appMenuItem setSubmenu:appMenu];

	/* --- IRC menu --- */
	NSMenuItem *ircMenuItem = [[NSMenuItem alloc] init];
	[menuBar addItem:ircMenuItem];
	NSMenu *ircMenu = [[NSMenu alloc] initWithTitle:@"IRC"];

	NSMenuItem *srvItem = [[NSMenuItem alloc]
		initWithTitle:@"Server List..."
		action:@selector(openServerList:) keyEquivalent:@"s"];
	[srvItem setTarget:menuTarget];
	[ircMenu addItem:srvItem];

	NSMenuItem *dccItem = [[NSMenuItem alloc]
		initWithTitle:@"DCC Transfers..."
		action:@selector(openDCCPanel:) keyEquivalent:@"t"];
	[dccItem setTarget:menuTarget];
	[ircMenu addItem:dccItem];

	[ircMenuItem setSubmenu:ircMenu];

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
			: @"HexChat";
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
		NSRect frame = NSMakeRect (200, 150, 410, 530);
		serverListWindow = [[NSWindow alloc]
			initWithContentRect:frame
			styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
				| NSWindowStyleMaskResizable)
			backing:NSBackingStoreBuffered
			defer:NO];
		[serverListWindow setTitle:@"Network List - HexChat"];
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

	/* If no sessions exist at all (fresh launch, user closed dialog),
	   exit the application just like the GTK frontend. */
	if (sess_list == NULL)
		hexchat_exit ();
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
		NSString *title = [NSString stringWithFormat:@"Edit %s - HexChat",
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
			" \017HexChat-Cocoa \00310" PACKAGE_VERSION "\n"
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
				[mainWindow setTitle:title ?: @"HexChat"];
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
			: @"HexChat";
		if (!t) t = @"HexChat";
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
