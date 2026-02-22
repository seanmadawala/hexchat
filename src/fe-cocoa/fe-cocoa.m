/* HexChat — Cocoa Frontend (Phase 2)
 * Copyright (C) 2026 Sean Madawala.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

/*
 * ==========================================================================
 *  PHASE 2: Single window with server/channel tree + user list
 *
 *  New Cocoa concepts introduced in this phase:
 *
 *  NSOutlineView — A hierarchical (tree) table view. Like NSTableView
 *    but rows can have children (expandable with disclosure triangles).
 *    Perfect for: server → channel1, channel2, ...
 *
 *  NSSplitView — A view that divides space into resizable panes.
 *    Like having movable dividers between panels. The user can drag
 *    the dividers to resize the tree, chat, and user list columns.
 *
 *  NSTextStorage — The "model" (data) behind an NSTextView. Think of
 *    it as a mutable attributed string that can be swapped in and out.
 *    Each session has its own NSTextStorage. When you click a channel
 *    in the tree, we tell the layout manager to use that session's
 *    text storage, and the text view instantly shows different content.
 *
 *  Data Source pattern — NSOutlineView and NSTableView don't store
 *    data themselves. Instead, they ask a "data source" object:
 *    "how many rows?" "what's in row 3?" This is like a callback
 *    system but object-oriented. We implement data source protocols.
 *
 *  Delegate pattern — Objects that handle events on behalf of others.
 *    NSOutlineViewDelegate handles "user clicked a row".
 *    NSTextFieldDelegate handles "user pressed Enter".
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

#include "fe-cocoa.h"


/* ==========================================================================
 *  FORWARD DECLARATIONS
 *
 *  We declare classes and functions here so they can reference each other.
 *  The full @implementation blocks come later in the file.
 * ==========================================================================
 */

static void create_main_window (void);
static void create_menu_bar (void);
static void switch_to_session (struct session *sess);
static void refresh_channel_tree (void);
static void refresh_user_list (void);

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
 *
 *  NSOutlineView needs Objective-C objects as "items" in the tree.
 *  We can't pass raw C pointers (struct server *, struct session *)
 *  directly because NSOutlineView retains items and compares them
 *  by object identity.
 *
 *  HCServerNode wraps a server — it's a top-level row in the tree.
 *  HCSessionNode wraps a session — it's a child row under a server.
 *
 *  We maintain a global NSMutableArray of HCServerNode objects.
 *  Each HCServerNode has an NSMutableArray of HCSessionNode children.
 * ==========================================================================
 */

@interface HCServerNode : NSObject
@property (assign, nonatomic) struct server *server;    /* C pointer, not retained */
@property (strong, nonatomic) NSString *name;           /* Display name */
@property (strong, nonatomic) NSMutableArray *children;  /* HCSessionNode objects */
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
 *  GLOBAL STATE — The single main window and its subviews
 * ==========================================================================
 */

static int done = FALSE;
static int done_intro = 0;

/* --- The one main window and its components --- */
static NSWindow      *mainWindow;       /* The single app window               */
static NSSplitView   *splitView;        /* 3-pane: tree | chat | users         */
static NSOutlineView *channelTree;      /* Left: server/channel tree           */
static NSScrollView  *channelTreeScroll;/* Wraps the outline view              */
static NSTextView    *chatTextView;     /* Center: chat text display           */
static NSScrollView  *chatScrollView;   /* Wraps the text view                 */
static NSTableView   *userListTable;    /* Right: user nick list               */
static NSScrollView  *userListScroll;   /* Wraps the table view                */
static NSTextField   *inputField;       /* Bottom: text input                  */

/* --- Data model for the channel tree --- */
static NSMutableArray *serverNodes;     /* Array of HCServerNode               */

/* --- Delegates (prevent deallocation) --- */
static id appDelegate;
static id inputDelegate;
static id treeDataSource;              /* Also serves as delegate              */
static id userListDataSource;          /* Also serves as delegate              */


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
	return YES;  /* Quit when the window closes. */
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
 *  HCInputDelegate — Handles Enter key in the input field
 * ==========================================================================
 */

@interface HCInputDelegate : NSObject <NSTextFieldDelegate>
@end

@implementation HCInputDelegate

- (BOOL)control:(NSControl *)control
	   textView:(NSTextView *)textView
doCommandBySelector:(SEL)commandSelector
{
	if (commandSelector == @selector(insertNewline:))
	{
		NSTextField *field = (NSTextField *)control;
		const char *text = [[field stringValue] UTF8String];

		if (text && text[0] != '\0' && current_sess)
		{
			handle_multiline (current_sess, (char *)text, TRUE, FALSE);
			[field setStringValue:@""];
		}
		return YES;
	}
	return NO;
}

@end


/* ==========================================================================
 *  HCChannelTreeDataSource — Data source + delegate for the left sidebar
 * ==========================================================================
 *
 *  COCOA LESSON: NSOutlineViewDataSource protocol
 *
 *  NSOutlineView asks us these questions to build the tree:
 *
 *  1. "How many children does this item have?"
 *     - If item == nil, return number of top-level items (servers)
 *     - If item is a server node, return number of its sessions
 *
 *  2. "What is child number N of this item?"
 *     - Return the HCServerNode or HCSessionNode at that index
 *
 *  3. "Is this item expandable?" (can it have children?)
 *     - Servers are expandable, sessions are not
 *
 *  4. "What should I display for this item?"
 *     - Return the name string
 *
 *  NSOutlineViewDelegate handles:
 *  5. "The user clicked/selected a row — what should happen?"
 *     - We switch to that session
 * ==========================================================================
 */

@interface HCChannelTreeDataSource : NSObject
	<NSOutlineViewDataSource, NSOutlineViewDelegate>
@end

@implementation HCChannelTreeDataSource

/* How many children does this item have? */
- (NSInteger)outlineView:(NSOutlineView *)outlineView
	numberOfChildrenOfItem:(id)item
{
	if (item == nil)
		return (NSInteger)[serverNodes count];  /* Top-level: servers */

	if ([item isKindOfClass:[HCServerNode class]])
		return (NSInteger)[((HCServerNode *)item).children count];

	return 0;  /* Sessions have no children */
}

/* Return child at index. */
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

/* Is this item expandable? */
- (BOOL)outlineView:(NSOutlineView *)outlineView
	isItemExpandable:(id)item
{
	return [item isKindOfClass:[HCServerNode class]];
}

/*
 * What to display for this item?
 *
 * COCOA LESSON: NSTableColumn + objectValue
 *
 * NSOutlineView (and NSTableView) use "cell-based" or "view-based" mode.
 * In cell-based mode (simpler), each cell asks for an "objectValue" —
 * typically an NSString — and displays it as text.
 */
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

/*
 * User selected a row — switch to that session.
 *
 * COCOA LESSON: outlineViewSelectionDidChange:
 *
 * This delegate method is called AFTER the selection changes.
 * We figure out which item was selected and switch to it.
 */
- (void)outlineViewSelectionDidChange:(NSNotification *)notification
{
	NSInteger row = [channelTree selectedRow];
	if (row < 0)
		return;

	id item = [channelTree itemAtRow:row];

	if ([item isKindOfClass:[HCSessionNode class]])
	{
		struct session *sess = ((HCSessionNode *)item).session;
		if (sess)
			switch_to_session (sess);
	}
	else if ([item isKindOfClass:[HCServerNode class]])
	{
		/* Clicked a server row — switch to the server session. */
		struct server *serv = ((HCServerNode *)item).server;
		if (serv && serv->server_session)
			switch_to_session (serv->server_session);
	}
}

@end


/* ==========================================================================
 *  HCUserListDataSource — Data source + delegate for the right sidebar
 * ==========================================================================
 *
 *  Much simpler than the tree — it's a flat list of nicks.
 *  We ask the current session's user_list_data (NSMutableArray) for
 *  the number of rows and the string at each row.
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

	return users[row];
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
	 * LAYOUT: We use a simple autoresizing approach.
	 *
	 * The NSSplitView fills the top portion (all except 30px for input).
	 * The NSTextField sits at the bottom.
	 *
	 *   +------+------------------+------+
	 *   | tree | chat scroll view | user |  <- NSSplitView (3 subviews)
	 *   |      |                  | list |
	 *   +------+------------------+------+
	 *   | input field                    |  <- NSTextField (fixed height)
	 *   +--------------------------------+
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

	/*
	 * COCOA LESSON: NSSplitView
	 *
	 * NSSplitView arranges its subviews side by side (horizontal) or
	 * stacked (vertical). isVertical=YES means columns (left-to-right).
	 *
	 * You add subviews in order: first = leftmost, last = rightmost.
	 * The user can drag the dividers to resize columns.
	 */
	splitView = [[NSSplitView alloc] initWithFrame:splitFrame];
	[splitView setVertical:YES];          /* Columns, not rows.               */
	[splitView setDividerStyle:NSSplitViewDividerStyleThin];
	[splitView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

	/* --- LEFT PANE: Channel tree (NSOutlineView in NSScrollView) --- */
	NSRect treeFrame = NSMakeRect (0, 0, 180, splitFrame.size.height);
	channelTreeScroll = [[NSScrollView alloc] initWithFrame:treeFrame];
	[channelTreeScroll setHasVerticalScroller:YES];
	[channelTreeScroll setHasHorizontalScroller:NO];
	[channelTreeScroll setAutoresizingMask:
		(NSViewWidthSizable | NSViewHeightSizable)];

	/*
	 * COCOA LESSON: NSOutlineView
	 *
	 * NSOutlineView is a subclass of NSTableView that supports
	 * hierarchical (tree) data. It shows disclosure triangles (▶/▼)
	 * to expand/collapse parent rows.
	 *
	 * It needs at least one NSTableColumn to display text.
	 * outlineTableColumn is the special column that shows the
	 * disclosure triangles + indentation for child rows.
	 */
	channelTree = [[NSOutlineView alloc] initWithFrame:
		[[channelTreeScroll contentView] bounds]];

	NSTableColumn *treeCol = [[NSTableColumn alloc]
		initWithIdentifier:@"channels"];
	[treeCol setWidth:170];
	[treeCol setTitle:@"Channels"];
	[channelTree addTableColumn:treeCol];
	[channelTree setOutlineTableColumn:treeCol];

	/* Style: no header, source-list style (macOS sidebar look). */
	[channelTree setHeaderView:nil];

	[channelTree setDataSource:(id<NSOutlineViewDataSource>)treeDataSource];
	[channelTree setDelegate:(id<NSOutlineViewDelegate>)treeDataSource];

	[channelTreeScroll setDocumentView:channelTree];

	/* --- CENTER PANE: Chat text view --- */
	NSRect chatFrame = NSMakeRect (0, 0, 580, splitFrame.size.height);
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

	/* Make text wrap to the view width. */
	[chatTextView setMaxSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
	[chatTextView setMinSize:NSMakeSize(0, chatFrame.size.height)];
	[chatTextView setAutoresizingMask:NSViewWidthSizable];
	[[chatTextView textContainer] setWidthTracksTextView:YES];

	[chatScrollView setDocumentView:chatTextView];

	/* --- RIGHT PANE: User list (NSTableView in NSScrollView) --- */
	NSRect userFrame = NSMakeRect (0, 0, 140, splitFrame.size.height);
	userListScroll = [[NSScrollView alloc] initWithFrame:userFrame];
	[userListScroll setHasVerticalScroller:YES];
	[userListScroll setHasHorizontalScroller:NO];
	[userListScroll setAutoresizingMask:
		(NSViewWidthSizable | NSViewHeightSizable)];

	/*
	 * COCOA LESSON: NSTableView
	 *
	 * A flat table (not hierarchical like NSOutlineView).
	 * Perfect for a simple list of nicks.
	 *
	 * Like NSOutlineView, it uses a data source to ask
	 * "how many rows?" and "what's in row N?"
	 */
	userListTable = [[NSTableView alloc] initWithFrame:
		[[userListScroll contentView] bounds]];

	NSTableColumn *userCol = [[NSTableColumn alloc]
		initWithIdentifier:@"nicks"];
	[userCol setWidth:130];
	[userCol setTitle:@"Users"];
	[userListTable addTableColumn:userCol];

	[userListTable setHeaderView:nil];  /* No header row. */

	[userListTable setDataSource:
		(id<NSTableViewDataSource>)userListDataSource];
	[userListTable setDelegate:
		(id<NSTableViewDelegate>)userListDataSource];

	[userListScroll setDocumentView:userListTable];

	/* --- Assemble the split view (order = left, center, right) --- */
	[splitView addSubview:channelTreeScroll];
	[splitView addSubview:chatScrollView];
	[splitView addSubview:userListScroll];

	[content addSubview:splitView];

	/*
	 * Set initial divider positions.
	 *
	 * setPosition:ofDividerAtIndex: sets where a divider sits.
	 * Divider 0 = between pane 0 and pane 1 (tree | chat)
	 * Divider 1 = between pane 1 and pane 2 (chat | users)
	 *
	 * IMPORTANT: We call adjustSubviews first, then set positions
	 * AFTER adding the split view to the window. This ensures
	 * the split view knows its own size and can lay out properly.
	 */
	[splitView adjustSubviews];
	[splitView setPosition:180 ofDividerAtIndex:0];
	[splitView setPosition:(bounds.size.width - 150) ofDividerAtIndex:1];

	/* Show the window. */
	[mainWindow makeKeyAndOrderFront:nil];
	[mainWindow makeFirstResponder:inputField];
}


/* ==========================================================================
 *  MENU BAR
 * ==========================================================================
 */

static void
create_menu_bar (void)
{
	NSMenu *menuBar = [[NSMenu alloc] init];
	NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
	[menuBar addItem:appMenuItem];

	NSMenu *appMenu = [[NSMenu alloc] init];
	NSMenuItem *quitItem = [[NSMenuItem alloc]
		initWithTitle:@"Quit HexChat"
		action:@selector(terminate:)
		keyEquivalent:@"q"];
	[appMenu addItem:quitItem];
	[appMenuItem setSubmenu:appMenu];

	[NSApp setMainMenu:menuBar];
}


/* ==========================================================================
 *  SESSION SWITCHING — The core of the single-window architecture
 * ==========================================================================
 *
 *  When the user clicks a channel in the tree, we:
 *  1. Save the current input text (if any)
 *  2. Swap the text view's text storage to the new session's buffer
 *  3. Reload the user list table
 *  4. Update current_sess and window title
 *  5. Restore the new session's input text
 *  6. Scroll chat to the bottom
 * ==========================================================================
 */

static void
switch_to_session (struct session *sess)
{
	if (!sess || !sess->gui || sess == current_sess)
		return;

	@autoreleasepool
	{
		/* Step 1: Save current session's input text. */
		if (current_sess && current_sess->gui)
		{
			const char *curText = [[inputField stringValue] UTF8String];
			g_free (current_sess->gui->input_text);
			current_sess->gui->input_text = g_strdup (curText ? curText : "");
		}

		/* Step 2: Update HexChat's session pointers. */
		current_sess = sess;
		current_tab = sess;
		if (sess->server)
			sess->server->front_session = sess;

		/*
		 * Step 3: Swap the text storage.
		 *
		 * COCOA LESSON: NSLayoutManager + replaceTextStorage
		 *
		 * NSTextView displays text via a chain:
		 *   NSTextStorage → NSLayoutManager → NSTextContainer → NSTextView
		 *
		 * NSTextStorage holds the actual text data.
		 * NSLayoutManager turns text into positioned glyphs.
		 * NSTextContainer defines the region where text is laid out.
		 * NSTextView renders everything on screen.
		 *
		 * To show different text, we swap the NSTextStorage.
		 * The layout manager re-lays out from the new storage,
		 * and the text view instantly shows different content.
		 */
		NSTextStorage *storage = get_text_storage (sess);
		if (storage && chatTextView)
		{
			[[chatTextView layoutManager] replaceTextStorage:storage];

			/* Scroll to the bottom. */
			NSRange endRange = NSMakeRange ([[storage string] length], 0);
			[chatTextView scrollRangeToVisible:endRange];
		}

		/* Step 4: Reload the user list for this session. */
		[userListTable reloadData];

		/* Step 5: Update window title. */
		NSString *title;
		if (sess->channel[0])
			title = [NSString stringWithUTF8String:sess->channel];
		else
			title = @"HexChat";
		[mainWindow setTitle:title];

		/* Step 6: Restore this session's saved input text. */
		if (sess->gui->input_text)
			[inputField setStringValue:
				[NSString stringWithUTF8String:sess->gui->input_text]];
		else
			[inputField setStringValue:@""];
	}
}


/* ==========================================================================
 *  CHANNEL TREE REFRESH — Rebuild the tree data from HexChat's sess_list
 * ==========================================================================
 *
 *  We iterate through HexChat's global session list, group sessions by
 *  server, and build HCServerNode/HCSessionNode objects.
 * ==========================================================================
 */

static void
refresh_channel_tree (void)
{
	@autoreleasepool
	{
		[serverNodes removeAllObjects];

		/* Walk the global session list. */
		GSList *slist;
		for (slist = sess_list; slist; slist = slist->next)
		{
			struct session *sess = slist->data;
			if (!sess || !sess->server)
				continue;

			/* Find or create the server node. */
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

			/* Add this session as a child. */
			HCSessionNode *sessNode = [[HCSessionNode alloc]
				initWithSession:sess];
			[srvNode.children addObject:sessNode];
		}

		/* Reload and expand. */
		[channelTree reloadData];
		[channelTree expandItem:nil expandChildren:YES];

		/*
		 * Select the current session in the tree so the user
		 * can see which channel is active.
		 */
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
 *  USER LIST REFRESH — Rebuild the user array from HexChat's user tree
 * ==========================================================================
 */

static void
refresh_user_list (void)
{
	[userListTable reloadData];
}

/*
 * Rebuild the NSMutableArray from the session's usertree.
 *
 * HexChat stores users in a balanced binary tree (tree *).
 * We need to flatten it into our NSMutableArray.
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

		/* Walk the user tree. tree_foreach calls our callback for each user. */
		tree *ut = sess->usertree;
		if (ut)
		{
			/*
			 * tree_foreach isn't available in all builds, so we use
			 * the userlist count and just show the count in the title.
			 * For the actual list, we iterate with tree_foreach.
			 */
			GList *list = userlist_double_list (sess);
			GList *iter;
			for (iter = list; iter; iter = iter->next)
			{
				struct User *user = iter->data;
				if (user)
				{
					NSString *nick;
					if (user->prefix[0])
						nick = [NSString stringWithFormat:@"%c%s",
							user->prefix[0], user->nick];
					else
						nick = [NSString stringWithUTF8String:user->nick];
					if (nick)
						[users addObject:nick];
				}
			}
			g_list_free (list);
		}
	}
}


/* ==========================================================================
 *
 *                  THE fe_* FUNCTIONS — HexChat Frontend API
 *
 * ==========================================================================
 */

/* --- Command-line arguments (same as Phase 1) --- */

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
	prefs.hex_gui_slist_skip = 1;

	@autoreleasepool
	{
		[NSApplication sharedApplication];

		appDelegate = [[HCAppDelegate alloc] init];
		[NSApp setDelegate:appDelegate];

		inputDelegate = [[HCInputDelegate alloc] init];
		treeDataSource = [[HCChannelTreeDataSource alloc] init];
		userListDataSource = [[HCUserListDataSource alloc] init];

		serverNodes = [[NSMutableArray alloc] init];

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


/* --- Timers and I/O (unchanged from Phase 1) --- */

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
 *
 *  Phase 2: We no longer create a new window. Instead:
 *  1. Allocate session_gui with its own NSTextStorage + user array
 *  2. Add the session to the channel tree
 *  3. If focused, switch to it
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
		/*
		 * Create this session's text storage (its own chat buffer).
		 *
		 * NSTextStorage is a subclass of NSMutableAttributedString.
		 * Each session gets its own so text is preserved when switching.
		 */
		NSTextStorage *storage = [[NSTextStorage alloc] init];
		gui->text_storage = (void *)CFBridgingRetain (storage);

		/* Create the user list array. */
		NSMutableArray *users = [[NSMutableArray alloc] init];
		gui->user_list_data = (void *)CFBridgingRetain (users);

		/* Refresh the channel tree to include this new session. */
		refresh_channel_tree ();

		/*
		 * If this should be focused (or it's the first session), switch.
		 *
		 * BUG FIX: Do NOT set current_sess before calling switch_to_session!
		 * switch_to_session() has an early-return check:
		 *   if (sess == current_sess) return;
		 * Setting current_sess first made it skip all the setup —
		 * the text storage was never connected to the text view,
		 * so text went into the buffer but was invisible.
		 */
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
 *  fe_print_text — Append text to the session's text storage.
 *
 *  Phase 2 change: We write to the session's OWN text storage,
 *  not directly to the text view. If this session is currently
 *  visible, the change appears immediately (because the layout
 *  manager is connected to this storage). If not, the text is
 *  buffered and appears when the user switches to this session.
 * -------------------------------------------------------------------------- */
void
fe_print_text (struct session *sess, char *text, time_t stamp,
               gboolean no_activity)
{
	NSTextStorage *storage = get_text_storage (sess);
	if (!storage)
		return;

	@autoreleasepool
	{
		/* Strip mIRC formatting codes. */
		int len = strlen (text);
		char *clean = g_malloc (len + 1);
		int i = 0, j = 0;

		while (i < len)
		{
			switch (text[i])
			{
			case '\003':
				i++;
				if (i < len && text[i] >= '0' && text[i] <= '9') i++;
				if (i < len && text[i] >= '0' && text[i] <= '9') i++;
				if (i < len && text[i] == ',')
				{
					i++;
					if (i < len && text[i] >= '0' && text[i] <= '9') i++;
					if (i < len && text[i] >= '0' && text[i] <= '9') i++;
				}
				continue;
			case '\002': case '\017': case '\026':
			case '\037': case '\010':
				break;
			default:
				clean[j++] = text[i];
				break;
			}
			i++;
		}
		clean[j] = '\0';

		NSString *nsText = [NSString stringWithUTF8String:clean];
		if (!nsText)
			nsText = [[NSString alloc] initWithBytes:clean length:j
				encoding:NSISOLatin1StringEncoding];
		g_free (clean);
		if (!nsText) return;

		NSDictionary *attrs = @{
			NSForegroundColorAttributeName:
				[NSColor colorWithWhite:0.9 alpha:1.0],
			NSFontAttributeName:
				[NSFont monospacedSystemFontOfSize:12
					weight:NSFontWeightRegular],
		};

		NSAttributedString *attrText = [[NSAttributedString alloc]
			initWithString:nsText attributes:attrs];

		dispatch_async (dispatch_get_main_queue (), ^{
			[storage beginEditing];
			[storage appendAttributedString:attrText];
			[storage endEditing];

			/* If this is the visible session, scroll to bottom. */
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
 *  fe_close_window — Session closed. Remove from tree, free resources.
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

	/* Refresh tree after removal. */
	dispatch_async (dispatch_get_main_queue (), ^{
		refresh_channel_tree ();
	});
}


/* --------------------------------------------------------------------------
 *  fe_set_topic — Channel topic changed.
 * -------------------------------------------------------------------------- */
void
fe_set_topic (struct session *sess, char *topic, char *stripped_topic)
{
	if (sess == current_sess && mainWindow && stripped_topic)
	{
		dispatch_async (dispatch_get_main_queue (), ^{
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
	/* Also refresh the tree so the channel name updates. */
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
	if (sess != current_sess) return;  /* Only update if visible. */
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
	/* Refresh tree when server connects (name becomes available). */
	dispatch_async (dispatch_get_main_queue (), ^{
		refresh_channel_tree ();
	});
}

void fe_get_bool (char *title, char *prompt, void *callback, void *userdata) {}
void fe_get_str (char *prompt, char *def, void *callback, void *ud) {}
void fe_get_int (char *prompt, int def, void *callback, void *ud) {}


/* ==========================================================================
 *  USER LIST FUNCTIONS — Phase 2 implementations
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
		NSString *nick;
		if (newuser->prefix[0])
			nick = [NSString stringWithFormat:@"%c%s",
				newuser->prefix[0], newuser->nick];
		else
			nick = [NSString stringWithUTF8String:newuser->nick];

		if (nick)
			[users addObject:nick];

		if (sess == current_sess)
			dispatch_async (dispatch_get_main_queue (), ^{
				[userListTable reloadData];
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
		/* Find and remove the nick. */
		NSString *target = [NSString stringWithUTF8String:user->nick];
		for (NSInteger i = (NSInteger)[users count] - 1; i >= 0; i--)
		{
			NSString *entry = users[i];
			/* Entry might have a prefix char, so check if it ends with the nick. */
			if ([entry isEqualToString:target] ||
				([entry length] > 0 && [[entry substringFromIndex:1] isEqualToString:target]))
			{
				[users removeObjectAtIndex:i];
				break;
			}
		}

		if (sess == current_sess)
			dispatch_async (dispatch_get_main_queue (), ^{
				[userListTable reloadData];
			});
	}
	return 0;
}


void
fe_userlist_rehash (struct session *sess, struct User *user)
{
	/* Rebuild the entire list (prefix may have changed). */
	rebuild_user_list_data (sess);
	if (sess == current_sess)
		dispatch_async (dispatch_get_main_queue (), ^{
			[userListTable reloadData];
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
	/* Could update a "N users" label. For now, just refresh. */
	if (sess == current_sess)
		dispatch_async (dispatch_get_main_queue (), ^{
			[userListTable reloadData];
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

void fe_dcc_add (struct DCC *dcc) {}
void fe_dcc_update (struct DCC *dcc) {}
void fe_dcc_remove (struct DCC *dcc) {}
int  fe_dcc_open_recv_win (int passive) { return FALSE; }
int  fe_dcc_open_send_win (int passive) { return FALSE; }
int  fe_dcc_open_chat_win (int passive) { return FALSE; }
void fe_dcc_send_filereq (struct session *sess, char *nick, int maxcps,
	int passive) {}

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
void fe_serverlist_open (session *sess) {}
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
