/* -*- mode: c++ ; coding: utf-8-unix -*- */
/*	last updated : 2013/09/23.19:38:48 */

/*
 * Copyright (c) 2013 yaruopooner [https://github.com/yaruopooner]
 *
 * This file is part of ac-clang.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */


/*================================================================================================*/
/*  Comment                                                                                       */
/*================================================================================================*/


/*================================================================================================*/
/*  Include Files                                                                                 */
/*================================================================================================*/

#include "ClangServer.hpp"


using	namespace	std;
// using	namespace	tr1;
using	namespace	std::tr1;


/*================================================================================================*/
/*  Global Class Method Definitions Section                                                       */
/*================================================================================================*/


/*

   ---- SERVER MESSAGE ---- 

   - SET_CLANG_PARAMETERS: setup libclang behavior parameters
     Message format:
        command_type:Server
		command_name:SET_CLANG_PARAMETERS
        translation_unit_flags:[#flag_name0|flag_name1|...#]
        complete_at_flags:[#flag_name0|flag_name1|...#]

   - CREATE_SESSION: create session.
     Message format:
        command_type:Server
		command_name:CREATE_SESSION
        session_name::[#session_name#]

   - DELETE_SESSION: delete session.
     Message format:
        command_type:Server
		command_name:DELETE_SESSION
        session_name::[#session_name#]

   - SHUTDOWN: shutdown the clang server (this program)
     Message format:
        command_type:Server
		command_name:SHUTDOWN


   ---- SESSION MESSAGE ----

   - SUSPEND: delete CXTranslationUnit
     Message format: 
        command_type:Session
		command_name:SUSPEND
        session_name:[#session_name#]
	 
   - RESUME: realloc CXTranslationUnit
     Message format: 
        command_type:Session
		command_name:RESUME
        session_name:[#session_name#]
	 
   - SET_CFLAGS: Specify CFLAGS argument passing to clang parser.
     Message format:
        command_type:Session
		command_name:SET_CFLAGS
        session_name:[#session_name#]
        num_cflags:[#num_cflags#]
            arg1 arg2 ...... (there should be num_cflags items here)
            CFLAGS's white space must be accept.
            a separator is '\n'.
		source_length:[#source_length#]
        <# SOURCE CODE #>

   - SET_SOURCECODE: Update the source code in the source buffer
     Message format:
        command_type:Session
		command_name:SET_SOURCECODE
        session_name:[#session_name#]
        source_length:[#source_length#]
        <# SOURCE CODE #>

   - REPARSE: Reparse the source code
        command_type:Session
		command_name:REPARSE
        session_name:[#session_name#]

   - COMPLETION: Do code completion at a specified point.
     Message format: 
        command_type:Session
		command_name:COMPLETION
        session_name:[#session_name#]
        line:[#line#]
        column:[#column#]
        source_length:[#source_length#]
        <# SOURCE CODE #>

   - SYNTAXCHECK: Retrieve diagnostic messages
     Message format:
        command_type:Session
		command_name:SYNTAXCHECK
        session_name:[#session_name#]
        source_length:[#source_length#]
        <# SOURCE CODE #>

   - DECLARATION: Get location of declaration at point 
     Message format: 
        command_type:Session
		command_name:DECLARATION
        session_name:[#session_name#]
        line:[#line#]
        column:[#column#]
        source_length:[#source_length#]
        <# SOURCE CODE #>

   - DEFINITION: Get location of definition at point 
     Message format: 
        command_type:Session
		command_name:DEFINITION
        session_name:[#session_name#]
        line:[#line#]
        column:[#column#]
        source_length:[#source_length#]
        <# SOURCE CODE #>

   - SMARTJUMP: Get location of definition at point.  If that fails, get the declaration. 
     Message format: 
        command_type:Session
		command_name:SMARTJUMP
        session_name:[#session_name#]
        line:[#line#]
        column:[#column#]
        source_length:[#source_length#]
        <# SOURCE CODE #>


*/




ClangServer::ClangServer( void )
	:
	m_Status( kStatus_Running )
{
	// server command
	m_ServerCommands.insert( ServerHandleMap::value_type( "SET_CLANG_PARAMETERS", &ClangServer::commandSetClangParameters ) );
	m_ServerCommands.insert( ServerHandleMap::value_type( "CREATE_SESSION", &ClangServer::commandCreateSession ) );
	m_ServerCommands.insert( ServerHandleMap::value_type( "DELETE_SESSION", &ClangServer::commandDeleteSession ) );
	m_ServerCommands.insert( ServerHandleMap::value_type( "SHUTDOWN", &ClangServer::commandShutdown ) );

	// session command
	m_SessionCommands.insert( SessionHandleMap::value_type( "SUSPEND", &ClangSession::commandSuspend ) );
	m_SessionCommands.insert( SessionHandleMap::value_type( "RESUME", &ClangSession::commandResume ) );
	m_SessionCommands.insert( SessionHandleMap::value_type( "SET_CFLAGS", &ClangSession::commandSetCFlags ) );
	m_SessionCommands.insert( SessionHandleMap::value_type( "SET_SOURCECODE", &ClangSession::commandSetSourceCode ) );
	m_SessionCommands.insert( SessionHandleMap::value_type( "REPARSE", &ClangSession::commandReparse ) );
	m_SessionCommands.insert( SessionHandleMap::value_type( "COMPLETION", &ClangSession::commandCompletion ) );
	m_SessionCommands.insert( SessionHandleMap::value_type( "SYNTAXCHECK", &ClangSession::commandSyntaxCheck ) );
	m_SessionCommands.insert( SessionHandleMap::value_type( "DECLARATION", &ClangSession::commandDeclaration ) );
	m_SessionCommands.insert( SessionHandleMap::value_type( "DEFINITION", &ClangSession::commandDefinition ) );
	m_SessionCommands.insert( SessionHandleMap::value_type( "SMARTJUMP", &ClangSession::commandSmartJump ) );
}

ClangServer::~ClangServer( void )
{
	// m_Sessions must be destruction early than m_Context.
	// Because m_Sessions depend to m_Context.
	m_Sessions.clear();
}


void	ClangServer::commandSetClangParameters( void )
{
	const string		translation_unit_flags		 = m_Reader.ReadToken( "translation_unit_flags:%s" );
	const string		complete_at_flags			 = m_Reader.ReadToken( "complete_at_flags:%s" );
	const uint32_t		translation_unit_flags_value = ClangFlagConverters::GetCXTranslationUnitFlags().GetValue( translation_unit_flags );
	const uint32_t		complete_at_flags_value		 = ClangFlagConverters::GetCXCodeCompleteFlags().GetValue( complete_at_flags );

	m_Context.SetTranslationUnitFlags( translation_unit_flags_value );
	m_Context.SetCompleteAtFlags( complete_at_flags_value );
}


void	ClangServer::commandCreateSession( void )
{
	const string				session_name = m_Reader.ReadToken( "session_name:%s" );

	// search session
	Dictionary::iterator		session_it	 = m_Sessions.find( session_name );

	if ( session_it == m_Sessions.end() )
	{
		// not found session
		// allocate & setup new session
		shared_ptr< ClangSession >				new_session( new ClangSession( session_name, m_Context, m_Reader, m_Writer ) );
		std::pair< Dictionary::iterator, bool > result = m_Sessions.insert( Dictionary::value_type( session_name, new_session ) );

		if ( result.second )
		{
			// success
			new_session->Allocate();
		}
	}
	else 
	{
		// already exist
	}
}


void	ClangServer::commandDeleteSession( void )
{
	const string				session_name = m_Reader.ReadToken( "session_name:%s" );

	// search session
	Dictionary::iterator		session_it	 = m_Sessions.find( session_name );

	if ( session_it != m_Sessions.end() )
	{
		// session_it->second->Deallocate();
		
		m_Sessions.erase( session_it );
	}
}


void	ClangServer::commandShutdown( void )
{
	m_Status = kStatus_Exit;
}




void	ClangServer::ParseServerCommand( void )
{
	const string				command_name = m_Reader.ReadToken( "command_name:%s" );

	ServerHandleMap::iterator	command_it	 = m_ServerCommands.find( command_name );

	// execute command handler
	if ( command_it != m_ServerCommands.end() )
	{
		command_it->second( *this );
	}
	else
	{
		// unknown command
	}
}

void	ClangServer::ParseSessionCommand( void )
{
	const string		command_name = m_Reader.ReadToken( "command_name:%s" );
	const string		session_name = m_Reader.ReadToken( "session_name:%s" );

	if ( session_name.empty() )
	{
		return;
	}

	// search session
	Dictionary::iterator	session_it = m_Sessions.find( session_name );

	// execute command handler
	if ( session_it != m_Sessions.end() )
	{
		SessionHandleMap::iterator		command_it = m_SessionCommands.find( command_name );

		if ( command_it != m_SessionCommands.end() )
		{
			command_it->second( *session_it->second );
		}
		else
		{
			// session not found
		}
	}
	else
	{
		// unknown command
	}
}


void	ClangServer::ParseCommand( void )
{
	do
	{
		const string	command_type = m_Reader.ReadToken( "command_type:%s" );

		if ( command_type == "Server" )
		{
			ParseServerCommand();
		}
		else if ( command_type == "Session" )
		{
			ParseSessionCommand();
		}
		else
		{
			// unknown command type
		}
	} while ( m_Status != kStatus_Exit );
}




/*================================================================================================*/
/*  EOF                                                                                           */
/*================================================================================================*/
