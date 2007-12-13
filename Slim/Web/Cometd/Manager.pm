package Slim::Web::Cometd::Manager;

# $Id$

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

# This class manages clients and subscriptions

use strict;

use Scalar::Util qw(weaken);
use Tie::RegexpHash;

use Slim::Utils::Log;
use Slim::Utils::Timers;
use Slim::Web::HTTP;

my $log = logger('network.cometd');

sub new {
	my ( $class, %args ) = @_;
	
	tie my %channels, 'Tie::RegexpHash';
	
	my $self = {
		conn     => {},         # client connection(s)
		events   => {},         # clients and their pending events
		channels => \%channels, # all channels and who is subscribed to them
	};
	
	bless $self, ref $class || $class;
}

# Add a new client and connection created during handshake
sub add_client {
	my ( $self, $clid ) = @_;
	
	# The per-client event hash holds one pending event per channel
	$self->{events}->{$clid} = {};
	
	$log->debug("add_client: $clid");
	
	return $clid;
}

# Update the connection, i.e. if the client reconnected
sub register_connection {
	my ( $self, $clid, $conn ) = @_;
	
	$self->{conn}->{$clid} = $conn;
	
	$log->debug("register_connection: $clid");
}

sub remove_connection {
	my ( $self, $clid ) = @_;
	
	delete $self->{conn}->{$clid};

	$log->debug("remove_connection: $clid");
}

sub clid_for_connection {
	my ( $self, $conn ) = @_;
	
	my $result;
	
	while ( my ($clid, $c) = each %{ $self->{conn} } ) {
		if ( $conn eq $c ) {
			$result = $clid;
		}
	}
	
	return $result;
}

sub remove_client {
	my ( $self, $clid ) = @_;
	
	delete $self->{conn}->{$clid};
	delete $self->{events}->{$clid};
	
	$self->remove_channels( $clid );
	
	$log->debug("remove_client: $clid");
}

sub is_valid_clid {
	my ( $self, $clid ) = @_;
	
	return exists $self->{events}->{$clid};
}

sub add_channels {
	my ( $self, $clid, $subs ) = @_;

	for my $sub ( @{$subs} ) {
		
		my $re_sub = $sub;
		
		# Turn channel globs into regexes
		# /foo/**, Matches /foo/bar, /foo/boo and /foo/bar/boo. Does not match /foo, /foobar or /foobar/boo
		if ( $re_sub =~ m{^/(.+)/\*\*$} ) {
			$re_sub = qr{^/$1/};
		}
		# /foo/*, Matches /foo/bar and /foo/boo. Does not match /foo, /foobar or /foo/bar/boo.
		elsif ( $re_sub =~ m{^/(.+)/\*$} ) {
			$re_sub = qr{^/$1/[^/]+};
		}
		
		$self->{channels}->{$re_sub} ||= {};
		$self->{channels}->{$re_sub}->{$clid} = 1;
		
		$log->debug("add_channels: $sub ($re_sub)");
	}
	
	return 1;
}

sub remove_channels {
	my ( $self, $clid, $subs ) = @_;
	
	if ( !$subs ) {
		# remove all channels for this client
		for my $channel ( keys %{ $self->{channels} } ) {
			for my $sub_clid ( keys %{ $self->{channels}->{$channel} } ) {
				if ( $clid eq $sub_clid ) {
					delete $self->{channels}->{$channel}->{$clid};
					
					if ( !scalar keys %{ $self->{channels}->{$channel} } ) {
						delete $self->{channels}->{$channel};
					}
					
					$log->debug("remove_channels for $clid: $channel");
				}
			}
		}
	}
	else {
		for my $sub ( @{$subs} ) {
			
			my $re_sub = $sub;
		
			# Turn channel globs into regexes
			# /foo/**, Matches /foo/bar, /foo/boo and /foo/bar/boo. Does not match /foo, /foobar or /foobar/boo
			if ( $re_sub =~ m{^/(.+)/\*\*$} ) {
				$re_sub = qr{^/$1/};
			}
			# /foo/*, Matches /foo/bar and /foo/boo. Does not match /foo, /foobar or /foo/bar/boo.
			elsif ( $re_sub =~ m{^/(.+)/\*$} ) {
				$re_sub = qr{^/$1/[^/]+};
			}
		
			for my $channel ( keys %{ $self->{channels} } ) {
				if ( $re_sub eq $channel ) {
					delete $self->{channels}->{$channel}->{$clid};
					
					if ( !scalar keys %{ $self->{channels}->{$channel} } ) {
						delete $self->{channels}->{$channel};
					}
				}
			}
		
			$log->debug("remove_channels for $clid: $sub ($re_sub)");
		}
	}
	
	return 1;
}

sub get_pending_events {
	my ( $self, $clid ) = @_;
	
	my $events = [];
	
	while ( my ($channel, $event) = each %{ $self->{events}->{$clid} } ) {
		push @{$events}, $event;
	}
	
	# Clear all pending events
	$self->{events}->{$clid} = {};
	
	return wantarray ? @{$events} : $events;
}

sub deliver_events {
	my ( $self, $events ) = @_;
	
	if ( ref $events ne 'ARRAY' ) {
		$events = [ $events ];
	}
	
	my @to_send;
	
	for my $event ( @{$events} ) {
		# Find subscriber(s) to this event
		my $channel = $event->{channel};
		
		if ( exists $self->{channels}->{$channel} ) {
			# Queue up all events for all subscribers
			# Since channels is a regexphash it will automatically match
			# globbed channels
			for my $clid ( keys %{ $self->{channels}->{$channel} } ) {
				push @to_send, $clid;
			
				$log->debug("Sending event on channel $channel to $clid");
			}
		}
	}
	
	# Send everything
	for my $clid ( @to_send ) {	
		my $conn = $self->{conn}->{$clid};
		
		# If we have a connection to send to...
		if ( $conn ) {
			# Add any pending events
			push @{$events}, ( $self->get_pending_events( $clid ) );
		
			if ( $log->is_debug ) {
				$log->debug( 
					  "Delivering events to $clid:\n"
					. Data::Dump::dump( $events )
				);
			}
		
			Slim::Web::Cometd::sendResponse( $conn, $events );
		}
		else {
			# queue the event for later
			$self->{events}->{$clid}->{ $events->[0]->{channel} } = $events->[0];
			
			if ( $log->is_debug ) {
				$log->debug( 'Queued ' . scalar @{$events} . " event(s) for $clid" );
			}
		}
	}
	
	return 1;
}

1;
