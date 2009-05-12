#!/usr/bin/perl

use warnings;
use strict;

use CPANPLUS::Backend;
use Getopt::Long;
use Pod::Usage;
use English '-no_match_vars';

BEGIN {
    eval { require CPANPLUS::Dist::Arch; }
        or die 'CPANPLUS::Dist::Arch must be installed for this script to work.'
}

my $force;
GetOptions( force => \$force ); # must be before messing with @ARGV

my $modname = shift @ARGV or pod2usage;

# Check if a PKGBUILD already exists...
die << 'END_ERROR' if ( -f 'PKGBUILD' && !$force );
PKGBUILD already exists in current directory.  Use -f to force overwrite.
END_ERROR

my $cb      = CPANPLUS::Backend->new;
my $modobj  = $cb->module_tree($modname)
    or die qq{module '$modname' not found in CPANPLUS};

# Try to avoid interactive requests...
$cb->configure_object->set_conf( 'prereqs', 0 );
$ENV{PERL_AUTOINSTALL} = '--skipdeps';

# Prepare the package, but don't install it...
$modobj->fetch  ( verbose => 0 );
$modobj->extract( verbose => 0 );
my $distobj = $modobj->dist( target => 'prepare',
                             format => 'CPANPLUS::Dist::Arch' )
    or die q{failed to prepare distribution object};

# Get the PKGBUILD from CPANPLUS::Dist::Arch and print to a file...
my $pkgbuild_txt = $distobj->get_pkgbuild()
    or die q{ERROR get_pkgbuild() returned an empty string};

open my $pkgbuild_file, '>', 'PKGBUILD'
    or die qq{ERROR creating PKGBUILD: $OS_ERROR};
print $pkgbuild_file $pkgbuild_txt;
close $pkgbuild_file
    or die qq{ERROR closing new PKGBUILD: $OS_ERROR};

print "Created PKGBUILD.\n";

exit 0;

__END__

=head1 NAME

cpanpkgbuild.pl - Create a PKGBUILD file for a perl module

=head1 SYNOPSIS

cpanpkgbuild.pl [-f] DBD::SQLite

Will create a PKGBUILD in the current directory for DBD::SQLite.  Then
use your favorite editor to customize PKGBUILD, run makepkg on it,
etc. etc.  The -f or -force flag forces overwriting any existing PKGBUILD.

=head1 AUTHOR

Justin Davis, C<< <jrcd83 at gmail.com> >>, juster on
L<http://bbs.archlinux.org>

=head1 COPYRIGHT & LICENSE

Copyright 2009 Justin Davis, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
