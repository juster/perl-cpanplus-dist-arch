#!perl -T

use warnings;
use strict;

use Test::More tests => 20;

use CPANPLUS::Dist::Arch qw( dist_pkgname dist_pkgver );

my %pkgname_of =
    ( '-Crazy-CPAN_Name-'  => 'perl-crazy-cpan-name',
      'AT-END-IS-PERL'    => 'at-end-is-perl',
      'Perl-At-Beginning' => 'perl-at-beginning',
      'Middle-Perl-Here'  => 'perl-middle-perl-here',

      'crazy~!@#$%^&*()_+{}|/\<>:"/' => 'perl-crazy',
      'Many-!!-$$-Hyphens'           => 'perl-many-hyphens',
      '-!_?-Leading-Hyphens'         => 'perl-leading-hyphens',

      # Make sure real names work, too...
      'CPANPLUS-Dist-Arch'       => 'perl-cpanplus-dist-arch',
      'SWIFT-Factory-Tag-Tag17A' => 'perl-swift-factory-tag-tag17a',
      'Data-Dumper'              => 'perl-data-dumper',

      # Test overridden names
      'libwww-perl'       => 'perl-libwww',
      'mod_perl'          => 'mod_perl',
      'glade-perl-two'    => 'perl-glade-two',
      'aceperl'           => 'perl-ace',

      'perl'              => 'perl',
     );

for my $cpan_name ( keys %pkgname_of ) {
    is( dist_pkgname($cpan_name),
        $pkgname_of{$cpan_name},
        "CPAN to pacman name translation of $cpan_name" );
}

my %pkgver_of =
    ( '1234-5678'  => '1234.5678',
      '!1_@23-45'  => '1.23.45',
      '98 65 AB.2' => '9865AB.2',
      '1~!@#$%^&*() _ 2+= - 3\][{}|;":, . 4/?><' => '1.2.3.4',
      '1234-ABCDE.fghi' => '1234.ABCDE.fghi',
     );

for my $cpan_ver ( keys %pkgver_of ) {
    is( dist_pkgver($cpan_ver),
        $pkgver_of{$cpan_ver},
        "CPAN to pacman version translation of $cpan_ver" );
}
