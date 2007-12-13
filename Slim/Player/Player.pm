package Slim::Player::Player;

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# $Id$
#

use strict;

use Math::VecStat;
use Scalar::Util qw(blessed);

use base qw(Slim::Player::Client);

use Slim::Buttons::SqueezeNetwork;
use Slim::Hardware::IR;
use Slim::Player::Client;
use Slim::Player::Source;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

my $log = logger('player.ui');

my $prefs = preferences('server');

our $defaultPrefs = {
	'bass'                 => 50,
	'digitalVolumeControl' => 1,
	'preampVolumeControl'  => 0,
	'disabledirsets'       => [],
	'irmap'                => sub { Slim::Hardware::IR::defaultMapFile() },
	'menuItem'             => [qw(
		NOW_PLAYING
		BROWSE_MUSIC
		RADIO
		MUSIC_SERVICES
		FAVORITES
		PLUGINS
		SETTINGS
		SQUEEZENETWORK_CONNECT
	)],
	'mp3SilencePrelude'    => 0,
	'pitch'                => 100,
	'power'                => 1,
	'powerOffBrightness'   => 1,
	'powerOnBrightness'    => 4,
	'screensaver'          => 'playlist',
	'idlesaver'            => 'nosaver',
	'offsaver'             => 'SCREENSAVER.datetime',
	'screensavertimeout'   => 30,
	'silent'               => 0,
	'syncPower'            => 0,
	'syncVolume'           => 0,
	'treble'               => 50,
	'volume'               => 50,
	'syncBufferThreshold'  => 4, 	# KB, 1/4s @ 128kb/s
	'bufferThreshold'      => 255,	# KB
	'powerOnResume'        => 'PauseOff-NoneOn',
	'maintainSync'         => 1,
	'minSyncAdjust'        => 30,	# ms
	'packetLatency'        => 2,	# ms
	'startDelay'           => 0,	# ms
	'playDelay'            => 0,	# ms
};

sub new {
	my ($class, $id, $paddr, $rev, $s, $deviceid, $uuid) = @_;

	my $client = $class->SUPER::new($id, $paddr, $rev, $s, $deviceid, $uuid);

	# initialize model-specific features:
	$client->revision($rev);

	return $client;
}

sub init {
	my $client = shift;

	# make sure any preferences this client may not have set are set to the default
	# This should be a method on client!
	$prefs->client($client)->init($defaultPrefs);

	$client->SUPER::init();

	Slim::Buttons::Home::updateMenu($client);

	# fire it up!
	$client->power($prefs->client($client)->get('power'));
	$client->startup();

	# start the screen saver
	Slim::Buttons::ScreenSaver::screenSaver($client);
	$client->brightness($prefs->client($client)->get($client->power() ? 'powerOnBrightness' : 'powerOffBrightness'));
}

# usage	- float	buffer fullness as a percentage
sub usage {
	my $client = shift;
	return $client->bufferSize() ? $client->bufferFullness() / $client->bufferSize() : 0;
}

# following now handled by display object
sub update      { shift->display->update(@_); }
sub showBriefly { shift->display->showBriefly(@_); }
sub pushLeft    { shift->display->pushLeft(@_); }
sub pushRight   { shift->display->pushRight(@_); }
sub pushUp      { shift->display->pushUp(@_); }
sub pushDown    { shift->display->pushDown(@_); }
sub bumpLeft    { shift->display->bumpLeft(@_); }
sub bumpRight   { shift->display->bumpRight(@_); }
sub bumpUp      { shift->display->bumpUp(@_); }
sub bumpDown    { shift->display->bumpDown(@_); }
sub brightness  { shift->display->brightness(@_); }
sub maxBrightness { shift->display->maxBrightness(@_); }
sub scrollTickerTimeLeft { shift->display->scrollTickerTimeLeft(@_); }
sub killAnimation { shift->display->killAnimation(@_); }
sub textSize    { shift->display->textSize(@_); }
sub maxTextSize { shift->display->maxTextSize(@_); }
sub linesPerScreen { shift->display->linesPerScreen(@_); }
sub symbols     { shift->display->symbols(@_); }
sub prevline1   { if (my $display = shift->display) { return $display->prevline1(@_); }}
sub prevline2   { if (my $display = shift->display) { return $display->prevline2(@_); }}
sub curDisplay  { shift->display->curDisplay(@_); }
sub curLines    { shift->display->curLines(@_); }
sub parseLines  { shift->display->parseLines(@_); }
sub renderOverlay { shift->display->renderOverlay(@_); }
sub measureText { shift->display->measureText(@_); }
sub displayWidth{ shift->display->displayWidth(@_); }
sub sliderBar   { shift->display->sliderBar(@_); }
sub progressBar { shift->display->progressBar(@_); }
sub balanceBar  { shift->display->balanceBar(@_); }
sub fonts         { shift->display->fonts(@_); }
sub displayHeight { shift->display->displayHeight(@_); }
sub currBrightness { shift->display->currBrightness(@_); }
sub vfdmodel    { shift->display->vfdmodel(@_); }

sub updateMode  { shift->display->updateMode(@_); }
sub animateState{ shift->display->animateState(@_); }
sub scrollState { shift->display->scrollState(@_); }

sub block       { Slim::Buttons::Block::block(@_); }
sub unblock     { Slim::Buttons::Block::unblock(@_); }

sub string      { shift->display->string(@_); }
sub doubleString{ shift->display->doubleString(@_); }

sub isPlayer {
	return 1;
}

sub power {
	my $client = shift;
	my $on = shift;
	
	my $currOn = $prefs->client($client)->get('power') || 0;

	return $currOn unless defined $on;
	return unless (!defined(Slim::Buttons::Common::mode($client)) || ($currOn != $on));

	$client->display->renderCache()->{defaultfont} = undef;

	$prefs->client($client)->set('power', $on);

	my $resume = Slim::Player::Sync::syncGroupPref($client, 'powerOnResume') || $prefs->client($client)->get('powerOnResume');
	$resume =~ /(.*)Off-(.*)On/;
	my ($resumeOff, $resumeOn) = ($1,$2);

	if (!$on) {

		# turning player off - unsync/pause/stop player and move to off mode
		my $sync = $prefs->client($client)->get('syncPower');

		if (defined $sync && $sync == 0) {

			if ( logger('player.sync')->is_info && Slim::Player::Sync::isSynced($client) ) {
				logger('player.sync')->info("Temporary Unsync " . $client->id);
			}

			Slim::Player::Sync::unsync($client, 1);
  		}
  
		if (Slim::Player::Source::playmode($client) eq 'play') {

			if (Slim::Player::Playlist::song($client) && 
				Slim::Music::Info::isRemoteURL(Slim::Player::Playlist::url($client))) {
				# always stop if currently playing remote stream
				$client->execute(["stop"]);
			
			} elsif ($resumeOff eq 'Pause') {
				# Pause client mid track
				$client->execute(["pause", 1]);
  		
			} else {
				# Stop client
				$client->execute(["stop"]);
			}
		}

		# turn off audio outputs
		$client->audio_outputs_enable(0);

		# move display to off mode
		$client->killAnimation();
		$client->brightness($prefs->client($client)->get('powerOffBrightness'));

		Slim::Buttons::Common::setMode($client, 'off');

	} else {

		# turning player on - reset mode & brightness, display welcome and sync/start playing
		$client->audio_outputs_enable(1);

		$client->update( { 'screen1' => {}, 'screen2' => {} } );

		$client->updateMode(2); # block updates to hide mode change

		Slim::Buttons::Common::setMode($client, 'home');

		$client->updateMode(0); # unblock updates
		
		# restore the saved brightness, unless its completely dark...
		my $powerOnBrightness = $prefs->client($client)->get('powerOnBrightness');

		if ($powerOnBrightness < 1) {
			$powerOnBrightness = 1;
			$prefs->client($client)->set('powerOnBrightness', $powerOnBrightness);
		}
		$client->brightness($powerOnBrightness);

		my $oneline = ($client->linesPerScreen() == 1);
		
		$client->showBriefly( {
			'center' => [ $client->string('WELCOME_TO_' . $client->model), $client->string('FREE_YOUR_MUSIC') ],
			'fonts' => { 
					'graphic-320x32' => 'standard',
					'graphic-280x16' => 'medium',
					'text'           => 2,
				},
			'screen2' => {},
			'jive' => undef,
		}, undef, undef, 1);

		# check if there is a sync group to restore
		Slim::Player::Sync::restoreSync($client);

		if (Slim::Player::Source::playmode($client) ne 'play') {
			
			if ($resumeOn =~ /Reset/) {
				# reset playlist to start
				$client->execute(["playlist","jump", 0, 1]);
			}

			if ($resumeOn =~ /Play/ && Slim::Player::Playlist::song($client) &&
				!Slim::Music::Info::isRemoteURL(Slim::Player::Playlist::url($client))) {
				# play if current playlist item is not a remote url
				$client->execute(["play"]);
			}
		}		
	}
}

sub audio_outputs_enable { }

sub maxVolume { return 100; }
sub minVolume {	return 0; }

sub maxTreble {	return 100; }
sub minTreble {	return 0; }

sub maxBass {	return 100; }
sub minBass {	return 0; }

# fade the volume up or down
# $fade = number of seconds to fade 100% (positive to fade up, negative to fade down) 
# $callback is function reference to be called when the fade is complete

sub fade_volume {
	my ($client, $fade, $callback, $callbackargs) = @_;

	my $int = 0.05; # interval between volume updates

	my $vol = abs($prefs->client($client)->get("volume"));
	
	Slim::Utils::Timers::killHighTimers($client, \&_fadeVolumeUpdate);

	$client->_fadeVolumeUpdate( {
		'startVol' => ($fade > 0) ? 0 : $vol,
		'endVol'   => ($fade > 0) ? $vol : 0,
		'startTime'=> Time::HiRes::time(),
		'int'      => $int,
		'rate'     => ($vol && $fade) ? $vol / $fade : 0,
		'cb'       => $callback,
		'cbargs'   => $callbackargs,
	} );
}

sub _fadeVolumeUpdate {
	my $client = shift;
	my $f = shift;
	
	# If the user manually changed the volume, stop fading
	if ( $f->{'vol'} && $f->{'vol'} != $client->volume ) {
		return;
	}
	
	my $now = Time::HiRes::time();

	# new vol based on time since fade started to minise impact of timers firing late
	$f->{'vol'} = $f->{'startVol'} + ($now - $f->{'startTime'}) * $f->{'rate'};

	my $rate = $f->{'rate'};

	if (
		   !$rate 
		|| ( $rate < 0 && $f->{'vol'} < $f->{'endVol'} )
		|| ( $rate > 0 && $f->{'vol'} > $f->{'endVol'} )
	) {

		# reached end of fade
		$client->volume($f->{'endVol'}, 1);

		if ($f->{'cb'}) {
			&{$f->{'cb'}}(@{$f->{'cbargs'}});
		}

	} else {

		$client->volume($f->{'vol'}, 1);
		Slim::Utils::Timers::setHighTimer($client, $now + $f->{'int'}, \&_fadeVolumeUpdate, $f);
	}
}

# mute or un-mute volume as necessary
# A negative volume indicates that the player is muted and should be restored 
# to the absolute value when un-muted.
sub mute {
	my $client = shift;
	
	if (!$client->isPlayer()) {
		return 1;
	}

	my $vol = $prefs->client($client)->get('volume');
	my $mute = $prefs->client($client)->get('mute');
	
	if (($vol < 0) && ($mute)) {
		# mute volume
		# todo: there is actually a hardware mute feature
		# in both decoders. Need to add Decoder::mute
		$client->volume(0);
	} else {
		# un-mute volume
		$vol *= -1;
		$client->volume($vol);
	}

	$prefs->client($client)->set('volume', $vol);
	$client->mixerDisplay('volume');
}

sub hasDigitalOut {
	return 0;
}

sub hasVolumeControl {
	return 1;
}
	
sub sendFrame {};

sub currentSongLines {
	my $client = shift;
	my $suppressScreen2 = shift; # suppress the screen2 display
	my $suppressDisplay = shift; # suppress both displays [leaving just jive hash]

	my $parts;
	my $status;
	my @lines = ();
	my @overlay = ();
	my $screen2;
	my $jive;
	
	my $playmode    = Slim::Player::Source::playmode($client);
	my $playlistlen = Slim::Player::Playlist::count($client);

	if ($playlistlen < 1) {

		$status = $client->string('NOTHING');

		@lines = ( $client->string('NOW_PLAYING'), $client->string('NOTHING') );

		if ($client->display->showExtendedText() && !$suppressDisplay && !$suppressScreen2) {
			$screen2 = {};
		}

	} else {

		if ($playmode eq "pause") {

			$status = $client->string('PAUSED');

			if ( $playlistlen == 1 ) {

				$lines[0] = $status;

			} else {

				$lines[0] = sprintf(
					$status." (%d %s %d) ",
					Slim::Player::Source::playingSongIndex($client) + 1, $client->string('OUT_OF'), $playlistlen
				);
			}

		# for taking photos of the display, comment out the line above, and use this one instead.
		# this will cause the display to show the "Now playing" screen to show when paused.
		# line1 = "Now playing" . sprintf " (%d %s %d) ", Slim::Player::Source::playingSongIndex($client) + 1, string('OUT_OF'), $playlistlen;

		} elsif ($playmode eq "stop") {

			$status = $client->string('STOPPED');

			if ( $playlistlen == 1 ) {
				$lines[0] = $status;
			}
			else {
				$lines[0] = sprintf(
					$status." (%d %s %d) ",
					Slim::Player::Source::playingSongIndex($client) + 1, $client->string('OUT_OF'), $playlistlen
				);
			}

		} else {

			$status = $client->string('PLAYING');

			if (Slim::Player::Source::rate($client) != 1) {

				$status = $lines[0] = $client->string('NOW_SCANNING') . ' ' . Slim::Player::Source::rate($client) . 'x';

			} elsif (Slim::Player::Playlist::shuffle($client)) {

				$lines[0] = $client->string('PLAYING_RANDOMLY');

			} else {

				$lines[0] = $client->string('PLAYING');
			}
			
			if ($client->volume() < 0) {
				$lines[0] .= " ". $client->string('LCMUTED');
			}

			if ( $playlistlen > 1 ) {
				$lines[0] .= sprintf(
					" (%d %s %d) ",
					Slim::Player::Source::playingSongIndex($client) + 1, $client->string('OUT_OF'), $playlistlen
				);
			}
		} 

		my $song = Slim::Player::Playlist::song($client);
		my $currentTitle = Slim::Music::Info::getCurrentTitle($client, $song->url);

		$lines[1] = $currentTitle;

		$overlay[1] = $client->symbols('notesymbol');

		# add screen2 information if required
		if ($client->display->showExtendedText() && !$suppressDisplay && !$suppressScreen2) {
			
			my ($s2line1, $s2line2);

			if ($song && $song->isRemoteURL) {

				my $title = Slim::Music::Info::displayText($client, $song, 'TITLE');

				if ( ($currentTitle || '') ne ($title || '') && !Slim::Music::Info::isURL($title) ) {
					$s2line2 = $title;
				}

			} else {

				$s2line1 = Slim::Music::Info::displayText($client, $song, 'ALBUM');
				$s2line2 = Slim::Music::Info::displayText($client, $song, 'ARTIST');

			}

			$screen2 = {
				'line' => [ $s2line1, $s2line2 ],
			};
		}

		$jive = {
			'type'    => 'song',
			'text'    => [ $status, $song->title ],
			'icon-id' => $song->remote ? 0 : ($song->album->artwork || 0) + 0,
		};
	}

	if (!$suppressDisplay) {

		$parts->{'line'}    = \@lines;
		$parts->{'overlay'} = \@overlay;
		$parts->{'screen2'} = $screen2 if defined $screen2;
		$parts->{'jive'}    = $jive if defined $jive;

		# add in the progress bar and time
		$client->nowPlayingModeLines($parts, $suppressScreen2) unless ($playlistlen < 1);

	} elsif ($suppressDisplay ne 'all') {

		$parts->{'jive'} = $jive || \@lines;
	}

	return $parts;
}

sub nowPlayingModeLines {
	my ($client, $parts, $screen2) = @_;

	my $display = $client->display;

	my $overlay;
	my $fractioncomplete = 0;
	my $songtime = '';

	my $mode = $prefs->client($client)->get('playingDisplayModes')->[ $prefs->client($client)->get('playingDisplayMode') ];

	unless (defined $mode) { $mode = 1; };

	my $modeOpts = $display->modes->[$mode];

	my $showBar      = $modeOpts->{bar};
	my $showTime     = $modeOpts->{secs};
	my $showFullness = $modeOpts->{fullness};
	my $displayWidth = $display->displayWidth($screen2 ? 2 : 1);
	
	# check if we don't know how long the track is...
	if (!Slim::Player::Source::playingSongDuration($client)) {
		$showBar = 0;
	}
	
	if ($showFullness) {
		$fractioncomplete = $client->usage();
	} elsif ($showBar) {
		$fractioncomplete = Slim::Player::Source::progress($client);
	}
	
	if ($showFullness) {
		$songtime = ' ' . int($fractioncomplete * 100 + 0.5)."%";
		
		# for remote streams where we know the bitrate, 
		# show the number of seconds of audio in the buffer instead of a percentage
		my $url = Slim::Player::Playlist::url($client);
		if ( Slim::Music::Info::isRemoteURL($url) ) {
			my $decodeBuffer;
			
			# Display decode buffer as seconds if we know the bitrate, otherwise show KB
			my $bitrate = Slim::Music::Info::getBitrate($url);
			if ( $bitrate > 0 ) {
				$decodeBuffer = sprintf( "%.1f", $client->bufferFullness() / ( int($bitrate / 8) ) );
			}
			else {
				$decodeBuffer = sprintf( "%d KB", $client->bufferFullness() / 1024 );
			}
			
			if ( $client->isa('Slim::Player::Squeezebox2') ) {
				# Only show output buffer status on SB2 and higher
				my $outputBuffer = $client->outputBufferFullness() / (44100 * 8);
				$songtime  = ' ' . sprintf "%s / %.1f", $decodeBuffer, $outputBuffer;
				$songtime .= ' ' . $client->string('SECONDS');
			}
			else {
				$songtime  = ' ' . sprintf "%s", $decodeBuffer;
				$songtime .= ' ' . $client->string('SECONDS');
			}
		}
	} elsif ($showTime) { 
		$songtime = ' ' . $client->textSongTime($showTime < 0);
	}

	if ($showTime || $showFullness) {
		$overlay = $songtime;
	}
	
	if ($showBar) {
		# show both the bar and the time
		my $leftLength = $display->measureText($parts->{line}[0], 1);
		my $barlen = $displayWidth - $leftLength - $display->measureText($overlay, 1);
		my $bar    = $display->symbols($client->progressBar($barlen, $fractioncomplete, ($showBar < 0)));

		$overlay = $bar . $songtime;
	}
	
	$parts->{overlay}[0] = $overlay if defined($overlay);
}

sub textSongTime {
	my $client = shift;
	my $remaining = shift;

	my $delta = 0;
	my $sign  = '';

	my $duration = Slim::Player::Source::playingSongDuration($client) || 0;

	if (Slim::Player::Source::playmode($client) eq "stop") {
		$delta = 0;
	} else {	
		$delta = Slim::Player::Source::songTime($client);
		if ($duration && $delta > $duration) {
			$delta = $duration;
		}
	}

	# 2 and 5 display remaining time, not elapsed
	if ($remaining) {
		if ($duration) {
			$delta = $duration - $delta;	
			$sign = '-';
		}
	}
	
	my $hrs = int($delta / (60 * 60));
	my $min = int(($delta - $hrs * 60 * 60) / 60);
	my $sec = $delta - ($hrs * 60 * 60 + $min * 60);
	
	if ($hrs) {

		return sprintf("%s%d:%02d:%02d", $sign, $hrs, $min, $sec);

	} else {

		return sprintf("%s%02d:%02d", $sign, $min, $sec);
	}
}

sub mixerDisplay {
	my $client = shift;
	my $feature = shift;
	
	if ($feature !~ /(?:volume|pitch|bass|treble)/) {
		return;
	}

	my $featureValue = $prefs->client($client)->get($feature);

	# Check for undefined - 0 is a valid value.
	if (!defined $featureValue) {
		return;
	}

	my $mid   = $client->mixerConstant($feature, 'mid');
	my $scale = $client->mixerConstant($feature, 'scale');

	my $headerValue = '';
	my ($parts, $oldvisu, $savedvisu);

	if ($client->mixerConstant($feature, 'balanced')) {

		$headerValue = sprintf(' (%d)', int((($featureValue - $mid) * $scale) + 0.5));

	} elsif ($feature eq 'volume') {

		if (my $linefunc = $client->customVolumeLines()) {

			$parts = &$linefunc($client, $featureValue);

		} else {
			
			$headerValue = $client->volumeString($featureValue);

		}

	} else {

		$headerValue = sprintf(' (%d)', int(($featureValue * $scale) + 0.5));
	}

	if ($feature eq 'pitch') {

		$headerValue .= '%';
	}

	my $featureHeader = join('', $client->string(uc($feature)), $headerValue);

	if (blessed($client->display) eq 'Slim::Display::Squeezebox2') {
		# XXXX hack attack: turn off visualizer when showing volume, etc.		
		$oldvisu = $client->modeParam('visu');
		$savedvisu = 1;
		$client->modeParam('visu', [0]);
	}

	$parts ||= Slim::Buttons::Input::Bar::lines($client, $featureValue, $featureHeader, {
		'min'       => $client->mixerConstant($feature, 'min'),
		'mid'       => $mid,
		'max'       => $client->mixerConstant($feature, 'max'),
		'noOverlay' => 1,
	});

	# suppress display forwarding
	$parts->{'jive'} = $parts->{'cli'} = undef;

	$client->display->showBriefly($parts, { 'name' => 'mixer' } );

	# Turn the visualizer back to it's old value.
	if ($savedvisu) {
		$client->modeParam('visu', $oldvisu);
	}
}

# Intended to be overridden by sub-classes who know better
sub packetLatency {
	return $prefs->client(shift)->get('packetLatency') / 1000;
}

use constant JIFFIES_OFFSET_TRACKING_LIST_SIZE => 10;
use constant JIFFIES_EPOCH_MIN_ADJUST          => 0.001;
use constant JIFFIES_EPOCH_MAX_ADJUST          => 0.005;

sub trackJiffiesEpoch {
	my ($client, $jiffies, $timestamp) = @_;

	# Note: we do not take the packet latency into account here;
	# see jiffiesToTimestamp

	my $jiffiesTime = $jiffies / $client->ticspersec;
	my $offset      = $timestamp - $jiffiesTime;
	my $epoch       = $client->jiffiesEpoch || 0;

	if ( logger('network.protocol')->is_debug ) {
		logger('network.protocol')->debug($client->id() . " trackJiffiesEpoch: epoch=$epoch, offset=$offset");
	}

	if (   $offset < $epoch			# simply a better estimate, or
		|| $offset - $epoch > 50	# we have had wrap-around (or first time)
	) {
		if ( logger('player.sync')->is_debug ) {
			if ( abs($offset - $epoch) > 0.001 ) {
				logger('player.sync')->debug( sprintf("%s adjust jiffies epoch %+.3fs", $client->id(), $offset - $epoch) );
			}
		}
		
		$client->jiffiesEpoch($epoch = $offset);	
	}

	my $diff = $offset - $epoch;
	my $jiffiesOffsetList = $client->jiffiesOffsetList();

	unshift @{$jiffiesOffsetList}, $diff;
	pop @{$jiffiesOffsetList}
		if (@{$jiffiesOffsetList} > JIFFIES_OFFSET_TRACKING_LIST_SIZE);

	if (   $diff > 0.001
		&& (@{$jiffiesOffsetList} == JIFFIES_OFFSET_TRACKING_LIST_SIZE)
	) {
		my $min_diff = Math::VecStat::min($jiffiesOffsetList);
		if ( $min_diff > JIFFIES_EPOCH_MIN_ADJUST ) {
			if ( $min_diff > JIFFIES_EPOCH_MAX_ADJUST ) {
				$min_diff = JIFFIES_EPOCH_MAX_ADJUST;
			}
			if ( logger('player.sync')->is_debug ) {
				logger('player.sync')->debug( sprintf("%s adjust jiffies epoch +%.3fs", $client->id(), $min_diff) );
			}
			$client->jiffiesEpoch($epoch += $min_diff);
			$diff -= $min_diff;
			@{$jiffiesOffsetList} = ();	# start tracking again
		}
	}
	return $diff;
}

sub jiffiesToTimestamp {
	my ($client, $jiffies) = @_;

	# Note: we only take the packet latency into account here,
	# rather than in trackJiffiesEpoch(), so that a bad calculated latency
	# (which presumably would be transient) does not permanently effect
	# our idea of the jiffies-epoch.
	
	return $client->jiffiesEpoch + $jiffies / $client->ticspersec - $client->packetLatency();
}
	
# Only works for SliMP3s and (maybe) SB1s
sub apparentStreamStartTime {
	my ($client, $statusTime) = @_;

	my $bytesPlayed = $client->bytesReceived()
						- $client->bufferFullness()
						- ($client->model() eq 'slimp3' ? 2000 : 2048);

	my $format = Slim::Player::Sync::masterOrSelf($client)->streamformat();

	my $timePlayed;

	if ( $format eq 'mp3' ) {
		$timePlayed = Slim::Player::Source::findTimeForOffset($client, $bytesPlayed) or return;
	}
	elsif ( $format eq 'wav' ) {
		$timePlayed = $bytesPlayed * 8 / (Slim::Player::Source::streamBitrate($client) or return);
	}
	else {
		return;
	}

	my $apparentStreamStartTime = $statusTime - $timePlayed;

	if ( logger('player.sync')->is_debug ) {
		logger('player.sync')->debug(
			$client->id()
			. " apparentStreamStartTime: $apparentStreamStartTime @ $statusTime \n"
			. "timePlayed:$timePlayed (bytesReceived:" . $client->bytesReceived()
			. " bufferFullness:" . $client->bufferFullness()
			.")"
		);
	}

	return $apparentStreamStartTime;
}

use constant PLAY_POINT_LIST_SIZE		=> 8;		# how many to keep
use constant MAX_STARTTIME_VARIATION	=> 0.015;	# latest apparent-stream-start-time estimate
													# must be this close to the average
sub publishPlayPoint {
	my ( $client, $statusTime, $apparentStreamStartTime, $cutoffTime ) = @_;

	my $playPoints = $client->playPoints();
	$client->playPoints($playPoints = []) if (!defined($playPoints));
	
	unshift(@{$playPoints}, [$statusTime, $apparentStreamStartTime]);

	# remove all old and excessive play-points
	pop @{$playPoints} if ( @{$playPoints} > PLAY_POINT_LIST_SIZE );
	while( @{$playPoints} && $playPoints->[-1][0] < $cutoffTime ) {
		pop @{$playPoints};
	}

	# Do we have a consistent set of playPoints so that we can publish one?
	if ( @{$playPoints} == PLAY_POINT_LIST_SIZE ) {
		my $meanStartTime = 0;
		foreach my $point ( @{$playPoints} ) {
			$meanStartTime += $point->[1];
		}
		$meanStartTime /= @{$playPoints};

		if ( abs($apparentStreamStartTime - $meanStartTime) < MAX_STARTTIME_VARIATION ) {
			# Ok, good enough, publish it!
			$client->playPoint( [$statusTime, $meanStartTime] );
			
			if ( 0 && logger('player.sync')->is_debug ) {
				logger('player.sync')->debug(
					$client->id()
					. " publishPlayPoint: $meanStartTime @ $statusTime"
				);
			}
		}
	}
}

1;

__END__
