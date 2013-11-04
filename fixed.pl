$self->{foldersList} = Wx::ListView->new($self->{foldersListPanel}, -1, wxDefaultPosition, wxDefaultSize, wxLC_LIST|wxSUNKEN_BORDER);
Wx::Event::EVT_MENU($self, $self->{Login}, \&do_login);
Wx::Event::EVT_MENU($self, $self->{Logout}, \&do_logout);
Wx::Event::EVT_MENU($self, $self->{Exit}, \&do_exit);
