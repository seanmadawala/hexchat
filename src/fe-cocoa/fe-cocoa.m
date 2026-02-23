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
static NSMutableArray *serverListNets;     /* Array of ircnet * (wrapped)     */
static id             serverListDataSource;

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
 *  FEATURE 5 — HCServerListDataSource
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

- (id)tableView:(NSTableView *)tableView
	objectValueForTableColumn:(NSTableColumn *)tableColumn
	row:(NSInteger)row
{
	if (!serverListNets || row < 0 || row >= (NSInteger)[serverListNets count])
		return @"";

	ircnet *net = [serverListNets[row] pointerValue];
	if (!net || !net->name) return @"???";
	return [NSString stringWithUTF8String:net->name];
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

		/* Build the network list from HexChat's global network_list. */
		serverListNets = [[NSMutableArray alloc] init];
		GSList *sl;
		for (sl = network_list; sl; sl = sl->next)
		{
			ircnet *net = sl->data;
			if (net)
				[serverListNets addObject:[NSValue valueWithPointer:net]];
		}

		/* Create the window. */
		NSRect frame = NSMakeRect (200, 200, 400, 500);
		serverListWindow = [[NSWindow alloc]
			initWithContentRect:frame
			styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
				| NSWindowStyleMaskResizable)
			backing:NSBackingStoreBuffered
			defer:NO];
		[serverListWindow setTitle:@"Server List"];
		[serverListWindow setMinSize:NSMakeSize(300, 300)];

		NSView *content = [serverListWindow contentView];
		NSRect bounds = [content bounds];

		/* Connect button (bottom). */
		NSButton *connectBtn = [[NSButton alloc]
			initWithFrame:NSMakeRect (bounds.size.width - 110, 10, 100, 32)];
		[connectBtn setTitle:@"Connect"];
		[connectBtn setBezelStyle:NSBezelStyleRounded];
		[connectBtn setTarget:menuTarget];
		[connectBtn setAction:@selector(connectFromServerList:)];
		[connectBtn setAutoresizingMask:
			(NSViewMinXMargin | NSViewMaxYMargin)];
		[content addSubview:connectBtn];

		/* Table view. */
		NSRect tableFrame = NSMakeRect (0, 50, bounds.size.width,
			bounds.size.height - 50);
		NSScrollView *scroll = [[NSScrollView alloc]
			initWithFrame:tableFrame];
		[scroll setHasVerticalScroller:YES];
		[scroll setAutoresizingMask:
			(NSViewWidthSizable | NSViewHeightSizable)];

		serverListTable = [[NSTableView alloc]
			initWithFrame:[[scroll contentView] bounds]];
		NSTableColumn *col = [[NSTableColumn alloc]
			initWithIdentifier:@"network"];
		[col setWidth:380];
		[col setTitle:@"Network"];
		[serverListTable addTableColumn:col];
		[serverListTable setHeaderView:nil];

		serverListDataSource = [[HCServerListDataSource alloc] init];
		[serverListTable setDataSource:
			(id<NSTableViewDataSource>)serverListDataSource];
		[serverListTable setDelegate:
			(id<NSTableViewDelegate>)serverListDataSource];
		[serverListTable setDoubleAction:@selector(connectFromServerList:)];
		[serverListTable setTarget:menuTarget];

		[scroll setDocumentView:serverListTable];
		[content addSubview:scroll];

		[serverListWindow makeKeyAndOrderFront:nil];
	}
}

/* Connect action for server list. */
@implementation HCMenuTarget (ServerList)
- (void)connectFromServerList:(id)sender
{
	NSInteger row = [serverListTable selectedRow];
	if (row < 0 || !serverListNets ||
		row >= (NSInteger)[serverListNets count])
		return;

	ircnet *net = [serverListNets[row] pointerValue];
	if (!net) return;

	/* Close the dialog. */
	[serverListWindow orderOut:nil];

	/* Connect using the first available session. */
	struct session *sess = current_sess;
	if (!sess && sess_list)
		sess = sess_list->data;
	if (sess)
		servlist_connect (sess, net, TRUE);
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
		dispatch_async (dispatch_get_main_queue (), ^{
			if (topicBar)
				[topicBar setStringValue:
					[NSString stringWithUTF8String:stripped_topic]];

			/* Also update window title. */
			NSString *title;
			if (sess->channel[0])
				title = [NSString stringWithFormat:@"%s — %s",
					sess->channel, stripped_topic];
			else
				title = [NSString stringWithUTF8String:stripped_topic];
			[mainWindow setTitle:title];
		});
	}
}


void
fe_set_title (struct session *sess)
{
	if (sess == current_sess && mainWindow)
	{
		dispatch_async (dispatch_get_main_queue (), ^{
			NSString *t = sess->channel[0]
				? [NSString stringWithUTF8String:sess->channel]
				: @"HexChat";
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
	dispatch_async (dispatch_get_main_queue (), ^{
		[inputField setStringValue:
			[NSString stringWithUTF8String:text]];
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
	dispatch_async (dispatch_get_main_queue (), ^{
		@autoreleasepool {
			NSAlert *alert = [[NSAlert alloc] init];
			[alert setMessageText:[NSString stringWithUTF8String:message]];
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
	dispatch_async (dispatch_get_main_queue (), ^{
		@autoreleasepool {
			if (flags & FRF_WRITE)
			{
				NSSavePanel *p = [NSSavePanel savePanel];
				if (title) [p setTitle:[NSString stringWithUTF8String:title]];
				if ([p runModal] == NSModalResponseOK)
				{
					const char *path = [[[p URL] path] UTF8String];
					if (path && callback) callback (userdata, (char *)path);
				}
			}
			else
			{
				NSOpenPanel *p = [NSOpenPanel openPanel];
				if (title) [p setTitle:[NSString stringWithUTF8String:title]];
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
