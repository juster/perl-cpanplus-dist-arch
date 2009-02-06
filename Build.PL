use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name         => 'CPANPLUS::Dist::Arch',
    license             => 'perl',
    dist_author         => 'Justin Davis <jrcd83@gmail.com>',
    dist_version_from   => 'lib/CPANPLUS/Dist/Arch.pm',
    build_requires => {
        'Test::More' => 0,
    },
    add_to_cleanup      => [ 'CPANPLUS-Dist-Arch-*' ],
    create_makefile_pl => 'traditional',
);

$builder->create_build_script();
