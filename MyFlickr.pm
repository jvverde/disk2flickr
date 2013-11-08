package MyFlickr;
use strict;
use warnings;
use Flickr::API;
use Data::Dumper;
use Browser::Open qw|open_browser|;
use Flickr::Upload;
use XML::XPath;
use XML::Simple;
use Carp;
use threads;
use threads::shared;
use Thread::Queue;

my $api_key = '470cd47d4fb1e54ac33ff740bc59bef4';
my $shared_secret = '354288e4575ad352';

my $api = new Flickr::API({
	key => $api_key,
	secret => $shared_secret
});

my $uploader = Flickr::Upload->new({
	key => $api_key,
	secret => $shared_secret
});

sub new {
	my ($self) = @_;
	return bless {}, $self;
}

my $xs = XML::Simple->new();
sub askAuth{
	my $self = shift;

	my $permission_wanted = 'write';
	print 'Get frob...';
	my $response = $api->execute_method('flickr.auth.getFrob');
	my $r = $response->decoded_content(charset => 'none');
	carp qq|Warning in askUser:\n$r| and return undef unless $r =~ /<rsp[^>]+stat\s*=\s*"ok".*>/i;
	$r =~ /<frob>(.+)<\/frob>/ or carp(qq|Warning:\n$r|) and return undef;
	my $frob = $1;
	my $url = $api->request_auth_url($permission_wanted,$frob);
	$url =~ s/&/^&/g if $^O eq 'MSWin32'; #if windows escape & in args of start cmd
	use threads;
	async {
		open_browser($url);
	};
	$self->{frob} = $frob;
	return $frob;
}

sub getToken{
	my $self = shift;
	#print 'Get token...';
	my $response = $api->execute_method('flickr.auth.getToken',{
		frob => $self->{frob}
	});
	print 'Check answer...';
	my $r = $response->decoded_content(charset => 'none');
	print $r;
	carp qq|Warning:\n$r| and return undef unless $r =~ /<rsp[^>]+stat\s*=\s*"ok".*>/i;
	print 'Extract token...';
	$r =~ /<token>(.+)<\/token>/ or carp qq|Warning:\n$r| and return undef;
	my $token = $1;
	print 'Save token...';
	$self->{user}->{auth_token} = $token;
	$r =~ /<user\s+nsid\s*=\s*"([^"]+)"\s+username\s*=\s*"([^"]+)"\s+fullname\s*=\s*"([^"]+)"/
		or die qq|ERROR:\n$r|;
	$self->{user}->{nsid} = $1;
	$self->{user}->{username} = $2;
	$self->{user}->{fullname} = $3;
	return $token;
}

sub checkFlickrPhoto{
	my ($self,$id) = @_;
	#print "Check photo $id";
	my $param = {
	  user_id => $self->{user}->{nsid},
	  auth_token => $self->{user}->{auth_token},
	  tags => qq|$id|
	};
	print Dumper $param;
	my $response = $api->execute_method('flickr.photos.search', $param);
	my $answer  = $response->decoded_content(charset => 'none');
	print "answer=$answer";
	my $xp = XML::XPath->new(xml => $answer);
	carp qq|Wrong answer:\n\t$answer|
		and return undef if $xp->getNodeText('/rsp/@stat')->value ne 'ok';
	my $nphotos = $xp->getNodeText('/rsp/photos/@total')->value;
	return $nphotos;
}
sub checkAllFlickrPhotos{
	my ($self) = @_;
	my $inFlickr = {};
	eval {
		my $cnt = 1;
		my $result;
		do{
			my $response = $api->execute_method('flickr.photos.search', {
			  user_id => $self->{user}->{nsid},
			  auth_token => $self->{user}->{auth_token},
			  extras => 'machine_tags',
			  per_page => 500,
			  page => $cnt++
			});
			my $answer  = $response->decoded_content(charset => 'none');
			$result = $xs->XMLin($answer);
			print Dumper $result and last if $result->{stat} ne 'ok';
			my $photos = $result->{photos}->{photo};
			foreach (keys %$photos){
				my $mtags = $photos->{$_}->{'machine_tags'};
				my @mtags = split /\s+/, $mtags;
				my %tags = map{split /\s*=\s*/,$_} @mtags;
				my $id = $tags{'meta:id'} // '';
				$inFlickr->{$id} = $_;
			}			
		}while($result->{photos}->{page} < $result->{photos}->{pages})
	};
	warn $@ if $@;
	return $inFlickr;
}
sub upload{
	my ($self,$file,@tags) = @_;
	my $photoid = $uploader->upload(
		photo => $file,
		auth_token => $self->{user}->{auth_token},
		tags => (join ' ', @tags),
		is_public => 0,
		hidden => 0
	) or warn "Failed to upload $file" and return undef;
	return $photoid;
}
sub replace{
	my ($self,$file,$photoid,@tags) = @_;
	my $new = $uploader->upload(
		uri => 'http://api.flickr.com/services/replace/',
		photo => $file,
		photo_id => $photoid,
		auth_token => $self->{user}->{auth_token},
		tags => (join ' ', @tags),
	) or warn "Failed to replace photo $photoid" and return undef;
	return $new;
}
