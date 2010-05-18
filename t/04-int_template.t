#!/usr/bin/perl

use warnings;
use strict;
use Test::More tests => 10;

sub make_inc_hook
{
    return sub {
        my (undef, $modfile) = @_;

        return 0 unless ( $modfile =~ m{\ATemplate} );

        my $done;
        $modfile =~ s{.pm\z}{};
        $modfile =~ s{/}{::}g;

        return sub {
            return 0 if $done;
            $_ = qq{package $modfile; 0;};
            return $done = 1;
        }
    };
}

BEGIN {
    unshift @INC, make_inc_hook();

    # The ::Test class is under out test directory.
    use lib qw(t/lib);
    use_ok( 'CPANPLUS::Dist::Arch::Test' );
}

my $cda_obj = CPANPLUS::Dist::Arch::Test->new( name    => 'CDA-Template',
                                               version => '0.01' );

# Test our builtin template engine.  Make sure [%- and -%] works...
is $cda_obj->get_tt_module, 0,
    'We are using our internal template engine.';

$cda_obj->set_pkgbuild_templ( '[%- pkgname -%]' );
is $cda_obj->get_pkgbuild, 'perl-cda-template',
    q{[%-'s and -%]'s work with our internal template engine};

$cda_obj->set_pkgbuild_templ( '[% pkgname %]' );
is $cda_obj->get_pkgbuild, 'perl-cda-template',
    q{[%'s and %]'s work with our internal template engine};


# TEST WHITESPACE
##############################################################################

ok $cda_obj->set_pkgbuild_templ( <<'END_TEMPL' );
[% IF pkgname -%]
GOOD[% END %]

END_TEMPL
is $cda_obj->get_pkgbuild, "GOOD\n";

ok $cda_obj->set_pkgbuild_templ( <<'END_TEMPL' );
[% IF pkgname -%]
GOOD
[% END %]

END_TEMPL
is $cda_obj->get_pkgbuild, "GOOD\n\n";

ok $cda_obj->set_pkgbuild_templ( <<'END_TEMPL' );
[% IF pkgname -%]GOOD
[% END %]
END_TEMPL
is $cda_obj->get_pkgbuild, "GOOD\n";
