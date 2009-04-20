#!/usr/bin/perl

use warnings;
use strict;

use CPANPLUS::Backend;
use Cwd;

BEGIN {
    eval { require CPANPLUS::Dist::Arch; }
        or die 'CPANPLUS::Dist::Arch must be installed for this script to work.'
}

my $cb      = CPANPLUS::Backend->new;
my $destdir = getcwd;

MODULE_ARG:
while ( my $module = shift @ARGV ) {
    my $modobj = $cb->module_tree( $module )
        or next MODULE_ARG;

    $modobj->install( target  => 'create',
                      format  => 'CPANPLUS::Dist::Arch',
                      verbose => 1,
                      pkg     => 'src',
                      destdir => $destdir );
}
