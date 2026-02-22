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
 *  OBJECTIVE-C LESSON: Why is this header pure C?
 * ==========================================================================
 *
 *  This header gets #included by files in src/common/ — which are plain C.
 *  Plain C doesn't understand Objective-C types like NSWindow* or NSTextView*.
 *
 *  So we use "void *" (a generic pointer, just like in C) to represent
 *  Cocoa objects here. In our .m file (Objective-C), we'll cast them back:
 *
 *      NSWindow *window = (__bridge NSWindow *)sess->gui->window;
 *
 *  This is a common pattern when mixing C and Objective-C in the same project.
 *
 *  Files that end in:
 *    .c   = plain C           (no Objective-C allowed)
 *    .m   = Objective-C       (C + objects)  <-- we use this
 *    .mm  = Objective-C++     (C++ + objects)
 * ==========================================================================
 */

#ifndef HEXCHAT_FE_COCOA_H
#define HEXCHAT_FE_COCOA_H

#define DISPLAY_NAME "HexChat"

/*
 * ==========================================================================
 *  DATA STRUCTURES — one per chat tab, one per server
 * ==========================================================================
 *
 *  HexChat's backend (src/common/) has two key structs:
 *
 *    struct session  — represents one chat tab (a channel, query, or server tab)
 *    struct server   — represents one IRC server connection
 *
 *  Each of these has a "gui" pointer that points to OUR frontend data.
 *  The backend never looks inside — it just passes it back to us.
 *
 *  In the GTK frontend, session_gui has ~30 GtkWidget pointers.
 *  For now, we keep it simple: just the essentials to get text on screen.
 * ==========================================================================
 */

/*
 * Per-tab GUI state. One of these exists for every open chat tab/window.
 *
 * The "void *" fields will actually hold Objective-C objects:
 *   - void *window      ->  NSWindow *       (the macOS window)
 *   - void *text_view   ->  NSTextView *     (the big scrollable text area)
 *   - void *input_field ->  NSTextField *    (the one-line input box at bottom)
 *   - void *user_list   ->  NSTableView *   (the user list on the right side)
 *   - void *topic_bar   ->  NSTextField *    (shows channel topic at top)
 */
typedef struct session_gui
{
	void *window;         /* NSWindow     — the macOS window for this tab     */
	void *text_view;      /* NSTextView   — where IRC messages appear         */
	void *scroll_view;    /* NSScrollView — wraps text_view for scrolling     */
	void *input_field;    /* NSTextField  — where user types commands/messages */
	void *user_list;      /* NSTableView  — nick list on the right (future)   */
	void *topic_bar;      /* NSTextField  — channel topic at top (future)     */
	void *nick_label;     /* NSTextField  — shows your current nick (future)  */

	/* Non-Cocoa fields: */
	char *input_text;     /* saved input text when this tab isn't focused     */
	char *topic_text;     /* saved topic text when this tab isn't focused     */

} session_gui;

/*
 * Per-server GUI state. One of these exists for every IRC server connection.
 * Mostly empty for now — we'll add rawlog window etc. later.
 */
typedef struct server_gui
{
	void *rawlog_window;  /* NSWindow  — raw IRC protocol viewer (future)     */

} server_gui;

#endif /* HEXCHAT_FE_COCOA_H */
