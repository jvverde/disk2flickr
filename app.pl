#!/usr/bin/perl -w -- 
#
# generated by wxGlade 0.6.8 (standalone edition) on Mon Nov 04 22:21:16 2013
#
# To get wxPerl visit http://wxPerl.sourceforge.net/
#

# This is an automatically generated file.
# Manual changes will be overwritten without warning!

use Wx 0.15 qw[:allclasses];
use strict;
package MyApp;

use base qw(Wx::App);
use strict;

use MyFrame;

sub OnInit {
    my( $self ) = shift;

    Wx::InitAllImageHandlers();

    my $frame = MyFrame->new();

    $self->SetTopWindow($frame);
    $frame->Show(1);

    return 1;
}
# end of class MyApp

package main;

unless(caller){
    my $app = MyApp->new();
    $app->MainLoop();
}
