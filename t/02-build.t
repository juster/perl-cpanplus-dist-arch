#!/usr/bin/perl

use warnings;
use strict;

use Test::More;
use CPANPLUS::Backend;
use CPANPLUS::Dist::Arch;

sub TEST_MODULE_NAME() { 'Acme::Bleach' };

plan skip_all => 'build testing requires pacman & makepkg installed'
    unless ( CPANPLUS::Dist::Arch::format_available );

plan tests => 4;

diag 'Testing package building with the '.TEST_MODULE_NAME.' module';

my $cb;
ok( $cb = CPANPLUS::Backend->new,
    q{load a CPANPLUS::Backend object} );
ok( $cb->configure_object->set_conf( 'dist_type', 'CPANPLUS::Dist::Arch' ),
    q{set dist_type to CPANPLUS::Dist::Arch'} );

my $test_mod;
ok( $test_mod = $cb->module_tree( TEST_MODULE_NAME ),
    q{load } . TEST_MODULE_NAME . q{'s module tree} );

ok( $test_mod->create, 'create module package' );
