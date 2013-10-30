package MyFlickr;
use strict;
use warnings;
use Flickr::API;
use Data::Dumper;
use Browser::Open qw|open_browser|;
use Flickr::Upload;
use Carp;

our $api_key = '19b47264d5e18d50962ac56345510fbc';
our $shared_secret = '9f01bc4567657508';

our $api = new Flickr::API({
	key => $api_key,
	secret => $shared_secret
});

sub new{
	 my $self = shift;
	return $self;
}

sub askAuth{
	my $self = shift;
	
	my $permission_wanted = 'write';
	print 'Get frob...';
	my $response = $api->execute_method('flickr.auth.getFrob');
	my $r = $response->decoded_content(charset => 'none');
	warn qq|Warning:\n$r|, next unless $r =~ /<rsp[^>]+stat\s*=\s*"ok".*>/i;
	$r =~ /<frob>(.+)<\/frob>/ or carp qq|Warning:\n$r| and return undef;
	my $frob = $1;
	my $url = $api->request_auth_url($permission_wanted,$frob);
	open_browser($url);
	return $frob;
}

sub do_getToken{
	my ($self,$frob) = @_;
	print 'Get token...';
	my $response = $api->execute_method('flickr.auth.getToken',{
		frob => $frob
	});
	print 'Check answer...';
	my $r = $response->decoded_content(charset => 'none');
	print $r;
	carp qq|Warning:\n$r| and return undef unless $r =~ /<rsp[^>]+stat\s*=\s*"ok".*>/i;
	print 'Extract token...';
	$r =~ /<token>(.+)<\/token>/ or carp qq|Warning:\n$r| and return undef;
	my $token = $1;
	print 'Save token...';
	$self->{auth_token} = $token;
	$r =~ /<user\s+nsid\s*=\s*"([^"]+)"\s+username\s*=\s*"([^"]+)"\s+fullname\s*=\s*"([^"]+)"/
		or die qq|ERROR:\n$r|;
	$self->{nsid} = $1;
	$self->{username} = $2;
	$self->{fullname} = $3;
	return $token;
}