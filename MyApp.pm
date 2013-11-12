use Wx 0.15 qw[:allclasses];
use strict;
use warnings qw(all);
use MyFlickr;
use Digest::SHA qw(sha256);
use File::HomeDir;
use Cwd qw{abs_path};
use threads;
use threads::shared;
use Data::Dumper;
use JSON;
use Image::JpegCheck;
use utf8;
use Encode::Locale;
use Encode;
######################my code ######################################
#use open qw|:locale|;
#binmode STDOUT, ':encoding(console_out)';
#binmode STDOUT, ':encoding(locale)';
$\ = "\n";

my $flickr = MyFlickr->new();
my $matching_pattern = '.';
my $home = File::HomeDir->my_home;

my $dbfile = qq|$home/.d2f.conf|;
#my $json  = JSON->new->utf8->pretty;
my $json  = JSON->new->pretty;
#my $json  = JSON->new->utf8;
sub openJSON{
	my ($file) = @_;
	return undef unless -r $file;
	my $result = undef;
	eval{
		local $/;
		open my $f, '<:encoding(UTF-8)', "$file" or die "Cannot open $file";
		#open my $f, '<', "$file" or die "Cannot open $file";
		#binmode $f;
		my $json_text   = <$f>;
		close $f;
		$result = $json->decode( $json_text );
	};
	warn $@ if $@;
	return $result;  
}
sub saveJSON{
	my ($file,$ref) = @_;
	eval{
		open my $f, '>:encoding(UTF-8)', "$file" or die "Cannot open $file";
		#open my $f, '>', "$file" or die "Cannot open $file";
		#binmode $f;
		print $f $json->encode($ref);
		close $f;
	};
	warn $@ if $@;
	return 1;
}

sub openDB{
  my ($file) = @_;
  my $result = openJSON($file) // {users => {}};
  return $result;
}
my $db = openDB($dbfile);

$flickr->{user} = $db->{users}->{$db->{currentUser}}->{flickr} // {}
	if $db->{currentUser} and defined $db->{users}->{$db->{currentUser}};

print Dumper $db;

my $syncDB = sub{
	saveJSON($dbfile,$db);
};

######some stuff to deal with the resources release of finished threads#####
my @finishedThreads :shared = ();
my $releaseResourcesT = async{
	while(1){
		lock @finishedThreads;
		cond_wait(@finishedThreads) until @finishedThreads > 0;
		foreach(@finishedThreads){
			threads->exit() unless defined $_;
			my $t = threads->object($_);
			$t->join() if defined $t;
		}
		undef @finishedThreads;
	}
};


my $releaseThisThread = sub{ #should be called from a thread which is finishing 
	lock @finishedThreads;
	push @finishedThreads, threads->self()->tid();
	cond_signal @finishedThreads;
};
my $wait4TheseThreads2Join = sub{
	$_->join() foreach(@_);
};

my $loadUser = sub{
	$db->{currentUser} = $flickr->{user}->{nsid} if defined $flickr->{user};
	$db->{currentUser} //= '';
	$db->{users}->{$db->{currentUser}} //= {};
	$db->{users}->{$db->{currentUser}}->{flickr} = $flickr->{user} // {};
	$db->{users}->{$db->{currentUser}}->{folders} //= {};
	$db->{users}->{$db->{currentUser}}->{options} //= {};
	$syncDB->();
};
my $removeUser = sub{
	$db->{currentUser} = '';
	$syncDB->();
};

$loadUser->();

sub computeFileID{
	warn(q|getFileID: File not defined|) and return undef unless defined $_[0];
	warn(q|getFileID: File not $_[0] found|) and return undef unless -e $_[0];
	my $sha = Digest::SHA->new();
	$sha->addfile($_[0],'b');
	my $s = -s $_[0]; #size
	return $sha->hexdigest.$s;
}

sub getFolders{
	my $dir = shift or return ();
	return ($dir, getSubFolders($dir));
}

sub getSubFolders{
	my $dir = shift;
	my @subdirs = ();
	eval{
		opendir DIR, $dir or die qq|Wasn't possible to open folder $dir : $!|;
		my @dirs = grep {-d qq|$dir/$_| and $_ ne '.' and $_ ne '..'} readdir DIR;
		closedir DIR;
		@subdirs = map {getFolders(qq|$dir/$_|)} @dirs; 
	};
	warn $@ if $@;
	return @subdirs;
}

sub getFiles{
	my ($dir) = @_;
	my @files = ();
	eval{
		opendir DIR, $dir or die qq|Wasn't possible to open folder $dir : $!|;
		@files = grep {/\.(jpg|jpeg|png)$/i} readdir DIR;
	};
	warn $@ if $@;
	return @files;
}

sub getDirInfo{
	my ($path) = @_;
	my $info = openJSON(qq|$path/.d2f.info|) // {};
	$info->{users} //= {};
	return $info;
}
sub saveDirInfo{
	my ($path,$info) = @_; 
	saveJSON(qq|$path/.d2f.info|,$info);
}


my $update_folders = sub{
	my $wnd = shift;
	$wnd->{uploadProgressBarSizer_staticbox}->SetLabel('Processing folders...');
	my @folders = map {encode(locale_fs => $_)} @_;
	$wnd->{uploadProgressBarSizer_staticbox}->SetLabel('Selecting folders...');
	my @subfolders = grep {
		my (@steps) = split /\/|\\/;
		$steps[$#steps] =~ qr/$matching_pattern/i
	} map {getFolders($_)} @folders;
	my $nfolders = scalar @subfolders;
	$wnd->{uploadProgressBar}->SetRange($nfolders);
	#syncProgressPanel
	my $inFlickr = undef;
	my $cnt = 0;
	my $retry = 1;
	while(my $folder = shift @subfolders){
		#my (@steps) = split /\/|\\/, $folder;
		$wnd->{uploadProgressBarSizer_staticbox}->SetLabel(
			"Uploading folders ($cnt of $nfolders done)"
		);
		$wnd->{uploadProgressBar}->SetValue($cnt++);
		#next if $steps[$#steps] !~ qr/$matching_pattern/i;
		print "Processing folder $folder (${retry}th retry";
		eval{
			my $dirInfo = getDirInfo($folder);
			$dirInfo->{users}->{$db->{currentUser}} //= {};
			my $fileInfo = $dirInfo->{users}->{$db->{currentUser}}->{files} //= {};
			my @files = getFiles($folder);
			$wnd->{syncProgressBar}->SetRange(scalar @files);
			my @photos = ();
			eval {
				my $c = 0;
				my $nfiles = scalar @files;
				foreach (@files){
					$wnd->{SyncProgressBarSizer_staticbox}->SetLabel(
						"Uploading files ($c of $nfiles done)"
					);
					$wnd->{syncProgressBar}->SetValue($c++);
					$fileInfo->{$_} //= {};
					$fileInfo->{$_}->{filename} = $_;
					$fileInfo->{$_}->{fullpathname} = abs_path qq|$folder/$_|;
					next unless defined newModificationTime($fileInfo->{$_});	
					next unless defined newFingerPrint($fileInfo->{$_});
					$inFlickr //= $flickr->checkAllFlickrPhotos();	#only happens once and only if needed		
					next unless defined notInFlickr($fileInfo->{$_},$inFlickr);
					next unless defined (my $photoid = uploadFile($fileInfo->{$_},$inFlickr));
					push @photos, $photoid;
				}
			};
			warn "Error uploading files in folder $folder:\n[$@]" if $@;
			saveDirInfo($folder,$dirInfo);
			$dirInfo->{users}->{$db->{currentUser}}->{flickrset} //= {};
			$dirInfo->{users}->{$db->{currentUser}}->{flickrset}->{name} 
				//= decode(locale => abs_path $folder);		
			unless (defined $dirInfo->{users}->{$db->{currentUser}}->{flickrset}->{setid}){
				@photos = map{$fileInfo->{$_}->{photoID}} 
					grep{defined $fileInfo->{$_}->{photoID}} @files;
			}
			$dirInfo->{users}->{$db->{currentUser}}->{flickrset}->{setid} 
				= $flickr->addPhotos2Set(
					$dirInfo->{users}->{$db->{currentUser}}->{flickrset},
					@photos
				) if @photos;
			saveDirInfo($folder,$dirInfo);
		};
		#This is a workaround
		warn "Error in folder $folder:\n[$@]" and redo if $@ and $retry++ < 10;
		$retry = 1;
	}
};
sub newModificationTime{
	my ($file) = @_;
	my $mtime =  (stat($file->{fullpathname}))[9];
	return $file->{mtime} = $mtime unless defined $file->{mtime} and $file->{mtime} eq $mtime;
	print "File $file->{filename} was previously uploaded and its modification time was not modified since then";
	return undef;
}
sub newFingerPrint{
	my ($file) = @_;
	my $id = computeFileID($file->{fullpathname});
	return $file->{id} = $id unless defined $file->{id} and $file->{id} eq $id;
	print "File $file->{filename} was previously uploaded and its fingerprint was not modified since then";
	return undef;
}
sub notInFlickr{
	my ($file, $inFlickr) = @_;
	return 1 unless defined $inFlickr->{$file->{id}};
	print "File $file->{filename} already in flickr with photoid = ", $inFlickr->{$file->{id}};
	$file->{photoID} = $inFlickr->{$file->{id}};
	return undef;
}
sub uploadFile{
	my ($file, $inFlickr) = @_;
	my $size = -s $file->{fullpathname};
	my @steps = reverse split /\//, $file->{fullpathname};	
	my @tags = (
		(map {qq|step:l$_="$steps[$_]"|} (1..$#steps)),
		qq|file:name="$file->{filename}"|,
		qq|file:size="$size"|,
		qq|meta:id="$file->{id}"|,
	);
	#print "Prepare to upload $file->{filename}";
	my $photoid = eval{
		unless ($file->{photoID}){
			my $photoid = $flickr->upload($file->{fullpathname},@tags) or return undef;
			print "File $file->{filename} uploaded to flickr (photoid = $photoid)";
			return $file->{photoID} = $inFlickr->{$file->{id}} = $photoid;
		}elsif(is_jpeg($file->{fullpathname})){
			#a older version exist in flickr
			$flickr->replace($file->{fullpathname},$file->{photoID},@tags) or return undef;	
			print "File $file->{filename} replaced on flickr (photoid = $file->{photoID})";
			return $file->{photoID};
		}else{
			print "File $file->{filename} is not a valid JPEG file";
			return undef;
		}
	};
	warn "Error uploaginf file $file->{filename}:\n$@" if $@;
	return $photoid;
}
######################End of my code ######################################


package MyApp;
use Wx qw[:everything];
use parent qw(MyFrame);
use strict;
use Data::Dumper;
use threads;
use threads::shared;
use Encode::Locale;
use Encode;

######aux functions#########################

sub __showMainPanel{
	my ($self) = @_;
	$self->{mainPanel}->Show(1);
	$self->__hideLoginPanel();
	$self->{mainPanel}->GetParent()->GetSizer()->Layout();
}
sub __hideMainPanel{
	my ($self) = @_;
	$self->{mainPanel}->Show(0);
}
sub __showLoginPanel{
    my ($self) = @_;
	$self-> __hideMainPanel();
	$self->{getTokenPanel}->Show(0);
	$self->{loginPanel}->Show(1);
	$self->{loginPanel}->GetParent()->GetSizer()->Layout();
	$self->__showAskAuthPanel();
}
sub __hideLoginPanel{
	my ($self) = @_;
	$self->{loginPanel}->Show(0);
}
sub __showCheckTokenPanel{
	my ($self) = @_;
	$self->__hideAskAuthPanel();
	$self->{getTokenPanel}->Show(1);
	$self->{getTokenPanel}->GetParent()->GetSizer()->Layout();
}
sub __hideCheckTokenPanel{
	my ($self) = @_;
	$self->{getTokenPanel}->Show(0);
}
sub  __showAskAuthPanel{
	my ($self) = @_;
	$self->__hideCheckTokenPanel();
	$self->{askAuthPanel}->Show(1);
	$self->{askAuthPanel}->GetParent()->GetSizer()->Layout();
}
sub  __hideAskAuthPanel{
	my ($self) = @_;
	$self->{askAuthPanel}->Show(0);
}

sub __setStatus{
	my ($self) = @_;
	if ($db->{currentUser} ne ''){
		my $name = $db->{users}->{$db->{currentUser}}->{flickr}->{fullname};
		$self->SetStatusText(
		  'User '
		  .  $name
		  . ' ('
		  . $db->{users}->{$db->{currentUser}}->{flickr}->{username}
			. ')'
		,0);
	}else{
				$self->SetStatusText('The user is not yet authorized',0);
	}
}

sub __setUserOptions{
	my ($self) = @_;
	my $p = 0;
	foreach (sort keys $db->{users}->{$db->{currentUser}}->{folders}){
		$self->{foldersList}->InsertStringItem($p++,$_);
	}
	$self->{backupRecursiveOptionSomeChoiceValue}->ChangeValue( 
		$db->{users}->{$db->{currentUser}}->{options}->{filter}->{some}->{value}
	) if defined $db->{users}->{$db->{currentUser}}->{options}->{filter}->{some}
		and defined $db->{users}->{$db->{currentUser}}->{options}->{filter}->{some}->{value};
	$self->{backupRecursiveOptionSomeChoiceName}->SetValue(
		$db->{users}->{$db->{currentUser}}->{options}->{filter}->{some}->{action}
	) if defined $db->{users}->{$db->{currentUser}}->{options}->{filter}->{some}
		and defined $db->{users}->{$db->{currentUser}}->{options}->{filter}->{some}->{action};
	$self->{backupRecursiveOptionSome}->SetFocus()
		if defined $db->{users}->{$db->{currentUser}}->{options}->{filter}->{some}
		and defined $db->{users}->{$db->{currentUser}}->{options}->{filter}->{some}->{action}	
		and defined $db->{users}->{$db->{currentUser}}->{options}->{filter}->{some}->{value};	
}

###############################

sub new {
    my( $self) = @_;
	$self = $self->SUPER::new();

	$self->SetSize(Wx::Size->new(550, 450));
	Wx::Event::EVT_CLOSE($self,sub{
			my ($self, $event) = @_;
			$syncDB->();
			print "Goodby";
			$event->Skip;
	});

	if($db->{currentUser} ne ''
	   	and defined $db->{users}->{$db->{currentUser}}
	   	and defined $db->{users}->{$db->{currentUser}}->{flickr}
	   	and defined $db->{users}->{$db->{currentUser}}->{flickr}->{auth_token}){
		$self->__showMainPanel();
		$self->__setUserOptions();
	}else{
		$self->__showLoginPanel();
	}
	$self->__setStatus();
	$self->{uploadProgressBar}->SetRange(100);
	$self->{uploadProgressBar}->SetValue(0);
	#$self->{syncProgressPanel}->Hide();
	#$self->{uploadProgressPanel}->Hide();
	$self->{backupSizer}->Show($self->{syncProgressPanel},0,1);
	$self->{backupSizer}->Show($self->{uploadProgressPanel},0,1);
	return $self;
}

sub go_login {
	my ($self) = @_;
	$self->__showLoginPanel();
}

sub go_logout {
	my ($self) = @_;
	$removeUser->();
	$syncDB->();
	$self->__showLoginPanel();
	$self->SetStatusText('The user is not authorized anymore',0);
}

my $lastDirectory = "";
sub go_browse {
	my ($self) = @_;
	my $dlg = Wx::DirDialog->new(
	  $self->{backupSubPanel},
	  "Please, choose a folder to backup",
	  $lastDirectory,
	  wxDD_CHANGE_DIR|wxDD_DIR_MUST_EXIST
	);
	if ($dlg->ShowModal == wxID_OK){
		$lastDirectory = $dlg->GetPath() or return;
		my $p = $self->{foldersList}->GetItemCount;
		$self->{foldersList}->InsertStringItem($p,$lastDirectory);
		$db->{users}->{$db->{currentUser}}->{folders}->{$lastDirectory} = time;
	}
}

sub go_remove_selected {
	my ($self) = @_;
	my $removeFromDB = sub{
		delete $db->{users}->{$db->{currentUser}}->{folders}->{$self->{foldersList}->GetItemText(shift)};
	};
	my $p = $self->{foldersList}->GetFirstSelected;
	$removeFromDB->($p);
	$self->{foldersList}->DeleteItem($p);
	while(($p = $self->{foldersList}->GetNextSelected($p)) >= 0){
		$removeFromDB->($p);
		$self->{foldersList}->DeleteItem($p)
	}
}

sub go_remove_all {
	my ($self) = @_;
	$self->{foldersList}->ClearAll;
	$db->{users}->{$db->{currentUser}}{folders} =  {};
}

sub go_backup {
	my ($self) = @_;
	unless(defined $flickr->{user} and defined $flickr->{user}->{nsid}){
		print "User not login";
		return $self->go_login();
	}
	my $count = $self->{foldersList}->GetItemCount;
	my @folders = map {$self->{foldersList}->GetItemText($_)} (0..$count-1);
	$self->{backupSizer}->Show($self->{uploadProgressPanel},1,1);
	$self->{backupSizer}->Show($self->{syncProgressPanel},1,1);
	async{
		eval{
			$update_folders->($self,@folders);
		};
		warn "Error updating folders:[$@]" if $@;
		$releaseThisThread->();
		$self->{backupSizer}->Show($self->{uploadProgressPanel},0,1);
		$self->{backupSizer}->Show($self->{syncProgressPanel},0,1);
		print "End";
	};
}

sub go_exit {
	my ($self) = @_;
	$self->Close;
}

sub go_close {
	my ($self) = @_;
	$self->Close;
}

sub go_main {
	my ($self) = @_;
	$self->__showMainPanel();
}

sub go_askAuth {
	my ($self) = @_;
	$flickr->askAuth() or warn q|ask auth error|;
	$self->__showCheckTokenPanel();
}

sub go_getToken {
	my ($self) = @_;
	print 'Get token...';
	$flickr->getToken() or return $self-> __showAskAuthPanel();
	$self->__showMainPanel();
	$loadUser->();
	$self->__setStatus();
}

sub go_matching_all{
	$matching_pattern = '.+';
	$db->{users}->{$db->{currentUser}}->{options}->{filter} = shared_clone {all => 1};	
}
sub _pattern{
	my ($self) = @_;
	my $choice = {};
    my $action = $self->{backupRecursiveOptionSomeChoiceName}->GetValue();		
    my $value = $self->{backupRecursiveOptionSomeChoiceValue}->GetValue();
	if ($action eq 'is equal to'){
		$matching_pattern = qq|^$value\$|;
		$choice = {action => 'is equal to', value => $value};
	}elsif($action eq 'not equal to'){
		$matching_pattern = qq|^(?!$value\$).+\$|;	
		$choice = {action => 'not equal to', value => $value};
	}elsif($action eq 'contains'){
		$matching_pattern = qq|$value|;	
		$choice = {action => 'contains', value => $value};
	}elsif($action eq 'not contains'){
		$matching_pattern = qq|^(?!.*$value).|;	
		$choice = {action => 'not contains', value => $value};
	}elsif($action eq 'starts with'){
		$matching_pattern = qq|^$value|;	
		$choice = {action => 'starts with', value => $value};
	}elsif($action eq 'not starts with'){
		$matching_pattern = qq|^(?!$value).|;	
		$choice = {action => 'not starts with', value => $value};
	}elsif($action eq 'ends with'){
		$matching_pattern = qq|$value\$|;	
		$choice = {action => 'ends with', value => $value};
	}elsif($action eq 'ends with'){
		$matching_pattern = qq|^(?!.*$value\$).|;	
		$choice = {action => 'ends with', value => $value};
	}else{
		$matching_pattern = qq|^\$|;	
		$choice = {action => ''};
	}
	#print $matching_pattern;
	$db->{users}->{$db->{currentUser}}->{options}->{filter} = shared_clone {some => $choice};	
}
sub go_matching_some{
	shift->_pattern;
	#$matching_pattern = qr/^$/;
}
sub go_matching_action{
	shift->_pattern;
}
sub go_matching_text_enter{
	shift->_pattern;
}

1;

