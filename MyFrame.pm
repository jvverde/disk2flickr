# generated by wxGlade 0.6.8 (standalone edition) on Tue Oct 29 09:46:14 2013
#
# To get wxPerl visit http://wxPerl.sourceforge.net/
#

use Wx 0.15 qw[:allclasses];
use strict;
use MyFlickr;
use Digest::SHA qw(sha256);
use File::HomeDir;
use Storable qw(lock_retrieve lock_store freeze thaw);
use File::Copy qw(cp);
use Cwd qw{abs_path};
use threads;
use threads::shared;
use Thread::Queue;
use Thread::Semaphore;
use Data::Dumper;
use JSON;
######################my code ######################################

$\ = "\n";

my $flickr = MyFlickr->new();
my $pattern = qr/./;
my $stop = 0;
my @tags = ();

my $filesQ = Thread::Queue->new(); #mark queue
my $fileIDQ = Thread::Queue->new(); #mark queue
my $checkFlickrQ = Thread::Queue->new(); #mark queue
my $uploadQ = Thread::Queue->new(); #mark queue
my $foldersQ = Thread::Queue->new(); #mark queue
#my $filesS = Thread::Semaphore->new(50);
#my $stopS = Thread::Semaphore->new(0);
my $home = File::HomeDir->my_home;


my $dbfile = qq|$home/.disk2flick|;
#my $json  = JSON->new->utf8->pretty;
my $json  = JSON->new->utf8;
my $db = shared_clone do{
	if (-r $dbfile){
		local $/;
	  open F, '<', $dbfile;
	  my $json_text   = <F>;
	  close F;
		cp $dbfile, qq|$dbfile.old|;
	  $json->decode( $json_text );
	}else{
		{}
	}
};

$db->{cnt}++;
$db->{users} //= shared_clone {};
$flickr->{user} = $db->{users}->{$db->{currentUser}}->{flickr}->{usr}
	if $db->{currentUser}
		and defined $db->{users}->{$db->{currentUser}}
		and defined $db->{users}->{$db->{currentUser}}->{flickr};

#print Dumper $db;

my $syncDB = sub{
	open F, '>', $dbfile;
	print F $json->encode($db);
	close F;
};

my $syncingFlickr :shared = 0;
sub syncFlickr{
	{ #create a local scope for lock
		lock $syncingFlickr;
		return if $syncingFlickr;
		$syncingFlickr = 1;
	}
	async{
		eval{
			print "Start sync from flickr for user $db->{currentUser}";
			my $photos = $flickr->checkAllFlickrPhotos();
			print "Sync from flickr finished";
			$db->{users}->{$db->{currentUser}}->{flickr}->{photos} = $photos;
		};
		warn $@ if $@;
		lock $syncingFlickr;
		$syncingFlickr = 0;
		cond_signal($syncingFlickr);
	};
}
sub checkShared{
	$db->{users}->{$db->{currentUser}} //= shared_clone {};
	$db->{users}->{$db->{currentUser}}->{flickr} //= shared_clone {};
	$db->{users}->{$db->{currentUser}}->{flickr}->{photos} //= shared_clone {};
	$db->{users}->{$db->{currentUser}}->{flickr}->{photos}->{photosIDs} //= shared_clone {};
	$db->{users}->{$db->{currentUser}}->{flickr}->{photos}->{filesIDs} //= shared_clone {};
	$db->{users}->{$db->{currentUser}}->{flickr}->{usr} = shared_clone($flickr->{user} // {});
	$db->{users}->{$db->{currentUser}}->{folders} //= shared_clone {};
	$db->{users}->{$db->{currentUser}}->{files} //= shared_clone {};
	$db->{users}->{$db->{currentUser}}->{fileIDs} //= shared_clone {};
	$db->{users}->{$db->{currentUser}}->{photoIDs} //= shared_clone {};
}
my $loadUser = sub{
	$db->{currentUser} = $flickr->{user}->{nsid}
		if(defined $flickr->{user} and defined $flickr->{user}->{nsid});
	$db->{currentUser} //= '';
	checkShared();
	syncFlickr() if $db->{currentUser} ne '';
	$syncDB->();
};
my $removeUser = sub{
	$db->{currentUser} = '';
	checkShared();
	$syncDB->();
};

$loadUser->();

sub texit{
	print "Exit thread\n";
	threads->exit();
}

my %threads = ();

$threads{filesT} = threads->create({exit => 'threads_only'}, sub {
	$SIG{'KILL'} = \&texit;
	while(1){
		eval{
			while (my $filename = $filesQ->dequeue()){
				my $mtime =  (stat($filename))[9];
				if(0 and defined $db->{users}->{$db->{currentUser}}->{files}->{$filename}
					and $db->{users}->{$db->{currentUser}}->{files}->{$filename}->{mtime} eq $mtime){
					print "File $filename was previously uploaded and was not modified since then";
				}else{
					$fileIDQ->enqueue({filename=>$filename,mtime=>$mtime});
				}
			}
		};
		threads->exit() unless $@;
		warn "$@\nI will Try again";
	}
});
$threads{filesIDT} = threads->create({exit => 'threads_only'}, sub {
	$SIG{'KILL'} = \&texit;
	while(1){
		eval{
			while (my $file = $fileIDQ->dequeue()){
				print "File=>",$file->{filename};
				my $id = computeFileID($file->{filename});
				if (0 and $db->{users}->{$db->{currentUser}}->{fileIDs}->{$id}){
					my $re = qr/$db->{users}->{$db->{currentUser}}->{fileIDs}->{$id}->{filename}/;
					if( $file->{filename} =~ /^re$/i){
						print "File $file->{filename} was previously uploaded and still have the same signature and same name";
					}else{
						print "File $file->{filename} was previously uploaded and still have the same signature but a diferente name $db->{users}->{$db->{currentUser}}->{fileIDs}->{$id}->{filename}";
						$db->{users}->{$db->{currentUser}}->{files}->{$file->{filename}} = shared_clone $file;
					}
				}else{
					$file->{id} = $id;
					$checkFlickrQ->enqueue($file);
				}
			}
		};
		threads->exit() unless $@;
		warn "$@\nI will Try again";
	}
});
$threads{checkFlickrT} = threads->create({exit => 'threads_only'}, sub {
	$SIG{'KILL'} = \&texit;
	while(1){
		eval{
			while (my $file = $checkFlickrQ->dequeue()){
				unless (defined $db->{users}->{$db->{currentUser}}->{flickr}->{photos}->{filesIDs}->{$file->{id}}){
					$uploadQ->enqueue($file);
				}else{
					print "File ($file->{filename}) already on flick. Won't duplicate";
					$db->{users}->{$db->{currentUser}}->{files} = shared_clone $file;
					$db->{users}->{$db->{currentUser}}->{fileIDs} = shared_clone $file;
				}
			}
		};
		threads->exit() unless $@;
		warn "$@\nI will Try again";
	}
});
$threads{uploadT} = threads->create({exit => 'threads_only'}, sub {
	$SIG{'KILL'} = \&texit;
	#my $db = lock_retrieve($dbfile);
	while(1){
		eval{
			while (my $file = $uploadQ->dequeue()){
				my @localtags = (
				  $file->{id},
					qq|dir:filename="$file->{filename}"|,
					qq|meta:id="$file->{id}"|,
					qq|time:modification="$file->{mtime}"|,
					map {qq|dir:step="$_"|} grep {/[^\s]/} split /\//, $file->{filename}
				);
				#pop @localtags; #discard filename from dir:step tags
				print "Prepare to upload $file->{filename}";
				my $photoid = $flickr->upload($file->{filename},@tags, @localtags)
					or warn "Failed to upload $file" and next;
				print "File $file->{filename} uploaded to flickr (photoid = $photoid)";
				#$db->{ids}->{$db->{users}->{nsid}}->{$file->{id}} = $photoid;
				$file->{photoid} = $photoid;
				$db->{users}->{$db->{currentUser}}->{files}->{$file->{filename}} = shared_clone $file;
				$db->{users}->{$db->{currentUser}}->{fileIDs}->{$file->{id}} = shared_clone $file;
				$db->{users}->{$db->{currentUser}}->{photoIDs}->{$file->{photoid}} = shared_clone $file;
				#print Dumper $db;
				#lock_store $db, $dbfile;
				$syncDB->();
			}
		};
		threads->exit() unless $@;
		warn "$@\nI will Try again";
	}
});

sub computeFileID{
	warn(q|getFileID: File not defined|) and return undef unless defined $_[0];
	warn(q|getFileID: File not $_[0] found|) and return undef unless -e $_[0];
	my $sha = Digest::SHA->new();
	$sha->addfile($_[0],'b');
	return $sha->hexdigest;
}

sub getFolder{
	my $dir = shift;
	exit if $stop;
	print qq|Get dir $dir|;
	if ($dir =~ $pattern){
		print qq|backup dir $dir|;
		backup($dir,@tags);
	}
	getSubFolders($dir);
}

my $getFolder = \&getFolder;

sub getSubFolders{
	my $dir = shift;
	opendir DIR, $dir or warn qq|Nao foi possivel abrir o directorio $dir| and return;
	my @subdirs = grep {-d qq|$dir/$_| and $_ ne '.' and $_ ne '..'} readdir DIR;
	closedir DIR;
	foreach my $subdir (@subdirs){
		getFolder(qq|$dir/$subdir|);
	}
}

sub backup{
	my ($dir,@tags) = @_;

	opendir DIR, $dir or warn qq|'nao foi possivel abrir o directorio corrente'|;

	my @files = grep {/\.(jpg|png)$/i} readdir DIR;
	foreach (@files){
		my $path = abs_path(qq|$dir/$_|);
		print "file=$path";
		eval{
			$filesQ->enqueue($path);
		};
		warn $@ if $@;
		exit if $stop;
	}
}

$threads{browseT} = threads->create({exit => 'threads_only'}, sub {
	$SIG{'KILL'} = \&texit;
	while(1){
		eval{
			while (my $folder = $foldersQ->dequeue()){
				{
					lock $syncingFlickr;
  				cond_wait($syncingFlickr) while($syncingFlickr);
  			}
				getFolder($folder);
			}
		};
		threads->exit() unless $@;
		warn "$@\nI will Try again";
	}
});

my $stopThreads = sub{
	$filesQ->end;
	$fileIDQ->end;
	$checkFlickrQ->end;
	$uploadQ->end;
	$foldersQ->end;
	foreach(keys %threads){
		print "wait $_";
		$threads{$_}->join();
	}
};
######################End of my code ######################################


# begin wxGlade: dependencies
# end wxGlade

# begin wxGlade: extracode
# end wxGlade

package MyFrame;

use Wx qw[:everything];
use base qw(Wx::Frame);
use strict;
use Data::Dumper;
use Carp;

######Manual generated functions#########################

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
		$self->SetStatusText(
		  'User '
		  .  $db->{users}->{$db->{currentUser}}->{flickr}->{usr}->{fullname}
		  . '('
		  . $db->{users}->{$db->{currentUser}}->{flickr}->{usr}->{username}
			. ')'
		,0);
	}else{
				$self->SetStatusText('The user is not yet authorized',0);
	}
}

sub __fillFoldersList{
	my ($self) = @_;
	my $p = 0;
	foreach (sort keys $db->{users}->{$db->{currentUser}}->{folders}){
		$self->{foldersList}->InsertStringItem($p++,$_);
	}
}

######end of manual generated functions#########################

sub new {
    my( $self, $parent, $id, $title, $pos, $size, $style, $name ) = @_;
    $parent = undef              unless defined $parent;
    $id     = -1                 unless defined $id;
    $title  = ""                 unless defined $title;
    $pos    = wxDefaultPosition  unless defined $pos;
    $size   = wxDefaultSize      unless defined $size;
    $name   = ""                 unless defined $name;

# begin wxGlade: MyFrame::new

	$style = wxDEFAULT_FRAME_STYLE
		unless defined $style;

	$self = $self->SUPER::new( $parent, $id, $title, $pos, $size, $style, $name );
	$self->{loginPanel} = Wx::ScrolledWindow->new($self, -1, wxDefaultPosition, wxDefaultSize, wxTAB_TRAVERSAL);
	$self->{getTokenPanel} = Wx::Panel->new($self->{loginPanel}, -1, wxDefaultPosition, wxDefaultSize, );
	$self->{getTokenInfoSubPanel} = Wx::Panel->new($self->{getTokenPanel}, -1, wxDefaultPosition, wxDefaultSize, wxDOUBLE_BORDER|wxTAB_TRAVERSAL);
	$self->{askAuthPanel} = Wx::Panel->new($self->{loginPanel}, -1, wxDefaultPosition, wxDefaultSize, );
	$self->{askAuthInfoSubPanel} = Wx::ScrolledWindow->new($self->{askAuthPanel}, -1, wxDefaultPosition, wxDefaultSize, wxDOUBLE_BORDER|wxTAB_TRAVERSAL);
	$self->{mainPanel} = Wx::ScrolledWindow->new($self, -1, wxDefaultPosition, wxDefaultSize, wxTAB_TRAVERSAL);
	$self->{backupNotebook} = Wx::Notebook->new($self->{mainPanel}, -1, wxDefaultPosition, wxDefaultSize, 0);
	$self->{backupPanel} = Wx::Panel->new($self->{backupNotebook}, -1, wxDefaultPosition, wxDefaultSize, );
	$self->{backupSubPanel} = Wx::Panel->new($self->{backupPanel}, -1, wxDefaultPosition, wxDefaultSize, );
	$self->{backupRecursiveOptionsPanel} = Wx::Panel->new($self->{backupSubPanel}, -1, wxDefaultPosition, wxDefaultSize, );
	$self->{backupRecursiveOptionsSizer_staticbox} = Wx::StaticBox->new($self->{backupRecursiveOptionsPanel}, -1, "Include subfolders" );
	$self->{backupSubSizer_staticbox} = Wx::StaticBox->new($self->{backupSubPanel}, -1, "Select folders to backup" );
	$self->{askAuthInfoSubHSizer_staticbox} = Wx::StaticBox->new($self->{askAuthInfoSubPanel}, -1, "Step 1: Get Authorization" );
	$self->{getTokenInfoSubHSizer_staticbox} = Wx::StaticBox->new($self->{getTokenInfoSubPanel}, -1, "Step 2: Check" );
	$self->{foldersListPanel} = Wx::ScrolledWindow->new($self->{backupSubPanel}, -1, wxDefaultPosition, wxDefaultSize, wxTAB_TRAVERSAL);


	# Menu Bar

	$self->{mainMenu} = Wx::MenuBar->new();
	my $wxglade_tmp_menu;
	$self->{File} = Wx::Menu->new();
	$self->{Login} = $self->{File}->Append(Wx::NewId(), "Login", "");
	$self->{Logout} = $self->{File}->Append(Wx::NewId(), "Logout", "");
	$self->{File}->AppendSeparator();
	$self->{Exit} = $self->{File}->Append(Wx::NewId(), "Exit", "");
	$self->{mainMenu}->Append($self->{File}, "File");
	$self->SetMenuBar($self->{mainMenu});

# Menu Bar end

	$self->{mainStatusBar} = $self->CreateStatusBar(2, 0);
	$self->{foldersList} = Wx::ListView->new($self->{foldersListPanel}, -1, wxDefaultPosition, wxDefaultSize, wxLC_LIST|wxSUNKEN_BORDER);
	$self->{browseDirNameButton} = Wx::Button->new($self->{backupSubPanel}, -1, "Add a new folder");
	$self->{RemoveButton} = Wx::Button->new($self->{backupSubPanel}, -1, "Remove selected folders");
	$self->{clearAllButton} = Wx::Button->new($self->{backupSubPanel}, -1, "Clear all");
	$self->{backupRecursiveOptionAll} = Wx::RadioButton->new($self->{backupRecursiveOptionsPanel}, -1, "All", wxDefaultPosition, wxDefaultSize, wxRB_GROUP|wxRB_USE_CHECKBOX);
	$self->{backupRecursiveOptionSome} = Wx::RadioButton->new($self->{backupRecursiveOptionsPanel}, -1, "Only if folder name ", wxDefaultPosition, wxDefaultSize, wxRB_USE_CHECKBOX);
	$self->{backupRecursiveOptionSomeChoiceName} = Wx::ComboBox->new($self->{backupRecursiveOptionsPanel}, -1, "", wxDefaultPosition, wxDefaultSize, ["is equal to", "constains", "start with", "end with"], wxCB_DROPDOWN|wxCB_DROPDOWN);
	$self->{backupRecursiveOptionSomeChoiceValue} = Wx::TextCtrl->new($self->{backupRecursiveOptionsPanel}, -1, "", wxDefaultPosition, wxDefaultSize, );
	$self->{backupRecursiveOptionNone} = Wx::RadioButton->new($self->{backupRecursiveOptionsPanel}, -1, "None (only files)", wxDefaultPosition, wxDefaultSize, wxRB_USE_CHECKBOX);
	$self->{start_button} = Wx::Button->new($self->{backupPanel}, -1, "Start");
	$self->{Close_button} = Wx::Button->new($self->{backupPanel}, -1, "Close");
	$self->{notebook_4_pane_2} = Wx::Panel->new($self->{backupNotebook}, -1, wxDefaultPosition, wxDefaultSize, );
	$self->{askAuthInfoLabel} = Wx::StaticText->new($self->{askAuthInfoSubPanel}, -1, "Go to your browser and give me permissions to acess to your acount", wxDefaultPosition, wxDefaultSize, wxALIGN_CENTRE);
	$self->{cancelAuthButton} = Wx::Button->new($self->{askAuthPanel}, -1, "Cancel");
	$self->{nextAuthButton} = Wx::Button->new($self->{askAuthPanel}, -1, "Get Auth...");
	$self->{getTokenInfoLabel} = Wx::StaticText->new($self->{getTokenInfoSubPanel}, -1, "Check the autorization. \n(Don't if you haven't give autorization in the browser)", wxDefaultPosition, wxDefaultSize, wxALIGN_CENTRE);
	$self->{cancelTokenButton} = Wx::Button->new($self->{getTokenPanel}, -1, "Cancel");
	$self->{nextTokenButton} = Wx::Button->new($self->{getTokenPanel}, -1, "Check...");

	$self->__set_properties();
	$self->__do_layout();

	Wx::Event::EVT_MENU($self, $self->{Login}->GetId, \&do_login);
	Wx::Event::EVT_MENU($self, $self->{Logout}->GetId, \&do_logout);
	Wx::Event::EVT_MENU($self, $self->{Exit}->GetId, \&do_exit);
	Wx::Event::EVT_LIST_BEGIN_DRAG($self, $self->{foldersList}->GetId, \&on_begin);
	Wx::Event::EVT_LIST_DELETE_ITEM($self, $self->{foldersList}->GetId, \&on_delete);
	Wx::Event::EVT_LIST_ITEM_SELECTED($self, $self->{foldersList}->GetId, \&on_selected);
	Wx::Event::EVT_BUTTON($self, $self->{browseDirNameButton}->GetId, \&do_browse);
	Wx::Event::EVT_BUTTON($self, $self->{RemoveButton}->GetId, \&do_remove_selected);
	Wx::Event::EVT_BUTTON($self, $self->{clearAllButton}->GetId, \&do_remove_all);
	Wx::Event::EVT_BUTTON($self, $self->{start_button}->GetId, \&do_backup);
	Wx::Event::EVT_BUTTON($self, $self->{Close_button}->GetId, \&do_close);
	Wx::Event::EVT_BUTTON($self, $self->{cancelAuthButton}->GetId, \&go_main);
	Wx::Event::EVT_BUTTON($self, $self->{nextAuthButton}->GetId, \&go_askAuth);
	Wx::Event::EVT_BUTTON($self, $self->{cancelTokenButton}->GetId, \&go_main);
	Wx::Event::EVT_BUTTON($self, $self->{nextTokenButton}->GetId, \&go_getToken);

# end wxGlade

	Wx::Event::EVT_CLOSE($self,sub{
			my ($self, $event) = @_;
			$stopThreads->();
			$syncDB->();
			print "Goodby";
			$event->Skip;
	});
	if($db->{currentUser} ne ''
	   	and defined $db->{users}->{$db->{currentUser}}
	   	and defined $db->{users}->{$db->{currentUser}}->{flickr}
	  	and defined $db->{users}->{$db->{currentUser}}->{flickr}->{usr}
	   	and defined $db->{users}->{$db->{currentUser}}->{flickr}->{usr}->{auth_token}){
		$self->__showMainPanel();
		$self->__setStatus();
		$self->__fillFoldersList();
	}else{
		$self->__showLoginPanel();
		$self->SetStatusText('The user is not yet authorized',0);
	}
  return $self;
}


sub __set_properties {
    my $self = shift;
# begin wxGlade: MyFrame::__set_properties

	$self->SetTitle("Disk2Flickr");
	$self->SetSize(Wx::Size->new(550, 380));
	$self->{mainStatusBar}->SetStatusWidths(-1,0);

	my( @mainStatusBar_fields ) = (
		"User Status",
		""
	);

	if( @mainStatusBar_fields ) {
		$self->{mainStatusBar}->SetStatusText($mainStatusBar_fields[$_], $_)
		for 0 .. $#mainStatusBar_fields ;
	}
	$self->{foldersListPanel}->SetScrollRate(10, 10);
	$self->{backupRecursiveOptionSomeChoiceName}->SetSelection(-1);
	$self->{mainPanel}->SetScrollRate(10, 10);
	$self->{askAuthInfoSubPanel}->SetScrollRate(10, 10);
	$self->{loginPanel}->Show(0);
	$self->{loginPanel}->SetScrollRate(10, 10);

# end wxGlade
}

sub __do_layout {
    my $self = shift;
# begin wxGlade: MyFrame::__do_layout

	$self->{mainSizer} = Wx::BoxSizer->new(wxVERTICAL);
	$self->{loginPanelSizer} = Wx::BoxSizer->new(wxVERTICAL);
	$self->{getTokenSizer} = Wx::BoxSizer->new(wxVERTICAL);
	$self->{getTokenControlSizer} = Wx::BoxSizer->new(wxHORIZONTAL);
	$self->{getTokenInfoSubHSizer}= Wx::StaticBoxSizer->new($self->{getTokenInfoSubHSizer_staticbox}, wxVERTICAL);
	$self->{getTokenInfoSubVSizer} = Wx::BoxSizer->new(wxHORIZONTAL);
	$self->{askAuthSizer} = Wx::BoxSizer->new(wxVERTICAL);
	$self->{askAuthControlSizer} = Wx::BoxSizer->new(wxHORIZONTAL);
	$self->{askAuthInfoSubHSizer}= Wx::StaticBoxSizer->new($self->{askAuthInfoSubHSizer_staticbox}, wxVERTICAL);
	$self->{askAuthInfoSubVSizer} = Wx::BoxSizer->new(wxHORIZONTAL);
	$self->{mainPainelSizer} = Wx::BoxSizer->new(wxHORIZONTAL);
	$self->{backupSizer} = Wx::BoxSizer->new(wxVERTICAL);
	$self->{mainControlHSizer} = Wx::BoxSizer->new(wxVERTICAL);
	$self->{mainControlVSizer} = Wx::BoxSizer->new(wxHORIZONTAL);
	$self->{backupSubSizer}= Wx::StaticBoxSizer->new($self->{backupSubSizer_staticbox}, wxVERTICAL);
	$self->{backupRecursiveOptionsSizer}= Wx::StaticBoxSizer->new($self->{backupRecursiveOptionsSizer_staticbox}, wxVERTICAL);
	$self->{backupRecursiveOptionSomeSizer} = Wx::BoxSizer->new(wxHORIZONTAL);
	$self->{foldersControlSizer} = Wx::BoxSizer->new(wxHORIZONTAL);
	$self->{foldersListSizer} = Wx::BoxSizer->new(wxVERTICAL);
	$self->{foldersListSizer}->Add($self->{foldersList}, 1, wxEXPAND, 0);
	$self->{foldersListPanel}->SetSizer($self->{foldersListSizer});
	$self->{backupSubSizer}->Add($self->{foldersListPanel}, 1, wxEXPAND, 0);
	$self->{foldersControlSizer}->Add($self->{browseDirNameButton}, 0, 0, 0);
	$self->{foldersControlSizer}->Add($self->{RemoveButton}, 0, 0, 0);
	$self->{foldersControlSizer}->Add($self->{clearAllButton}, 0, 0, 0);
	$self->{backupSubSizer}->Add($self->{foldersControlSizer}, 0, wxALIGN_CENTER_HORIZONTAL, 0);
	$self->{backupRecursiveOptionsSizer}->Add($self->{backupRecursiveOptionAll}, 0, 0, 0);
	$self->{backupRecursiveOptionSomeSizer}->Add($self->{backupRecursiveOptionSome}, 0, wxALIGN_CENTER_VERTICAL, 0);
	$self->{backupRecursiveOptionSomeSizer}->Add($self->{backupRecursiveOptionSomeChoiceName}, 0, 0, 0);
	$self->{backupRecursiveOptionSomeSizer}->Add($self->{backupRecursiveOptionSomeChoiceValue}, 0, 0, 0);
	$self->{backupRecursiveOptionsSizer}->Add($self->{backupRecursiveOptionSomeSizer}, 1, wxEXPAND, 0);
	$self->{backupRecursiveOptionsSizer}->Add($self->{backupRecursiveOptionNone}, 0, 0, 0);
	$self->{backupRecursiveOptionsPanel}->SetSizer($self->{backupRecursiveOptionsSizer});
	$self->{backupSubSizer}->Add($self->{backupRecursiveOptionsPanel}, 0, wxTOP|wxEXPAND, 2);
	$self->{backupSubPanel}->SetSizer($self->{backupSubSizer});
	$self->{backupSizer}->Add($self->{backupSubPanel}, 1, wxEXPAND, 0);
	$self->{mainControlVSizer}->Add($self->{start_button}, 0, 0, 0);
	$self->{mainControlVSizer}->Add(20, 1, 0, 0, 0);
	$self->{mainControlVSizer}->Add($self->{Close_button}, 0, 0, 0);
	$self->{mainControlHSizer}->Add($self->{mainControlVSizer}, 0, wxTOP|wxALIGN_CENTER_HORIZONTAL, 10);
	$self->{backupSizer}->Add($self->{mainControlHSizer}, 0, wxALIGN_CENTER_HORIZONTAL, 0);
	$self->{backupPanel}->SetSizer($self->{backupSizer});
	$self->{backupNotebook}->AddPage($self->{backupPanel}, "Backup");
	$self->{backupNotebook}->AddPage($self->{notebook_4_pane_2}, "Help");
	$self->{mainPainelSizer}->Add($self->{backupNotebook}, 1, wxEXPAND, 0);
	$self->{mainPanel}->SetSizer($self->{mainPainelSizer});
	$self->{mainSizer}->Add($self->{mainPanel}, 1, wxEXPAND, 0);
	$self->{askAuthInfoSubVSizer}->Add($self->{askAuthInfoLabel}, 0, wxALL|wxALIGN_CENTER_VERTICAL, 2);
	$self->{askAuthInfoSubHSizer}->Add($self->{askAuthInfoSubVSizer}, 1, wxALIGN_CENTER_HORIZONTAL, 0);
	$self->{askAuthInfoSubPanel}->SetSizer($self->{askAuthInfoSubHSizer});
	$self->{askAuthSizer}->Add($self->{askAuthInfoSubPanel}, 5, wxEXPAND, 0);
	$self->{askAuthControlSizer}->Add($self->{cancelAuthButton}, 0, wxALIGN_CENTER_HORIZONTAL, 0);
	$self->{askAuthControlSizer}->Add(20, 1, 0, 0, 0);
	$self->{askAuthControlSizer}->Add($self->{nextAuthButton}, 0, wxALIGN_CENTER_HORIZONTAL, 0);
	$self->{askAuthSizer}->Add($self->{askAuthControlSizer}, 1, wxTOP|wxALIGN_CENTER_HORIZONTAL, 5);
	$self->{askAuthPanel}->SetSizer($self->{askAuthSizer});
	$self->{loginPanelSizer}->Add($self->{askAuthPanel}, 1, wxEXPAND, 0);
	$self->{getTokenInfoSubVSizer}->Add($self->{getTokenInfoLabel}, 0, wxALL|wxALIGN_CENTER_VERTICAL, 2);
	$self->{getTokenInfoSubHSizer}->Add($self->{getTokenInfoSubVSizer}, 1, wxALIGN_CENTER_HORIZONTAL, 0);
	$self->{getTokenInfoSubPanel}->SetSizer($self->{getTokenInfoSubHSizer});
	$self->{getTokenSizer}->Add($self->{getTokenInfoSubPanel}, 5, wxEXPAND, 0);
	$self->{getTokenControlSizer}->Add($self->{cancelTokenButton}, 0, wxALIGN_CENTER_HORIZONTAL, 0);
	$self->{getTokenControlSizer}->Add(20, 1, 0, 0, 0);
	$self->{getTokenControlSizer}->Add($self->{nextTokenButton}, 0, wxALIGN_CENTER_HORIZONTAL, 0);
	$self->{getTokenSizer}->Add($self->{getTokenControlSizer}, 1, wxTOP|wxALIGN_CENTER_HORIZONTAL, 5);
	$self->{getTokenPanel}->SetSizer($self->{getTokenSizer});
	$self->{loginPanelSizer}->Add($self->{getTokenPanel}, 1, wxEXPAND, 0);
	$self->{loginPanel}->SetSizer($self->{loginPanelSizer});
	$self->{mainSizer}->Add($self->{loginPanel}, 2, wxEXPAND, 0);
	$self->SetSizer($self->{mainSizer});
	$self->Layout();

# end wxGlade
}


sub do_login {
	my ($self, $event) = @_;
	$self->__showLoginPanel();
  $event->Skip;
# wxGlade: MyFrame::do_login <event_handler>

	warn "Event handler (do_login) not implemented";
	$event->Skip;

# end wxGlade
}


sub do_logout {
	my ($self, $event) = @_;
	$removeUser->();
	$syncDB->();
	$self->__showLoginPanel();
	$self->SetStatusText('The user is not authorized anymore',0);
	return $event->Skip;
# wxGlade: MyFrame::do_logout <event_handler>

	warn "Event handler (do_logout) not implemented";
	$event->Skip;

# end wxGlade
}


sub do_exit {
	my ($self, $event) = @_;
	$self->Close;
	return $event->Skip;
# wxGlade: MyFrame::do_exit <event_handler>
	warn "Event handler (do_exit) not implemented";
	$event->Skip;

# end wxGlade
}


sub on_begin {
	my ($self, $event) = @_;
# wxGlade: MyFrame::on_begin <event_handler>

	warn "Event handler (on_begin) not implemented";
	$event->Skip;

# end wxGlade
}


sub on_delete {
	my ($self, $event) = @_;
# wxGlade: MyFrame::on_delete <event_handler>

	warn "Event handler (on_delete) not implemented";
	$event->Skip;

# end wxGlade
}


sub on_selected {
	my ($self, $event) = @_;
# wxGlade: MyFrame::on_selected <event_handler>

	warn "Event handler (on_selected) not implemented";
	$event->Skip;

# end wxGlade
}

my $lastDirectory = "";
sub do_browse {
	my ($self, $event) = @_;
	my $dlg = Wx::DirDialog->new(
	  $self->{backupSubPanel},
	  "Please, choose a folder to backup",
	  $lastDirectory,
	  wxDD_CHANGE_DIR|wxDD_DIR_MUST_EXIST
	);
	if ($dlg->ShowModal == wxID_OK){
		$lastDirectory = $dlg->GetPath();
		my $p = $self->{foldersList}->GetItemCount;
		$self->{foldersList}->InsertStringItem($p,$lastDirectory);
		$db->{users}->{$db->{currentUser}}->{folders}->{$lastDirectory} = time;
	}
	return $event->Skip;
# wxGlade: MyFrame::do_browse <event_handler>

	warn "Event handler (do_browse) not implemented";
	$event->Skip;

# end wxGlade
}


sub do_remove_selected {
	my ($self, $event) = @_;
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


# wxGlade: MyFrame::do_remove_selected <event_handler>
	warn "Event handler (do_remove_selected) not implemented";
	$event->Skip;

# end wxGlade
}


sub do_remove_all {
	my ($self, $event) = @_;
	$self->{foldersList}->ClearAll;
	$db->{users}->{$db->{currentUser}}{folders} = {};
	return $event->Skip;

# wxGlade: MyFrame::do_remove_all <event_handler>

	warn "Event handler (do_remove_all) not implemented";
	$event->Skip;

# end wxGlade
}


sub do_backup {
	my ($self, $event) = @_;
	unless(defined $flickr->{user} and defined $flickr->{user}->{nsid}){
		print "User not login";
		return $self->do_login($event);
	}
	my $count = $self->{foldersList}->GetItemCount;
	my $i = 0;
	while($i < $count){
		print $self->{foldersList}->GetItemText($i);
		#$getFolder->($self->{foldersList}->GetItemText($i++));
		$foldersQ->enqueue($self->{foldersList}->GetItemText($i++));
	}
	return $event->Skip;
# wxGlade: MyFrame::do_backup <event_handler>

	warn "Event handler (do_backup) not implemented";
	$event->Skip;

# end wxGlade
}


sub do_close {
	my ($self, $event) = @_;
	$self->Close;
	return $event->Skip;
# wxGlade: MyFrame::do_close <event_handler>

	warn "Event handler (do_close) not implemented";
	$event->Skip;

# end wxGlade
}


sub go_main {
	my ($self, $event) = @_;
	$self->__showMainPanel();
	return $event->Skip;
# wxGlade: MyFrame::go_main <event_handler>

	warn "Event handler (go_main) not implemented";
	$event->Skip;

# end wxGlade
}


sub go_askAuth {
	my ($self, $event) = @_;
	$flickr->askAuth() or carp q|ask auth error|;
	$self->__showCheckTokenPanel();
  return  $event->Skip;
# wxGlade: MyFrame::go_askAuth <event_handler>

	warn "Event handler (go_askAuth) not implemented";
	$event->Skip;

# end wxGlade
}


sub go_getToken {
	my ($self, $event) = @_;
	print 'Get token...';
	$flickr->getToken() or return $self-> __showAskAuthPanel();
	$self->__showMainPanel();
	$loadUser->();
	$self->__setStatus();
	return $event->Skip;
# wxGlade: MyFrame::go_getToken <event_handler>

	warn "Event handler (go_getToken) not implemented";
	$event->Skip;

# end wxGlade
}

# end of class MyFrame

1;

