package MyLogic;
use base qw(MyFrame);
use strict;

sub new {
    my( $self) = @_;

    $self = $self->SUPER::new();
	return $self;
}
sub do_logout{
    my ($self, $event) = @_;
	print "do_logout\n\n----------------\n";
    #$event->Skip;
    # end wxGlade
}
1;