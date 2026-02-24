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
 *  Why is this header pure C?
 *
 *  This header gets #included by files in src/common/ — which are plain C.
 *  Plain C doesn't understand Objective-C types like NSWindow* or NSTextView*.
 *  So we use "void *" pointers here and cast them in the .m file.
 * ==========================================================================
 */

#ifndef HEXCHAT_FE_COCOA_H
#define HEXCHAT_FE_COCOA_H

#define DISPLAY_NAME "MacChat"

/*
 * ==========================================================================
 *  PHASE 2 ARCHITECTURE — Single Window with Three Columns
 * ==========================================================================
 *
 *  +----------+---------------------------+---------+
 *  | Server/  |                           | User    |
 *  | Channel  |   Chat text area          | List    |
 *  | Tree     |   (NSTextView — swaps     | (Table) |
 *  |          |    content per session)    |         |
 *  | libera   |                           | @op     |
 *  |  #chan1  |                           | +voice  |
 *  |  #chan2  |                           | nick1   |
 *  +----------+---------------------------+---------+
 *  | [input field                                 ] |
 *  +------------------------------------------------+
 *
 *  Key design:
 *  - ONE main window (global, shared by all sessions)
 *  - Each session has its OWN NSTextStorage (text buffer)
 *  - When you click a channel in the tree, we swap which
 *    NSTextStorage the text view displays
 *  - Each session has its OWN NSMutableArray of user nicks
 *  - When switching sessions, the user list table reloads
 *
 *  The global widgets (window, text view, split view, etc.) are NOT
 *  stored in session_gui — they live as globals in fe-cocoa.m.
 *  session_gui only stores per-session data.
 * ==========================================================================
 */

/*
 * Per-session GUI state. Each open channel/query/server tab has one.
 *
 * void * fields hold Objective-C objects:
 *   text_storage   -> NSTextStorage * (this session's chat text buffer)
 *   user_list_data -> NSMutableArray<NSString *> * (nick list for this session)
 */
typedef struct session_gui
{
	void *text_storage;    /* NSTextStorage — this session's text buffer       */
	void *user_list_data;  /* NSMutableArray — nicks in this channel           */

	char *input_text;      /* saved input text when this tab isn't focused     */
	char *topic_text;      /* saved topic text                                 */

	unsigned long marker_pos; /* character offset for marker line              */

} session_gui;

/*
 * Per-server GUI state.
 */
typedef struct server_gui
{
	void *rawlog_window;   /* NSWindow — raw IRC protocol viewer (future)      */

} server_gui;

#endif /* HEXCHAT_FE_COCOA_H */
