#!/usr/bin/perl

use warnings;
use strict;

use Test::More;
use CPANPLUS::Backend;
use CPANPLUS::Dist::Arch;
use Net::Ping;

my $TEST_MODULE =  'Acme::Bleach';

plan skip_all => 'build testing requires pacman & makepkg installed'
    unless ( CPANPLUS::Dist::Arch::format_available );

my $p = Net::Ping->new();
plan skip_all => 'must be able to connect to CPAN for these tests'
    unless ( $p->ping( 'cpan.org' ));
$p->close();

plan tests => 5;

diag "Downloading and packaging the $TEST_MODULE module";

my $cb;
ok( $cb = CPANPLUS::Backend->new,
    q{load a CPANPLUS::Backend object} );

# ok( $cb->configure_object->set_conf( 'dist_type', 'CPANPLUS::Dist::Arch' ),
#     q{set dist_type to CPANPLUS::Dist::Arch'} );

my $test_mod;
ok( $test_mod = $cb->module_tree( $TEST_MODULE ),
    qq{load ${TEST_MODULE}'s module tree} );

ok $test_mod->install( target  => 'create',
                       format  => 'CPANPLUS::Dist::Arch',
                       destdir => '/tmp' ),
    'create module package';

my $pkg_fqp = $test_mod->status->dist->get_pkgpath;
ok( -e $pkg_fqp, 'package was created' );
ok unlink $pkg_fqp;
