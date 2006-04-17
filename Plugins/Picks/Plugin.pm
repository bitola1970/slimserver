package Plugins::Picks::Plugin;

# $Id$

# Load Picks via an OPML file - so we can ride on top of the Podcast Browser
#
# Still todo - Add web UI to replace old flat Picks list.

use strict;

use Slim::Buttons::Common;
use Slim::Buttons::XMLBrowser;
use Slim::Utils::Misc;

my $FEED = 'http://www.slimdevices.com/picks/radio.opml';

sub enabled {
	return ($::VERSION ge '6.1');
}

sub initPlugin {
	$::d_plugins && msg("Picks: initPlugin()\n");

	Slim::Buttons::Common::addMode('PLUGIN.Picks', getFunctions(), \&setMode);
	
#        |requires Client
#        |  |is a Query
#        |  |  |has Tags
#        |  |  |  |Function to call
#        C  Q  T  F
    Slim::Control::Request::addDispatch(['picks', '_index', '_quantity'],
        [0, 1, 1, \&picksQuery]);

}

sub getDisplayName {
	return 'PLUGIN_PICKS_MODULE_NAME';
}

sub addMenu {
	return 'RADIO';
}

sub getFunctions {
	return {};
}

sub setMode {
	my $client = shift;
	my $method = shift;

	if ($method eq 'pop') {
		Slim::Buttons::Common::popMode($client);
		return;
	}

	# use INPUT.Choice to display the list of feeds
	my %params = (
		header   => 'PLUGIN_PICKS_LOADING_PICKS',
		modeName => 'Picks Plugin',
		url      => $FEED,
		title    => $client->string(getDisplayName()),
	);

	Slim::Buttons::Common::pushMode($client, 'xmlbrowser', \%params);
	
	# we'll handle the push in a callback
	$client->param('handledTransition',1)
}

sub picksQuery {
	my $request = shift;
	
	$::d_plugins && msg("Picks: picksQuery()\n");

	# check this is the correct query.
	if ($request->isNotQuery([['picks']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	Slim::Buttons::XMLBrowser::getFeedViaHTTP($request, $FEED, \&_picksQuery_done, \&_picksQuery_error);
	
	$request->setStatusProcessing();
}

sub _picksQuery_done {
	my $request = shift;
	my $url     = shift;
	my $feed    = shift;

	my $loopname = '@loop';
	my $cnt = 0;
		
	for my $item ( @{$feed->{'items'}} ) {
		$request->addResultLoop($loopname, $cnt, 'name', $item->{'name'});
		$request->addResultLoop($loopname, $cnt, 'hasitems', scalar @{$item->{'items'}});
		$cnt++;
	}

	$request->setStatusDone();
}

sub _picksQuery_error {
	my $request = shift;
	my $url     = shift;
	my $err     = shift;

	$::d_plugins && msg("Picks: error retrieving <$url>:\n");
	$::d_plugins && msg($err);
	
	$request->addResult("networkerror", 1);
	$request->addResult('count', 0);

	$request->setStatusDone();	
}

sub strings {
	return "
PLUGIN_PICKS_MODULE_NAME
	DE	Slim Devices Auswahl
	EN	Slim Devices Picks
	ES	Preferidas de Slim Devices
	HE	המומלצים
	NL	De beste van Slim Devices

PLUGIN_PICKS_LOADING_PICKS
	DE	Lade Slim Devices Picks...
	EN	Loading Slim Devices Picks...
	ES	Cargando las Preferidas de Slim Devices...
	HE	טוען מועדפים
	NL	Laden van de beste van Slim Devices...
";}

1;
