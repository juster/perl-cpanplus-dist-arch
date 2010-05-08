#!/usr/bin/perl

use warnings;
use strict;

use CPANPLUS::Dist::Arch qw(:all);
use CPANPLUS::Backend    qw();
use Module::CoreList     qw();
use Capture::Tiny        qw(capture);
use ALPM                 qw(/etc/pacman.conf);

my @repodbs = map { ALPM->db( $_ ) } qw/ core extra community /;
my $be      = CPANPLUS::Backend->new();
$be->configure_object->set_conf( 'prereqs', 0 );
$ENV{PERL_AUTOINSTALL} = '--skipdeps';

# Checks if a package is provided by [core] or [extra] or [community].
# TODO: check the AUR too? see if there's a package uploaded already?
sub aur_needs_pkg
{
    my $pkg_name = dist_pkgname( shift );
    for my $db ( @repodbs ) {
        if ( $db->find( $pkg_name ) ) {
            warn "$pkg_name is in the [${\$db->name}] repo\n";
            return 0;
        }
    }

    return 1;
}

my $corelist = $Module::CoreList::version{ 0+$] };
my %is_checked;

# Desc   : Filters out modules which are available to pacman.
# Params : The module name to filter along with its dependencies.
# Returns: A list of modules someone might want to upload to AUR.
sub aur_needed_deps
{
    my $mod_name = shift;
    return () if exists $corelist->{ $mod_name };
    return () if $is_checked{ $mod_name }++;

    warn "Looking up $mod_name...\n";
    my $mod_obj  = $be->module_tree( $mod_name )
        or die "Could not find module: $mod_name";

    capture { $mod_obj->prepare };
    my @dep_names = keys %{ $mod_obj->status->prereqs };

    return ( ( aur_needs_pkg( $mod_obj->package_name ) ? $mod_name : () ),
             ( map { aur_needed_deps( $_ ) } @dep_names )
            );
}

my $modname = shift @ARGV
    or die <<"END_USAGE";
Usage: $0 [module name]
  List all of the dependencies of a module that are not already packaged.
  Oh and do that recursively.  Include the module, too.
END_USAGE

my %seen;
print map  { $_, "\n" } sort grep { ! $seen{$_}++ }
    aur_needed_deps( $modname );

    
