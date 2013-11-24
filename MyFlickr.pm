package MyFlickr;
use strict;
use warnings;
use Flickr::API;
use Data::Dumper;
use Browser::Open qw|open_browser|;
use Flickr::Upload;
use XML::XPath;
use XML::Simple;
use utf8;
#use Encode::Locale;
use Encode;

my $api_key = 'c17dfef7e22e88fea9e4f262ffbed050';
my $shared_secret = 'b6594d9e991af066';

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
	warn qq|Warning in askUser:\n$r| and return undef unless $r =~ /<rsp[^>]+stat\s*=\s*"ok".*>/i;
	$r =~ /<frob>(.+)<\/frob>/ or warn(qq|Warning:\n$r|) and return undef;
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
	warn qq|Warning:\n$r| and return undef unless $r =~ /<rsp[^>]+stat\s*=\s*"ok".*>/i;
	print 'Extract token...';
	$r =~ /<token>(.+)<\/token>/ or warn qq|Warning:\n$r| and return undef;
	my $token = $1;
	print 'Save token...';
	$self->{user}->{auth_token} = $token;
	$r =~ /<user\s+nsid\s*=\s*"([^"]+)"\s+username\s*=\s*"([^"]+)"\s+fullname\s*=\s*"([^"]+)"/
		or die qq|ERROR:\n$r|;
	$self->{user}->{nsid} = $1;
	$self->{user}->{username} = decode('utf8' => $2);
	$self->{user}->{fullname} = decode('utf8' => $3);
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
	warn qq|Wrong answer:\n\t$answer|
		and return undef if $xp->getNodeText('/rsp/@stat')->value ne 'ok';
	my $nphotos = $xp->getNodeText('/rsp/photos/@total')->value;
	return $nphotos;
}
sub checkAllFlickrPhotos{
	my ($self,$callback) = @_;
	my $inFlickr = {byID => {}, byPhotoID => {}};
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
			$result = eval{$xs->XMLin($answer);};
			die "Error getting all flickr photos\n".Dumper($result) if $result->{stat} ne 'ok';
			$callback->( #give some feedback about progress
				$result->{photos}->{page} * $result->{photos}->{perpage}
				, $result->{photos}->{total}
			) if defined $callback and ref $callback eq 'CODE';
			my $photos = $result->{photos}->{photo};
			foreach (keys %$photos){
				my $mtags = $photos->{$_}->{'machine_tags'};
				my @mtags = split /\s+/, $mtags;
				my %tags = map{split /\s*=\s*/,$_} @mtags;
				my $id = $tags{'meta:id'} // '';
				$inFlickr->{byID}->{$id} = $inFlickr->{byPhotoID}->{$_} = $_;
			}			
		}while($result->{photos}->{page} < $result->{photos}->{pages})
	};
	warn $@ if $@;
	return $inFlickr;
}
sub upload{
	my ($self,$file,@tags) = @_;
	my $photoid = eval {$uploader->upload(
		photo => $file,
		auth_token => $self->{user}->{auth_token},
		tags => (join ' ', @tags),
		is_public => 0,
		hidden => 0
	)} or warn "Failed to upload $file:\n$@";
	return $photoid;
}
sub replace{
	my ($self,$file,$photoid,@tags) = @_;
	my $new = eval{$uploader->upload(
		uri => 'http://api.flickr.com/services/replace/',
		photo => $file,
		photo_id => $photoid,
		auth_token => $self->{user}->{auth_token},
		tags => (join ' ', @tags),
	)} or warn "Failed to replace photo $photoid";
	return $new;
}
sub getAllSetsByTitle{
	my ($self) = @_;
	my $photosets = {};
	eval {
		my $result;
		my $page = 1;
		do{
			my $response = $api->execute_method('flickr.photosets.getList', {
			  user_id => $self->{user}->{nsid},
			  auth_token => $self->{user}->{auth_token},
			  per_page => 500,
			  page => $page++
			});
			my $answer  = $response->decoded_content(charset => 'none');
			$result = eval{$xs->XMLin($answer);};
			warn "Error getting the photosets:\n".Dumper($result) if $result->{stat} ne 'ok';
			return undef unless $result->{photosets}->{total} > 0;
			return $photosets->{$result->{photosets}->{photoset}->{title}} = [
				$result->{photosets}->{photoset}
			] if 1 == $result->{photosets}->{total};
			push @{$photosets->{$result->{photosets}->{photoset}->{$_}->{title}}}, $_
				foreach (keys %{$result->{photosets}->{photoset}});	
		}while($result->{photosets}->{page} < $result->{photosets}->{pages})
	};
	warn $@ if $@;
	return $photosets
}
sub createSet{
	my ($self,$title,$primary_photo_id) = @_;
	print "Create a new set with name $title";
	my $setID = eval{
		my $response = $api->execute_method('flickr.photosets.create', {
		  user_id => $self->{user}->{nsid},
		  auth_token => $self->{user}->{auth_token},
		  title  => $title,
		  primary_photo_id => $primary_photo_id
		});
		my $answer  = $response->decoded_content(charset => 'none');
		my $result = eval {$xs->XMLin($answer);};
		die "Impossible to create the set $title\n".Dumper($result) if $result->{stat} ne 'ok';;
		$result->{photoset}->{id};
	};
	die "Warn at createSet:\n<$@>" if $@;
	return $setID;
}
sub addPhotos2Set{
	my ($self,$set,@photos) = @_;
	my $setID;
	if (defined $set->{setid}){
	#we must test if it exists
		$setID = $set->{setid};	
	}else{
		my $photosets = $self->getAllSetsByTitle();
		my @gids = map {@{$photosets->{$_}}} grep{$_ eq $set->{name}} map {local $,=","; print $_, ' = ', $set->{name};$_} 
			keys %$photosets;
		if (@gids){
			print "Found a set with same name =  $set->{name}";
			$setID = $gids[0];	
		}else{
			my $title = encode('UTF-8' => $set->{name});
			$setID = $self->createSet($title,$photos[0]);
		}
	}
	$self->movePhotos2set($setID,@photos) if defined $setID;
	return $setID;
}
sub movePhotos2set{
	my ($self,$setID,@photos) = @_;
	foreach(@photos){
		eval {
			my $response = $api->execute_method('flickr.photosets.addPhoto', {
			  user_id => $self->{user}->{nsid},
			  auth_token => $self->{user}->{auth_token},
			  photoset_id  => $setID,
			  photo_id => $_
			});				
		};
		warn $@ if $@;
	}
}